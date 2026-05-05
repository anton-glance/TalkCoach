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

    private func makeSUT(
        defaultDeviceID: AudioObjectID? = 42,
        isRunning: Bool = false
    ) -> (MicMonitor, FakeCoreAudioDeviceProvider, DelegateSpy) {
        let fake = FakeCoreAudioDeviceProvider()
        fake.stubbedDefaultDeviceID = defaultDeviceID
        fake.stubbedIsRunning = isRunning
        let sut = MicMonitor(provider: fake)
        let spy = DelegateSpy()
        sut.delegate = spy
        return (sut, fake, spy)
    }

    // MARK: - Start / Stop basics

    func testStartSetsIsMonitoringTrue() {
        let (sut, _, _) = makeSUT()
        sut.start()
        XCTAssertTrue(sut.isRunning)
    }

    func testStopSetsIsMonitoringFalse() {
        let (sut, _, _) = makeSUT()
        sut.start()
        sut.stop()
        XCTAssertFalse(sut.isRunning)
    }

    func testStartIdempotent() {
        let (sut, fake, _) = makeSUT()
        sut.start()
        sut.start()
        XCTAssertEqual(fake.addIsRunningListenerCallCount, 1)
        XCTAssertEqual(fake.addDefaultDeviceListenerCallCount, 1)
    }

    func testStopIdempotent() {
        let (sut, fake, _) = makeSUT()
        sut.stop()
        XCTAssertEqual(fake.removeIsRunningListenerCallCount, 0)
        XCTAssertEqual(fake.removeDefaultDeviceListenerCallCount, 0)
    }

    // MARK: - Initial state emission

    func testStartMicAlreadyRunningEmitsActivated() {
        let (sut, _, spy) = makeSUT(isRunning: true)
        sut.start()
        XCTAssertEqual(spy.activatedCount, 1)
        XCTAssertEqual(spy.deactivatedCount, 0)
    }

    func testStartMicNotRunningDoesNotEmit() {
        let (sut, _, spy) = makeSUT(isRunning: false)
        sut.start()
        XCTAssertEqual(spy.activatedCount, 0)
        XCTAssertEqual(spy.deactivatedCount, 0)
    }

    // MARK: - Runtime transitions

    func testRunningTransitionFalseToTrueEmitsActivated() async {
        let (sut, fake, spy) = makeSUT(isRunning: false)
        sut.start()
        fake.stubbedIsRunning = true
        fake.simulateIsRunningChange()
        await Task.yield()
        XCTAssertEqual(spy.activatedCount, 1)
    }

    func testRunningTransitionTrueToFalseEmitsDeactivated() async {
        let (sut, fake, spy) = makeSUT(isRunning: true)
        sut.start()
        XCTAssertEqual(spy.activatedCount, 1)
        fake.stubbedIsRunning = false
        fake.simulateIsRunningChange()
        await Task.yield()
        XCTAssertEqual(spy.deactivatedCount, 1)
    }

    func testSameValueNotificationDoesNotDoubleEmit() async {
        let (sut, fake, spy) = makeSUT(isRunning: true)
        sut.start()
        XCTAssertEqual(spy.activatedCount, 1)
        fake.simulateIsRunningChange()
        await Task.yield()
        XCTAssertEqual(spy.activatedCount, 1, "Same-value notification should not double-emit")
    }

    // MARK: - Default device change

    func testDefaultDeviceChangeOldListenerRemoved() async {
        let (sut, fake, _) = makeSUT()
        sut.start()
        fake.stubbedDefaultDeviceID = 99
        fake.simulateDefaultDeviceChange()
        await Task.yield()
        XCTAssertEqual(fake.removeIsRunningListenerCallCount, 1)
    }

    func testDefaultDeviceChangeNewListenerAttached() async {
        let (sut, fake, _) = makeSUT()
        sut.start()
        XCTAssertEqual(fake.addIsRunningListenerCallCount, 1)
        fake.stubbedDefaultDeviceID = 99
        fake.simulateDefaultDeviceChange()
        await Task.yield()
        XCTAssertEqual(fake.addIsRunningListenerCallCount, 2)
    }

    func testDefaultDeviceChangeSameDeviceIsNoOp() async {
        let (sut, fake, _) = makeSUT(defaultDeviceID: 42)
        sut.start()
        fake.simulateDefaultDeviceChange()
        await Task.yield()
        XCTAssertEqual(fake.removeIsRunningListenerCallCount, 0, "Same device should not detach listener")
        XCTAssertEqual(fake.addIsRunningListenerCallCount, 1, "Same device should not re-attach listener")
    }

    func testDefaultDeviceChangeNoReplacementTreatsAsNotRunning() async {
        let (sut, fake, spy) = makeSUT(isRunning: true)
        sut.start()
        XCTAssertEqual(spy.activatedCount, 1)
        fake.stubbedDefaultDeviceID = nil
        fake.simulateDefaultDeviceChange()
        await Task.yield()
        XCTAssertEqual(spy.deactivatedCount, 1)
    }

    func testDefaultDeviceChangeNewDeviceRunningEmitsActivation() async {
        let (sut, fake, spy) = makeSUT(isRunning: false)
        sut.start()
        fake.stubbedDefaultDeviceID = 99
        fake.stubbedIsRunning = true
        fake.simulateDefaultDeviceChange()
        await Task.yield()
        XCTAssertEqual(spy.activatedCount, 1)
    }

    func testDefaultDeviceChangeNewDeviceNotRunningEmitsDeactivation() async {
        let (sut, fake, spy) = makeSUT(isRunning: true)
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
        let (sut, fake, _) = makeSUT()
        sut.start()
        sut.stop()
        XCTAssertGreaterThanOrEqual(fake.removeIsRunningListenerCallCount, 1)
        XCTAssertEqual(fake.removeDefaultDeviceListenerCallCount, 1)
    }

    func testStopStopsEmittingAfterSubsequentChanges() async {
        let (sut, fake, spy) = makeSUT(isRunning: false)
        sut.start()
        sut.stop()
        fake.stubbedIsRunning = true
        fake.simulateIsRunningChange()
        await Task.yield()
        XCTAssertEqual(spy.activatedCount, 0)
        XCTAssertEqual(spy.deactivatedCount, 0)
    }

    func testStartAfterStopWorks() async {
        let (sut, fake, spy) = makeSUT(isRunning: false)
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
}
