import SwiftUI
import AppKit

enum SettingsWindow {
    nonisolated(unsafe) static let id = "settings"
}

nonisolated func pauseResumeMenuTitle(coachingEnabled: Bool) -> String {
    coachingEnabled ? "Pause Coaching" : "Resume Coaching"
}

@main
struct TalkCoachApp: App {
    var body: some Scene {
        MenuBarExtra("TalkCoach", systemImage: "waveform.badge.mic") {
            MenuBarContent()
        }

        Window("Settings", id: SettingsWindow.id) {
            Text("Settings (placeholder; M1.3 builds this)")
        }
        .defaultLaunchBehavior(.suppressed)
    }
}

struct MenuBarContent: View {
    @AppStorage("coachingEnabled") private var coachingEnabled = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About TalkCoach") {
            NSApplication.shared.activate()
            NSApplication.shared.orderFrontStandardAboutPanel(nil)
        }

        Button(pauseResumeMenuTitle(coachingEnabled: coachingEnabled)) {
            coachingEnabled.toggle()
        }

        Button("Settings…") {
            openWindow(id: SettingsWindow.id)
        }

        Divider()

        Button("Quit TalkCoach") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
