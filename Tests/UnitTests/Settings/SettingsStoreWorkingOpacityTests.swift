import XCTest
@testable import TalkCoach

@MainActor final class SettingsStoreWorkingOpacityTests: XCTestCase {

    private func makeStore() -> (SettingsStore, UserDefaults) {
        let suiteName = "SettingsStoreWorkingOpacityTests.\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (SettingsStore(userDefaults: defaults), defaults)
    }

    func testWorkingOpacityDefaultIsOne() {
        let (store, _) = makeStore()
        XCTAssertEqual(store.workingOpacity, 1.00, accuracy: 0.001)
    }

    func testWorkingOpacityClampsBelowMin() {
        let (store, _) = makeStore()
        store.workingOpacity = 0.05
        XCTAssertEqual(store.workingOpacity, 0.1, accuracy: 0.001)
    }

    func testWorkingOpacityClampAboveMax() {
        let (store, _) = makeStore()
        store.workingOpacity = 1.5
        XCTAssertEqual(store.workingOpacity, 1.0, accuracy: 0.001)
    }

    func testWorkingOpacityPersistsKey() {
        let (store, defaults) = makeStore()
        store.workingOpacity = 0.80
        let raw = defaults.object(forKey: "workingOpacity") as? Double
        XCTAssertEqual(raw ?? 0, 0.80, accuracy: 0.001)
    }
}
