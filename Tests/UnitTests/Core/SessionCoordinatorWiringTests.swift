// swiftlint:disable file_length
import AVFAudio
import XCTest
@testable import TalkCoach

// MARK: - MinimalCoreAudioProvider
// Internal (not private) so integration tests in Tests/IntegrationTests/Core/ can reuse it.

final class MinimalCoreAudioProvider: CoreAudioDeviceProvider, @unchecked Sendable {
    nonisolated func defaultInputDeviceID() -> AudioObjectID? { nil }
    nonisolated func isDeviceRunningSomewhere(_ id: AudioObjectID) -> Bool? { nil }
    nonisolated func addIsRunningListener(
        device: AudioObjectID, handler: @escaping @Sendable () -> Void
    ) -> AnyObject? { nil }
    nonisolated func removeIsRunningListener(device: AudioObjectID, token: AnyObject) {}
    nonisolated func addDefaultDeviceListener(
        handler: @escaping @Sendable () -> Void
    ) -> AnyObject? { nil }
    nonisolated func removeDefaultDeviceListener(token: AnyObject) {}
}

// MARK: - WiringFakeAudioEngineProvider (private to wiring tests; mirrors AudioPipelineTests version)

@MainActor
private final class WiringFakeAudioEngineProvider: AudioEngineProvider {
    var callLog: [String] = []
    var lastInstalledBlock: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var startShouldThrow = false
    var isVoiceProcessingEnabled: Bool { false }

    func setVoiceProcessingEnabled(_ enabled: Bool) throws {}
    func installTap(
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    ) {
        callLog.append("installTap")
        lastInstalledBlock = block
    }
    func removeTap() { callLog.append("removeTap"); lastInstalledBlock = nil }
    func prepare() {}
    func start() throws {
        if startShouldThrow { throw NSError(domain: "FakeEngine", code: -1) }
        callLog.append("start")
    }
    func stop() { callLog.append("stop") }
}

// MARK: - FakeLanguageDetector

final class FakeLanguageDetector: LanguageDetecting, @unchecked Sendable {
    nonisolated(unsafe) var stubbedLocale: Locale = Locale(identifier: "en-US")
    nonisolated(unsafe) var stubbedError: Error?
    nonisolated(unsafe) var startCallCount = 0
    nonisolated(unsafe) var stopCallCount = 0

    private let cont: AsyncStream<Locale>.Continuation
    nonisolated let localeChange: AsyncStream<Locale>

    init() {
        // swiftlint:disable:next identifier_name
        var c: AsyncStream<Locale>.Continuation!
        localeChange = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c = $0 }
        cont = c
    }

    func start() async throws -> Locale {
        startCallCount += 1
        // swiftlint:disable:next identifier_name
        if let e = stubbedError { throw e }
        return stubbedLocale
    }

    func stop() async {
        stopCallCount += 1
        cont.finish()
    }

    func simulateLocaleChange(_ locale: Locale) { cont.yield(locale) }
}

// MARK: - FailingTranscriberBackend

final class FailingTranscriberBackend: TranscriberBackend, @unchecked Sendable {
    let tokenStream: AsyncStream<TranscribedToken> = AsyncStream { $0.finish() }
    let engineReadyStream: AsyncStream<Void> = AsyncStream { $0.finish() }
    let speakingActivityStream: AsyncStream<Bool> = AsyncStream { $0.finish() }
    func start(locale: Locale, audioProvider: (any AudioBufferProvider)?) async throws {
        throw TranscriberBackendError.modelUnavailable
    }
    func stop() async {}
}

// MARK: - YieldingStubBackend
// Internal so SessionCoordinatorIntegrationTests can reuse it.

final class YieldingStubBackend: TranscriberBackend, @unchecked Sendable {
    nonisolated(unsafe) var startCallCount = 0
    nonisolated(unsafe) var stopCallCount = 0

    private let cont: AsyncStream<TranscribedToken>.Continuation
    let tokenStream: AsyncStream<TranscribedToken>
    let engineReadyStream: AsyncStream<Void> = AsyncStream { $0.yield(()); $0.finish() }
    let speakingActivityStream: AsyncStream<Bool> = AsyncStream { $0.finish() }

    init() {
        // swiftlint:disable:next identifier_name
        var c: AsyncStream<TranscribedToken>.Continuation!
        tokenStream = AsyncStream { c = $0 }
        cont = c
    }

    func start(locale: Locale, audioProvider: (any AudioBufferProvider)?) async throws { startCallCount += 1 }
    func stop() async { stopCallCount += 1; cont.finish() }
    func yield(_ token: TranscribedToken) { cont.yield(token) }
}

// MARK: - NeverReadyStubBackend
// Internal so SessionCoordinatorTests can use it for the engine-ready topology test.

final class NeverReadyStubBackend: TranscriberBackend, @unchecked Sendable {
    private let tokenCont: AsyncStream<TranscribedToken>.Continuation
    let tokenStream: AsyncStream<TranscribedToken>

