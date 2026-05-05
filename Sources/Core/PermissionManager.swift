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
    switch permission {
    case .microphone:
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    case .speechRecognition:
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!
    }
}

@MainActor
final class PermissionManager {
    let statusProvider: PermissionStatusProvider

    init(statusProvider: PermissionStatusProvider = SystemPermissionStatusProvider()) {
        self.statusProvider = statusProvider
    }

    func currentStatus() -> AuthorizationOutcome {
        let mic = statusProvider.micAuthorizationStatus()
        let speech = statusProvider.speechAuthorizationStatus()
        return mapOutcome(mic: mic, speech: speech)
    }

    func requestAll() async -> AuthorizationOutcome {
        let micGranted = await requestMic()
        if micGranted {
            _ = await requestSpeech()
        }
        let outcome = currentStatus()
        Logger.app.info("Permission request completed with outcome: \(String(describing: outcome))")
        return outcome
    }

    // MARK: - Denied alert (app-modal via runModal per LSUIElement constraint)

    func showDeniedAlert(for outcome: AuthorizationOutcome) {
        guard outcome != .allAuthorized, outcome != .notDetermined else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = alertTitle(for: outcome)
        alert.informativeText = alertMessage(for: outcome)
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let url = settingsURL(for: outcome)
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Private

    private func requestMic() async -> Bool {
        let granted = await statusProvider.requestMicAccess()
        Logger.app.info("Mic access request result: \(granted ? "granted" : "denied")")
        return granted
    }

    private func requestSpeech() async -> Bool {
        let status = await statusProvider.requestSpeechAuthorization()
        let granted = status == .authorized
        Logger.app.info("Speech authorization request result: \(granted ? "granted" : "denied")")
        return granted
    }

    private func mapOutcome(
        mic: AVAuthorizationStatus,
        speech: SFSpeechRecognizerAuthorizationStatus
    ) -> AuthorizationOutcome {
        let micDenied = mic == .denied || mic == .restricted
        let speechDenied = speech == .denied || speech == .restricted

        if mic == .notDetermined || (!micDenied && speech == .notDetermined) {
            return .notDetermined
        }
        if micDenied && speechDenied {
            return .bothDenied
        }
        if micDenied {
            return .micDenied
        }
        if speechDenied {
            return .speechDenied
        }
        return .allAuthorized
    }

    private nonisolated func alertTitle(for outcome: AuthorizationOutcome) -> String {
        switch outcome {
        case .micDenied:
            "Microphone Access Required"
        case .speechDenied:
            "Speech Recognition Access Required"
        case .bothDenied:
            "Microphone & Speech Recognition Access Required"
        case .allAuthorized, .notDetermined:
            ""
        }
    }

    private nonisolated func alertMessage(for outcome: AuthorizationOutcome) -> String {
        switch outcome {
        case .micDenied:
            "TalkCoach needs microphone access to analyze your speaking pace. "
                + "Please grant access in System Settings."
        case .speechDenied:
            "TalkCoach needs speech recognition permission to transcribe your speech on-device. "
                + "Please grant access in System Settings."
        case .bothDenied:
            "TalkCoach needs both microphone and speech recognition access. "
                + "Please grant access in System Settings."
        case .allAuthorized, .notDetermined:
            ""
        }
    }

    private nonisolated func settingsURL(for outcome: AuthorizationOutcome) -> URL {
        switch outcome {
        case .speechDenied:
            systemSettingsURL(for: .speechRecognition)
        default:
            systemSettingsURL(for: .microphone)
        }
    }
}
