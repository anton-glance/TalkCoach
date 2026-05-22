// swiftlint:disable file_length
import Combine
import CoreAudio
import XCTest
@testable import TalkCoach

// MARK: - VadStubBackend

private final class VadStubBackend: TranscriberBackend, @unchecked Sendable {
    private let tokenCont: AsyncStream<TranscribedToken>.Continuation
    let tokenStream: AsyncStream<TranscribedToken>
    let engineReadyStream: AsyncStream<Void> = AsyncStream { $0.yield(()); $0.finish() }
    private let vadCont: AsyncStream<Bool>.Continuation
    let vadActivityStream: AsyncStream<Bool>

    init() {
        // swiftlint:disable:next identifier_name
        var tc: AsyncStream<TranscribedToken>.Continuation!
        tokenStream = AsyncStream { tc = $0 }
        tokenCont = tc
        // swiftlint:disable:next identifier_name
        var vc: AsyncStream<Bool>.Continuation!
        vadActivityStream = AsyncStream { vc = $0 }
        vadCont = vc
    }

    func start(locale: Locale, audioProvider: (any AudioBufferProvider)?) async throws {}
    func stop() async { tokenCont.finish(); vadCont.finish() }
    func yieldVad(_ hasVoice: Bool) { vadCont.yield(hasVoice) }
}

// MARK: - Fake Provider (duplicated from MicMonitorTests — Convention 6: drive real MicMonitor)

private final class FakeCoreAudioDeviceProvider: CoreAudioDeviceProvider, @unchecked Sendable {
    nonisolated(unsafe) var stubbedDefaultDeviceID: AudioObjectID? = 42
    nonisolated(unsafe) var stubbedIsRunning: Bool = false
    nonisolated(unsafe) private(set) var addIsRunningListenerCallCount = 0
    nonisolated(unsafe) private(set) var removeIsRunningListenerCallCount = 0
    nonisolated(unsafe) private(set) var addDefaultDeviceListenerCallCount = 0
    nonisolated(unsafe) private(set) var removeDefaultDeviceListenerCallCount = 0
    nonisolated(unsafe) private(set) var isRunningHandler: (@Sendable () -> Void)?
    nonisolated(unsafe) private(set) var defaultDeviceHandler: (@Sendable () -> Void)?
    private final class Token {}

    nonisolated func defaultInputDeviceID() -> AudioObjectID? { stubbedDefaultDeviceID }
    nonisolated func isDeviceRunningSomewhere(_ deviceID: AudioObjectID) -> Bool? { stubbedIsRunning }

    nonisolated func addIsRunningListener(
        device: AudioObjectID, handler: @escaping @Sendable () -> Void
    ) -> AnyObject? {
        addIsRunningListenerCallCount += 1
        isRunningHandler = handler
        return Token()
    }

    nonisolated func removeIsRunningListener(device: AudioObjectID, token: AnyObject) {
        removeIsRunningListenerCallCount += 1
    }

    nonisolated func addDefaultDeviceListener(
        handler: @escaping @Sendable () -> Void
    ) -> AnyObject? {
        addDefaultDeviceListenerCallCount += 1
        defaultDeviceHandler = handler
        return Token()
    }

    nonisolated func removeDefaultDeviceListener(token: AnyObject) {
        removeDefaultDeviceListenerCallCount += 1
    }

    func simulateIsRunningChange() { isRunningHandler?() }
    func simulateDefaultDeviceChange() { defaultDeviceHandler?() }
}

// MARK: - Tests

@MainActor
// swiftlint:disable:next type_body_length
final class SessionCoordinatorTests: XCTestCase {

    private var fake: FakeCoreAudioDeviceProvider!
    private var settingsStore: SettingsStore!
    private var defaults: UserDefaults!
    private var sut: SessionCoordinator!

    private func makeSUT(
        coachingEnabled: Bool = true,
        isRunning: Bool = false,
        defaultDeviceID: AudioObjectID? = 42
    ) {
        defaults = UserDefaults(suiteName: "SessionCoordinatorTests.\(name)")!
        defaults.removePersistentDomain(forName: "SessionCoordinatorTests.\(name)")
        defaults.set(coachingEnabled, forKey: "coachingEnabled")
        settingsStore = SettingsStore(userDefaults: defaults)
        fake = FakeCoreAudioDeviceProvider()
        fake.stubbedDefaultDeviceID = defaultDeviceID
        fake.stubbedIsRunning = isRunning
        let micMonitor = MicMonitor(provider: fake)
        sut = SessionCoordinator(
            micMonitor: micMonitor,
            settingsStore: settingsStore
        )
    }

