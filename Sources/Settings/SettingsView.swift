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

            Section("Speaking Pace") {
                Text("WPM target band: \(settingsStore.wpmTargetMin)\u{2013}\(settingsStore.wpmTargetMax) WPM")
                    .foregroundStyle(.secondary)
            }

            Section {
                Stepper(
                    "Inactivity timeout: \(Int(settingsStore.inactivityThresholdSeconds))s",
                    value: $settingsStore.inactivityThresholdSeconds,
                    in: 5...120,
                    step: 1
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
                Text("Inactivity timeout: how long Locto waits in silence before checking if another app is using the mic. Default 15s.\nWidget hide delay: how long the widget stays visible after the last word before fading out. Default 4s.")
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
