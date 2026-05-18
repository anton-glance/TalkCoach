import XCTest
@testable import TalkCoach

// MARK: - FakeAudioProcessProber

final class FakeAudioProcessProber: AudioProcessProber, @unchecked Sendable {
    nonisolated(unsafe) var stubbedReaders: [pid_t] = []
    nonisolated(unsafe) private(set) var callCount = 0

    func externalReaders(excluding ourPID: pid_t) async -> [pid_t] {
        callCount += 1
        return stubbedReaders
    }
}

// MARK: - AudioProcessProberPollTests

@MainActor
final class AudioProcessProberPollTests: XCTestCase {

    private func makeSUT(
        audioProcessProber: (any AudioProcessProber)? = nil,
        probePollInterval: TimeInterval = 0.1
    ) -> (sut: SessionCoordinator, defaults: UserDefaults) {
        let suiteName = "PollTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "coachingEnabled")
        defaults.set(probePollInterval, forKey: "probePollIntervalSeconds")
        let settingsStore = SettingsStore(userDefaults: defaults)
        let micMonitor = MicMonitor(provider: MinimalCoreAudioProvider())
        let sut = SessionCoordinator(
            micMonitor: micMonitor,
            settingsStore: settingsStore,
            audioProcessProber: audioProcessProber
        )
        return (sut, defaults)
    }

    private func makeWiring() -> SessionWiring {
        let engineProvider = ProbeTestEngineProvider()
        let pipeline = AudioPipeline(provider: engineProvider)
        let fakeLD = FakeLanguageDetector()
        let localesProvider = FakeSupportedLocalesProvider()
        localesProvider.locales = [Locale(identifier: "en-US")]
        return SessionWiring(
            audioPipeline: pipeline,
            languageDetector: fakeLD,
            appleBackendFactory: TestAppleBackendFactory(),
            parakeetBackendFactory: TestParakeetBackendFactory(),
            supportedLocalesProvider: localesProvider
        )
    }

    // MARK: - T-FIX5-1: pollTask is nil before session, non-nil after wiring completes

    func testPollTask_IsNilBeforeSession_NonNilAfterWiring() async throws {
        let prober = FakeAudioProcessProber()
        prober.stubbedReaders = [999] // non-empty so session does not end via poll
        let (sut, _) = makeSUT(audioProcessProber: prober)

        XCTAssertNil(sut.pollTask, "pollTask must be nil before any session")

        sut.wiring = makeWiring()
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        XCTAssertNotNil(sut.pollTask,
                        "pollTask must be non-nil after wiring completes (poll started, AC-FIX5-A1)")
    }

    // MARK: - T-FIX5-2: session continues while external readers are present

    func testPoll_SessionContinues_WhenExternalReadersPresent() async throws {
        let prober = FakeAudioProcessProber()
        prober.stubbedReaders = [123, 456] // non-empty → external apps reading → session continues
        let (sut, _) = makeSUT(audioProcessProber: prober, probePollInterval: 0.1)

        var endedCount = 0
        sut.onSessionEnded { _ in endedCount += 1 }

        sut.wiring = makeWiring()
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        try await Task.sleep(for: .milliseconds(500)) // 5+ poll cycles at 0.1s

        XCTAssertEqual(endedCount, 0,
                       "Session must NOT end while external readers are present (AC-FIX5-POLARITY)")
        if case .active = sut.state { } else {
            XCTFail("Session must remain .active while external readers present")
        }
        XCTAssertGreaterThanOrEqual(prober.callCount, 3,
                                    "Poll must have run multiple times; callCount=\(prober.callCount) (AC-FIX5-POLARITY)")
    }

    // MARK: - T-FIX5-3: session ends immediately when external readers empty from start

    func testPoll_SessionEnds_WhenExternalReadersEmptyFromStart() async throws {
        let prober = FakeAudioProcessProber()
        prober.stubbedReaders = [] // empty from start → no external app → end session
        let (sut, _) = makeSUT(audioProcessProber: prober, probePollInterval: 0.1)

        let exp = XCTestExpectation(description: "session ended when readers empty from start")
        sut.onSessionEnded { _ in exp.fulfill() }

        sut.wiring = makeWiring()
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        await fulfillment(of: [exp], timeout: 3.0)

        XCTAssertEqual(sut.lastEndReason, .micFreedExternally,
                       "Session must end with .micFreedExternally when readers empty from start (AC-FIX5-POLARITY)")
        XCTAssertEqual(sut.state, .idle)
    }

    // MARK: - T-FIX5-4: poll calls prober multiple times at configured interval

