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

// MARK: - Last-used display target-screen tests

@MainActor
final class FloatingPanelLastUsedDisplayTests: XCTestCase {

    private static let builtIn = ScreenDescription(
        localizedName: "Built-in Display",
        visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 900),
        frame: NSRect(x: 0, y: 0, width: 1440, height: 900)
    )

    private static let external = ScreenDescription(
        localizedName: "External Monitor",
        visibleFrame: NSRect(x: 1440, y: 0, width: 2560, height: 1440),
        frame: NSRect(x: 1440, y: 0, width: 2560, height: 1440)
    )

    private var fake: FakeCoreAudioDeviceProvider!
    private var fakeScreen: FakeScreenProvider!
    private var fakeScheduler: FakeHideScheduler!
    private var settingsStore: SettingsStore!
    private var coordinator: SessionCoordinator!
    private var sut: FloatingPanelController!

    private func makeSUT(
        screens: [ScreenDescription]? = nil,
        mainScreen: ScreenDescription? = nil
    ) {
        let defaults = UserDefaults(suiteName: "LastUsedDisplayTests.\(name)")!
        defaults.removePersistentDomain(forName: "LastUsedDisplayTests.\(name)")
        defaults.set(true, forKey: "coachingEnabled")
        settingsStore = SettingsStore(userDefaults: defaults)
        fake = FakeCoreAudioDeviceProvider()
        fake.stubbedDefaultDeviceID = 42
        fake.stubbedIsRunning = false
        fakeScreen = FakeScreenProvider()
        fakeScreen.stubbedMainScreen = mainScreen ?? Self.builtIn
        fakeScreen.stubbedAllScreens = screens ?? [Self.builtIn]
        fakeScheduler = FakeHideScheduler()
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

    // MARK: - Target screen selection

    func testRestoresOnLastUsedDisplayWhenConnected() async {
        makeSUT(screens: [Self.builtIn, Self.external], mainScreen: Self.builtIn)
        settingsStore.setLastUsedDisplay("External Monitor")
        settingsStore.setPosition(CGPoint(x: 50, y: 50), for: "External Monitor")
        sut.start()
        coordinator.start()
        await activateMic()

        let expectedOrigin = CGPoint(
            x: Self.external.frame.origin.x + 50,
            y: Self.external.frame.origin.y + 50
        )
        XCTAssertEqual(sut.currentPanelFrame?.origin, expectedOrigin)
    }

    func testFallsBackToMainWhenLastUsedDisplayDisconnected() async {
        makeSUT(screens: [Self.builtIn], mainScreen: Self.builtIn)
        settingsStore.setLastUsedDisplay("External Monitor")
        sut.start()
        coordinator.start()
        await activateMic()

        let expectedX = Self.builtIn.visibleFrame.maxX - 144 - 16
        let expectedY = Self.builtIn.visibleFrame.maxY - 144 - 16
        XCTAssertEqual(sut.currentPanelFrame?.origin, CGPoint(x: expectedX, y: expectedY))
    }

    func testFallsBackToMainWhenLastUsedDisplayUnset() async {
        makeSUT(screens: [Self.builtIn, Self.external], mainScreen: Self.builtIn)
        sut.start()
        coordinator.start()
        await activateMic()

        let expectedX = Self.builtIn.visibleFrame.maxX - 144 - 16
        let expectedY = Self.builtIn.visibleFrame.maxY - 144 - 16
        XCTAssertEqual(sut.currentPanelFrame?.origin, CGPoint(x: expectedX, y: expectedY))
    }

    func testDragSavesLastUsedDisplay() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()

        sut.handlePanelDragEnd(panelFrame: NSRect(x: 200, y: 300, width: 144, height: 144))

        XCTAssertEqual(settingsStore.lastUsedDisplay(), "Built-in Display")
    }

    func testCrossScreenDragUpdatesLastUsedDisplay() async {
        makeSUT(screens: [Self.builtIn, Self.external])
        sut.start()
        coordinator.start()
        await activateMic()

        sut.handlePanelDragEnd(panelFrame: NSRect(x: 1500, y: 500, width: 144, height: 144))

        XCTAssertEqual(settingsStore.lastUsedDisplay(), "External Monitor")
    }

    func testLastUsedDisplayDefaultFrameWhenNoSavedPosition() async {
        makeSUT(screens: [Self.builtIn, Self.external], mainScreen: Self.builtIn)
        settingsStore.setLastUsedDisplay("External Monitor")
        sut.start()
        coordinator.start()
        await activateMic()

        let expectedX = Self.external.visibleFrame.maxX - 144 - 16
        let expectedY = Self.external.visibleFrame.maxY - 144 - 16
        XCTAssertEqual(sut.currentPanelFrame?.origin, CGPoint(x: expectedX, y: expectedY))
    }

    func testLastUsedDisplayWithClampedPosition() async {
        makeSUT(screens: [Self.builtIn, Self.external], mainScreen: Self.builtIn)
        settingsStore.setLastUsedDisplay("External Monitor")
        settingsStore.setPosition(CGPoint(x: 9999, y: 9999), for: "External Monitor")
        sut.start()
        coordinator.start()
        await activateMic()

        let frame = sut.currentPanelFrame!
        let clampedX = Self.external.visibleFrame.maxX - 144
        let clampedY = Self.external.visibleFrame.maxY - 144
        XCTAssertEqual(frame.origin.x, clampedX, accuracy: 0.01)
        XCTAssertEqual(frame.origin.y, clampedY, accuracy: 0.01)
    }
}
