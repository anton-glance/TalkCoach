import AVFAudio
import XCTest
@testable import TalkCoach

// MARK: - SwitchTestEngineProvider

@MainActor
private final class SwitchTestEngineProvider: AudioEngineProvider {
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
        if startShouldThrow { throw NSError(domain: "SwitchTestEngine", code: -1) }
        callLog.append("start")
    }
    func stop() { callLog.append("stop") }
    func recreate() { callLog.append("recreate") }
    func inputNodeInputFormat() -> AVAudioFormat? { nil }
}

// MARK: - SwitchTestScheduler

@MainActor
private final class SwitchTestScheduler: HideScheduler {
    private struct Entry {
        let token: HideSchedulerToken
        let action: @MainActor @Sendable () -> Void
    }
    private var entries: [Entry] = []

    func schedule(
        delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> HideSchedulerToken {
        let token = HideSchedulerToken()
        entries.append(Entry(token: token, action: action))
        return token
    }
    func cancel(_ token: HideSchedulerToken) {
        entries.removeAll { $0.token == token }
    }
    func fireNext() {
        guard !entries.isEmpty else { return }
        let e = entries.removeFirst()
        e.action()
    }
}

// MARK: - SwitchTestClock

private final class SwitchTestClock: @unchecked Sendable {
    var current: Date = Date(timeIntervalSinceReferenceDate: 100)
    func now() -> Date { current }
    func advance(by seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}

// MARK: - DeviceSwitchTests

@MainActor
final class DeviceSwitchTests: XCTestCase {

    private func makeSUT() -> SessionCoordinator {
        let suiteName = "DeviceSwitchTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "coachingEnabled")
        let settingsStore = SettingsStore(userDefaults: defaults)
        let micMonitor = MicMonitor(provider: MinimalCoreAudioProvider())
        return SessionCoordinator(micMonitor: micMonitor, settingsStore: settingsStore)
    }

    private func makeWiring(
        engineProvider: SwitchTestEngineProvider? = nil
    ) -> (wiring: SessionWiring, provider: SwitchTestEngineProvider, fakeLD: FakeLanguageDetector) {
        let provider = engineProvider ?? SwitchTestEngineProvider()
        let pipeline = AudioPipeline(provider: provider)
        let fakeLD = FakeLanguageDetector()
        fakeLD.stubbedLocale = Locale(identifier: "en-US")
        let wiring = SessionWiring(
            audioPipeline: pipeline,
            languageDetector: fakeLD,
            backend: YieldingStubBackend()
        )
        return (wiring, provider, fakeLD)
    }

    // MARK: - AC-SW1: micDeviceChanged() fires onSwitchStarted hook; hook calls enterWaiting()

    func testMicDeviceChanged_CallsOnSwitchStartedHook() async throws {
        let sut = makeSUT()
        let (wiring, _, _) = makeWiring()
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        // Build a WPMCalculator driven to non-nil wpmVoiced so enterWaiting() has observable effect.
        let clock = SwitchTestClock()
        let scheduler = SwitchTestScheduler()
        let wpmCalc = WPMCalculator(
            settings: SettingsStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!),
            scheduler: scheduler,
            now: clock.now
        )
        wpmCalc.sessionActivated()
        // engineReadyCutoff = 99.0 + 0.5 = 99.5; clock starts at 100.0 → tokens accepted
        wpmCalc.engineReadyFired(at: Date(timeIntervalSinceReferenceDate: 99))
        wpmCalc.notifyVADEvent(.speechStarted(sessionTime: 0.0))
        clock.advance(by: 3.0)           // now = 103; voiced = 3s ≥ minVoicedSeconds
        wpmCalc.notifyVADEvent(.speechStopped(sessionTime: 3.0))
        await wpmCalc.consume(
            TranscribedToken(token: "one two three four", startTime: 0, endTime: 0.1, isFinal: true)
        )
        scheduler.fireNext()             // runs computeAndPublish(): words=4 ≥ 3, voiced=3.0 ≥ 2.0
        XCTAssertNotNil(wpmCalc.wpmVoiced, "Precondition: wpmVoiced must be non-nil before the switch")

