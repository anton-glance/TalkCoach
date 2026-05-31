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
    @MainActor func fireAll() {
        let pending = entries
        entries.removeAll()
        for entry in pending { entry.action() }
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

// MARK: - Tests

@MainActor
final class FloatingPanelPositionTests: XCTestCase {

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
    private var defaults: UserDefaults!
    private var coordinator: SessionCoordinator!
    private var sut: FloatingPanelController!

    private func makeSUT(
        screens: [ScreenDescription]? = nil,
        mainScreen: ScreenDescription? = nil,
        coachingEnabled: Bool = true
    ) {
        defaults = UserDefaults(suiteName: "PositionTests.\(name)")!
        defaults.removePersistentDomain(forName: "PositionTests.\(name)")
        defaults.set(coachingEnabled, forKey: "coachingEnabled")
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

    // MARK: - Restore on show

    func testRestoresStoredPositionForKnownScreen() async {
        makeSUT()
        settingsStore.setPosition(CGPoint(x: 50, y: 50), for: "Built-in Display")
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        XCTAssertEqual(sut.panelState, .visible)
        XCTAssertTrue(sut.isShowingPanel)
        // Panel is 160×160 (144 + 8pt margin each side); panel origin = visual origin - 8.
        let expectedOrigin = CGPoint(
            x: Self.builtIn.frame.origin.x + 50 - 8,
            y: Self.builtIn.frame.origin.y + 50 - 8
        )
        XCTAssertEqual(sut.currentPanelFrame?.origin, expectedOrigin)
    }

    func testFallsBackToDefaultForUnknownScreen() async {
        makeSUT()
        settingsStore.setPosition(CGPoint(x: 50, y: 50), for: "External Monitor")
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        // Panel origin = (visual origin) - 8pt hoverMargin on each axis.
        let expectedX = Self.builtIn.visibleFrame.maxX - 144 - 16 - 8
        let expectedY = Self.builtIn.visibleFrame.maxY - 144 - 16 - 8
        XCTAssertEqual(sut.currentPanelFrame?.origin, CGPoint(x: expectedX, y: expectedY))
    }

    func testFallsBackToDefaultWhenSavedDictIsEmpty() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        // Panel origin = (visual origin) - 8pt hoverMargin on each axis.
        let expectedX = Self.builtIn.visibleFrame.maxX - 144 - 16 - 8
        let expectedY = Self.builtIn.visibleFrame.maxY - 144 - 16 - 8
        XCTAssertEqual(sut.currentPanelFrame?.origin, CGPoint(x: expectedX, y: expectedY))
    }

    // MARK: - Save after drag

    func testSavesPositionAfterDrag() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()

        // Panel is 160×160; for visual widget at (200, 300) the panel origin is (192, 292).
        // handlePanelDragEnd strips hoverMargin to recover (200, 300) and saves that as the relative position.
        let draggedPanelFrame = NSRect(x: 192, y: 292, width: 160, height: 160)
        sut.handlePanelDragEnd(panelFrame: draggedPanelFrame)

        let saved = settingsStore.position(for: "Built-in Display")
        XCTAssertEqual(saved, CGPoint(x: 200, y: 300))
    }

    func testSaveFiresOncePerDrag() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()

        // Panel is 160×160; visual widget at (100,100) → panel (92,92); visual at (200,300) → panel (192,292).
        sut.handlePanelDragEnd(panelFrame: NSRect(x: 92, y: 92, width: 160, height: 160))
        sut.handlePanelDragEnd(panelFrame: NSRect(x: 192, y: 292, width: 160, height: 160))

        let saved = settingsStore.position(for: "Built-in Display")
        XCTAssertEqual(saved, CGPoint(x: 200, y: 300), "Final drag position must overwrite earlier ones")
    }

    // MARK: - Cross-screen drag

    func testCrossScreenDragSavesForDestinationScreen() async {
        makeSUT(screens: [Self.builtIn, Self.external])
        sut.start()
        coordinator.start()
        await activateMic()

        // Visual widget at (1500, 500) on External Monitor → panel origin (1492, 492).
        let draggedPanelFrame = NSRect(x: 1492, y: 492, width: 160, height: 160)
        sut.handlePanelDragEnd(panelFrame: draggedPanelFrame)

        let saved = settingsStore.position(for: "External Monitor")
        // Saved position is visual widget origin relative to destination screen origin (1440, 0).
        XCTAssertEqual(saved, CGPoint(x: 1500 - Self.external.frame.origin.x,
                                     y: 500 - Self.external.frame.origin.y))
        XCTAssertNil(
            settingsStore.position(for: "Built-in Display"),
            "Must NOT save for the source screen"
        )
    }

    // MARK: - Off-screen clamping

    func testSavedPositionOffScreenIsClamped() async {
        makeSUT()
        settingsStore.setPosition(CGPoint(x: 2000, y: 2000), for: "Built-in Display")
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        let frame = sut.currentPanelFrame!
        // Clamped visual origin = (maxX - 144, maxY - 144); panel origin = visual - 8.
        let clampedX = Self.builtIn.visibleFrame.maxX - 144 - 8
        let clampedY = Self.builtIn.visibleFrame.maxY - 144 - 8
        XCTAssertEqual(frame.origin.x, clampedX, accuracy: 0.01)
        XCTAssertEqual(frame.origin.y, clampedY, accuracy: 0.01)
    }

    func testClampDoesNotOverwriteSavedPosition() async {
        makeSUT()
        settingsStore.setPosition(CGPoint(x: 2000, y: 2000), for: "Built-in Display")
        sut.start()
        coordinator.start()
        await activateMic()

        let saved = settingsStore.position(for: "Built-in Display")
        XCTAssertEqual(saved, CGPoint(x: 2000, y: 2000), "Clamp must not overwrite saved value")
    }

    // MARK: - Disconnected screen fallback

    func testDisconnectedScreenFallsBackToDefault() async {
        makeSUT()
        settingsStore.setPosition(CGPoint(x: 50, y: 50), for: "External Monitor")
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        // Panel origin = (visual origin) - 8pt hoverMargin on each axis.
        let expectedX = Self.builtIn.visibleFrame.maxX - 144 - 16 - 8
        let expectedY = Self.builtIn.visibleFrame.maxY - 144 - 16 - 8
        XCTAssertEqual(sut.currentPanelFrame?.origin, CGPoint(x: expectedX, y: expectedY))
    }

    // MARK: - SettingsStore encoding

    func testSettingsStorePositionForUnknownScreenReturnsNil() {
        makeSUT()
        XCTAssertNil(settingsStore.position(for: "Nonexistent Screen"))
    }

    func testSettingsStoreDecodesCorruptDataAsEmpty() {
        defaults = UserDefaults(suiteName: "PositionTests.corrupt.\(name)")!
        defaults.removePersistentDomain(forName: "PositionTests.corrupt.\(name)")
        defaults.set(Data([0xFF, 0xFE, 0x00]), forKey: "widgetPositionByDisplay")
        let store = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(store.widgetPositionByDisplay, [:])
    }

    // MARK: - Default position computation

    func testDefaultPositionComputedCorrectly() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()
        coordinator.lastEngineReadyAt = Date()
        await Task.yield()

        // Panel origin = (visual origin) - 8pt hoverMargin on each axis.
        let expectedX = Self.builtIn.visibleFrame.maxX - 144 - 16 - 8
        let expectedY = Self.builtIn.visibleFrame.maxY - 144 - 16 - 8
        XCTAssertEqual(sut.currentPanelFrame?.origin, CGPoint(x: expectedX, y: expectedY))
    }

    // MARK: - Deallocation with drag observer

    func testNoRetainCyclesWithDragEnd() async {
        makeSUT()
        sut.start()
        coordinator.start()
        await activateMic()

        sut.handlePanelDragEnd(panelFrame: NSRect(x: 92, y: 92, width: 160, height: 160))

        weak var weakController = sut
        sut.stop()
        sut = nil

        XCTAssertNil(weakController, "Controller must deallocate after drag-end + stop")
    }

}
