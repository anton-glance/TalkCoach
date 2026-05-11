import CoreAudio
import XCTest
@testable import TalkCoach

// MARK: - Fake Provider

// FakeHALProcess mirrors an entry in kAudioHardwarePropertyProcessObjectList.
// isRunningInput can be changed between poll ticks without firing any listener,
// which mirrors the empirically confirmed macOS behaviour (kAudioProcessPropertyIsRunningInput
// accepts listener registration but never delivers callbacks — Probe IRI-self, Session 028).
struct FakeHALProcess {
    let objectID: AudioObjectID
    let pid: pid_t
    var isRunningInput: Bool
}

private final class FakeCoreAudioDeviceProvider: CoreAudioDeviceProvider, @unchecked Sendable {
    nonisolated(unsafe) var stubbedDefaultDeviceID: AudioObjectID? = 42
    nonisolated(unsafe) var stubbedIsRunning: Bool = false

    nonisolated(unsafe) private(set) var addIsRunningListenerCallCount = 0
    nonisolated(unsafe) private(set) var removeIsRunningListenerCallCount = 0
    nonisolated(unsafe) private(set) var addDefaultDeviceListenerCallCount = 0
    nonisolated(unsafe) private(set) var removeDefaultDeviceListenerCallCount = 0

    nonisolated(unsafe) private(set) var isRunningHandler: (@Sendable () -> Void)?
    nonisolated(unsafe) private(set) var defaultDeviceHandler: (@Sendable () -> Void)?

    // MARK: External process tracking support (M3.7.1)

    // Any pid NOT equal to fakeSelfPID is treated as an external process.
    nonisolated(unsafe) var fakeSelfPID: pid_t = 999
    nonisolated(unsafe) var fakeProcesses: [FakeHALProcess] = []
    nonisolated(unsafe) private(set) var processObjectsCallCount: Int = 0
    nonisolated(unsafe) private(set) var processObjectListHandler: (@Sendable () -> Void)?

    private final class Token {}

    nonisolated func defaultInputDeviceID() -> AudioObjectID? {
        stubbedDefaultDeviceID
    }

    nonisolated func isDeviceRunningSomewhere(_ deviceID: AudioObjectID) -> Bool? {
        stubbedIsRunning
    }

    nonisolated func addIsRunningListener(
        device: AudioObjectID,
        handler: @escaping @Sendable () -> Void
    ) -> AnyObject? {
        addIsRunningListenerCallCount += 1
        isRunningHandler = handler
        return Token()
    }

    // Handler intentionally NOT cleared — lets testStopStopsEmittingAfterSubsequentChanges exercise MicMonitor's late-callback guard.
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

    // Symmetric with removeIsRunningListener — handler intentionally retained.
    nonisolated func removeDefaultDeviceListener(token: AnyObject) {
        removeDefaultDeviceListenerCallCount += 1
    }

    nonisolated func processObjects() -> [AudioObjectID] {
        processObjectsCallCount += 1
        return fakeProcesses.map { $0.objectID }
    }

    nonisolated func pid(of processObjectID: AudioObjectID) -> pid_t? {
        fakeProcesses.first { $0.objectID == processObjectID }?.pid
    }

    nonisolated func isProcessRunningInput(_ processObjectID: AudioObjectID) -> Bool {
        fakeProcesses.first { $0.objectID == processObjectID }?.isRunningInput ?? false
    }

    nonisolated func selfPID() -> pid_t { fakeSelfPID }

    nonisolated func addProcessObjectListListener(
        handler: @escaping @Sendable () -> Void
    ) -> AnyObject? {
        processObjectListHandler = handler
        return Token()
    }

    nonisolated func removeProcessObjectListListener(token: AnyObject) {}

    // MARK: Simulation helpers

    func simulateIsRunningChange() {
        isRunningHandler?()
    }

    func simulateDefaultDeviceChange() {
        defaultDeviceHandler?()
    }

    func simulateProcessObjectListChange() {
        processObjectListHandler?()
    }
}

// MARK: - Delegate Spy

private final class DelegateSpy: MicMonitorDelegate {
    private(set) var activatedCount = 0
    private(set) var deactivatedCount = 0

    func micActivated() {
        activatedCount += 1
    }

