import AppKit
import SwiftUI

private let kModalWidth: CGFloat = 560
private let kModalHeight: CGFloat = 600
private let kCornerRadius: CGFloat = 22

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private var viewModel: OnboardingViewModel?

    func open(settingsStore: SettingsStore, onComplete: @escaping () -> Void) {
        let viewModel = OnboardingViewModel(settingsStore: settingsStore, onComplete: onComplete)
        self.viewModel = viewModel
        let shell = OnboardingShell(viewModel: viewModel)
        let rootView = shell
            .frame(width: kModalWidth, height: kModalHeight)
        let controller = NSHostingController(rootView: rootView)
        let win = NSWindow(contentViewController: controller)
        win.styleMask = [.borderless]
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.level = .normal
        win.contentView?.wantsLayer = true
        win.contentView?.layer?.cornerRadius = kCornerRadius
        win.contentView?.layer?.masksToBounds = true
        win.setContentSize(NSSize(width: kModalWidth, height: kModalHeight))
        win.delegate = self
        centerOnScreen(win)
        self.window = win
        ActivationPolicyController.shared.registerWindow("onboarding")
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        viewModel = nil
        ActivationPolicyController.shared.unregisterWindow("onboarding")
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { false }

    private func centerOnScreen(_ win: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            win.center(); return
        }
        let screenFrame = screen.frame
        let x = screenFrame.midX - kModalWidth / 2
        let y = screenFrame.midY - kModalHeight / 2
        win.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func applicationShouldHandleReopen() -> Bool {
        window?.isVisible == true ? false : true
    }
}
