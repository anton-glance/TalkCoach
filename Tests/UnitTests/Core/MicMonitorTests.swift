import CoreAudio
import XCTest
@testable import TalkCoach

// MARK: - Fake Provider

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

    func simulateIsRunningChange() {
        isRunningHandler?()
    }

    func simulateDefaultDeviceChange() {
        defaultDeviceHandler?()
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
}
