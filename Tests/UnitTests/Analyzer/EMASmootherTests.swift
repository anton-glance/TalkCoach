import XCTest
@testable import TalkCoach

@MainActor
final class EMASmootherTests: XCTestCase {

    func testFirstCallReturnsInputDirectly() {
        var smoother = EMASmoother(alpha: 0.5)
        let result = smoother.smooth(100.0)
        XCTAssertEqual(result, 100.0, accuracy: 0.001)
    }

    func testSecondCallAverages() {
        var smoother = EMASmoother(alpha: 0.5)
        _ = smoother.smooth(100.0)
        let result = smoother.smooth(0.0)
        // 0.5 * 0.0 + 0.5 * 100.0 = 50.0
        XCTAssertEqual(result, 50.0, accuracy: 0.001)
    }

    func testAlphaOnePassesThrough() {
        var smoother = EMASmoother(alpha: 1.0)
        _ = smoother.smooth(100.0)
        let result = smoother.smooth(42.0)
        XCTAssertEqual(result, 42.0, accuracy: 0.001)
    }

    func testResetClearsPreviousOutput() {
        var smoother = EMASmoother(alpha: 0.5)
        _ = smoother.smooth(100.0)
        smoother.reset()
        // After reset, next call should behave as first call.
        let result = smoother.smooth(50.0)
        XCTAssertEqual(result, 50.0, accuracy: 0.001)
    }

    func testResetAllowsNewAccumulation() {
        var smoother = EMASmoother(alpha: 0.5)
        _ = smoother.smooth(200.0)
        smoother.reset()
        _ = smoother.smooth(10.0)
        let result = smoother.smooth(0.0)
        // 0.5 * 0.0 + 0.5 * 10.0 = 5.0
        XCTAssertEqual(result, 5.0, accuracy: 0.001)
    }
}
