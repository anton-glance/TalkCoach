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
