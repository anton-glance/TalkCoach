import AVFoundation
import Speech

protocol PermissionStatusProvider: Sendable {
    func micAuthorizationStatus() -> AVAuthorizationStatus
    func speechAuthorizationStatus() -> SFSpeechRecognizerAuthorizationStatus
    func requestMicAccess() async -> Bool
    func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus
}

struct SystemPermissionStatusProvider: PermissionStatusProvider {
    func micAuthorizationStatus() -> AVAuthorizationStatus { .notDetermined }
    func speechAuthorizationStatus() -> SFSpeechRecognizerAuthorizationStatus { .notDetermined }
    func requestMicAccess() async -> Bool { false }
    func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus { .notDetermined }
}
