import AppKit
import AVFoundation
import OSLog
import Speech

enum AuthorizationOutcome: Equatable, Sendable {
    case allAuthorized
    case micDenied
    case speechDenied
    case bothDenied
    case notDetermined
}

enum PermissionKind: Sendable {
    case microphone
    case speechRecognition
}

nonisolated func systemSettingsURL(for permission: PermissionKind) -> URL {
    URL(string: "about:blank")!
}

@MainActor
final class PermissionManager {
    let statusProvider: PermissionStatusProvider

    init(statusProvider: PermissionStatusProvider = SystemPermissionStatusProvider()) {
        self.statusProvider = statusProvider
    }

    func currentStatus() -> AuthorizationOutcome {
        .notDetermined
    }

    func requestAll() async -> AuthorizationOutcome {
        .notDetermined
    }

    func showDeniedAlert(for outcome: AuthorizationOutcome) {
    }
}
