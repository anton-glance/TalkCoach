// swiftlint:disable file_length
import AVFAudio
import XCTest
@testable import TalkCoach

// MARK: - FakeMicAvailabilityProber

final class FakeMicAvailabilityProber: MicAvailabilityProbing, @unchecked Sendable {
    nonisolated(unsafe) var stubbedResult: Bool = false
    nonisolated(unsafe) var probeCallCount = 0
    nonisolated(unsafe) var onProbe: (() -> Void)?

    func probe() async -> Bool {
        probeCallCount += 1
        onProbe?()
        return stubbedResult
    }
}

// MARK: - FakeSystemEventObserver

final class FakeSystemEventObserver: SystemEventObserving, @unchecked Sendable {
    nonisolated(unsafe) var startCallCount = 0
    nonisolated(unsafe) var stopCallCount = 0
    nonisolated(unsafe) var sleepHandler: (@MainActor () -> Void)?
    nonisolated(unsafe) var shutdownHandler: (@MainActor () -> Void)?

    func start(
        onSleep: @escaping @MainActor () -> Void,
        onShutdown: @escaping @MainActor () -> Void
    ) {
        startCallCount += 1
        sleepHandler = onSleep
        shutdownHandler = onShutdown
    }

    func stop() { stopCallCount += 1 }

    @MainActor func simulateSleep() { sleepHandler?() }
    @MainActor func simulateShutdown() { shutdownHandler?() }
}

// MARK: - ProbeTestEngineProvider

@MainActor
final class ProbeTestEngineProvider: AudioEngineProvider {
    var callLog: [String] = []
    var startShouldThrow = false
    var lastInstalledBlock: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
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
        if startShouldThrow { throw NSError(domain: "ProbeTestEngine", code: -1) }
        callLog.append("start")
    }
    func stop() { callLog.append("stop") }
}

// MARK: - DisconnectProbeReconnectTests

@MainActor
// swiftlint:disable:next type_body_length
final class DisconnectProbeReconnectTests: XCTestCase {

    private func makeSUT(
        coachingEnabled: Bool = true,
        inactivityTimer: any InactivityTimer = FakeInactivityTimer(),
        micProber: (any MicAvailabilityProbing)? = nil
    ) -> (sut: SessionCoordinator, defaults: UserDefaults) {
        let suiteName = "ProbeTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(coachingEnabled, forKey: "coachingEnabled")
        let settingsStore = SettingsStore(userDefaults: defaults)
        let micMonitor = MicMonitor(provider: MinimalCoreAudioProvider())
        let sut = SessionCoordinator(
            micMonitor: micMonitor,
            settingsStore: settingsStore,
            inactivityTimer: inactivityTimer,
            micProber: micProber
        )
        return (sut, defaults)
    }

    private func makeSUTWithObserver(
        inactivityTimer: any InactivityTimer = FakeInactivityTimer(),
        micProber: (any MicAvailabilityProbing)? = nil,
        systemEventObserver: any SystemEventObserving
    ) -> SessionCoordinator {
        let suiteName = "ObserverTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "coachingEnabled")
        let settingsStore = SettingsStore(userDefaults: defaults)
        let micMonitor = MicMonitor(provider: MinimalCoreAudioProvider())
        return SessionCoordinator(
            micMonitor: micMonitor,
            settingsStore: settingsStore,
            inactivityTimer: inactivityTimer,
            micProber: micProber,
            systemEventObserver: systemEventObserver
        )
    }