    func micDeactivated() {
        deactivatedCount += 1
    }
}

// MARK: - Tests

@MainActor
final class MicMonitorTests: XCTestCase {

    private var sut: MicMonitor!
    private var fake: FakeCoreAudioDeviceProvider!
    private var spy: DelegateSpy!

    private func makeSUT(
        defaultDeviceID: AudioObjectID? = 42,
        isRunning: Bool = false
    ) {
        fake = FakeCoreAudioDeviceProvider()
        fake.stubbedDefaultDeviceID = defaultDeviceID
        fake.stubbedIsRunning = isRunning
        sut = MicMonitor(provider: fake)
        spy = DelegateSpy()
        sut.delegate = spy
    }

    // MARK: - Start / Stop basics

    func testStartSetsIsMonitoringTrue() {
        makeSUT()
        sut.start()
        XCTAssertTrue(sut.isRunning)
    }

    func testStopSetsIsMonitoringFalse() {
        makeSUT()
        sut.start()
        sut.stop()
        XCTAssertFalse(sut.isRunning)
    }

    func testStartIdempotent() {
        makeSUT()
        sut.start()
        sut.start()
        XCTAssertEqual(fake.addIsRunningListenerCallCount, 1)
        XCTAssertEqual(fake.addDefaultDeviceListenerCallCount, 1)
    }

    func testStopIdempotent() {
        makeSUT()
        sut.stop()
        XCTAssertEqual(fake.removeIsRunningListenerCallCount, 0)
        XCTAssertEqual(fake.removeDefaultDeviceListenerCallCount, 0)
    }

    // MARK: - Initial state emission

    func testStartMicAlreadyRunningEmitsActivated() {
        makeSUT(isRunning: true)
        sut.start()
        XCTAssertEqual(spy.activatedCount, 1)
        XCTAssertEqual(spy.deactivatedCount, 0)
    }

    func testStartMicNotRunningDoesNotEmit() {
        makeSUT(isRunning: false)
        sut.start()
        XCTAssertEqual(spy.activatedCount, 0)
        XCTAssertEqual(spy.deactivatedCount, 0)
    }

    // MARK: - Runtime transitions

    func testRunningTransitionFalseToTrueEmitsActivated() async {
        makeSUT(isRunning: false)
        sut.start()
        fake.stubbedIsRunning = true
        fake.simulateIsRunningChange()
        await Task.yield()
        XCTAssertEqual(spy.activatedCount, 1)
    }

    func testRunningTransitionTrueToFalseEmitsDeactivated() async {
        makeSUT(isRunning: true)
        sut.start()
        XCTAssertEqual(spy.activatedCount, 1)
        fake.stubbedIsRunning = false
        fake.simulateIsRunningChange()
        await Task.yield()
        XCTAssertEqual(spy.deactivatedCount, 1)
    }

    func testSameValueNotificationDoesNotDoubleEmit() async {
        makeSUT(isRunning: true)
        sut.start()
        XCTAssertEqual(spy.activatedCount, 1)
        fake.simulateIsRunningChange()
        await Task.yield()
        XCTAssertEqual(spy.activatedCount, 1, "Same-value notification should not double-emit")
    }

    // MARK: - Default device change

    func testDefaultDeviceChangeOldListenerRemoved() async {
        makeSUT()
        sut.start()
        fake.stubbedDefaultDeviceID = 99
        fake.simulateDefaultDeviceChange()
        await Task.yield()
        XCTAssertEqual(fake.removeIsRunningListenerCallCount, 1)
    }

    func testDefaultDeviceChangeNewListenerAttached() async {
        makeSUT()
        sut.start()
        XCTAssertEqual(fake.addIsRunningListenerCallCount, 1)
        fake.stubbedDefaultDeviceID = 99
        fake.simulateDefaultDeviceChange()
        await Task.yield()
        XCTAssertEqual(fake.addIsRunningListenerCallCount, 2)
    }

    func testDefaultDeviceChangeSameDeviceIsNoOp() async {
        makeSUT(defaultDeviceID: 42)
        sut.start()
        fake.simulateDefaultDeviceChange()
        await Task.yield()
        XCTAssertEqual(
            fake.removeIsRunningListenerCallCount, 0,
            "Same device should not detach listener"
        )
        XCTAssertEqual(
            fake.addIsRunningListenerCallCount, 1,
            "Same device should not re-attach listener"
        )
    }