    // MARK: - Session lifecycle

    func testMicActivatedWithCoachingEnabledStartsSession() async {
        makeSUT(coachingEnabled: true, isRunning: false)
        sut.start()
        fake.stubbedIsRunning = true
        fake.simulateIsRunningChange()
        await Task.yield()

        guard case .active(let ctx) = sut.state else {
            XCTFail("Expected .active state, got \(sut.state)")
            return
        }
        XCTAssertNotNil(ctx.id)
        XCTAssertEqual(ctx.startedAt.timeIntervalSinceNow, 0, accuracy: 1.0)
    }

    func testMicActivatedWithCoachingDisabledDoesNotStartSession() async {
        makeSUT(coachingEnabled: false, isRunning: false)
        sut.start()
        var endedSessionReceived = false
        sut.onSessionEnded { _ in endedSessionReceived = true }
        fake.stubbedIsRunning = true
        fake.simulateIsRunningChange()
        await Task.yield()
        XCTAssertEqual(sut.state, .idle)
        XCTAssertFalse(endedSessionReceived)
    }

    func testMicDeactivatedDuringActiveSessionEndsSession() async {
        makeSUT(coachingEnabled: true, isRunning: false)
        sut.start()
        var endedSession: EndedSession?
        sut.onSessionEnded { endedSession = $0 }

        fake.stubbedIsRunning = true
        fake.simulateIsRunningChange()
        await Task.yield()

        guard case .active(let ctx) = sut.state else {
            XCTFail("Expected .active state")
            return
        }
        let sessionID = ctx.id
        let startedAt = ctx.startedAt

        fake.stubbedIsRunning = false
        fake.simulateIsRunningChange()
        await Task.yield()

        XCTAssertEqual(sut.state, .idle)
        XCTAssertNotNil(endedSession)
        XCTAssertEqual(endedSession?.id, sessionID)
        XCTAssertEqual(endedSession?.startedAt, startedAt)
        XCTAssertEqual(endedSession?.endedAt.timeIntervalSinceNow ?? -999, 0, accuracy: 1.0)
    }

    func testMicDeactivatedWhileIdleIsNoOp() async {
        makeSUT(coachingEnabled: true, isRunning: false)
        sut.start()
        var endedSessionReceived = false
        sut.onSessionEnded { _ in endedSessionReceived = true }
        fake.stubbedIsRunning = false
        fake.simulateIsRunningChange()
        await Task.yield()
        XCTAssertEqual(sut.state, .idle)
        XCTAssertFalse(endedSessionReceived)
    }

    // MARK: - Multiple sessions and uniqueness

    func testSequentialSessionsHaveUniqueIds() async {
        makeSUT(coachingEnabled: true, isRunning: false)
        sut.start()
        var endedSessions: [EndedSession] = []
        sut.onSessionEnded { endedSessions.append($0) }

        for _ in 0..<2 {
            fake.stubbedIsRunning = true
            fake.simulateIsRunningChange()
            await Task.yield()
            fake.stubbedIsRunning = false
            fake.simulateIsRunningChange()
            await Task.yield()
        }

        XCTAssertEqual(endedSessions.count, 2)
        XCTAssertNotEqual(endedSessions[0].id, endedSessions[1].id)
        XCTAssertNotEqual(endedSessions[0].startedAt, endedSessions[1].startedAt)
    }

    func testRapidMicTogglesCreateMultipleDistinctSessions() async {
        makeSUT(coachingEnabled: true, isRunning: false)
        sut.start()
        var endedSessions: [EndedSession] = []
        sut.onSessionEnded { endedSessions.append($0) }

        for _ in 0..<5 {
            fake.stubbedIsRunning = true
            fake.simulateIsRunningChange()
            await Task.yield()
            fake.stubbedIsRunning = false
            fake.simulateIsRunningChange()
            await Task.yield()
        }

        XCTAssertEqual(endedSessions.count, 5)
        let ids = Set(endedSessions.map(\.id))
        XCTAssertEqual(ids.count, 5, "All session IDs must be unique")
    }