    private func makeWiringWithResume(
        stubbedLocale: String = "en-US",
        appleLocales: [String] = ["en-US"],
        resumeProvider: ProbeTestEngineProvider? = nil
    // swiftlint:disable:next large_tuple
    ) -> (
        wiring: SessionWiring,
        engineProvider: ProbeTestEngineProvider,
        fakeLD: FakeLanguageDetector,
        resumeProvider: ProbeTestEngineProvider
    ) {
        let engineProvider = ProbeTestEngineProvider()
        let pipeline = AudioPipeline(provider: engineProvider)
        let fakeLD = FakeLanguageDetector()
        fakeLD.stubbedLocale = Locale(identifier: stubbedLocale)

        let localesProvider = FakeSupportedLocalesProvider()
        localesProvider.locales = appleLocales.map { Locale(identifier: $0) }

        let resolvedResumeProvider = resumeProvider ?? ProbeTestEngineProvider()

        let wiring = SessionWiring(
            audioPipeline: pipeline,
            languageDetector: fakeLD,
            appleBackendFactory: TestAppleBackendFactory(),
            parakeetBackendFactory: TestParakeetBackendFactory(),
            supportedLocalesProvider: localesProvider,
            resumePipelineProvider: resolvedResumeProvider
        )
        return (wiring, engineProvider, fakeLD, resolvedResumeProvider)
    }

    // MARK: - T1: inactivityThresholdSeconds from settings (not hardcoded 30)

    func testInactivityThreshold_UsesSetting_NotHardcoded30() async throws {
        let fakeTimer = FakeInactivityTimer()
        let (sut, _) = makeSUT(inactivityTimer: fakeTimer)

        let (wiring, _, _, _) = makeWiringWithResume()
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        XCTAssertEqual(fakeTimer.lastScheduledTimeout, 15,
                       "Timer must use inactivityThresholdSeconds=15 from settings, not hardcoded 30")
    }

    // MARK: - T2: IRS=false → session finalized after probe

    func testProbe_IRSFalse_FinalizesSession() async throws {
        let fakeTimer = FakeInactivityTimer()
        let prober = FakeMicAvailabilityProber()
        prober.stubbedResult = false // IRS=false → no other app using mic → finalize

        let (sut, _) = makeSUT(inactivityTimer: fakeTimer, micProber: prober)

        var endedSessions: [EndedSession] = []
        sut.onSessionEnded { endedSessions.append($0) }

        let (wiring, _, _, _) = makeWiringWithResume()
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        let probeExp = XCTestExpectation(description: "session finalized after IRS=false probe")
        sut.onSessionEnded { _ in probeExp.fulfill() }
        fakeTimer.fireNow()
        await fulfillment(of: [probeExp], timeout: 3.0)

        XCTAssertGreaterThanOrEqual(prober.probeCallCount, 1, "Probe must be invoked")
        XCTAssertEqual(sut.state, .idle,
                       "Session must finalize when IRS=false (no other app is using the mic)")
    }

    // MARK: - T3: IRS=true → session resumed, state still .active, same session ID

    func testProbe_IRSTrue_ResumesSession_StateRemainsActive() async throws {
        let fakeTimer = FakeInactivityTimer()
        let prober = FakeMicAvailabilityProber()
        prober.stubbedResult = true // IRS=true → another app IS using mic → resume

        let (sut, _) = makeSUT(inactivityTimer: fakeTimer, micProber: prober)

        var endedCount = 0
        sut.onSessionEnded { _ in endedCount += 1 }

        let (wiring, _, _, _) = makeWiringWithResume()
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        let originalID: UUID
        if case .active(let ctx) = sut.state {
            originalID = ctx.id
        } else {
            XCTFail("Must be active before probe"); return
        }

        fakeTimer.fireNow()
        try await Task.sleep(for: .milliseconds(500))

        if case .active(let ctx) = sut.state {
            XCTAssertEqual(ctx.id, originalID,
                           "Session ID must be preserved across probe+resume (AC-9)")
        } else {
            XCTFail("Session must remain .active when IRS=true (another app is using the mic)")
        }
        XCTAssertEqual(endedCount, 0, "onSessionEnded must NOT fire when IRS=true")
    }

    // MARK: - T4: probeInFlight guard — micDeactivated() is no-op during probe

