import AppKit

protocol AlertPresenter: Sendable {
    @MainActor func presentDismissConfirmation() -> Bool
}

struct SystemAlertPresenter: AlertPresenter {
    @MainActor func presentDismissConfirmation() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Are you sure you are not going to speak during this session?"
        alert.addButton(withTitle: "Yes")
        alert.addButton(withTitle: "No")
        alert.alertStyle = .informational
        return alert.runModal() == .alertFirstButtonReturn
    }
}