        var hookCalled = false
        sut.onSwitchStarted = {
            hookCalled = true
            wpmCalc.enterWaiting()
        }

        sut.micDeviceChanged()
        await Task.yield()

        XCTAssertTrue(hookCalled, "onSwitchStarted must be called when micDeviceChanged() fires (AC-SW1)")
        XCTAssertNil(wpmCalc.wpmVoiced,
                     "onSwitchStarted hook must call enterWaiting(), clearing wpmVoiced (Correction 1)")
    }

    // MARK: - AC-SW2: micDeviceChanged() sets isSwitching = true

    func testMicDeviceChanged_SetsIsSwitchingTrue() async throws {
        let sut = makeSUT()
        let (wiring, _, _) = makeWiring()
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        sut.onSwitchStarted = {}
        sut.micDeviceChanged()
        await Task.yield()

        XCTAssertTrue(sut.isSwitching, "isSwitching must be true after micDeviceChanged (AC-SW2)")
    }

    // MARK: - AC-SW3: AVAudioEngineConfigurationChange fires onSwitchStarted when session active

    func testConfigChangeNotification_CallsOnSwitchStarted_WhenSessionActive() async throws {
        let sut = makeSUT()
        let (wiring, _, _) = makeWiring()
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        var hookCalled = false
        sut.onSwitchStarted = { hookCalled = true }

        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(hookCalled,
                      "Config-change notification must trigger onSwitchStarted when session active (AC-SW3)")
    }

    // MARK: - AC-SW4: micDeviceChanged() eventually calls switchDevice() on active pipeline

    func testMicDeviceChanged_EventuallyCallsSwitchDeviceOnPipeline() async throws {
        let provider = SwitchTestEngineProvider()
        let sut = makeSUT()
        let (wiring, _, _) = makeWiring(engineProvider: provider)
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        provider.callLog.removeAll()
        sut.onSwitchStarted = {}
        sut.micDeviceChanged()

        // Wait for switchDevice() 300ms settle + startEngine (M6.8 Path B timing)
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertTrue(provider.callLog.contains("stop"),
                      "micDeviceChanged must trigger engine stop via switchDevice (AC-SW4); callLog=\(provider.callLog)")
        XCTAssertTrue(provider.callLog.contains("start"),
                      "micDeviceChanged must trigger engine restart via switchDevice (AC-SW4); callLog=\(provider.callLog)")
    }

    // MARK: - AC-SW-FAIL: restart failure ends session with .pipelineRestartFailed

    func testSwitch_OnRestartFailure_EndsSessionNormally() async throws {
        let provider = SwitchTestEngineProvider()
        let sut = makeSUT()
        let (wiring, _, _) = makeWiring(engineProvider: provider)
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        // Cause the next engine start (inside switchDevice) to fail.
        provider.startShouldThrow = true
        sut.onSwitchStarted = {}
        sut.micDeviceChanged()

        // Wait for 300ms settle + failed startEngine + performDeviceSwitch return.
        if let task = sut.switchTask { await task.value }

        XCTAssertEqual(sut.state, .idle,
                       "Session must end when switchDevice() throws (AC-SW-FAIL)")
        XCTAssertEqual(sut.lastEndReason, .pipelineRestartFailed,
                       "End reason must be .pipelineRestartFailed on engine restart failure")
        XCTAssertFalse(sut.isSwitching,
                       "isSwitching must be false after failed switch (defer block)")
    }

    // MARK: - AC-SW9: isSwitching resets to false after switch completes

    func testIsSwitching_ResetsToFalse_AfterSwitchCompletes() async throws {
        let sut = makeSUT()
        let (wiring, _, _) = makeWiring()
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        sut.onSwitchStarted = {}
        sut.micDeviceChanged()
        await Task.yield()

        XCTAssertTrue(sut.isSwitching, "isSwitching must be true immediately after micDeviceChanged")

        // Wait for switchDevice() 300ms settle + startEngine + reset
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertFalse(sut.isSwitching,
                       "isSwitching must reset to false after switch completes (AC-SW9)")
    }

