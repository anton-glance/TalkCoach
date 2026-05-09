import AVFAudio
import XCTest
@testable import TalkCoach

// MARK: - IntegrationFakeAudioEngineProvider (private; no hardware)

@MainActor
private final class IntegrationFakeAudioEngineProvider: AudioEngineProvider {
    var lastInstalledBlock: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var isVoiceProcessingEnabled: Bool { false }

    func setVoiceProcessingEnabled(_ enabled: Bool) throws {}
    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) { lastInstalledBlock = block }
    func removeTap() { lastInstalledBlock = nil }
    func prepare() {}
    func start() throws {}
    func stop() {}
}

// MARK: - SessionCoordinatorIntegrationTests

/// Verifies the full wiring path:
///   SessionCoordinator → real LanguageDetector → real TranscriptionEngine → FakeTokenConsumer
/// Uses fake backends to avoid requiring an Apple speech model installation.
/// Transcription quality is covered by TranscriptionEngineIntegrationTests.
@MainActor
final class SessionCoordinatorIntegrationTests: XCTestCase {

    private func makeSUT() -> SessionCoordinator {
        let suiteName = "IntegrationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "coachingEnabled")
        let settingsStore = SettingsStore(userDefaults: defaults)
        let micMonitor = MicMonitor(provider: MinimalCoreAudioProvider())
        return SessionCoordinator(micMonitor: micMonitor, settingsStore: settingsStore)
    }

    // AC-I1: Full wiring path delivers tokens end-to-end and calls sessionEnded() on teardown.
    func testEndToEndWiringDeliversTokensAndNotifiesSessionEnded() async throws {
        let sut = makeSUT()

        // Real AudioPipeline (fake engine — no hardware)
        let engineProvider = IntegrationFakeAudioEngineProvider()
        let pipeline = AudioPipeline(provider: engineProvider)

        // Real LanguageDetector — single declared locale → SingleLocaleStrategy → returns immediately
        let ld = LanguageDetector(
            declaredLocales: [Locale(identifier: "en_US")],
            partialTranscriptProvider: StubPartialTranscriptProvider(),
            whisperLIDProvider: StubWhisperLIDProvider(),
            audioBufferProvider: AudioPipelineBufferProvider(pipeline: pipeline)
        )

        // Fake backend that can yield tokens on demand
        let yieldingFactory = YieldingAppleBackendFactory()
        let localesProvider = FakeSupportedLocalesProvider()
        localesProvider.locales = [Locale(identifier: "en_US")]

        sut.wiring = SessionWiring(
            audioPipeline: pipeline,
            languageDetector: ld,
            appleBackendFactory: yieldingFactory,
            parakeetBackendFactory: TestParakeetBackendFactory(),
            supportedLocalesProvider: localesProvider
        )

        let consumer = FakeTokenConsumer()
        sut.addConsumer(consumer)

        // Trigger wiring and wait for all four setup steps to complete
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        // Deliver a token through the backend relay path
        let tokenExpectation = XCTestExpectation(description: "Consumer receives token end-to-end")
        consumer.onReceiveToken = { tokenExpectation.fulfill() }

        let token = TranscribedToken(token: "integration", startTime: 0.0, endTime: 0.5, isFinal: true)
        yieldingFactory.stubbedBackend.yield(token)

        await fulfillment(of: [tokenExpectation], timeout: 3.0)

        XCTAssertEqual(consumer.receivedTokens.first?.token, "integration",
                       "Token must flow coordinator → engine → relay → consumer")

        // Verify sessionEnded() is called after session stops
        let sessionEndedExpectation = XCTestExpectation(description: "sessionEnded called on consumer")
        consumer.onSessionEnded = { sessionEndedExpectation.fulfill() }
        sut.micDeactivated()

        await fulfillment(of: [sessionEndedExpectation], timeout: 3.0)

        XCTAssertEqual(consumer.sessionEndedCallCount, 1,
                       "sessionEnded() must be called exactly once on teardown")
    }
}
