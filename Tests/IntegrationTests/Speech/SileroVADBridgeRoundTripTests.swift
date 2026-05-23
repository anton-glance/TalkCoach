import XCTest
import CParakeetBridge
@testable import TalkCoach

/// Integration round-trip: Swift → Rust → ORT → Swift for the Silero VAD bridge.
///
/// Red phase: sl_engine_create always returns null (stub) → test XCTSkips.
/// Green phase: requires silero_vad.onnx in Application Support; XCTSkips if absent.
final class SileroVADBridgeRoundTripTests: XCTestCase {

    func testSileroCreateProcessDestroyRoundTrip() throws {
        let modelPath = sileroModelPath()
        let engine = modelPath.withCString { sl_engine_create($0) }
        try XCTSkipIf(engine == nil, "silero_vad.onnx not available at \(modelPath) — skipping bridge round-trip (expected in CI)")
        defer { sl_engine_destroy(engine) }

        // Feed 512 zero-value samples; prob must be in [0, 1] and must not crash.
        let samples = [Float](repeating: 0.0, count: 512)
        let prob = samples.withUnsafeBufferPointer { ptr in
            sl_process_frame(engine, ptr.baseAddress!, ptr.count)
        }
        XCTAssertGreaterThanOrEqual(prob, 0.0, "probability must be ≥ 0")
        XCTAssertLessThanOrEqual(prob, 1.0, "probability must be ≤ 1")

        // Second call must not crash and must still return a valid probability.
        let prob2 = samples.withUnsafeBufferPointer { ptr in
            sl_process_frame(engine, ptr.baseAddress!, ptr.count)
        }
        XCTAssertGreaterThanOrEqual(prob2, 0.0)
        XCTAssertLessThanOrEqual(prob2, 1.0)

        // sl_engine_reset must not crash.
        sl_engine_reset(engine)
    }

    func testSileroCreateWithNullReturnsNull() {
        let result = sl_engine_create(nil)
        // Stub always returns null; green implementation also returns null for nil path.
        XCTAssertNil(result)
    }

    func testSileroProcessFrameWithNullEngineReturnsZero() {
        let samples = [Float](repeating: 0.5, count: 512)
        let prob = samples.withUnsafeBufferPointer { ptr in
            sl_process_frame(nil, ptr.baseAddress!, ptr.count)
        }
        XCTAssertEqual(prob, 0.0, "null engine must return 0.0 without crashing")
    }

    func testSileroDestroyNullIsNoOp() {
        sl_engine_destroy(nil)
    }

    func testSileroResetNullIsNoOp() {
        sl_engine_reset(nil)
    }

    // MARK: - Helpers

    private func sileroModelPath() -> String {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            return ""
        }
        return appSupport
            .appendingPathComponent("TalkCoach")
            .appendingPathComponent("Models")
            .appendingPathComponent("silero_vad.onnx")
            .path
    }
}
