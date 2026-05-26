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
                LanguagePickerView()
            } header: {
                Text("Languages")
            } footer: {
                Text("Select 1\u{2013}2 languages for speech coaching.")
            }

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
                    "Row A median window: \(settingsStore.wpmMedianWindowHops) hops",
                    value: $settingsStore.wpmMedianWindowHops,
                    in: 1...10,
                    step: 1
                )
                Stepper(
                    "Row B EMA alpha: \(String(format: "%.2f", settingsStore.wpmEmaAlpha))",
                    value: $settingsStore.wpmEmaAlpha,
                    in: 0.1...1.0,
                    step: 0.05
                )
            } header: {
                Text("Speaking Pace (WPM)")
            } footer: {
                Text("Pause threshold is reserved \u{2014} not used until M4.3.\nRow A: median of last N hops (N=1 = raw). Row B: EMA alpha (higher = more responsive).")
            }

            Section {
                Stepper(
                    "Mic poll interval: \(String(format: "%.1f", settingsStore.probePollIntervalSeconds))s",
                    value: $settingsStore.probePollIntervalSeconds,
                    in: 0.5...5.0,
                    step: 0.5
                )
                Stepper(
                    "Widget hide delay: \(Int(settingsStore.widgetHideDelaySeconds))s",
                    value: $settingsStore.widgetHideDelaySeconds,
                    in: 1...30,
                    step: 1
                )
            } header: {
                Text("Session Behavior")
            } footer: {
                Text("Mic poll interval: how often Locto checks whether another app has claimed the mic. Default 1s.\nWidget hide delay: how long the widget stays visible after the last word before fading out. Default 4s.")
            }

            Section("Filler Words") {
                if settingsStore.declaredLocales.isEmpty {
                    Text("Pick a language to configure fillers.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(settingsStore.declaredLocales, id: \.self) { localeID in
                        let name = LocaleRegistry.allLocales
                            .first { $0.identifier == localeID }?.displayName ?? localeID
                        Text("Filler dictionary for \(name) \u{2014} editor coming soon")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 560)
    }
}