    func testMicDeactivated_IsNoOp_WhileProbeInFlight() async throws {
        let fakeTimer = FakeInactivityTimer()
        let prober = FakeMicAvailabilityProber()
        prober.stubbedResult = true // probe resolves to resume

        let (sut, _) = makeSUT(inactivityTimer: fakeTimer, micProber: prober)

        var endedCount = 0
        sut.onSessionEnded { _ in endedCount += 1 }

        let (wiring, _, _, _) = makeWiringWithResume()
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        fakeTimer.fireNow()
        // Immediately call micDeactivated() while probe is logically in flight.
        // probeInFlight guard must suppress this call.
        sut.micDeactivated()
        try await Task.sleep(for: .milliseconds(500))

        // Probe resolved IRS=true → resume. micDeactivated() was no-op.
        XCTAssertEqual(endedCount, 0,
                       "micDeactivated() during probe must be a no-op — probeInFlight guard must engage (AC-10)")
    }

    // MARK: - T5: Resume creates new AudioPipeline via resumePipelineProvider

    func testResume_CreatesNewPipeline_ViaResumePipelineProvider() async throws {
        let fakeTimer = FakeInactivityTimer()
        let prober = FakeMicAvailabilityProber()
        prober.stubbedResult = true

        let (sut, _) = makeSUT(inactivityTimer: fakeTimer, micProber: prober)

        let resumeProvider = ProbeTestEngineProvider()
        let (wiring, _, _, _) = makeWiringWithResume(resumeProvider: resumeProvider)
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        fakeTimer.fireNow()
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertTrue(resumeProvider.callLog.contains("start"),
                      "Resume must use resumePipelineProvider to create new AudioPipeline; log=\(resumeProvider.callLog)")
    }

    // MARK: - T6: Resume skips LD.start(), uses cached locale

    func testResume_SkipsLanguageDetector_UsesCachedLocale() async throws {
        let fakeTimer = FakeInactivityTimer()
        let prober = FakeMicAvailabilityProber()
        prober.stubbedResult = true

        let (sut, _) = makeSUT(inactivityTimer: fakeTimer, micProber: prober)

        let (wiring, _, fakeLD, _) = makeWiringWithResume()
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        let ldCallsAfterInit = fakeLD.startCallCount

        fakeTimer.fireNow()
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(fakeLD.startCallCount, ldCallsAfterInit,
                       "LD.start() must NOT be called on resume — cached locale must be reused (AC-11)")
    }

    // MARK: - T7: HAL settling wait ≥100ms before probe() is called

    func testHALSettlingWait_AtLeast100ms_BeforeProbe() async throws {
        let fakeTimer = FakeInactivityTimer()
        let prober = FakeMicAvailabilityProber()
        prober.stubbedResult = false

        let (sut, _) = makeSUT(inactivityTimer: fakeTimer, micProber: prober)

        let (wiring, _, _, _) = makeWiringWithResume()
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        let fireTime = Date()
        let probeCalledExp = XCTestExpectation(description: "probe() called")
        var probeCallTime: Date?
        prober.onProbe = {
            probeCallTime = Date()
            probeCalledExp.fulfill()
        }

        fakeTimer.fireNow()
        await fulfillment(of: [probeCalledExp], timeout: 3.0)

        let elapsedMs = probeCallTime!.timeIntervalSince(fireTime) * 1000
        XCTAssertGreaterThanOrEqual(elapsedMs, 100.0,
                                    "probe() must not be called until ≥100ms after timer fires (HAL settling, Spike #13.5); elapsed=\(Int(elapsedMs))ms")
    }

    // MARK: - T8: No micProber → inactivity directly finalizes (backward compat)
    // Wiring must be set for the timer to be scheduled (timer arms inside runSession).
    // With wiring but no micProber, timer fires → direct finalize (no probe).

    func testNoProber_InactivityTimer_DirectlyFinalizesSession() async throws {
        let fakeTimer = FakeInactivityTimer()
        let (sut, _) = makeSUT(inactivityTimer: fakeTimer, micProber: nil)

        var endedCount = 0
        sut.onSessionEnded { _ in endedCount += 1 }

        let (wiring, _, _, _) = makeWiringWithResume()
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        fakeTimer.fireNow()

        XCTAssertEqual(endedCount, 1,
                       "Without a micProber, inactivity must directly finalize the session (backward compat)")
        XCTAssertEqual(sut.state, .idle)
    }