    func testDefaultDeviceChangeNoReplacementTreatsAsNotRunning() async {
        makeSUT(isRunning: true)
        sut.start()
        XCTAssertEqual(spy.activatedCount, 1)
        fake.stubbedDefaultDeviceID = nil
        fake.simulateDefaultDeviceChange()
        await Task.yield()
        XCTAssertEqual(spy.deactivatedCount, 1)
    }

    func testDefaultDeviceChangeNewDeviceRunningEmitsActivation() async {
        makeSUT(isRunning: false)
        sut.start()
        fake.stubbedDefaultDeviceID = 99
        fake.stubbedIsRunning = true
        fake.simulateDefaultDeviceChange()
        await Task.yield()
        XCTAssertEqual(spy.activatedCount, 1)
    }

    func testDefaultDeviceChangeNewDeviceNotRunningEmitsDeactivation() async {
        makeSUT(isRunning: true)
        sut.start()
        XCTAssertEqual(spy.activatedCount, 1)
        fake.stubbedDefaultDeviceID = 99
        fake.stubbedIsRunning = false
        fake.simulateDefaultDeviceChange()
        await Task.yield()
        XCTAssertEqual(spy.deactivatedCount, 1)
    }

    // MARK: - Cleanup

    func testStopRemovesBothListeners() {
        makeSUT()
        sut.start()
        sut.stop()
        XCTAssertGreaterThanOrEqual(fake.removeIsRunningListenerCallCount, 1)
        XCTAssertEqual(fake.removeDefaultDeviceListenerCallCount, 1)
    }

    func testStopStopsEmittingAfterSubsequentChanges() async {
        makeSUT(isRunning: false)
        sut.start()
        sut.stop()
        fake.stubbedIsRunning = true
        fake.simulateIsRunningChange()
        await Task.yield()
        XCTAssertEqual(spy.activatedCount, 0)
        XCTAssertEqual(spy.deactivatedCount, 0)
    }

    func testStartAfterStopWorks() async {
        makeSUT(isRunning: false)
        sut.start()
        sut.stop()
        XCTAssertFalse(sut.isRunning)

        fake.stubbedIsRunning = true
        sut.start()
        XCTAssertTrue(sut.isRunning)
        XCTAssertEqual(spy.activatedCount, 1)

        fake.stubbedIsRunning = false
        fake.simulateIsRunningChange()
        await Task.yield()
        XCTAssertEqual(spy.deactivatedCount, 1)
    }

    func testDeinitRemovesListenersIfStillRunning() {
        let deinitFake = FakeCoreAudioDeviceProvider()
        deinitFake.stubbedDefaultDeviceID = 42
        deinitFake.stubbedIsRunning = false
        autoreleasepool {
            let monitor = MicMonitor(provider: deinitFake)
            monitor.start()
            XCTAssertEqual(deinitFake.addIsRunningListenerCallCount, 1)
            XCTAssertEqual(deinitFake.addDefaultDeviceListenerCallCount, 1)
        }
        XCTAssertEqual(deinitFake.removeIsRunningListenerCallCount, 1)
        XCTAssertEqual(deinitFake.removeDefaultDeviceListenerCallCount, 1)
    }

    // MARK: - M3.7.1 External Process Tracking

    // AC-a: Polling detects mic release without listener notification.
    // Mirrors empirically confirmed macOS behaviour: isRunningInput changes silently.
    func testMicDeactivatedFiresWhenExternalProcessReleasesViaPollingDetection() {
        makeSUT()
        fake.fakeProcesses = [FakeHALProcess(objectID: 10, pid: 100, isRunningInput: true)]
        sut.start()
        sut.beginExternalProcessTracking()

        // Tick 1: external process is active — no deactivation
        sut.executePollTick()
        XCTAssertEqual(spy.deactivatedCount, 0, "No deactivation while external process is active")

        // External releases mic; no listener fires (mirrors macOS behaviour)
        fake.fakeProcesses[0] = FakeHALProcess(objectID: 10, pid: 100, isRunningInput: false)

        // Tick 2: no external active → micDeactivated must fire
        sut.executePollTick()
        XCTAssertEqual(spy.deactivatedCount, 1, "micDeactivated must fire when polling detects external release")
    }

