import AVFoundation
import Speech
import XCTest
@testable import TalkCoach

private final class FakePermissionStatusProvider: PermissionStatusProvider, @unchecked Sendable {
    nonisolated(unsafe) var micStatus: AVAuthorizationStatus = .notDetermined
    nonisolated(unsafe) var speechStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    nonisolated(unsafe) var micRequestResult: Bool = false
    nonisolated(unsafe) var speechRequestResult: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    nonisolated(unsafe) private(set) var micRequestCalled = false
    nonisolated(unsafe) private(set) var speechRequestCalled = false
    nonisolated(unsafe) private(set) var requestOrder: [String] = []

    nonisolated func micAuthorizationStatus() -> AVAuthorizationStatus { micStatus }
    nonisolated func speechAuthorizationStatus() -> SFSpeechRecognizerAuthorizationStatus { speechStatus }

    nonisolated func requestMicAccess() async -> Bool {
        micRequestCalled = true
        requestOrder.append("mic")
        micStatus = micRequestResult ? .authorized : .denied
        return micRequestResult
    }

    nonisolated func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        speechRequestCalled = true
        requestOrder.append("speech")
        speechStatus = speechRequestResult
        return speechRequestResult
    }
}

@MainActor
final class PermissionManagerTests: XCTestCase {

    private func makeSUT(
        micStatus: AVAuthorizationStatus = .notDetermined,
        speechStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined,
        micRequestResult: Bool = false,
        speechRequestResult: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    ) -> (PermissionManager, FakePermissionStatusProvider) {
        let fake = FakePermissionStatusProvider()
        fake.micStatus = micStatus
        fake.speechStatus = speechStatus
        fake.micRequestResult = micRequestResult
        fake.speechRequestResult = speechRequestResult
        let manager = PermissionManager(statusProvider: fake)
        return (manager, fake)
    }

    // MARK: - currentStatus tests

    func testCurrentStatusBothAuthorized() {
        let (manager, _) = makeSUT(micStatus: .authorized, speechStatus: .authorized)
        XCTAssertEqual(manager.currentStatus(), .allAuthorized)
    }

    func testCurrentStatusMicDenied() {
        let (manager, _) = makeSUT(micStatus: .denied, speechStatus: .authorized)
        XCTAssertEqual(manager.currentStatus(), .micDenied)
    }

    func testCurrentStatusSpeechDenied() {
        let (manager, _) = makeSUT(micStatus: .authorized, speechStatus: .denied)
        XCTAssertEqual(manager.currentStatus(), .speechDenied)
    }

    func testCurrentStatusBothDenied() {
        let (manager, _) = makeSUT(micStatus: .denied, speechStatus: .denied)
        XCTAssertEqual(manager.currentStatus(), .bothDenied)
    }

    func testCurrentStatusMicNotDeterminedSpeechAuthorized() {
        let (manager, _) = makeSUT(micStatus: .notDetermined, speechStatus: .authorized)
        XCTAssertEqual(manager.currentStatus(), .notDetermined)
    }

    func testCurrentStatusMicRestricted() {
        let (manager, _) = makeSUT(micStatus: .restricted, speechStatus: .authorized)
        XCTAssertEqual(manager.currentStatus(), .micDenied)
    }

    // MARK: - requestAll tests

    func testRequestAllStopsAtMicDenied() async {
        let (manager, fake) = makeSUT(micRequestResult: false)
        let outcome = await manager.requestAll()
        XCTAssertTrue(fake.micRequestCalled)
        XCTAssertFalse(fake.speechRequestCalled)
        XCTAssertEqual(outcome, .micDenied)
    }

    func testRequestAllRequestsBothWhenMicGranted() async {
        let (manager, fake) = makeSUT(micRequestResult: true, speechRequestResult: .authorized)
        let outcome = await manager.requestAll()
        XCTAssertTrue(fake.micRequestCalled)
        XCTAssertTrue(fake.speechRequestCalled)
        XCTAssertEqual(fake.requestOrder, ["mic", "speech"])
        XCTAssertEqual(outcome, .allAuthorized)
    }

    func testRequestAllRequestsBothMicGrantedSpeechDenied() async {
        let (manager, fake) = makeSUT(micRequestResult: true, speechRequestResult: .denied)
        let outcome = await manager.requestAll()
        XCTAssertTrue(fake.micRequestCalled)
        XCTAssertTrue(fake.speechRequestCalled)
        XCTAssertEqual(outcome, .speechDenied)
    }

    // MARK: - URL builder

    func testSystemSettingsURLForMicrophone() {
        let url = systemSettingsURL(for: .microphone)
        XCTAssertEqual(
            url.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        )
    }
}
