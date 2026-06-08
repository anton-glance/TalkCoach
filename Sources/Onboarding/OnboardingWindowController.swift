import AppKit
import SwiftUI

private let kModalWidth:  CGFloat = 560
private let kModalHeight: CGFloat = 600
private let kCornerRadius: CGFloat = 22

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private(set) var window: NSWindow?
    private var viewModel: OnboardingViewModel?

    func open(settingsStore: SettingsStore, onComplete: @escaping () -> Void) {
        let vm = OnboardingViewModel(settingsStore: settingsStore, onComplete: onComplete)
        viewModel = vm
        let shell = OnboardingShell(viewModel: vm)
        let rootView = shell
            .frame(width: kModalWidth, height: kModalHeight)
        let controller = NSHostingController(rootView: rootView)
        let win = NSWindow(contentViewController: controller)
        win.styleMask = [.borderless]
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.isMovableByWindowBackground = false
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.setContentSize(NSSize(width: kModalWidth, height: kModalHeight))
        win.delegate = self
        centerOnScreen(win)
        self.window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        viewModel = nil
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { false }

    private func centerOnScreen(_ win: NSWindow) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            win.center(); return
        }
        let sf = screen.frame
        let x = sf.midX - kModalWidth / 2
        let y = sf.midY - kModalHeight / 2
        win.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func applicationShouldHandleReopen() -> Bool {
        window?.isVisible == true ? false : true
    }
}