    // engineReadyContinuation kept alive indefinitely — stream never yields, never finishes.
    private let engineReadyContinuation: AsyncStream<Void>.Continuation
    let engineReadyStream: AsyncStream<Void>
    let speakingActivityStream: AsyncStream<Bool> = AsyncStream { $0.finish() }

    init() {
        var tokenStreamCont: AsyncStream<TranscribedToken>.Continuation!
        tokenStream = AsyncStream { tokenStreamCont = $0 }
        tokenCont = tokenStreamCont

        var erc: AsyncStream<Void>.Continuation!
        engineReadyStream = AsyncStream { erc = $0 }
        engineReadyContinuation = erc
    }

    func start(locale: Locale, audioProvider: (any AudioBufferProvider)?) async throws {}
    func stop() async {
        engineReadyContinuation.finish()
        tokenCont.finish()
    }
    func yield(_ token: TranscribedToken) { tokenCont.yield(token) }
}

// MARK: - SessionCoordinatorWiringTests

@MainActor
final class SessionCoordinatorWiringTests: XCTestCase {

    private func makeSUT(coachingEnabled: Bool = true) -> SessionCoordinator {
        let suiteName = "WiringTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(coachingEnabled, forKey: "coachingEnabled")
        let settingsStore = SettingsStore(userDefaults: defaults)
        let micMonitor = MicMonitor(provider: MinimalCoreAudioProvider())
        return SessionCoordinator(micMonitor: micMonitor, settingsStore: settingsStore)
    }

    private func makeWiring(
        stubbedLocale: String = "en-US",
        langError: Error? = nil,
        backend: (any TranscriberBackend)? = nil,
        engineStartShouldThrow: Bool = false
    ) -> (
        wiring: SessionWiring,
        engineProvider: WiringFakeAudioEngineProvider,
        fakeLD: FakeLanguageDetector
    ) {
        let engineProvider = WiringFakeAudioEngineProvider()
        engineProvider.startShouldThrow = engineStartShouldThrow
        let pipeline = AudioPipeline(provider: engineProvider)

        let fakeLD = FakeLanguageDetector()
        fakeLD.stubbedLocale = Locale(identifier: stubbedLocale)
        fakeLD.stubbedError = langError

        let wiring = SessionWiring(
            audioPipeline: pipeline,
            languageDetector: fakeLD,
            backend: backend ?? YieldingStubBackend()
        )
        return (wiring, engineProvider, fakeLD)
    }

    // MARK: - AC-W1: micActivated → pipeline starts, LD starts, backend starts

    func testMicActivatedStartsPipelineThenLDThenBackend() async throws {
        let sut = makeSUT()
        let stub = YieldingStubBackend()

        let (wiring, engineProvider, fakeLD) = makeWiring(backend: stub)
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        XCTAssertTrue(engineProvider.callLog.contains("start"), "AudioPipeline must be started")
        XCTAssertEqual(fakeLD.startCallCount, 1, "LanguageDetector must be started once")
        XCTAssertEqual(stub.startCallCount, 1, "Backend must be started once")
    }

    // MARK: - AC-W2: micDeactivated → teardown in order (backend.stop, LD.stop, consumer.sessionEnded)

    func testMicDeactivatedStopsBackendAndLD() async throws {
        let sut = makeSUT()
        let yieldingBackend = YieldingStubBackend()

        let (wiring, _, fakeLD) = makeWiring(backend: yieldingBackend)
        sut.wiring = wiring

        let consumer = FakeTokenConsumer()
        sut.addConsumer(consumer)

        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        let sessionEndedExp = XCTestExpectation(description: "sessionEnded called on consumer")
        consumer.onSessionEnded = { sessionEndedExp.fulfill() }

        sut.micDeactivated()
        await fulfillment(of: [sessionEndedExp], timeout: 3.0)

        XCTAssertEqual(yieldingBackend.stopCallCount, 1, "Backend must be stopped")
        XCTAssertEqual(fakeLD.stopCallCount, 1, "LanguageDetector must be stopped")
        XCTAssertEqual(consumer.sessionEndedCallCount, 1, "Consumer must receive sessionEnded()")
    }

    // MARK: - AC-W5: localeChange emitted → logged, no engine restart

    func testLocaleChangeIsLoggedButEngineNotRestarted() async throws {
        let sut = makeSUT()
        let yieldingBackend = YieldingStubBackend()

        let (wiring, _, fakeLD) = makeWiring(backend: yieldingBackend)
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        fakeLD.simulateLocaleChange(Locale(identifier: "fr-FR"))
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(yieldingBackend.startCallCount, 1,
                       "Backend must NOT restart on locale change (deferred to M3.8)")
    }

    // MARK: - AC-W6: AudioPipeline.start() throws → LD never started, rollback

    func testAudioPipelineStartFailureNeverStartsLD() async throws {
        let sut = makeSUT()
        let (wiring, _, fakeLD) = makeWiring(engineStartShouldThrow: true)
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        XCTAssertEqual(fakeLD.startCallCount, 0, "LD must never start when AudioPipeline fails")
    }

    // MARK: - AC-W7: LD.start() throws → pipeline stopped, TE never created

