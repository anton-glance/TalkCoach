import SwiftUI

struct PlaceholderWidgetView: View {
    @ObservedObject var viewModel: WidgetViewModel
    var onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 8) {
                Spacer()

                // WPM-A row (raw, fixed 10s denominator)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("A")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(wpmText(viewModel.currentWPMRaw))
                        .font(.system(size: 28, weight: .light, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }

                // Activity state label
                Text(Self.label(for: viewModel.activityState))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)

                // WPM-B row (voiced-seconds denominator)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("B")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text(wpmText(viewModel.currentWPMVoiced))
                        .font(.system(size: 28, weight: .light, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // REMOVE-IN-M5.7: replace with hover-only close affordance
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .frame(width: 144, height: 144)
        .background(.regularMaterial) // REMOVE-IN-M5.7: replace with Liquid Glass material
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
    }

    private func wpmText(_ value: Int?) -> String {
        value.map { "\($0)" } ?? "---"
    }

    private static func label(for state: WidgetActivityState) -> String {
        switch state {
        case .idle: return ""
        case .warming: return "Warming\u{2026}"
        case .counting: return "Counting\u{2026}"
        case .waiting: return "Waiting\u{2026}"
        case .wrapping: return "Wrapping\u{2026}"
        case .recovering: return "Recovering\u{2026}"
        case .dismissed: return ""
        }
    }
}
