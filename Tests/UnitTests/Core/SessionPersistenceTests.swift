import CoreAudio
import SwiftData
import XCTest
@testable import TalkCoach

// MARK: - Fakes

private final class FakeCoreAudioDeviceProvider: CoreAudioDeviceProvider, @unchecked Sendable {
    nonisolated(unsafe) var stubbedDefaultDeviceID: AudioObjectID? = 42
    nonisolated(unsafe) var stubbedIsRunning: Bool = false
    nonisolated(unsafe) private(set) var isRunningHandler: (@Sendable () -> Void)?
    private final class Token {}
    nonisolated func defaultInputDeviceID() -> AudioObjectID? { stubbedDefaultDeviceID }
    nonisolated func isDeviceRunningSomewhere(_ deviceID: AudioObjectID) -> Bool? { stubbedIsRunning }
    nonisolated func addIsRunningListener(
        device: AudioObjectID, handler: @escaping @Sendable () -> Void
    ) -> AnyObject? { isRunningHandler = handler; return Token() }
    nonisolated func removeIsRunningListener(device: AudioObjectID, token: AnyObject) {}
    nonisolated func addDefaultDeviceListener(
        handler: @escaping @Sendable () -> Void
    ) -> AnyObject? { Token() }
    nonisolated func removeDefaultDeviceListener(token: AnyObject) {}
    func simulateIsRunningChange() { isRunningHandler?() }
}

private final class FakeSessionPersisting: SessionPersisting, @unchecked Sendable {
    nonisolated(unsafe) var shouldThrow = false
    nonisolated(unsafe) private(set) var savedRecords: [SessionRecord] = []

    func save(_ record: SessionRecord) async throws {
        if shouldThrow { throw NSError(domain: "FakeSessionPersisting", code: 1) }
        savedRecords.append(record)
    }
}

// MARK: - Tests

@MainActor
final class SessionPersistenceTests: XCTestCase {

    private var fake: FakeCoreAudioDeviceProvider!
    private var settingsStore: SettingsStore!
    private var coordinator: SessionCoordinator!
    private var store: SessionStore!

    private func makeSUT(coachingEnabled: Bool = true) throws {
        let suiteName = "SessionPersistenceTests.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(coachingEnabled, forKey: "coachingEnabled")
        settingsStore = SettingsStore(userDefaults: defaults)
        fake = FakeCoreAudioDeviceProvider()
        fake.stubbedDefaultDeviceID = 42
        fake.stubbedIsRunning = false
        let micMonitor = MicMonitor(provider: fake)
        coordinator = SessionCoordinator(micMonitor: micMonitor, settingsStore: settingsStore)

        let schema = Schema(versionedSchema: SchemaV1.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: SessionMigrationPlan.self,
            configurations: config
        )
        store = SessionStore(modelContainer: container)
    }

    private func wireCallback() {
        let capturedStore = store!
        coordinator.onSessionEnded { ended in
            let record = SessionRecord.placeholder(from: ended)
            Task {
                do {
                    try await capturedStore.save(record)
                } catch {
                    // Mirrors production: log and swallow
                }
            }
        }
    }

    private func wireCallback(persisting: some SessionPersisting) {
        coordinator.onSessionEnded { ended in
            let record = SessionRecord.placeholder(from: ended)
            Task {
                do {
                    try await persisting.save(record)
                } catch {
                    // Mirrors production: log and swallow
                }
            }
        }
    }

    private func activateMic() async {
        fake.stubbedIsRunning = true
        fake.simulateIsRunningChange()
        await Task.yield()
    }

    private func deactivateMic() async {
        fake.stubbedIsRunning = false
        fake.simulateIsRunningChange()
        await Task.yield()
    }

    private func waitForPersistence() async throws {
        try await Task.sleep(for: .milliseconds(100))
    }

    // MARK: - Normal session end