    // MARK: - T9: requestFinalize() ends active session

    func testRequestFinalize_EndsActiveSession() {
        let (sut, _) = makeSUT()

        var endedCount = 0
        sut.onSessionEnded { _ in endedCount += 1 }

        sut.micActivated()
        if case .active = sut.state { } else {
            XCTFail("Must be active"); return
        }

        sut.requestFinalize()

        XCTAssertEqual(endedCount, 1, "requestFinalize() must end the active session (AC-13)")
        XCTAssertEqual(sut.state, .idle)
    }

    func testRequestFinalize_IsNoOp_WhenIdle() {
        let (sut, _) = makeSUT()

        var endedCount = 0
        sut.onSessionEnded { _ in endedCount += 1 }

        sut.requestFinalize()

        XCTAssertEqual(endedCount, 0, "requestFinalize() must be no-op when idle")
    }

    // MARK: - T10: System sleep finalizes active session

    func testSystemSleep_FinalizesActiveSession() async throws {
        let fakeTimer = FakeInactivityTimer()
        let fakeObserver = FakeSystemEventObserver()
        let sut = makeSUTWithObserver(
            inactivityTimer: fakeTimer,
            micProber: nil,
            systemEventObserver: fakeObserver
        )

        var endedSessions: [EndedSession] = []
        sut.onSessionEnded { endedSessions.append($0) }

        let (wiring, _, _, _) = makeWiringWithResume()
        sut.wiring = wiring
        sut.start()
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        XCTAssertEqual(fakeObserver.startCallCount, 1, "SystemEventObserver must be started on coordinator.start()")

        fakeObserver.simulateSleep()

        XCTAssertEqual(endedSessions.count, 1, "Sleep event must finalize the active session (AC-14)")
        XCTAssertEqual(sut.state, .idle)
    }

    // MARK: - T11: System shutdown finalizes active session

    func testSystemShutdown_FinalizesActiveSession() async throws {
        let fakeTimer = FakeInactivityTimer()
        let fakeObserver = FakeSystemEventObserver()
        let sut = makeSUTWithObserver(
            inactivityTimer: fakeTimer,
            micProber: nil,
            systemEventObserver: fakeObserver
        )

        var endedSessions: [EndedSession] = []
        sut.onSessionEnded { endedSessions.append($0) }

        let (wiring, _, _, _) = makeWiringWithResume()
        sut.wiring = wiring
        sut.start()
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        fakeObserver.simulateShutdown()

        XCTAssertEqual(endedSessions.count, 1, "Shutdown event must finalize the active session (AC-14)")
        XCTAssertEqual(sut.state, .idle)
    }

    // MARK: - T12: SystemEventObserver stopped on coordinator.stop()

    func testSystemEventObserver_Stopped_OnCoordinatorStop() {
        let fakeObserver = FakeSystemEventObserver()
        let sut = makeSUTWithObserver(systemEventObserver: fakeObserver)

        sut.start()
        XCTAssertEqual(fakeObserver.startCallCount, 1,
                       "SystemEventObserver must be started when coordinator starts")

        sut.stop()
        XCTAssertEqual(fakeObserver.stopCallCount, 1,
                       "SystemEventObserver must be stopped when coordinator stops")
    }

    // MARK: - T13: lastTokenArrival is nil initially, set after first token

