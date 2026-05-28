import SwiftUI
import OSLog

nonisolated func shouldAutoOpenSettings(hasCompletedSetup: Bool) -> Bool {
    !hasCompletedSetup
}

struct SettingsView: View {
    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        Form {
            Section {
                Stepper(
                    "Refresh every \(Int(settingsStore.wpmRefreshInterval))s",
                    value: $settingsStore.wpmRefreshInterval,
                    in: 1.0...10.0,
                    step: 1.0
                )
                Stepper(
                    "Pause threshold: \(String(format: "%.1f", settingsStore.wpmPauseThreshold))s",
                    value: $settingsStore.wpmPauseThreshold,
                    in: 0.5...10.0,
                    step: 0.5
                )
                Stepper(
                    "EMA smoothing: \(String(format: "%.2f", settingsStore.wpmEmaAlpha))",
                    value: $settingsStore.wpmEmaAlpha,
                    in: 0.1...1.0,
                    step: 0.05
                )
            } header: {
                Text("Speaking Pace (WPM)")
            } footer: {
                Text("Pause threshold: silence longer than this fades the widget to dim waiting state. EMA alpha: smoothing factor for WPM display (higher = more responsive, lower = smoother).")
            }

            Section {
                Stepper(
                    "Pause resets streak: \(String(format: "%.1f", settingsStore.monologuePauseThreshold))s",
                    value: $settingsStore.monologuePauseThreshold,
                    in: 0.5...10.0,
                    step: 0.5
                )
                Stepper(
                    "Level 1 at: \(String(format: "%.2f", settingsStore.monologueLevel1Minutes)) min",
                    value: $settingsStore.monologueLevel1Minutes,
                    in: 0.25...30.0,
                    step: 0.25
                )
                Stepper(
                    "Level 2 at: \(String(format: "%.2f", settingsStore.monologueLevel2Minutes)) min",
                    value: $settingsStore.monologueLevel2Minutes,
                    in: 0.25...30.0,
                    step: 0.25
                )
                Stepper(
                    "Level 3 at: \(String(format: "%.2f", settingsStore.monologueLevel3Minutes)) min",
                    value: $settingsStore.monologueLevel3Minutes,
                    in: 0.25...30.0,
                    step: 0.25
                )
            } header: {
                Text("Monologue")
            } footer: {
                Text("Streak resets when you yield longer than the pause threshold. Levels 1\u{2013}3 trigger the monologue indicator (v1.x widget feature). Defaults: 2.5s pause, 1 / 1.5 / 2.5 min.")
            }

            Section {
                Stepper(
                    "Working opacity: \(String(format: "%.2f", settingsStore.workingOpacity))",
                    value: $settingsStore.workingOpacity,
                    in: 0.1...1.0,
                    step: 0.05
                )
                Stepper(
                    "Dim opacity: \(String(format: "%.2f", settingsStore.waitingOpacity))",
                    value: $settingsStore.waitingOpacity,
                    in: 0.1...1.0,
                    step: 0.05
                )
                Stepper(
                    "Stay visible after session: \(String(format: "%.1f", settingsStore.lingerFullSeconds))s",
                    value: $settingsStore.lingerFullSeconds,
                    in: 1.0...10.0,
                    step: 0.5
                )
                Stepper(
                    "Fade-out duration: \(String(format: "%.1f", settingsStore.lingerFadeSeconds))s",
                    value: $settingsStore.lingerFadeSeconds,
                    in: 0.5...5.0,
                    step: 0.5
                )
                Stepper(
                    "Recovery grace: \(String(format: "%.1f", settingsStore.recoveryGraceSeconds))s",
                    value: $settingsStore.recoveryGraceSeconds,
                    in: 0.5...5.0,
                    step: 0.5
                )
            } header: {
                Text("Widget Behavior")
            } footer: {
                Text("Working opacity: panel alpha while actively counting. Dim opacity: panel alpha during pauses. Stay visible: full-opacity hold after session ends. Fade-out: animation duration. Recovery grace: window after audio recovery for a token before dimming.")
            }

            Section {
                Stepper(
                    "Mic poll interval: \(String(format: "%.1f", settingsStore.probePollIntervalSeconds))s",
                    value: $settingsStore.probePollIntervalSeconds,
                    in: 0.5...5.0,
                    step: 0.5
                )
            } header: {
                Text("Session")
            } footer: {
                Text("How often the app checks whether another app has claimed the microphone. Default 1s.")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 560)
    }
}