    func testDuplicateMicActivatedWhileActiveIsNoOp() async {
        makeSUT(coachingEnabled: true, isRunning: false)
        sut.start()
        var endedSessions: [EndedSession] = []
        sut.onSessionEnded { endedSessions.append($0) }

        fake.stubbedIsRunning = true
        fake.simulateIsRunningChange()
        await Task.yield()
        guard case .active(let firstCtx) = sut.state else {
            XCTFail("Expected .active state")
            return
        }

        fake.simulateIsRunningChange()
        await Task.yield()
        guard case .active(let secondCtx) = sut.state else {
            XCTFail("Expected .active state to persist")
            return
        }
        XCTAssertEqual(firstCtx.id, secondCtx.id, "Session ID must not change on duplicate activation")
        XCTAssertTrue(endedSessions.isEmpty, "No session should have ended")
    }

    // MARK: - Pause / Resume coaching

    func testPauseMidSessionTerminatesActiveSession() async {
        makeSUT(coachingEnabled: true, isRunning: false)
        sut.start()
        var endedSession: EndedSession?
        sut.onSessionEnded { endedSession = $0 }

        fake.stubbedIsRunning = true
        fake.simulateIsRunningChange()
        await Task.yield()
        guard case .active(let ctx) = sut.state else {
            XCTFail("Expected .active state")
            return
        }
        let sessionID = ctx.id

        settingsStore.coachingEnabled = false
        await Task.yield()
        XCTAssertEqual(sut.state, .idle)
        XCTAssertNotNil(endedSession)
        XCTAssertEqual(endedSession?.id, sessionID)
    }

    func testResumeWhileMicStillActiveDoesNotStartNewSession() async {
        makeSUT(coachingEnabled: true, isRunning: false)
        sut.start()
        sut.onSessionEnded { _ in }

        fake.stubbedIsRunning = true
        fake.simulateIsRunningChange()
        await Task.yield()
        XCTAssertNotEqual(sut.state, .idle)

        settingsStore.coachingEnabled = false
        await Task.yield()
        XCTAssertEqual(sut.state, .idle)

        settingsStore.coachingEnabled = true
        await Task.yield()
        XCTAssertEqual(sut.state, .idle, "No new session should start on resume alone")
    }

    // MARK: - Start / Stop lifecycle

    func testStartInitializesMicMonitor() {
        makeSUT(coachingEnabled: true, isRunning: false)
        sut.start()
        XCTAssertGreaterThanOrEqual(fake.addIsRunningListenerCallCount, 1)
        XCTAssertGreaterThanOrEqual(fake.addDefaultDeviceListenerCallCount, 1)
    }

    func testStopTearsDownMicMonitorAndEndsActiveSession() async {
        makeSUT(coachingEnabled: true, isRunning: false)
        sut.start()
        var endedSession: EndedSession?
        sut.onSessionEnded { endedSession = $0 }

        fake.stubbedIsRunning = true
        fake.simulateIsRunningChange()
        await Task.yield()
        XCTAssertNotEqual(sut.state, .idle)

        sut.stop()
        XCTAssertEqual(sut.state, .idle)
        XCTAssertNotNil(endedSession, "Active session should end on stop()")
        XCTAssertFalse(sut.isRunning)
    }

    func testStartIdempotent() {
        makeSUT(coachingEnabled: true, isRunning: false)
        sut.start()
        sut.start()
        XCTAssertEqual(fake.addDefaultDeviceListenerCallCount, 1)
    }

    func testStopIdempotent() {
        makeSUT(coachingEnabled: true, isRunning: false)
        sut.stop()
        sut.start()
        sut.stop()
        sut.stop()
        XCTAssertFalse(sut.isRunning)
    }

    // MARK: - Consumer contract

    func testConsumerNotificationsOnMainActor() async {
        makeSUT(coachingEnabled: true, isRunning: false)
        sut.start()
        var handlerCalled = false
        sut.onSessionEnded { _ in
            MainActor.assertIsolated()
            handlerCalled = true
        }

        fake.stubbedIsRunning = true
        fake.simulateIsRunningChange()
        await Task.yield()
        fake.stubbedIsRunning = false
        fake.simulateIsRunningChange()
        await Task.yield()
        XCTAssertTrue(handlerCalled)
    }

    func testCoachingEnabledLiveSync() async {
        makeSUT(coachingEnabled: false, isRunning: false)
        sut.start()

        fake.stubbedIsRunning = true
        fake.simulateIsRunningChange()
        await Task.yield()
        XCTAssertEqual(sut.state, .idle)

        fake.stubbedIsRunning = false
        fake.simulateIsRunningChange()
        await Task.yield()

        settingsStore.coachingEnabled = true

        fake.stubbedIsRunning = true
        fake.simulateIsRunningChange()
        await Task.yield()
        XCTAssertNotEqual(sut.state, .idle, "Session should start after coaching re-enabled")
    }

    // MARK: - Engine-ready behavior