    func testLastTokenArrival_NilInitially_ThenSetsOnToken() async throws {
        let fakeTimer = FakeInactivityTimer()
        let (sut, _) = makeSUT(inactivityTimer: fakeTimer)

        let yieldingFactory = YieldingAppleBackendFactory()
        let engineProvider = ProbeTestEngineProvider()
        let pipeline = AudioPipeline(provider: engineProvider)
        let fakeLD = FakeLanguageDetector()
        let locales = FakeSupportedLocalesProvider()
        locales.locales = [Locale(identifier: "en-US")]

        let wiring = SessionWiring(
            audioPipeline: pipeline,
            languageDetector: fakeLD,
            appleBackendFactory: yieldingFactory,
            parakeetBackendFactory: TestParakeetBackendFactory(),
            supportedLocalesProvider: locales,
            resumePipelineProvider: nil
        )
        sut.wiring = wiring

        XCTAssertNil(sut.lastTokenArrival, "lastTokenArrival must be nil before any session (AC-12)")

        let consumer = FakeTokenConsumer()
        sut.addConsumer(consumer)
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        let tokenExp = XCTestExpectation(description: "token consumed")
        consumer.onReceiveToken = { tokenExp.fulfill() }
        let before = Date()
        yieldingFactory.stubbedBackend.yield(
            TranscribedToken(token: "hi", startTime: 0, endTime: 0.4, isFinal: true)
        )
        await fulfillment(of: [tokenExp], timeout: 2.0)

        XCTAssertNotNil(sut.lastTokenArrival, "lastTokenArrival must be set after first token")
        XCTAssertGreaterThanOrEqual(sut.lastTokenArrival!, before)
    }

    // MARK: - T14: lastTokenArrival resets to nil after session ends

    func testLastTokenArrival_ResetsToNil_AfterSessionEnds() async throws {
        let fakeTimer = FakeInactivityTimer()
        let (sut, _) = makeSUT(inactivityTimer: fakeTimer)

        let yieldingFactory = YieldingAppleBackendFactory()
        let engineProvider = ProbeTestEngineProvider()
        let pipeline = AudioPipeline(provider: engineProvider)
        let fakeLD = FakeLanguageDetector()
        let locales = FakeSupportedLocalesProvider()
        locales.locales = [Locale(identifier: "en-US")]

        let wiring = SessionWiring(
            audioPipeline: pipeline,
            languageDetector: fakeLD,
            appleBackendFactory: yieldingFactory,
            parakeetBackendFactory: TestParakeetBackendFactory(),
            supportedLocalesProvider: locales,
            resumePipelineProvider: nil
        )
        sut.wiring = wiring

        let consumer = FakeTokenConsumer()
        sut.addConsumer(consumer)
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        let tokenExp = XCTestExpectation(description: "token consumed")
        consumer.onReceiveToken = { tokenExp.fulfill() }
        yieldingFactory.stubbedBackend.yield(
            TranscribedToken(token: "hi", startTime: 0, endTime: 0.4, isFinal: true)
        )
        await fulfillment(of: [tokenExp], timeout: 2.0)
        XCTAssertNotNil(sut.lastTokenArrival)

        let teardownExp = XCTestExpectation(description: "teardown complete")
        consumer.onSessionEnded = { teardownExp.fulfill() }
        sut.micDeactivated()
        await fulfillment(of: [teardownExp], timeout: 3.0)

        XCTAssertNil(sut.lastTokenArrival,
                     "lastTokenArrival must reset to nil after session ends (AC-12)")
    }

    // MARK: - T15: effectiveSpeakingDuration field exists on SessionRecord (AC-16)

    func testEffectiveSpeakingDuration_ExistsAndIsMutable_OnSessionRecord() {
        var record = SessionRecord.placeholder(from: EndedSession(
            id: UUID(),
            startedAt: Date().addingTimeInterval(-60),
            endedAt: Date()
        ))
        record.effectiveSpeakingDuration = 42.5
        XCTAssertEqual(record.effectiveSpeakingDuration, 42.5, accuracy: 0.001,
                       "effectiveSpeakingDuration must exist and be mutable on SessionRecord (AC-16)")
    }

    // MARK: - T16: stop() during probe does not double-finalize session

    func testStop_DuringProbe_DoesNotDoubleFinalizeSession() async throws {
        let fakeTimer = FakeInactivityTimer()
        let prober = FakeMicAvailabilityProber()
        prober.stubbedResult = false

        let (sut, _) = makeSUT(inactivityTimer: fakeTimer, micProber: prober)

        var endedCount = 0
        sut.onSessionEnded { _ in endedCount += 1 }

        let (wiring, _, _, _) = makeWiringWithResume()
        sut.wiring = wiring
        sut.start()
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        fakeTimer.fireNow()
        sut.stop()
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertLessThanOrEqual(endedCount, 1,
                                 "Session must not be finalized more than once (stop + probe race)")
        XCTAssertEqual(sut.state, .idle)
    }

