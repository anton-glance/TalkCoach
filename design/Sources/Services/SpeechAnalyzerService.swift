//
//  SpeechAnalyzerService.swift
//  TalkingCoach
//
//  Wraps the macOS 26+ `SpeechAnalyzer` + `SpeechTranscriber` framework.
//  Drives `WidgetState` based on live speech.
//
//  Pipeline:
//      AVAudioEngine input  →  SpeechTranscriber  →  word stream
//                                                     ↓
//                                              PaceCalculator
//                                              FillerDetector
//                                                     ↓
//                                              @Published WidgetState
//
//  Threading: speech work runs on a dedicated `Task`; published state is
//  republished on @MainActor before observers see it.
//
//  Apple references:
//      • https://developer.apple.com/documentation/speech/speechanalyzer
//      • https://developer.apple.com/videos/play/wwdc2025/277/
//
//  NOTE for the implementing agent:
//  The `SpeechAnalyzer` API surface evolves between macOS 26.0 and 26.x.
//  Confirm exact module/class names against current docs before merging.
//  The skeleton below is shaped for the WWDC25 design (SpeechTranscriber
//  module; async result stream).
//

import Foundation
import AVFoundation
import Speech
import Combine

@MainActor
final class SpeechAnalyzerService: ObservableObject {

    // MARK: - Public state (read by views)

    @Published private(set) var widgetState = WidgetState()

    // MARK: - Authorization

    enum AuthState {
        case unknown, requesting, authorized, denied
    }
    @Published private(set) var authState: AuthState = .unknown

    // MARK: - Lifecycle

    private let audioEngine = AVAudioEngine()
    private var transcriberTask: Task<Void, Never>?
    private var pace = PaceCalculator()
    private var fillers = FillerDetector()
    private var sessionStart: Date?

    // MARK: - Public API

    func bootstrap() async {
        authState = .requesting
        let micGranted = await requestMicrophone()
        let speechGranted = await requestSpeech()
        authState = (micGranted && speechGranted) ? .authorized : .denied
    }

    func startListening() async {
        guard authState == .authorized else { return }
        guard !audioEngine.isRunning else { return }

        do {
            try configureAudioEngine()
            try audioEngine.start()
            sessionStart = Date()
            pace.reset()
            fillers.reset()
            widgetState.isMicActive = true
            startTranscription()
            startPaceTimer()
        } catch {
            // Surface to a future error pipeline; for v1 just log.
            print("[TalkingCoach] startListening failed: \(error)")
            widgetState.isMicActive = false
        }
    }

    func stopListening() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        transcriberTask?.cancel()
        transcriberTask = nil
        sessionStart = nil
        widgetState.isMicActive = false
    }

    // MARK: - Audio capture

    private func configureAudioEngine() throws {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            // Forward buffer to the transcriber. With SpeechAnalyzer/SpeechTranscriber
            // the recommended flow is to push buffers into the transcription input
            // stream — see the framework docs for the current API.
            self?.feedTranscriber(buffer: buffer, time: time)
        }
        audioEngine.prepare()
    }

    private func feedTranscriber(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        // Implementation note: SpeechAnalyzer accepts AVAudioPCMBuffers via its
        // input handler. Pass buffer along to the active analyzer instance.
        // Concretely: `analyzer.analyzeAudioBuffer(buffer)` (verify exact name).
    }

    // MARK: - Transcription

    private func startTranscription() {
        transcriberTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }

            // Pseudocode for the WWDC25 SpeechTranscriber pattern:
            //
            //     let transcriber = try SpeechTranscriber(locale: .current,
            //                                             options: [.onDevice])
            //     let analyzer = try SpeechAnalyzer(modules: [transcriber])
            //     for try await result in transcriber.results {
            //         for word in result.words {
            //             await self.ingest(word: word.text,
            //                               at: word.timestamp)
            //         }
            //     }
            //
            // Replace with the current API once verified against docs.
        }
    }

    /// Called from the transcription stream for each finalized word.
    private func ingest(word raw: String, at timestamp: TimeInterval) async {
        let normalized = raw
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { !$0.isPunctuation }
        guard !normalized.isEmpty else { return }

        pace.append(timestamp: timestamp)
        let isFiller = fillers.observe(word: normalized)

        // We don't need to update WPM on every word (timer handles that),
        // but we do need to refresh fillers immediately when one is hit.
        if isFiller {
            await refreshFillers()
        }
    }

    // MARK: - Pace timer

    private var paceTimerTask: Task<Void, Never>?

    private func startPaceTimer() {
        paceTimerTask?.cancel()
        paceTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(DesignTokens.Pace.currentWPMRecomputeInterval))
                await self?.refreshPace()
            }
        }
    }

    private func refreshPace() async {
        let now = Date()
        let current = pace.currentWPM(now: now)
        let avg = pace.averageWPM(sessionStart: sessionStart ?? now, now: now)
        widgetState.currentWPM = Int(current.rounded())
        widgetState.averageWPM = Int(avg.rounded())
    }

    private func refreshFillers() async {
        widgetState.topFillers = fillers.topN(DesignTokens.Fillers.topNToShow)
            .map { FillerEntry(word: $0.key, count: $0.value) }
    }

    // MARK: - Authorization

    private func requestMicrophone() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                cont.resume(returning: granted)
            }
        }
    }

    private func requestSpeech() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }
}

// MARK: - Pace calculator

struct PaceCalculator {
    /// Timestamps (relative to `Date()`) at which words occurred.
    private var timestamps: [Date] = []

    mutating func reset() { timestamps.removeAll() }

    mutating func append(timestamp: TimeInterval) {
        timestamps.append(Date(timeIntervalSinceReferenceDate: timestamp))
    }

    /// Words in trailing window × scale. Returns 0 if no words yet.
    func currentWPM(now: Date) -> Double {
        let window = DesignTokens.Pace.currentWPMWindowSeconds
        let cutoff = now.addingTimeInterval(-window)
        let count = timestamps.filter { $0 >= cutoff }.count
        guard count > 0 else { return 0 }
        return Double(count) * (60.0 / window)
    }

    /// Total words / minutes since session start.
    func averageWPM(sessionStart: Date, now: Date) -> Double {
        let minutes = max(now.timeIntervalSince(sessionStart) / 60.0, 1.0/60.0)
        return Double(timestamps.count) / minutes
    }
}

// MARK: - Filler detector

struct FillerDetector {
    private var counts: [String: Int] = [:]

    mutating func reset() { counts.removeAll() }

    /// Returns true if the word was a filler (and the count was incremented).
    @discardableResult
    mutating func observe(word: String) -> Bool {
        guard DesignTokens.Fillers.words.contains(word) else { return false }
        counts[word, default: 0] += 1
        return true
    }

    /// Top N filler entries, descending by count, alphabetical tie-break.
    func topN(_ n: Int) -> [(key: String, value: Int)] {
        counts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .prefix(n)
            .map { ($0.key, $0.value) }
    }
}
