import SwiftUI

struct StepReady: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    var body: some View {
        ModalSheet(align: .center, onClose: viewModel.complete) {
            VStack(spacing: 0) {
                OnboardingLockup(markSize: 30)
                Text("You're all set.")
                    .font(.custom("InterDisplay-Medium", size: 30))
                    .tracking(-0.8)
                    .foregroundStyle(DesignTokens.Text.primary)
                    .padding(.top, 32)
                Text("Open your favorite calling app and start talking. Locto appears on its own — no buttons to press.")
                    .font(.system(size: 15))
                    .lineSpacing(9.75)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignTokens.Text.secondary)
                    .frame(maxWidth: 400)
                    .padding(.top, 8)
                AppParadeView(reducedMotion: reducedMotion)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    .padding(.top, 26)
            }
        } footer: {
            HStack {
                Spacer()
                OnboardingPrimaryButton("Start coaching") { viewModel.complete() }
            }
            .frame(maxWidth: .infinity)
        }
    }
}
