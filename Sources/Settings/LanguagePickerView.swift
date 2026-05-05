import SwiftUI

struct LanguagePickerView: View {
    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        ForEach(LocaleRegistry.allLocales) { entry in
            let isSelected = settingsStore.declaredLocales.contains(entry.identifier)
            let isDisabled = !isSelected && settingsStore.declaredLocales.count >= 2

            Toggle(isOn: Binding(
                get: { isSelected },
                set: { newValue in
                    if newValue {
                        settingsStore.toggleLocale(entry.identifier)
                    } else {
                        settingsStore.toggleLocale(entry.identifier)
                    }
                }
            )) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.displayName)
                        Text(entry.identifier)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(backendLabel(for: entry.backend))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(isDisabled)
        }
    }

    private func backendLabel(for backend: LocaleRegistry.Backend) -> String {
        switch backend {
        case .apple: "Apple, ~150 MB"
        case .parakeet: "Parakeet, ~1.2 GB"
        }
    }
}