    // MARK: - AC-SW-A: session ID is preserved across device switch

    func testSwitch_PreservesSessionIDAndCounters() async throws {
        let sut = makeSUT()
        let (wiring, _, _) = makeWiring()
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        guard case .active(let ctx) = sut.state else {
            XCTFail("Expected active state before switch")
            return
        }
        let capturedId = ctx.id

        sut.onSwitchStarted = {}
        sut.micDeviceChanged()
        await Task.yield()
        try await Task.sleep(for: .milliseconds(600))

        guard case .active(let ctx2) = sut.state else {
            XCTFail("Expected active state after switch")
            return
        }
        XCTAssertEqual(ctx2.id, capturedId,
                       "Session ID must be preserved across device switch")
        XCTAssertNil(sut.lastEndReason,
                     "No session end must occur during a successful switch")
        XCTAssertFalse(sut.isSwitching,
                       "isSwitching must be false after switch completes")
    }

    // MARK: - AC-SW-B: rapid double micDeviceChanged() supersedes the first call

    func testSwitch_RapidDoubleSwitch_SupersedesFirst() async throws {
        let provider = SwitchTestEngineProvider()
        let sut = makeSUT()
        let (wiring, _, _) = makeWiring(engineProvider: provider)
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        provider.callLog.removeAll()
        sut.onSwitchStarted = {}
        sut.micDeviceChanged()
        sut.micDeviceChanged()   // immediately, before any await — same MainActor turn
        // AirPods Pro HFP negotiation fires 2-3 device-change events per physical action; the latest event must supersede prior in-flight switches.
        try await Task.sleep(for: .milliseconds(1400))

        // task1 is cancelled mid-switchDevice (after stop, before start/recreate); task2 drains it
        // then completes a full cycle — proving the second call superseded and ran.
        XCTAssertEqual(provider.callLog.filter { $0 == "stop" }.count, 2,
                       "Both tasks must call stop; callLog=\(provider.callLog)")
        XCTAssertEqual(provider.callLog.filter { $0 == "start" }.count, 1,
                       "Only the superseding task completes start; callLog=\(provider.callLog)")
        XCTAssertEqual(provider.callLog.filter { $0 == "recreate" }.count, 1,
                       "Only the superseding task completes recreate; callLog=\(provider.callLog)")
        guard case .active = sut.state else {
            XCTFail("Expected active state after supersede switch; state=\(sut.state)")
            return
        }
        XCTAssertFalse(sut.isSwitching,
                       "isSwitching must be false after switch completes")
    }

    // MARK: - AC-SW-E: AVAudioEngineConfigurationChange during switch is dropped by isSwitching guard

    func testConfigChange_DuringSwitch_DoesNotDoubleRebuild() async throws {
        let provider = SwitchTestEngineProvider()
        let sut = makeSUT()
        let (wiring, _, _) = makeWiring(engineProvider: provider)
        sut.wiring = wiring
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        provider.callLog.removeAll()
        sut.onSwitchStarted = {}
        sut.micDeviceChanged()   // sets isSwitching=true synchronously, spawns switchTask
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)   // before the 300ms sleep elapses
        try await Task.sleep(for: .milliseconds(50))   // gives the observer's Task { @MainActor } a turn, where the !isSwitching guard fires
        try await Task.sleep(for: .milliseconds(600))   // original switch completes

        XCTAssertEqual(provider.callLog.filter { $0 == "stop" }.count, 1,
                       "Config-change during switch must not trigger a second stop; callLog=\(provider.callLog)")
        XCTAssertEqual(provider.callLog.filter { $0 == "start" }.count, 1,
                       "Config-change during switch must not trigger a second start; callLog=\(provider.callLog)")
        XCTAssertEqual(provider.callLog.filter { $0 == "recreate" }.count, 1,
                       "Config-change during switch must not trigger a second recreate; callLog=\(provider.callLog)")
    }
}
