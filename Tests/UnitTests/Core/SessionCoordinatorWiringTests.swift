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
        var c: AsyncStream<Locale>.Continuation!
        localeChange = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { c = $0 }
        cont = c
    }

    func start() async throws -> Locale {
        startCallCount += 1
        if let e = stubbedError { throw e }
        return stubbedLocale
    }

    func stop() async {
        stopCallCount += 1
        cont.finish()
    }

    func simulateLocaleChange(_ locale: Locale) { cont.yield(locale) }
}

// MARK: - FailingTranscriberBackend / FailingAppleBackendFactory

final class FailingTranscriberBackend: TranscriberBackend, @unchecked Sendable {
    let tokenStream: AsyncStream<TranscribedToken> = AsyncStream { $0.finish() }
    func start(locale: Locale) async throws { throw TranscriberBackendError.modelUnavailable }
    func stop() async {}
}

final class FailingAppleBackendFactory: AppleBackendFactory, @unchecked Sendable {
    nonisolated(unsafe) var makeCallCount = 0
    func make(audioBufferProvider: any AudioBufferProvider) -> any TranscriberBackend {
        makeCallCount += 1
        return FailingTranscriberBackend()
    }
}

// MARK: - YieldingStubBackend / YieldingAppleBackendFactory
// Internal so SessionCoordinatorIntegrationTests can reuse them.

final class YieldingStubBackend: TranscriberBackend, @unchecked Sendable {
    nonisolated(unsafe) var startCallCount = 0
    nonisolated(unsafe) var stopCallCount = 0

    private let cont: AsyncStream<TranscribedToken>.Continuation
    let tokenStream: AsyncStream<TranscribedToken>

    init() {
        var c: AsyncStream<TranscribedToken>.Continuation!
        tokenStream = AsyncStream { c = $0 }
        cont = c
    }

    func start(locale: Locale) async throws { startCallCount += 1 }
    func stop() async { stopCallCount += 1; cont.finish() }
    func yield(_ token: TranscribedToken) { cont.yield(token) }
}

final class YieldingAppleBackendFactory: AppleBackendFactory, @unchecked Sendable {
    nonisolated(unsafe) var makeCallCount = 0
    let stubbedBackend: YieldingStubBackend

    init(backend: YieldingStubBackend = YieldingStubBackend()) {
        self.stubbedBackend = backend
    }

    func make(audioBufferProvider: any AudioBufferProvider) -> any TranscriberBackend {
        makeCallCount += 1
        return stubbedBackend
    }
}

// MARK: - FakeInactivityTimer

final class FakeInactivityTimer: InactivityTimer, @unchecked Sendable {
    private(set) var scheduleCallCount = 0
    private(set) var cancelCallCount = 0
    private(set) var lastScheduledTimeout: TimeInterval?
    private var pendingAction: (@MainActor () -> Void)?

    func schedule(after timeout: TimeInterval, action: @escaping @MainActor () -> Void) {
        scheduleCallCount += 1
        lastScheduledTimeout = timeout
        pendingAction = action
    }

    func cancel() {
        cancelCallCount += 1
        pendingAction = nil
    }

    @MainActor func fireNow() {
        let a = pendingAction
        pendingAction = nil
        a?()
    }
}

// MARK: - SessionCoordinatorWiringTests

@MainActor
final class SessionCoordinatorWiringTests: XCTestCase {

    private func makeSUT(
        coachingEnabled: Bool = true,
        inactivityTimer: any InactivityTimer = FakeInactivityTimer()
    ) -> SessionCoordinator {
        let suiteName = "WiringTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(coachingEnabled, forKey: "coachingEnabled")
        let settingsStore = SettingsStore(userDefaults: defaults)
        let micMonitor = MicMonitor(provider: MinimalCoreAudioProvider())
        return SessionCoordinator(micMonitor: micMonitor, settingsStore: settingsStore, inactivityTimer: inactivityTimer)
    }

