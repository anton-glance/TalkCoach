import Combine
import Foundation
import OSLog

/// Sliding-window WPM calculator driven by wall-clock token arrivals and Silero VAD events.
///
/// Ships two variants simultaneously for live A/B evaluation (S6 smoke gate):
///   wpmRaw    — words / (10s fixed denominator) — WPM-A
///   wpmVoiced — words / (voiced-seconds denominator) — WPM-B
///
/// Both go nil together when data is below the minimum floor.
@MainActor
final class WPMCalculator: TokenConsumer {

    // MARK: - Private types

    private struct LatestSnapshot {
        let wordCount: Int
        let arrivedAt: Date
    }

    private struct VoiceInterval {
        let start: Date
        var end: Date?
    }

    // MARK: - Constants

    static let windowSeconds: TimeInterval = 10.0
    static let minWordsForReading: Int = 3
    static let minVoicedSecondsForReading: TimeInterval = 2.0
    static let engineReadyGracePeriod: TimeInterval = 0.5

    // MARK: - Dependencies

    private let settings: SettingsStore
    private let scheduler: any HideScheduler
    private let now: () -> Date

    // MARK: - Session state

    /// Non-nil only while a session is active. nil = post-teardown guard armed.
    private var engineReadyCutoff: Date?
    /// The most-recent token's word count. Replaced (not appended) on each hop.
    private var latestSnapshot: LatestSnapshot?
    private var voiceIntervals: [VoiceInterval] = []
    private var currentSpeechStart: Date?
    private var refreshToken: HideSchedulerToken?
    /// true from sessionActivated() until sessionEnded(); guards notifyVADEvent.
    private var isActive = false

    // MARK: - Published output

    @Published private(set) var wpmRaw: Int?
    @Published private(set) var wpmVoiced: Int?

    // MARK: - Init

    init(
        settings: SettingsStore,
        scheduler: any HideScheduler,
        now: @escaping () -> Date = { Date() }
    ) {
        self.settings = settings
        self.scheduler = scheduler
        self.now = now
    }

    // MARK: - Session lifecycle

    /// Call when session wiring starts, before the first notifyVADEvent can fire.
    /// Arms VAD recording from session start, independently of Parakeet engine-ready.
    func sessionActivated() {
        isActive = true
    }

    /// Call when the transcription engine signals it is ready.
    /// Discards any tokens that arrive before `readyTime + engineReadyGracePeriod`.
    func engineReadyFired(at readyTime: Date) {
        isActive = true  // belt-and-suspenders if sessionActivated() was not called first
        let prevWords = latestSnapshot?.wordCount ?? 0
        engineReadyCutoff = readyTime.addingTimeInterval(Self.engineReadyGracePeriod)
        latestSnapshot = nil
        // voiceIntervals and currentSpeechStart intentionally preserved:
        // VAD events from session start are valid; voicedSecondsInWindow clips to engineReadyCutoff.
        Logger.analyzer.info(
            "wpm-warmup-cutoff: cutoffRef=\(self.engineReadyCutoff!.timeIntervalSinceReferenceDate, format: .fixed(precision: 3)) clearedWords=\(prevWords) retainedIntervals=\(self.voiceIntervals.count) speechStartSet=\(self.currentSpeechStart != nil)"
        )
        startRefreshLoop()
    }

    /// Call when the widget enters waiting state (silence-hold fired).
    /// Cancels the refresh loop, clears in-window state, and publishes nil.
    /// The loop restarts on the next `notifyVADEvent(.speechStarted)`.
    func enterWaiting() {
        if let token = refreshToken {
            scheduler.cancel(token)
            refreshToken = nil
        }
        latestSnapshot = nil
        voiceIntervals.removeAll()
        currentSpeechStart = nil
        wpmRaw = nil
        wpmVoiced = nil
    }

    /// Forward VAD transitions from `SileroVADGate.transitionStream` here.
    func notifyVADEvent(_ event: VADTransitionEvent) {
        let cutoffSet = engineReadyCutoff != nil
        let accepted = isActive
        switch event {
        case .speechStarted:
            Logger.analyzer.info("wpm-vad: started cutoffSet=\(cutoffSet) accepted=\(accepted)")
            guard isActive else { return }
            currentSpeechStart = now()
            // Restart the refresh loop if enterWaiting() paused it.
            if refreshToken == nil, engineReadyCutoff != nil {
                startRefreshLoop()
            }
        case .speechStopped:
            Logger.analyzer.info("wpm-vad: stopped cutoffSet=\(cutoffSet) accepted=\(accepted)")
            guard isActive else { return }
            if let start = currentSpeechStart {
                voiceIntervals.append(VoiceInterval(start: start, end: now()))
                currentSpeechStart = nil
            }
        }
    }