    func testLanguageDetectorStartFailureStopsPipeline() async throws {
        let sut = makeSUT()
        let stub = YieldingStubBackend()

        let (wiring, engineProvider, _) = makeWiring(
            langError: LanguageDetectorError.noLocalesDeclared,
            backend: stub
        )
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        XCTAssertTrue(engineProvider.callLog.contains("stop"),
                      "Pipeline must be stopped on LD failure; callLog=\(engineProvider.callLog)")
        XCTAssertEqual(stub.startCallCount, 0, "Backend must NOT be started when LD fails")
    }

    // MARK: - AC-W9: backend.start() throws → LD.stop + pipeline.stop

    func testBackendStartFailureStopsLDAndPipeline() async throws {
        let sut = makeSUT()
        let failingBackend = FailingTranscriberBackend()

        let (wiring, engineProvider, fakeLD) = makeWiring(backend: failingBackend)
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        XCTAssertEqual(fakeLD.stopCallCount, 1, "LD must be stopped on backend start failure")
        XCTAssertTrue(engineProvider.callLog.contains("stop"),
                      "Pipeline must be stopped on backend start failure; callLog=\(engineProvider.callLog)")
    }

    // MARK: - AC-W10: token from backend → all registered consumers receive it

    func testTokenFromBackendReachesAllRegisteredConsumers() async throws {
        let sut = makeSUT()
        let yieldingBackend = YieldingStubBackend()

        let (wiring, _, _) = makeWiring(backend: yieldingBackend)
        sut.wiring = wiring

        let consumer1 = FakeTokenConsumer()
        let consumer2 = FakeTokenConsumer()
        sut.addConsumer(consumer1)
        sut.addConsumer(consumer2)

        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        let exp1 = XCTestExpectation(description: "consumer1 receives token")
        let exp2 = XCTestExpectation(description: "consumer2 receives token")
        consumer1.onReceiveToken = { exp1.fulfill() }
        consumer2.onReceiveToken = { exp2.fulfill() }

        let token = TranscribedToken(token: "hello", startTime: 0.0, endTime: 0.5, isFinal: true)
        yieldingBackend.yield(token)

        await fulfillment(of: [exp1, exp2], timeout: 2.0)

        XCTAssertEqual(consumer1.receivedTokens.first?.token, "hello")
        XCTAssertEqual(consumer2.receivedTokens.first?.token, "hello")
    }

    // MARK: - Sequential consumption invariant
    // After LD.start() returns, AudioPipeline.bufferStream must be available to a new
    // subscriber (TranscriptionEngine). WhisperLID (Strategy 3, isBlocking=true) is the
    // only strategy that consumes audio; it completes before start() returns.

    func testLDReleasesBufferStreamBeforeTESubscribes() async throws {
        let engineProvider = WiringFakeAudioEngineProvider()
        let pipeline = AudioPipeline(provider: engineProvider)
        try pipeline.start()

        let audioProvider = AudioPipelineBufferProvider(pipeline: pipeline)
        let whisper = FakeWhisperLIDProvider()
        whisper.stubbedError = WhisperLIDProviderError.modelUnavailable

        // en_US + ja_JP triggers WhisperLID strategy (Strategy 3, isBlocking=true)
        // swiftlint:disable:next identifier_name
        let ld = LanguageDetector(
            declaredLocales: [Locale(identifier: "en_US"), Locale(identifier: "ja_JP")],
            partialTranscriptProvider: StubPartialTranscriptProvider(),
            whisperLIDProvider: whisper,
            audioBufferProvider: audioProvider
        )

        // Deliver a buffer large enough to satisfy WhisperLID's 3-second audio target.
        // At 48000 Hz: ceil(3.0 * 48000) = 144000 frames. Use 149000 for margin.
        deliverBuffer(to: engineProvider, frameCount: 149_000)

        // LD.start() blocks until WhisperLID finishes (isBlocking = true).
        // WhisperLID collects the large buffer, calls whisper (throws .modelUnavailable),
        // falls back to initialLocale, and returns. The for-await loop over bufferStream ends.
        _ = try await ld.start()

        // After LD.start() returns, LD is no longer iterating bufferStream.
        // A new consumer (simulating TE's AppleTranscriberBackend) subscribes here.
        let newBufferExpectation = XCTestExpectation(
            description: "New consumer receives buffer after LD releases stream"
        )
        let stream = pipeline.bufferStream
        let consumeTask = Task { @MainActor in
            for await _ in stream {
                newBufferExpectation.fulfill()
                break
            }
        }

        deliverBuffer(to: engineProvider, frameCount: 480)
        await fulfillment(of: [newBufferExpectation], timeout: 2.0)
        consumeTask.cancel()
    }

    private func deliverBuffer(
        to provider: WiringFakeAudioEngineProvider,
        frameCount: AVAudioFrameCount = 480
    ) {
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return }
        buffer.frameLength = frameCount
        let time = AVAudioTime(sampleTime: 0, atRate: 48_000)
        provider.lastInstalledBlock?(buffer, time)
    }

}
