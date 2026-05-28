import SwiftUI

// Stub — RED phase. Real implementation follows in the GREEN commit.
struct WidgetView: View {
    @ObservedObject var viewModel: WidgetViewModel
    var onDismiss: () -> Void

    var body: some View { EmptyView() }

    static func monoLabelText(streakSeconds: TimeInterval, l2Seconds: TimeInterval) -> String { "" }
    static func monoLabelWeight(
        streakSeconds: TimeInterval,
        l2Seconds: TimeInterval,
        isIdle: Bool
    ) -> Font.Weight { .regular }
    static func monoCaretFraction(streakSeconds: TimeInterval, l3Seconds: TimeInterval) -> Double { -1 }
    static func formatMonoTime(_ seconds: TimeInterval) -> (minutes: String, seconds: String) { ("", "") }
}