    // MARK: - TokenConsumer

    // nonisolated to satisfy nonisolated protocol TokenConsumer; body hops to MainActor.
    nonisolated func consume(_ token: TranscribedToken) async {
        await MainActor.run { [self] in
            let count = countWords(in: token.token)
            guard let cutoff = engineReadyCutoff else {
                Logger.analyzer.info("wpm-consume: words=\(count) beforeCutoff=true accepted=false noSession=true")
                return
            }
            let arrival = now()
            let isBefore = arrival < cutoff
            Logger.analyzer.info("wpm-consume: words=\(count) beforeCutoff=\(isBefore) accepted=\(!isBefore && count > 0)")
            guard arrival >= cutoff else { return }
            guard count > 0 else { return }
            latestSnapshot = LatestSnapshot(wordCount: count, arrivedAt: arrival)
        }
    }

    nonisolated func sessionEnded() async {
        await MainActor.run { [self] in
            isActive = false
            if let token = refreshToken {
                scheduler.cancel(token)
                refreshToken = nil
            }
            engineReadyCutoff = nil
            latestSnapshot = nil
            voiceIntervals.removeAll()
            currentSpeechStart = nil
            wpmRaw = nil
            wpmVoiced = nil
        }
    }

    // MARK: - Refresh loop

    private func startRefreshLoop() {
        if let token = refreshToken {
            scheduler.cancel(token)
        }
        refreshToken = scheduler.schedule(delay: settings.wpmRefreshInterval) { [weak self] in
            self?.onRefreshFired()
        }
    }

    private func onRefreshFired() {
        guard engineReadyCutoff != nil else { return }
        computeAndPublish()
        startRefreshLoop()
    }

    // MARK: - Compute

    private func computeAndPublish() {
        let currentNow = now()
        let cutoff = currentNow.addingTimeInterval(-Self.windowSeconds)

        // Evict snapshot if it fell outside the window.
        if let snap = latestSnapshot, snap.arrivedAt < cutoff {
            latestSnapshot = nil
        }
        voiceIntervals.removeAll { interval in
            guard let end = interval.end else { return false }
            return end < cutoff
        }

        let words = latestSnapshot?.wordCount ?? 0
        let voicedSec = voicedSecondsInWindow(since: cutoff, now: currentNow)

        let tElapsed = engineReadyCutoff.map { currentNow.timeIntervalSince($0) } ?? 0
        Logger.analyzer.info(
            "wpm-refresh: A=\(self.wpmRaw ?? -1) B=\(self.wpmVoiced ?? -1) words=\(words) voicedSec=\(voicedSec, format: .fixed(precision: 2)) snapshotWords=\(self.latestSnapshot?.wordCount ?? 0) voiceIntervals=\(self.voiceIntervals.count) currentSpeechStartSet=\(self.currentSpeechStart != nil) tElapsed=\(tElapsed, format: .fixed(precision: 1))"
        )

        guard words >= Self.minWordsForReading, voicedSec >= Self.minVoicedSecondsForReading else {
            wpmRaw = nil
            wpmVoiced = nil
            return
        }

        wpmRaw = Int(round(Double(words) / (Self.windowSeconds / 60.0)))
        wpmVoiced = Int(round(Double(words) / (voicedSec / 60.0)))

        Logger.analyzer.info(
            "WPMCalculator: A=\(self.wpmRaw ?? -1) B=\(self.wpmVoiced ?? -1) words=\(words) voiced=\(voicedSec, format: .fixed(precision: 2))s"
        )
    }

    private func voicedSecondsInWindow(since windowStart: Date, now currentNow: Date) -> TimeInterval {
        var total: TimeInterval = 0
        // Clip voiced time to the later of the 10s window boundary or the engine-ready cutoff.
        // Words before engineReadyCutoff are discarded as warmup garbage, so pre-cutoff voiced
        // seconds must not inflate the denominator with unmatched time.
        let effectiveCutoff = max(windowStart, engineReadyCutoff ?? .distantPast)

        for interval in voiceIntervals {
            guard let end = interval.end else { continue }
            let clippedStart = max(interval.start, effectiveCutoff)
            let clippedEnd = min(end, currentNow)
            if clippedEnd > clippedStart {
                total += clippedEnd.timeIntervalSince(clippedStart)
            }
        }

        if let start = currentSpeechStart {
            let clippedStart = max(start, effectiveCutoff)
            if currentNow > clippedStart {
                total += currentNow.timeIntervalSince(clippedStart)
            }
        }

        return total
    }

    // MARK: - Word counting

    private func countWords(in text: String) -> Int {
        text.components(separatedBy: .whitespaces)
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
            .count
    }
}
