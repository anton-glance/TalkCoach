import SwiftUI

struct PlaceholderWidgetView: View {
    @ObservedObject var viewModel: WidgetViewModel
    var onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 8) {
                Spacer()
                if let startedAt = viewModel.sessionStartedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Text(Self.formatElapsed(from: startedAt, to: context.date))
                            .font(.system(size: 36, weight: .light, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                    }
                } else {
                    Text("--:--")
                        .font(.system(size: 36, weight: .light, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                VStack(spacing: 2) {
                    Text(Self.label(for: viewModel.activityState))
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text("\(viewModel.totalTokens) tokens")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.tertiary)
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

    private static func label(for state: WidgetActivityState) -> String {
        switch state {
        case .waiting: return "Listening\u{2026}"
        case .counting: return "Counting\u{2026}"
        case .probing: return "Checking mic\u{2026}"
        case .resuming: return "Resuming\u{2026}"
        }
    }

    private static func formatElapsed(from start: Date, to now: Date) -> String {
        let interval = max(0, now.timeIntervalSince(start))
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