    // AC-b: Mid-session process join is tracked; no duplicate micActivated;
    // departure of the original process does not fire micDeactivated if the new one is still active.
    func testMicActivatedNotDuplicatedAndNewProcessTrackedMidSession() async {
        makeSUT()
        fake.fakeProcesses = [FakeHALProcess(objectID: 10, pid: 100, isRunningInput: true)]
        sut.start()
        sut.beginExternalProcessTracking()
        sut.executePollTick()  // establishes external state as active

        // New process B joins mid-session via ProcessObjectList event
        fake.fakeProcesses.append(FakeHALProcess(objectID: 20, pid: 200, isRunningInput: true))
        fake.simulateProcessObjectListChange()
        await Task.yield()  // let the dispatched executePollTick run

        // No duplicate micActivated — we are already in an active session
        XCTAssertEqual(spy.activatedCount, 0, "No duplicate micActivated while already tracking external processes")

        // Original process A leaves; B is still active
        fake.fakeProcesses.removeFirst()
        sut.executePollTick()

        // B still running → no deactivation
        XCTAssertEqual(spy.deactivatedCount, 0, "micDeactivated must NOT fire while process B is still active")
    }

    // AC-c: Polling timer must not run while external tracking is inactive (idle state).
    func testPollingDoesNotRunWhenIdle() {
        makeSUT()
        sut.start()
        // beginExternalProcessTracking() intentionally NOT called
        XCTAssertEqual(
            fake.processObjectsCallCount, 0,
            "processObjects must not be called when external tracking is inactive"
        )
    }

    // AC-d: Polling stops after endExternalProcessTracking; no additional processObjects calls.
    func testPollingStopsAfterEndExternalProcessTracking() {
        makeSUT()
        fake.fakeProcesses = [FakeHALProcess(objectID: 10, pid: 100, isRunningInput: true)]
        sut.start()
        sut.beginExternalProcessTracking()
        sut.executePollTick()
        let countAfterOneTick = fake.processObjectsCallCount

        sut.endExternalProcessTracking()
        sut.executePollTick()  // must be a no-op after tracking stops

        XCTAssertEqual(
            fake.processObjectsCallCount, countAfterOneTick,
            "No additional processObjects calls after endExternalProcessTracking"
        )
    }

    // AC-e: BlackHole fallback — empty process list + isRunningSomewhere=true → external reader present.
    func testBlackHoleFallbackWhenProcessListIsEmpty() {
        makeSUT(isRunning: true)
        fake.fakeProcesses = []  // empty — HAL enumeration unavailable or no processes
        sut.start()
        sut.beginExternalProcessTracking()

        sut.executePollTick()

        XCTAssertEqual(
            spy.deactivatedCount, 0,
            "Empty process list + isRunningSomewhere=true must be treated as external reader present"
        )
    }

    // AC-f: Each poll tick re-enumerates the live process list, not a cached snapshot.
    // A process that joined between ticks must be tracked immediately on the next tick.
    func testReEnumerationOnEachPollTickTracksLateJoiner() {
        makeSUT()
        fake.fakeProcesses = [FakeHALProcess(objectID: 10, pid: 100, isRunningInput: true)]
        sut.start()
        sut.beginExternalProcessTracking()

        sut.executePollTick()  // tick 1: sees A

        // B joins between tick 1 and 2, no ProcessObjectList event fired
        fake.fakeProcesses.append(FakeHALProcess(objectID: 20, pid: 200, isRunningInput: true))
        sut.executePollTick()  // tick 2: re-enumerates, sees A and B

        // A releases mic between tick 2 and 3
        fake.fakeProcesses[0] = FakeHALProcess(objectID: 10, pid: 100, isRunningInput: false)
        sut.executePollTick()  // tick 3: re-enumerates, B still active → no deactivation

        XCTAssertEqual(spy.deactivatedCount, 0, "No deactivation: B still active after re-enumeration caught it")
        XCTAssertEqual(fake.processObjectsCallCount, 3, "processObjects called once per tick")
    }
}
