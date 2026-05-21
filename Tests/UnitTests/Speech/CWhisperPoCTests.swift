import XCTest
import CWhisper

// PoC: verifies the CWhisper bridge target links correctly and Metal embed library
// is built into libwhisper.a (GGML_METAL_EMBED_LIBRARY=ON). These three checks are
// the sub-commit 1 exit criterion — they must all pass before any backend Swift work.
@MainActor final class CWhisperPoCTests: XCTestCase {

    func testCWhisperImportsAndLinks() {
        // The Swift import at the top of this file is the real compile-time check.
        // At runtime: confirm cwhisper_init is callable and returns nil for missing path.
        let ctx = cwhisper_init("/tmp/nonexistent-model-talkcoach-poc.bin", false)
        XCTAssertNil(ctx, "cwhisper_init must return nil for a nonexistent model path")
    }

    func testInitReturnsNilForMissingModel() {
        let ctx = cwhisper_init("/tmp/nonexistent-model-talkcoach-poc.bin", true)
        XCTAssertNil(ctx, "cwhisper_init returns nil without crashing on missing model path")
    }

    func testSystemInfoReportsMetalEmbed() {
        guard let rawPtr = cwhisper_system_info() else {
            XCTFail("cwhisper_system_info() returned nil")
            return
        }
        let info = String(cString: rawPtr)
        XCTAssert(
            info.contains("MTL : EMBED_LIBRARY = 1"),
            "Expected 'MTL : EMBED_LIBRARY = 1' in system_info output; got:\n\(info)"
        )
    }
}
