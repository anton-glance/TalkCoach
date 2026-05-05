import SwiftUI
import AppKit
import OSLog

nonisolated func pauseResumeMenuTitle(coachingEnabled: Bool) -> String {
    coachingEnabled ? "Pause Coaching" : "Resume Coaching"
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var current: AppDelegate?

    let settingsStore = SettingsStore()
    let permissionManager = PermissionManager()
    private(set) var settingsWindow: NSWindow?

    override init() {
        super.init()
        AppDelegate.current = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        let wasSetupCompletedBefore = defaults.bool(forKey: "hasCompletedSetup")

        if !wasSetupCompletedBefore {
            let declaredLocales = defaults.object(forKey: "declaredLocales") as? [String] ?? []
            if declaredLocales.isEmpty {
                let sysLocale = Locale.current.identifier
                    .replacingOccurrences(of: "-", with: "_")
                if LocaleRegistry.allLocales.contains(where: { $0.identifier == sysLocale }) {
                    defaults.set([sysLocale], forKey: "declaredLocales")
                    defaults.set(true, forKey: "hasCompletedSetup")
                    Logger.app.info("Silent-committed system locale: \(sysLocale)")
                }
            }
            DispatchQueue.main.async {
                self.openSettings()
            }
        }
    }

    func openSettings() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingView = NSHostingController(
            rootView: SettingsView()
                .environmentObject(settingsStore)
        )

        let window = NSWindow(contentViewController: hostingView)
        window.title = "TalkCoach Settings"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(width: 520, height: 600))
        window.center()
        window.isReleasedWhenClosed = false
        window.isRestorable = false

        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct TalkCoachApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra("TalkCoach", systemImage: "waveform.badge.mic") {
            MenuBarContent()
                .environmentObject(delegate.settingsStore)
        }
    }
}

struct MenuBarContent: View {
    @AppStorage("coachingEnabled") private var coachingEnabled = true
    @AppStorage("hasCompletedSetup") private var hasCompletedSetup = false

    var body: some View {
        Button("About TalkCoach") {
            NSApplication.shared.activate()
            NSApplication.shared.orderFrontStandardAboutPanel(nil)
        }

        Button(pauseResumeMenuTitle(coachingEnabled: coachingEnabled)) {
            coachingEnabled.toggle()
        }

        Button("Settings\u{2026}") {
            AppDelegate.current?.openSettings()
        }

        #if DEBUG
        // M1.6 scaffolding — removed in M2.3 when SessionCoordinator becomes the production caller.
        Button("Check Permissions") {
            Task {
                guard let manager = AppDelegate.current?.permissionManager else { return }
                let outcome = await manager.requestAll()
                if outcome != .allAuthorized {
                    manager.showDeniedAlert(for: outcome)
                }
            }
        }
        #endif

        Divider()

        Button("Quit TalkCoach") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
