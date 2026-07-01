import SwiftUI

private let widgetPositions: [CGPoint] = [
    CGPoint(x: 340, y: 40),
    CGPoint(x: 150, y: 120),
    CGPoint(x: 20, y: 62),
    CGPoint(x: 250, y: 92),
    CGPoint(x: 92, y: 34)
]

struct StepWidget: View {
    @ObservedObject private var viewModel: OnboardingViewModel
    @StateObject private var syntheticVM: WidgetViewModel
    @State private var posIdx: Int = 0
    @State private var wpmValue: Int = 150
    @State private var streakValue: Double = 14
    @State private var reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    init(viewModel: OnboardingViewModel) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _syntheticVM = StateObject(wrappedValue: WidgetViewModel(settings: viewModel.settingsStore))
    }

    private var pos: CGPoint { widgetPositions[posIdx] }

    var body: some View {
        ModalSheet(align: .center) {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: "The widget")
                Text("Put it wherever you like.")
                    .font(.custom("InterDisplay-Medium", size: 26))
                    .tracking(-0.6)
                    .foregroundStyle(DesignTokens.Text.primary)
                    .padding(.top, 12)
                Text("The tile appears on its own when a call starts — green means you're in your sweet spot. Drag it anywhere on your screen, and it stays exactly where you leave it.")
                    .font(.system(size: 14))
                    .foregroundStyle(DesignTokens.Text.secondary)
                    .lineSpacing(7)
                    .padding(.top, 6)
                    .padding(.bottom, 18)
                WidgetCrop(syntheticVM: syntheticVM, pos: pos)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } footer: {
            ProgressDots(total: 5, current: 4)
            Spacer()
            OnboardingPrimaryButton("Next") { viewModel.advance() }
        }
        .onAppear {
            setupSyntheticVM()
            if !reducedMotion { startTimers() }
        }
    }

    private func setupSyntheticVM() {
        syntheticVM.activityState = .counting
        syntheticVM.currentWPMVoiced = 150
        syntheticVM.streakSeconds = 14
        syntheticVM.hasReceivedWPM = true
        syntheticVM.isSessionActive = true
    }

    private func startTimers() {
        // WPM drift
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                let delta = Int.random(in: -5...5)
                wpmValue = max(138, min(166, wpmValue + delta))
                syntheticVM.currentWPMVoiced = wpmValue
            }
        }
        // Streak tick
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                streakValue = streakValue >= 75 ? 12 : streakValue + 1
                syntheticVM.streakSeconds = streakValue
            }
        }
        // Position cycle
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.95)) {
                    posIdx = (posIdx + 1) % widgetPositions.count
                }
            }
        }
    }
}

private struct WidgetCrop: View {
    let syntheticVM: WidgetViewModel
    let pos: CGPoint
    var body: some View {
        ScreenCrop(height: 246, caption: "Drag the widget anywhere on your screen") {
            // Menu bar sliver
            HStack {
                Spacer()
                HStack(spacing: 11) {
                    ZStack {
                        Circle()
                            .strokeBorder(DesignTokens.Text.primary.opacity(0.78), lineWidth: 1.5)
                            .frame(width: 13, height: 13)
                        Circle()
                            .frame(width: 13 * 0.172, height: 13 * 0.172)
                            .foregroundStyle(DesignTokens.Text.primary.opacity(0.78))
                    }
                    .frame(width: 13, height: 13)
                    Image(systemName: "battery.75").font(.system(size: 11)).foregroundStyle(DesignTokens.Text.primary.opacity(0.78))
                    Image(systemName: "wifi").font(.system(size: 10)).foregroundStyle(DesignTokens.Text.primary.opacity(0.78))
                    Text("9:41").font(.system(size: 11.5)).foregroundStyle(DesignTokens.Text.primary.opacity(0.72))
                }
                .padding(.trailing, 12)
            }
            .frame(height: 24)
            .frame(maxWidth: .infinity)
            .background(Color(red: 247/255, green: 245/255, blue: 239/255).opacity(0.92))
            .overlay(alignment: .bottom) { Divider().opacity(0.10) }

            // Widget at 0.72 scale, cursor rides inside the same animated container
            ZStack(alignment: .bottomTrailing) {
                WidgetView(viewModel: syntheticVM) { }
                // Drag cursor: spec path "M5 3l5.5 16 2.2-6.4L19 10 5 3z"
                Canvas { ctx, _ in
                    var path = Path()
                    path.move(to: CGPoint(x: 5, y: 3))
                    path.addLine(to: CGPoint(x: 10.5, y: 19))
                    path.addLine(to: CGPoint(x: 12.7, y: 12.6))
                    path.addLine(to: CGPoint(x: 19, y: 10))
                    path.closeSubpath()
                    ctx.fill(path, with: .color(.white))
                    ctx.stroke(path, with: .color(Color(red: 31/255, green: 41/255, blue: 55/255)), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                }
                .frame(width: 22, height: 22)
                .shadow(color: .black.opacity(0.4), radius: 1, y: 1)
                .padding(.trailing, 8)
                .padding(.bottom, 6)
            }
            .scaleEffect(0.72, anchor: .topLeading)
            .offset(x: pos.x, y: pos.y)
            .animation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.95), value: pos)
        }
    }
}