    func testEngineReady_PublishesLastEngineReadyAt() async throws {
        makeSUT()
        let yieldingBackend = YieldingStubBackend()
        let engineProvider = ProbeTestEngineProvider()
        let pipeline = AudioPipeline(provider: engineProvider)
        let fakeLD = FakeLanguageDetector()
        sut.wiring = SessionWiring(
            audioPipeline: pipeline,
            languageDetector: fakeLD,
            backend: yieldingBackend
        )

        sut.start()
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }
        // engineReadyTask runs in parallel with sessionWiringTask — await it separately.
        if let task = sut.engineReadyTask { await task.value }

        XCTAssertNotNil(sut.lastEngineReadyAt,
                        "lastEngineReadyAt must be set when engine-ready signal arrives from backend")
    }

    func testEngineReadyTask_DoesNotBlockRelayTask_WhenEngineReadyNeverFires() async throws {
        makeSUT()
        let neverReadyBackend = NeverReadyStubBackend()
        let engineProvider = ProbeTestEngineProvider()
        let pipeline = AudioPipeline(provider: engineProvider)
        let fakeLD = FakeLanguageDetector()

        let consumer = FakeTokenConsumer()
        sut.addConsumer(consumer)
        sut.wiring = SessionWiring(
            audioPipeline: pipeline,
            languageDetector: fakeLD,
            backend: neverReadyBackend
        )

        sut.start()
        sut.micActivated()
        // sessionWiringTask completes as soon as all tasks are spawned —
        // engineReadyStream never yielding must NOT block this.
        if let task = sut.sessionWiringTask { await task.value }

        // relayTask is running concurrently — verify it can receive and forward tokens
        let tokenExp = XCTestExpectation(description: "token relayed even without engine-ready")
        consumer.onReceiveToken = { tokenExp.fulfill() }
        neverReadyBackend.yield(
            TranscribedToken(token: "hi", startTime: 0, endTime: 0.1, isFinal: true)
        )
        await fulfillment(of: [tokenExp], timeout: 2.0)
    }

    // MARK: - VAD debounce (AC-4.5)

    func testDebounceVadFalseFor200msSetsIsVoiceInactive() async throws {
        makeSUT()
        let vadBackend = VadStubBackend()
        sut.wiring = SessionWiring(
            audioPipeline: AudioPipeline(provider: ProbeTestEngineProvider()),
            languageDetector: FakeLanguageDetector(),
            backend: vadBackend
        )
        sut.start()
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        // t0: first false — debounce must prevent immediate flip.
        // Use a 20ms sleep (not Task.yield) to guarantee the passthrough has fired before asserting.
        vadBackend.yieldVad(false)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(sut.isVoiceInactive,
                       "Must not flip isVoiceInactive on first false at t0 (200ms debounce required)")

        // t0+120ms: still within debounce window
        try await Task.sleep(for: .milliseconds(100))
        vadBackend.yieldVad(false)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(sut.isVoiceInactive,
                       "Must not flip isVoiceInactive at t0+120ms (120ms < 200ms threshold)")

        // t0+350ms total: threshold crossed — must flip
        try await Task.sleep(for: .milliseconds(210))
        vadBackend.yieldVad(false)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(sut.isVoiceInactive,
                      "Must flip isVoiceInactive after sustained false exceeding 200ms threshold")
    }

    func testVadTrueImmediatelyClearsIsVoiceInactive() async throws {
        makeSUT()
        let vadBackend = VadStubBackend()
        sut.wiring = SessionWiring(
            audioPipeline: AudioPipeline(provider: ProbeTestEngineProvider()),
            languageDetector: FakeLanguageDetector(),
            backend: vadBackend
        )
        sut.start()
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        // Confirm debounce is active — first false must not flip immediately.
        // Use a 20ms sleep to guarantee the passthrough has fired before asserting.
        vadBackend.yieldVad(false)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(sut.isVoiceInactive,
                       "Must not flip immediately on first false — confirms debounce is active")

        // Sustain false past 200ms threshold to reach isVoiceInactive == true
        try await Task.sleep(for: .milliseconds(230))
        vadBackend.yieldVad(false)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(sut.isVoiceInactive,
                      "Must be true after sustained false for 250ms (setup for immediate-clear test)")

        // Single true must clear isVoiceInactive immediately — no debounce on voice onset
        vadBackend.yieldVad(true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(sut.isVoiceInactive,
                       "True must clear isVoiceInactive immediately within one Task.yield() tick (no debounce on voice onset)")
    }
}
