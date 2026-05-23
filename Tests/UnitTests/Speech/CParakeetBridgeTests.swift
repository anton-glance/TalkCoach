import XCTest
import CParakeetBridge
@testable import TalkCoach

/// AC-4 (narrowed): libwhisper/libggml are gone from the binary.
/// Does NOT assert Metal/MetalKit/Accelerate — those are legitimate system links.
@MainActor
final class CParakeetBridgeTests: XCTestCase {

    func testPkEngineCreateWithNullReturnsNull() {
        // pk_engine_create(nil) must return null without crashing.
        let result = pk_engine_create(nil)
        XCTAssertNil(result, "pk_engine_create(nil) must return null")
    }

    func testPkFreeResultWithNullIsNoOp() {
        // pk_free_result(nil) must be a no-op without crashing.
        pk_free_result(nil)
    }

    func testPkTranscribeWithNullEngineReturnsNull() {
        let samples: [Float] = [0.0, 0.0, 0.0]
        let result = samples.withUnsafeBufferPointer { ptr in
            pk_transcribe(nil, ptr.baseAddress, ptr.count)
        }
        XCTAssertNil(result, "pk_transcribe with null engine must return null")
    }

    /// AC-4 (narrowed): libwhisper and libggml symbols must not appear in the linked binary.
    /// Metal/MetalKit/Accelerate are permitted — they are legitimate system framework links.
    func testNoWhisperOrGgmlSymbolsLinked() throws {
        let binaryURL = Bundle(for: type(of: self)).executableURL
        guard let url = binaryURL else {
            XCTFail("Could not locate test binary URL")
            return
        }
        let data = try Data(contentsOf: url)
        let text = String(bytes: data, encoding: .ascii) ?? ""
        let whisperHits = text.ranges(of: "libwhisper").count + text.ranges(of: "libggml").count
        XCTAssertEqual(
            whisperHits, 0,
            "libwhisper/libggml must not be linked — found \(whisperHits) occurrences"
        )
    }
}
