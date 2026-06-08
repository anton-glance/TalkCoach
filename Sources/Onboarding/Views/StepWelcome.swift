import SwiftUI

struct StepWelcome: View {
    @ObservedObject var viewModel: OnboardingViewModel
    var body: some View {
        ModalSheet(align: .center) {
            VStack(spacing: 0) {
                OnboardingLockup(markSize: 30)
                Text("speak in your\nsweet spot.")
                    .font(.custom("InterDisplay-Light", size: 40))
                    .tracking(-1.6)
                    .lineSpacing(4)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignTokens.Text.primary)
                    .padding(.top, 36)
                Text("Locto is an ambient speech coach that lives at the edge of your screen. It watches your pace and nudges you back to your sweet spot — quietly, while you talk. Everything runs on your Mac. Nothing is recorded, and nothing ever leaves your device.")
                    .font(.system(size: 15))
                    .lineSpacing(9.75)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(DesignTokens.Text.secondary)
                    .frame(maxWidth: 380)
                    .padding(.top, 18)
            }
            .accessibilityElement(children: .combine)
        } footer: {
            ProgressDots(total: 5, current: 1)
            Spacer()
            OnboardingPrimaryButton("Get started") { viewModel.advance() }
        }
    }
}