    func testPoll_CallsProberMultipleTimes_AtConfiguredInterval() async throws {
        let prober = FakeAudioProcessProber()
        prober.stubbedReaders = [123] // non-empty → session continues, poll keeps running
        let (sut, _) = makeSUT(audioProcessProber: prober, probePollInterval: 0.1)

        sut.wiring = makeWiring()
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        try await Task.sleep(for: .milliseconds(450)) // 4+ cycles at 0.1s

        XCTAssertGreaterThanOrEqual(prober.callCount, 3,
                                    "Prober must be called multiple times at configured interval; callCount=\(prober.callCount) (AC-FIX5-A4)")
    }

    // MARK: - T-FIX5-5: probePollIntervalSeconds stored and retrieved from SettingsStore

    func testProbePollIntervalSeconds_DefaultIs1_AndPersists() {
        let suiteName = "PollInterval.\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(userDefaults: defaults)

        XCTAssertEqual(store.probePollIntervalSeconds, 1.0, accuracy: 0.001,
                       "probePollIntervalSeconds must default to 1.0s (AC-FIX5-G1)")

        store.probePollIntervalSeconds = 2.5

        let store2 = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(store2.probePollIntervalSeconds, 2.5, accuracy: 0.001,
                       "probePollIntervalSeconds must persist across SettingsStore instances (AC-FIX5-G1)")
    }

    // MARK: - T-FIX5-6: poll stops when session ends

    func testPoll_StopsWhenSessionEnds() async throws {
        let prober = FakeAudioProcessProber()
        prober.stubbedReaders = [123] // non-empty — keeps session alive; poll keeps running
        let (sut, _) = makeSUT(audioProcessProber: prober, probePollInterval: 0.1)

        sut.wiring = makeWiring()
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        try await Task.sleep(for: .milliseconds(250))
        let callCountDuringSession = prober.callCount
        XCTAssertGreaterThan(callCountDuringSession, 0, "Poll must be running during session")

        sut.micDeactivated()
        try await Task.sleep(for: .milliseconds(300))

        let callCountAfterEnd = prober.callCount
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(prober.callCount, callCountAfterEnd,
                       "Poll must stop when session ends — no more prober calls after session end (AC-FIX5-A5)")
    }

    // MARK: - T-FIX5-POLARITY: session ends when external readers transition from present to empty

    func testPoll_SessionEnds_WhenExternalReadersBecomeEmpty() async throws {
        let prober = FakeAudioProcessProber()
        prober.stubbedReaders = [123] // start with external app reading → session continues
        let (sut, _) = makeSUT(audioProcessProber: prober, probePollInterval: 0.1)

        var endedCount = 0
        sut.onSessionEnded { _ in endedCount += 1 }

        sut.wiring = makeWiring()
        sut.micActivated()
        if let task = sut.sessionWiringTask { await task.value }

        // Multiple poll cycles with non-empty readers — session must remain alive
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(endedCount, 0, "Session must remain active while external readers present")
        guard case .active = sut.state else {
            XCTFail("Session must be .active while external readers present"); return
        }

        // Simulate external app releasing the mic
        prober.stubbedReaders = []

        let endExp = XCTestExpectation(description: "session ended after readers cleared")
        sut.onSessionEnded { _ in endExp.fulfill() }
        await fulfillment(of: [endExp], timeout: 1.0)

        XCTAssertEqual(sut.lastEndReason, .micFreedExternally,
                       "Session must end with .micFreedExternally when readers become empty (AC-FIX5-POLARITY)")
        XCTAssertEqual(sut.state, .idle)
    }

    // MARK: - isExternalReader helper (unit tests, no OS calls)

    func testIsExternalReader_OwnPID_Excluded() {
        XCTAssertFalse(
            isExternalReader(pid: 1234, bundle: "com.other.app", isRunningInput: true, ourPID: 1234),
            "Own PID must be excluded"
        )
    }

    func testIsExternalReader_AppleBundle_Excluded() {
        XCTAssertFalse(
            isExternalReader(pid: 999, bundle: "com.apple.CoreSpeech", isRunningInput: true, ourPID: 1234),
            "com.apple.* bundles must be excluded"
        )
    }

    func testIsExternalReader_NotRunning_Excluded() {
        XCTAssertFalse(
            isExternalReader(pid: 999, bundle: "com.other.app", isRunningInput: false, ourPID: 1234),
            "Non-running processes must be excluded"
        )
    }

    func testIsExternalReader_ThirdPartyRunning_Included() {
        XCTAssertTrue(
            isExternalReader(pid: 999, bundle: "com.zoom.us", isRunningInput: true, ourPID: 1234),
            "Third-party running reader must be included"
        )
    }
}