    private func makeWiring(
        stubbedLocale: String = "en-US",
        appleLocales: [String] = ["en-US"],
        langError: Error? = nil,
        appleFactory: (any AppleBackendFactory)? = nil,
        parakeetFactory: (any ParakeetBackendFactory)? = nil,
        engineStartShouldThrow: Bool = false
    ) -> (
        wiring: SessionWiring,
        engineProvider: WiringFakeAudioEngineProvider,
        fakeLD: FakeLanguageDetector,
        localesProvider: FakeSupportedLocalesProvider
    ) {
        let engineProvider = WiringFakeAudioEngineProvider()
        engineProvider.startShouldThrow = engineStartShouldThrow
        let pipeline = AudioPipeline(provider: engineProvider)

        let fakeLD = FakeLanguageDetector()
        fakeLD.stubbedLocale = Locale(identifier: stubbedLocale)
        fakeLD.stubbedError = langError

        let af = appleFactory ?? TestAppleBackendFactory()
        let pf = parakeetFactory ?? TestParakeetBackendFactory()

        let localesProvider = FakeSupportedLocalesProvider()
        localesProvider.locales = appleLocales.map { Locale(identifier: $0) }

        let wiring = SessionWiring(
            audioPipeline: pipeline,
            languageDetector: fakeLD,
            appleBackendFactory: af,
            parakeetBackendFactory: pf,
            supportedLocalesProvider: localesProvider
        )
        return (wiring, engineProvider, fakeLD, localesProvider)
    }

    // MARK: - AC-W1: micActivated → pipeline starts, LD starts, TE starts

    func testMicActivatedStartsPipelineThenLDThenTE() async throws {
        let sut = makeSUT()
        let stub = SpeechStubBackend()
        let apple = TestAppleBackendFactory()
        apple.stubbedBackend = stub

        let (wiring, engineProvider, fakeLD, _) = makeWiring(appleFactory: apple)
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        XCTAssertTrue(engineProvider.callLog.contains("start"), "AudioPipeline must be started")
        XCTAssertEqual(fakeLD.startCallCount, 1, "LanguageDetector must be started once")
        XCTAssertEqual(apple.makeCallCount, 1, "Apple backend factory must be called once")
        XCTAssertEqual(stub.startCallCount, 1, "TranscriptionEngine backend must be started once")
    }

    // MARK: - AC-W2: micDeactivated → teardown in order (engine.stop, LD.stop, consumer.sessionEnded)

    func testMicDeactivatedStopsEngineAndLD() async throws {
        let sut = makeSUT()
        let yieldingFactory = YieldingAppleBackendFactory()

        let (wiring, _, fakeLD, _) = makeWiring(appleFactory: yieldingFactory)
        sut.wiring = wiring

        let consumer = FakeTokenConsumer()
        sut.addConsumer(consumer)

        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        let sessionEndedExp = XCTestExpectation(description: "sessionEnded called on consumer")
        consumer.onSessionEnded = { sessionEndedExp.fulfill() }

        sut.micDeactivated()
        await fulfillment(of: [sessionEndedExp], timeout: 3.0)

        XCTAssertEqual(yieldingFactory.stubbedBackend.stopCallCount, 1, "TE backend must be stopped")
        XCTAssertEqual(fakeLD.stopCallCount, 1, "LanguageDetector must be stopped")
        XCTAssertEqual(consumer.sessionEndedCallCount, 1, "Consumer must receive sessionEnded()")
    }

    // MARK: - AC-W3: Apple locale → Apple factory used, Parakeet not called

    func testAppleLocaleRoutesToAppleFactory() async throws {
        let sut = makeSUT()
        let apple = TestAppleBackendFactory()
        let parakeet = TestParakeetBackendFactory()

        let (wiring, _, _, _) = makeWiring(
            stubbedLocale: "en-US",
            appleLocales: ["en-US"],
            appleFactory: apple,
            parakeetFactory: parakeet
        )
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        XCTAssertEqual(apple.makeCallCount, 1, "Apple factory must be called for Apple-supported locale")
        XCTAssertEqual(parakeet.makeCallCount, 0, "Parakeet factory must NOT be called")
    }