    func testSessionPersistedOnNormalEnd() async throws {
        try makeSUT()
        wireCallback()
        coordinator.start()

        await activateMic()
        guard case .active(let ctx) = coordinator.state else {
            XCTFail("Expected .active state")
            return
        }
        let sessionID = ctx.id

        await deactivateMic()
        try await waitForPersistence()

        let records = try await store.fetchAll()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, sessionID)
    }

    // MARK: - Multiple sessions

    func testMultipleSessionsAllPersisted() async throws {
        try makeSUT()
        wireCallback()
        coordinator.start()

        var sessionIDs: [UUID] = []
        for _ in 0..<3 {
            await activateMic()
            guard case .active(let ctx) = coordinator.state else {
                XCTFail("Expected .active state")
                return
            }
            sessionIDs.append(ctx.id)
            await deactivateMic()
            try await waitForPersistence()
        }

        let records = try await store.fetchAll()
        XCTAssertEqual(records.count, 3)
        let recordIDs = Set(records.map(\.id))
        for expectedID in sessionIDs {
            XCTAssertTrue(recordIDs.contains(expectedID), "Missing session \(expectedID)")
        }
    }

    // MARK: - Pause mid-session

    func testPauseMidSessionPersisted() async throws {
        try makeSUT(coachingEnabled: true)
        wireCallback()
        coordinator.start()

        await activateMic()
        guard case .active(let ctx) = coordinator.state else {
            XCTFail("Expected .active state")
            return
        }
        let sessionID = ctx.id

        settingsStore.coachingEnabled = false
        await Task.yield()
        try await waitForPersistence()

        let records = try await store.fetchAll()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, sessionID)
    }

    // MARK: - No double save from single registration

    func testCallbackRegistrationDoesNotDoubleSave() async throws {
        try makeSUT()
        wireCallback()
        coordinator.start()

        await activateMic()
        await deactivateMic()
        try await waitForPersistence()

        await activateMic()
        await deactivateMic()
        try await waitForPersistence()

        let records = try await store.fetchAll()
        XCTAssertEqual(records.count, 2, "One registration should save exactly one record per session")
    }

    // MARK: - Handler survives stop/restart

    func testStopRestartDoesNotDoubleRegister() async throws {
        try makeSUT()
        wireCallback()
        coordinator.start()

        await activateMic()
        coordinator.stop()
        try await waitForPersistence()

        coordinator.start()

        await activateMic()
        await deactivateMic()
        try await waitForPersistence()

        let records = try await store.fetchAll()
        XCTAssertEqual(records.count, 2, "Handler persists across stop/start — 2 sessions = 2 records")
    }

    // MARK: - Save failure resilience

    func testSaveFailureIsLoggedAndAppContinues() async throws {
        try makeSUT()
        let fakePersisting = FakeSessionPersisting()
        fakePersisting.shouldThrow = true
        wireCallback(persisting: fakePersisting)
        coordinator.start()

        await activateMic()
        await deactivateMic()
        try await waitForPersistence()

        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(fakePersisting.savedRecords.isEmpty, "Throwing save should not accumulate records")
    }

    // MARK: - Placeholder record fields

    func testPlaceholderRecordFieldsFromEndedSession() {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = Date(timeIntervalSince1970: 1_700_000_300)
        let ended = EndedSession(id: id, startedAt: start, endedAt: end)

        let record = SessionRecord.placeholder(from: ended)

        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.startedAt, start)
        XCTAssertEqual(record.endedAt, end)
        XCTAssertEqual(record.language, "")
        XCTAssertEqual(record.totalWords, 0)
        XCTAssertEqual(record.averageWPM, 0)
        XCTAssertEqual(record.peakWPM, 0)
        XCTAssertEqual(record.wpmStandardDeviation, 0)
        XCTAssertEqual(record.effectiveSpeakingDuration, 0)
        XCTAssertTrue(record.wpmSamples.isEmpty)
        XCTAssertTrue(record.fillerCounts.isEmpty)
        XCTAssertTrue(record.repeatedPhrases.isEmpty)
    }

    // MARK: - App quit during session

    func testAppQuitDuringSessionPersistsRecord() async throws {
        try makeSUT()
        wireCallback()
        coordinator.start()

        await activateMic()
        guard case .active(let ctx) = coordinator.state else {
            XCTFail("Expected .active state")
            return
        }
        let sessionID = ctx.id

        coordinator.stop()
        try await waitForPersistence()

        let records = try await store.fetchAll()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, sessionID)
    }
}
