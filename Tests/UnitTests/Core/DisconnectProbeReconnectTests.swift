import AVFAudio
import XCTest
@testable import TalkCoach

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
final class DisconnectProbeReconnectTests: XCTestCase {

    private func makeSUT(
        coachingEnabled: Bool = true,
        audioProcessProber: (any AudioProcessProber)? = nil
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
            audioProcessProber: audioProcessProber
        )
        return (sut, defaults)
    }

    private func makeSUTWithObserver(
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
            systemEventObserver: systemEventObserver
        )
    }

    private func makeWiring(
        stubbedLocale: String = "en-US",
        backend: (any TranscriberBackend)? = nil
    // swiftlint:disable:next large_tuple
    ) -> (wiring: SessionWiring, engineProvider: ProbeTestEngineProvider, fakeLD: FakeLanguageDetector) {
        let engineProvider = ProbeTestEngineProvider()
        let pipeline = AudioPipeline(provider: engineProvider)
        let fakeLD = FakeLanguageDetector()
        fakeLD.stubbedLocale = Locale(identifier: stubbedLocale)
        let wiring = SessionWiring(
            audioPipeline: pipeline,
            languageDetector: fakeLD,
            backend: backend ?? YieldingStubBackend()
        )
        return (wiring, engineProvider, fakeLD)
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
        let fakeObserver = FakeSystemEventObserver()
        let sut = makeSUTWithObserver(systemEventObserver: fakeObserver)

        var endedSessions: [EndedSession] = []
        sut.onSessionEnded { endedSessions.append($0) }

        let (wiring, _, _) = makeWiring()
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
        let fakeObserver = FakeSystemEventObserver()
        let sut = makeSUTWithObserver(systemEventObserver: fakeObserver)

        var endedSessions: [EndedSession] = []
        sut.onSessionEnded { endedSessions.append($0) }

        let (wiring, _, _) = makeWiring()
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
        let (sut, _) = makeSUT()

        let yieldingBackend = YieldingStubBackend()
        let (wiring, _, _) = makeWiring(backend: yieldingBackend)
        sut.wiring = wiring

        XCTAssertNil(sut.lastTokenArrival, "lastTokenArrival must be nil before any session (AC-12)")

        let consumer = FakeTokenConsumer()
        sut.addConsumer(consumer)
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        let tokenExp = XCTestExpectation(description: "token consumed")
        consumer.onReceiveToken = { tokenExp.fulfill() }
        let before = Date()
        yieldingBackend.yield(
            TranscribedToken(token: "hi", startTime: 0, endTime: 0.4, isFinal: true)
        )
        await fulfillment(of: [tokenExp], timeout: 2.0)

        XCTAssertNotNil(sut.lastTokenArrival, "lastTokenArrival must be set after first token")
        XCTAssertGreaterThanOrEqual(sut.lastTokenArrival!, before)
    }

    // MARK: - T14: lastTokenArrival resets to nil after session ends

    func testLastTokenArrival_ResetsToNil_AfterSessionEnds() async throws {
        let (sut, _) = makeSUT()

        let yieldingBackend = YieldingStubBackend()
        let (wiring, _, _) = makeWiring(backend: yieldingBackend)
        sut.wiring = wiring

        let consumer = FakeTokenConsumer()
        sut.addConsumer(consumer)
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        let tokenExp = XCTestExpectation(description: "token consumed")
        consumer.onReceiveToken = { tokenExp.fulfill() }
        yieldingBackend.yield(
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
}
