import CoreAudio
import XCTest
@testable import TalkCoach

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

private final class FakeAlertPresenter: AlertPresenter, @unchecked Sendable {
    nonisolated(unsafe) var stubbedResult: Bool = false
    @MainActor func presentDismissConfirmation() -> Bool { stubbedResult }
}

private struct FakeSchedulerEntry {
    let delay: TimeInterval
    let action: @MainActor @Sendable () -> Void
    let token: HideSchedulerToken
}

private final class FakeHideScheduler: HideScheduler, @unchecked Sendable {
    nonisolated(unsafe) private(set) var entries: [FakeSchedulerEntry] = []
    nonisolated(unsafe) private(set) var cancelCallCount = 0
    @MainActor func schedule(
        delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void
    ) -> HideSchedulerToken {
        let token = HideSchedulerToken()
        entries.append(FakeSchedulerEntry(delay: delay, action: action, token: token))
        return token
    }
    @MainActor func cancel(_ token: HideSchedulerToken) {
        cancelCallCount += 1
        entries.removeAll { $0.token == token }
    }
    @MainActor func fire(delay matching: TimeInterval) {
        guard let idx = entries.firstIndex(where: { $0.delay == matching }) else { return }
        let entry = entries.remove(at: idx)
        entry.action()
    }
}

private final class FakeScreenProvider: ScreenProvider, @unchecked Sendable {
    nonisolated(unsafe) var stubbedMainScreen: ScreenDescription?
    nonisolated(unsafe) var stubbedAllScreens: [ScreenDescription] = []
    @MainActor func mainScreen() -> ScreenDescription? { stubbedMainScreen }
    @MainActor func allScreens() -> [ScreenDescription] { stubbedAllScreens }
}

// MARK: - Notification-based save trigger tests

@MainActor
final class FloatingPanelDragTriggerTests: XCTestCase {

    private static let builtIn = ScreenDescription(
        localizedName: "Built-in Display",
        visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900),
        frame: NSRect(x: 0, y: 0, width: 1440, height: 900)
    )

    private var fake: FakeCoreAudioDeviceProvider!
    private var fakeScheduler: FakeHideScheduler!
    private var settingsStore: SettingsStore!
    private var sut: FloatingPanelController!
    private var coordinator: SessionCoordinator!

    private func makeSUT() {
        let defaults = UserDefaults(suiteName: "DragTriggerTests.\(name)")!
        defaults.removePersistentDomain(forName: "DragTriggerTests.\(name)")
        defaults.set(true, forKey: "coachingEnabled")
        settingsStore = SettingsStore(userDefaults: defaults)
        fake = FakeCoreAudioDeviceProvider()
        fake.stubbedDefaultDeviceID = 42
        fake.stubbedIsRunning = false
        fakeScheduler = FakeHideScheduler()
        let fakeScreen = FakeScreenProvider()
        fakeScreen.stubbedMainScreen = Self.builtIn
        fakeScreen.stubbedAllScreens = [Self.builtIn]
        let micMonitor = MicMonitor(provider: fake)
        coordinator = SessionCoordinator(micMonitor: micMonitor, settingsStore: settingsStore)
        sut = FloatingPanelController(
            sessionCoordinator: coordinator,
            alertPresenter: FakeAlertPresenter(),
            hideScheduler: fakeScheduler,
            screenProvider: fakeScreen,
            settingsStore: settingsStore
        )
    }

    private func activateMic() async {
        fake.stubbedIsRunning = true
        fake.simulateIsRunningChange()
        await Task.yield()
    }

    func testProgrammaticMoveDoesNotTriggerSave() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()

        XCTAssertNil(
            settingsStore.position(for: "Built-in Display"),
            "showPanel's setFrame must not trigger a position save"
        )
        let debounceEntries = fakeScheduler.entries.filter { $0.delay == 0.3 }
        XCTAssertTrue(
            debounceEntries.isEmpty,
            "No debounce timer should be scheduled for programmatic moves"
        )
    }

    func testDragSaveFiresAfterDebounceDelay() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()

        guard let panel = sut.panelWindow else {
            return XCTFail("Panel must exist after mic activation")
        }
        panel.setFrameOrigin(CGPoint(x: 200, y: 300))

        let debounceEntries = fakeScheduler.entries.filter { $0.delay == 0.3 }
        XCTAssertEqual(
            debounceEntries.count, 1,
            "Exactly one debounce timer should be scheduled"
        )

        fakeScheduler.fire(delay: 0.3)

        let saved = settingsStore.position(for: "Built-in Display")
        XCTAssertNotNil(saved, "Position must be saved after debounce fires")
    }

    func testDebounceCoalescesMultipleMoves() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()

        guard let panel = sut.panelWindow else {
            return XCTFail("Panel must exist after mic activation")
        }

        let initialCancelCount = fakeScheduler.cancelCallCount

        panel.setFrameOrigin(CGPoint(x: 100, y: 100))
        panel.setFrameOrigin(CGPoint(x: 150, y: 150))
        panel.setFrameOrigin(CGPoint(x: 200, y: 300))

        let debouncesCanceled = fakeScheduler.cancelCallCount - initialCancelCount
        XCTAssertEqual(
            debouncesCanceled, 2,
            "First two debounce timers must be canceled"
        )

        let debounceEntries = fakeScheduler.entries.filter { $0.delay == 0.3 }
        XCTAssertEqual(
            debounceEntries.count, 1,
            "Only the last debounce timer should remain"
        )

        fakeScheduler.fire(delay: 0.3)

        let saved = settingsStore.position(for: "Built-in Display")
        XCTAssertNotNil(
            saved,
            "Position must be saved exactly once after coalesced debounce"
        )
    }

    func testMoveObserverRemovedOnStop() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()

        guard let panel = sut.panelWindow else {
            return XCTFail("Panel must exist after mic activation")
        }

        sut.stop()

        panel.setFrameOrigin(CGPoint(x: 200, y: 300))

        let debounceEntries = fakeScheduler.entries.filter { $0.delay == 0.3 }
        XCTAssertTrue(
            debounceEntries.isEmpty,
            "No debounce timer should fire after stop()"
        )
    }
}
