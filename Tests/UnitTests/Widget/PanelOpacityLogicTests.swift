import XCTest
@testable import TalkCoach

@MainActor final class PanelOpacityLogicTests: XCTestCase {

    // MARK: - targetAlpha pure function

    func testTargetAlphaCountingUsesWorkingOpacity() {
        let alpha = FloatingPanelController.targetAlpha(for: .counting, workingOpacity: 0.85, waitingOpacity: 0.50)
        XCTAssertEqual(Double(alpha ?? 0), 0.85, accuracy: 0.001)
    }

    func testTargetAlphaWaitingUsesWaitingOpacity() {
        let alpha = FloatingPanelController.targetAlpha(for: .waiting, workingOpacity: 0.85, waitingOpacity: 0.50)
        XCTAssertEqual(Double(alpha ?? 0), 0.50, accuracy: 0.001)
    }

    func testTargetAlphaWarmingIsOne() {
        let alpha = FloatingPanelController.targetAlpha(for: .warming, workingOpacity: 0.85, waitingOpacity: 0.50)
        XCTAssertEqual(Double(alpha ?? 0), 1.0, accuracy: 0.001)
    }

    func testTargetAlphaRecoveringIsOne() {
        let alpha = FloatingPanelController.targetAlpha(for: .recovering, workingOpacity: 0.85, waitingOpacity: 0.50)
        XCTAssertEqual(Double(alpha ?? 0), 1.0, accuracy: 0.001)
    }

    func testTargetAlphaIdleIsNil() {
        let alpha = FloatingPanelController.targetAlpha(for: .idle, workingOpacity: 0.85, waitingOpacity: 0.50)
        XCTAssertNil(alpha)
    }

    // MARK: - panelOpacityDuration pure function

    func testOpacityDurationCountingToWaiting() {
        let dur = FloatingPanelController.panelOpacityDuration(from: .counting, to: .waiting)
        XCTAssertEqual(dur, 0.7, accuracy: 0.001)
    }

    func testOpacityDurationWaitingToCounting() {
        let dur = FloatingPanelController.panelOpacityDuration(from: .waiting, to: .counting)
        XCTAssertEqual(dur, 0.7, accuracy: 0.001)
    }

    func testOpacityDurationWarmingToCounting() {
        let dur = FloatingPanelController.panelOpacityDuration(from: .warming, to: .counting)
        XCTAssertEqual(dur, 0.3, accuracy: 0.001)
    }
}
