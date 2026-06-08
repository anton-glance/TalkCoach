import SwiftUI

struct OnboardingShell: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.white
            Group {
                switch viewModel.currentStep {
                case 1: StepWelcome(viewModel: viewModel)
                case 2: StepSetup(viewModel: viewModel)
                case 3: StepMenuBar(viewModel: viewModel)
                case 4: StepWidget(viewModel: viewModel)
                default: StepReady(viewModel: viewModel)
                }
            }
            .id(viewModel.currentStep)
            .transition(.opacity.animation(.easeInOut(duration: DesignTokens.Motion.fast)))
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 0.5)
        )
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: DesignTokens.Motion.base)) { appeared = true }
        }
    }
}