    // MARK: - AC-W4: Parakeet locale → Parakeet factory used, Apple not called

    func testParakeetLocaleRoutesToParakeetFactory() async throws {
        let sut = makeSUT()
        let apple = TestAppleBackendFactory()
        let parakeet = TestParakeetBackendFactory()
        parakeet.supportedIdentifiers = ["ru-RU"]

        let (wiring, _, _, _) = makeWiring(
            stubbedLocale: "ru-RU",
            appleLocales: ["en-US"],
            appleFactory: apple,
            parakeetFactory: parakeet
        )
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        XCTAssertEqual(apple.makeCallCount, 0, "Apple factory must NOT be called for Parakeet locale")
        XCTAssertEqual(parakeet.makeCallCount, 1, "Parakeet factory must be called")
    }

    // MARK: - AC-W5: localeChange emitted → logged, no engine restart

    func testLocaleChangeIsLoggedButEngineNotRestarted() async throws {
        let sut = makeSUT()
        let yieldingFactory = YieldingAppleBackendFactory()

        let (wiring, _, fakeLD, _) = makeWiring(appleFactory: yieldingFactory)
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        fakeLD.simulateLocaleChange(Locale(identifier: "fr-FR"))
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(yieldingFactory.stubbedBackend.startCallCount, 1,
                       "Engine must NOT restart on locale change (deferred to M3.8)")
        XCTAssertEqual(yieldingFactory.makeCallCount, 1,
                       "Apple factory must be called exactly once")
    }

    // MARK: - AC-W6: AudioPipeline.start() throws → LD never started, rollback

    func testAudioPipelineStartFailureNeverStartsLD() async throws {
        let sut = makeSUT()
        let (wiring, _, fakeLD, _) = makeWiring(engineStartShouldThrow: true)
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        XCTAssertEqual(fakeLD.startCallCount, 0, "LD must never start when AudioPipeline fails")
    }

    // MARK: - AC-W7: LD.start() throws → pipeline stopped, TE never created

    func testLanguageDetectorStartFailureStopsPipeline() async throws {
        let sut = makeSUT()
        let apple = TestAppleBackendFactory()

        let (wiring, engineProvider, _, _) = makeWiring(
            langError: LanguageDetectorError.noLocalesDeclared,
            appleFactory: apple
        )
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        XCTAssertTrue(engineProvider.callLog.contains("stop"),
                      "Pipeline must be stopped on LD failure; callLog=\(engineProvider.callLog)")
        XCTAssertEqual(apple.makeCallCount, 0, "TE factory must NOT be called when LD fails")
    }

    // MARK: - AC-W8: TE.init throws unsupportedLocale → LD.stop + pipeline.stop

    func testTranscriptionEngineInitFailureStopsLDAndPipeline() async throws {
        let sut = makeSUT()
        // "zz-ZZ" is not in Apple locales and Parakeet supports nothing → unsupportedLocale
        let (wiring, engineProvider, fakeLD, _) = makeWiring(
            stubbedLocale: "zz-ZZ",
            appleLocales: ["en-US"]
        )
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        XCTAssertEqual(fakeLD.stopCallCount, 1, "LD must be stopped on TE init failure")
        XCTAssertTrue(engineProvider.callLog.contains("stop"),
                      "Pipeline must be stopped on TE init failure; callLog=\(engineProvider.callLog)")
    }

    // MARK: - AC-W9: TE.start() throws → LD.stop + pipeline.stop

    func testTranscriptionEngineStartFailureStopsLDAndPipeline() async throws {
        let sut = makeSUT()
        let failingApple = FailingAppleBackendFactory()

        let (wiring, engineProvider, fakeLD, _) = makeWiring(appleFactory: failingApple)
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        XCTAssertEqual(fakeLD.stopCallCount, 1, "LD must be stopped on TE start failure")
        XCTAssertTrue(engineProvider.callLog.contains("stop"),
                      "Pipeline must be stopped on TE start failure; callLog=\(engineProvider.callLog)")
    }