    // MARK: - T-FIX-4: Session-end reason is structured and correct per trigger source (AC-FIX-5)

    func testSessionEndReason_XButton() {
        let (sut, _) = makeSUT()
        sut.start()
        sut.micActivated()
        sut.requestFinalize()
        XCTAssertEqual(sut.lastEndReason, .xButton, "requestFinalize must record reason .xButton")
    }

    func testSessionEndReason_Quit() {
        let (sut, _) = makeSUT()
        sut.start()
        sut.micActivated()
        sut.stop()
        XCTAssertEqual(sut.lastEndReason, .quit, "stop() must record reason .quit")
    }

    func testSessionEndReason_Sleep() {
        let fakeObserver = FakeSystemEventObserver()
        let sut = makeSUTWithObserver(systemEventObserver: fakeObserver)
        sut.start()
        sut.micActivated()
        fakeObserver.simulateSleep()
        XCTAssertEqual(sut.lastEndReason, .sleep, "System sleep must record reason .sleep")
    }

    func testSessionEndReason_Shutdown() {
        let fakeObserver = FakeSystemEventObserver()
        let sut = makeSUTWithObserver(systemEventObserver: fakeObserver)
        sut.start()
        sut.micActivated()
        fakeObserver.simulateShutdown()
        XCTAssertEqual(sut.lastEndReason, .shutdown, "System shutdown must record reason .shutdown")
    }

    func testSessionEndReason_CoachingDisabled() async {
        let (sut, defaults) = makeSUT()
        sut.start()
        sut.micActivated()
        defaults.set(false, forKey: "coachingEnabled")
        await Task.yield()
        XCTAssertEqual(sut.lastEndReason, .coachingDisabled,
                       "Coaching disabled mid-session must record reason .coachingDisabled")
    }

    func testSessionEndReason_MicOffListener() {
        let (sut, _) = makeSUT()
        sut.start()
        sut.micActivated()
        sut.micDeactivated()
        XCTAssertEqual(sut.lastEndReason, .micOffListener,
                       "micDeactivated must record reason .micOffListener")
    }

    // MARK: - T-FIX3-B2: captureActivityState transitions probing → resuming → waiting (AC-FIX3-B2)

    func testActivityState_TransitionsToProbingThenResuming() async throws {
        let fakeTimer = FakeInactivityTimer()
        let prober = FakeMicAvailabilityProber()
        prober.stubbedResult = true // IRS=true → resume

        let suiteName = "CaptureActivity.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "coachingEnabled")
        let settingsStore = SettingsStore(userDefaults: defaults)
        let micMonitor = MicMonitor(provider: MinimalCoreAudioProvider())
        let sut = SessionCoordinator(
            micMonitor: micMonitor,
            settingsStore: settingsStore,
            inactivityTimer: fakeTimer,
            micProber: prober,
            resumingHoldDuration: 0.1
        )

        let (wiring, _, _, _) = makeWiringWithResume()
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        XCTAssertEqual(sut.captureActivityState, .waiting,
                       "captureActivityState must start as .waiting (AC-FIX3-B2)")

        fakeTimer.fireNow()
        // handleInactivityTimeout sets captureActivityState = .probing synchronously before async task
        XCTAssertEqual(sut.captureActivityState, .probing,
                       "captureActivityState must be .probing immediately after inactivity fires (AC-FIX3-B2)")

        // Wait past HAL settling (100ms) + probe + resumeSession + resumingHoldDuration (100ms)
        try await Task.sleep(for: .milliseconds(800))

        XCTAssertEqual(sut.captureActivityState, .waiting,
                       "captureActivityState must return to .waiting after resume hold completes (AC-FIX3-B2)")
    }
}
