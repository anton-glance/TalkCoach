import AVFoundation
import Speech
import XCTest
@testable import TalkCoach

// MARK: - FileBufferProvider

/// Reads a .caf/.wav file and streams CapturedAudioBuffer values to a backend.
nonisolated final class FileBufferProvider: AudioBufferProvider, @unchecked Sendable {
    private let url: URL

    init(url: URL) { self.url = url }

    func bufferStream() -> AsyncStream<CapturedAudioBuffer> {
        let url = self.url
        return AsyncStream { continuation in
            Task.detached {
                do {
                    let file = try AVAudioFile(forReading: url)
                    let format = file.processingFormat
                    let capacity: AVAudioFrameCount = 4096
                    while true {
                        guard let pcm = AVAudioPCMBuffer(
                            pcmFormat: format, frameCapacity: capacity
                        ) else { break }
                        do { try file.read(into: pcm) } catch { break }
                        if pcm.frameLength == 0 { break }
                        var samples: [[Float]] = []
                        if let floatData = pcm.floatChannelData {
                            for ch in 0..<Int(format.channelCount) {
                                samples.append(Array(UnsafeBufferPointer(
                                    start: floatData[ch],
                                    count: Int(pcm.frameLength)
                                )))
                            }
                        }
                        continuation.yield(CapturedAudioBuffer(
                            frameLength: pcm.frameLength,
                            sampleRate: format.sampleRate,
                            channelCount: format.channelCount,
                            sampleTime: 0,
                            hostTime: 0,
                            samples: samples
                        ))
                    }
                } catch {}
                continuation.finish()
            }
        }
    }
}

// MARK: - TranscriptionEngineIntegrationTests

@MainActor
final class TranscriptionEngineIntegrationTests: XCTestCase {

    /// AC11: AppleTranscriberBackend produces ≥1 token from en_short.caf within 10 s.
    /// Skips cleanly via XCTSkip if the EN speech model is not installed on this machine.
    func testAppleBackendProducesTokensFromFixture() async throws {
        guard let url = Bundle(for: type(of: self)).url(
            forResource: "en_short", withExtension: "caf"
        ) else {
            XCTFail("en_short.caf fixture not found in test bundle")
            return
        }

        let localesProvider = SystemSupportedLocalesProvider()
        let testLocale = Locale(identifier: "en-US")

        let appleLocales = await localesProvider.supportedLocales()
        guard let matched = appleLocales.first(where: { localeMatches($0, testLocale) }) else {
            throw XCTSkip("en-US not found in SpeechTranscriber.supportedLocales on this system")
        }

        // Probe model without triggering a download.
        let isInstalled = try await SystemAssetInventoryStatusProvider()
            .isInstalled(locale: matched)
        if !isInstalled {
            throw XCTSkip("EN speech model not installed — skipping integration test")
        }

        let backend = AppleTranscriberBackend(
            audioBufferProvider: FileBufferProvider(url: url),
            localesProvider: localesProvider
        )

        try await backend.start(locale: testLocale)

        let tokenExpectation = XCTestExpectation(description: "≥1 token produced within 10 s")
        let collectTask = Task {
            for await _ in backend.tokenStream {
                tokenExpectation.fulfill()
                break
            }
        }

        await fulfillment(of: [tokenExpectation], timeout: 10.0)
        collectTask.cancel()
        await backend.stop()
    }
}