    // MARK: - AC-W10: token from backend → all registered consumers receive it

    func testTokenFromBackendReachesAllRegisteredConsumers() async throws {
        let sut = makeSUT()
        let yieldingFactory = YieldingAppleBackendFactory()

        let (wiring, _, _, _) = makeWiring(appleFactory: yieldingFactory)
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
        yieldingFactory.stubbedBackend.yield(token)

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

    // MARK: - M3.7.2 Inactivity Timer

    func testInactivityTimer_FiresEndCurrentSession_When30sElapseWithoutTokens() async throws {
        let fakeTimer = FakeInactivityTimer()
        let sut = makeSUT(inactivityTimer: fakeTimer)

        var endedSessions: [EndedSession] = []
        sut.onSessionEnded { endedSessions.append($0) }

        let (wiring, _, _, _) = makeWiring()
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        XCTAssertGreaterThanOrEqual(fakeTimer.scheduleCallCount, 1,
                                    "Timer must be armed after runSession() enters")
        XCTAssertEqual(fakeTimer.lastScheduledTimeout, 15,
                       "Timer must use inactivityThresholdSeconds=15 from settings (M3.7.3 behavioral change)")

        fakeTimer.fireNow()

        XCTAssertEqual(endedSessions.count, 1, "Exactly one session must end on inactivity fire")
        XCTAssertEqual(sut.state, .idle)
    }

    func testInactivityTimer_DoesNotFire_WhenTokenReceivedBefore30s() async throws {
        let fakeTimer = FakeInactivityTimer()
        let sut = makeSUT(inactivityTimer: fakeTimer)

        let yieldingFactory = YieldingAppleBackendFactory()
        let (wiring, _, _, _) = makeWiring(appleFactory: yieldingFactory)
        sut.wiring = wiring

        let consumer = FakeTokenConsumer()
        sut.addConsumer(consumer)

        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        let countAfterWiring = fakeTimer.scheduleCallCount

        let tokenExp = XCTestExpectation(description: "token consumed")
        consumer.onReceiveToken = { tokenExp.fulfill() }
        yieldingFactory.stubbedBackend.yield(
            TranscribedToken(token: "hello", startTime: 0, endTime: 0.5, isFinal: true)
        )
        await fulfillment(of: [tokenExp], timeout: 2.0)

        XCTAssertGreaterThan(fakeTimer.scheduleCallCount, countAfterWiring,
                             "Timer must reset (reschedule) on token receipt")
        if case .active = sut.state { } else {
            XCTFail("Session must still be active — timer was not fired")
        }
    }

    func testInactivityTimer_DoesNotFire_AfterMicDeactivated() async throws {
        let fakeTimer = FakeInactivityTimer()
        let sut = makeSUT(inactivityTimer: fakeTimer)

        var endedCount = 0
        sut.onSessionEnded { _ in endedCount += 1 }

        let yieldingFactory = YieldingAppleBackendFactory()
        let (wiring, _, _, _) = makeWiring(appleFactory: yieldingFactory)
        sut.wiring = wiring

        let consumer = FakeTokenConsumer()
        sut.addConsumer(consumer)
        let teardownExp = XCTestExpectation(description: "teardown completes")
        consumer.onSessionEnded = { teardownExp.fulfill() }

        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        sut.micDeactivated()
        await fulfillment(of: [teardownExp], timeout: 3.0)

        XCTAssertGreaterThanOrEqual(fakeTimer.cancelCallCount, 1,
                                    "Timer must be cancelled when session ends")
        XCTAssertEqual(endedCount, 1)

        fakeTimer.fireNow()
        XCTAssertEqual(endedCount, 1, "Timer fire after cancel must be a no-op")
    }

    func testInactivityTimer_DoesNotFire_AfterEndCurrentSessionCalled() async throws {
        let fakeTimer = FakeInactivityTimer()
        let sut = makeSUT(inactivityTimer: fakeTimer)
        sut.start()

        var endedCount = 0
        sut.onSessionEnded { _ in endedCount += 1 }

        let yieldingFactory = YieldingAppleBackendFactory()
        let (wiring, _, _, _) = makeWiring(appleFactory: yieldingFactory)
        sut.wiring = wiring

        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        sut.stop()  // calls endCurrentSession() → inactivityTimer.cancel()

        XCTAssertEqual(endedCount, 1, "Session must end via stop()")
        XCTAssertGreaterThanOrEqual(fakeTimer.cancelCallCount, 1,
                                    "Timer must be cancelled in stop()")

        fakeTimer.fireNow()
        XCTAssertEqual(endedCount, 1, "Fire after cancel is a no-op (idempotency under any session-end path)")
    }

    func testInactivityTimer_ResetsCleanly_OnEveryTokenReceipt() async throws {
        let fakeTimer = FakeInactivityTimer()
        let sut = makeSUT(inactivityTimer: fakeTimer)

        let yieldingFactory = YieldingAppleBackendFactory()
        let (wiring, _, _, _) = makeWiring(appleFactory: yieldingFactory)
        sut.wiring = wiring

        let consumer = FakeTokenConsumer()
        sut.addConsumer(consumer)

        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        let countAfterWiring = fakeTimer.scheduleCallCount

        let allTokensExp = XCTestExpectation(description: "5 tokens consumed")
        allTokensExp.expectedFulfillmentCount = 5
        consumer.onReceiveToken = { allTokensExp.fulfill() }

        for i in 0..<5 {
            yieldingFactory.stubbedBackend.yield(
                TranscribedToken(token: "word\(i)", startTime: Double(i), endTime: Double(i) + 0.5, isFinal: true)
            )
        }
        await fulfillment(of: [allTokensExp], timeout: 3.0)

        XCTAssertEqual(fakeTimer.scheduleCallCount, countAfterWiring + 5,
                       "Timer must be rescheduled exactly once per token (5 resets)")
        if case .active = sut.state { } else {
            XCTFail("Session must still be active — timer reset, not fired")
        }
    }

    func testInactivityTimer_FiresOnceOnly_NotMultipleTimes() async throws {
        let fakeTimer = FakeInactivityTimer()
        let sut = makeSUT(inactivityTimer: fakeTimer)

        var endedCount = 0
        sut.onSessionEnded { _ in endedCount += 1 }

        let (wiring, _, _, _) = makeWiring()
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        fakeTimer.fireNow()
        XCTAssertEqual(endedCount, 1, "Session must end on first fire")

        fakeTimer.fireNow()
        XCTAssertEqual(endedCount, 1, "Second fire must be a no-op (pendingAction cleared + state .idle)")
    }

    func testInactivityTimer_CleanlyCancels_OnSessionCoordinatorStop() async throws {
        let fakeTimer = FakeInactivityTimer()
        let sut = makeSUT(inactivityTimer: fakeTimer)
        sut.start()

        let (wiring, _, _, _) = makeWiring()
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        sut.stop()

        XCTAssertGreaterThanOrEqual(fakeTimer.cancelCallCount, 1,
                                    "Timer must be cancelled on SessionCoordinator.stop()")
    }

    func testInactivityTimer_FiresEvenAfterWiringFailure() async throws {
        let fakeTimer = FakeInactivityTimer()
        let sut = makeSUT(inactivityTimer: fakeTimer)

        var endedCount = 0
        sut.onSessionEnded { _ in endedCount += 1 }

        let (wiring, _, _, _) = makeWiring(engineStartShouldThrow: true)
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        XCTAssertEqual(fakeTimer.scheduleCallCount, 1,
                       "Timer must be armed at top of runSession() before wiring failure")
        if case .active = sut.state { } else {
            XCTFail("Session must still be .active after wiring failure — only timer can end it")
        }

        fakeTimer.fireNow()

        XCTAssertEqual(endedCount, 1, "Session must end on inactivity fire even after wiring failure")
        XCTAssertEqual(sut.state, .idle)
    }
}
