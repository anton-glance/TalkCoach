import AVFoundation
import Speech

protocol PermissionStatusProvider: Sendable {
    func micAuthorizationStatus() -> AVAuthorizationStatus
    func speechAuthorizationStatus() -> SFSpeechRecognizerAuthorizationStatus
    func requestMicAccess() async -> Bool
    func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus
}

struct SystemPermissionStatusProvider: PermissionStatusProvider {

    func micAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func speechAuthorizationStatus() -> SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    func requestMicAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}
