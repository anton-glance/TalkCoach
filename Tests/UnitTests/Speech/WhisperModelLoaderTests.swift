import XCTest
@testable import TalkCoach

@MainActor final class WhisperModelLoaderTests: XCTestCase {

    func testThrowsWhenWhisperModelMissingFromBundle() {
        let testBundle = Bundle(for: WhisperModelLoaderTests.self)
        XCTAssertThrowsError(try WhisperModelLoader.whisperModelURL(bundle: testBundle)) { error in
            XCTAssertEqual(error as? WhisperModelLoaderError, .whisperModelNotFound)
        }
    }

    func testThrowsWhenSileroModelMissingFromBundle() {
        let testBundle = Bundle(for: WhisperModelLoaderTests.self)
        XCTAssertThrowsError(try WhisperModelLoader.sileroModelURL(bundle: testBundle)) { error in
            XCTAssertEqual(error as? WhisperModelLoaderError, .sileroModelNotFound)
        }
    }
}
