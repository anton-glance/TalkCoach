import AVFoundation
import SwiftUI

struct StepSetup: View {
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var showMicConfirmation = false

    var body: some View {
        ModalSheet(align: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: "Set up")
                Text("Let's get you set up.")
                    .font(.custom("InterDisplay-Medium", size: 26))
                    .tracking(-0.6)
                    .foregroundStyle(DesignTokens.Text.primary)
                    .padding(.top, 12)
                Text("One permission and your languages. Takes about ten seconds.")
                    .font(.system(size: 14))
                    .foregroundStyle(DesignTokens.Text.secondary)
                    .padding(.top, 6)

                // Mic permission card
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Microphone")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(DesignTokens.Text.primary)
                        Text("To hear your speech during calls. It's analyzed on your Mac and discarded — never recorded.")
                            .font(.system(size: 13))
                            .foregroundStyle(DesignTokens.Text.secondary)
                            .lineSpacing(5.85)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    OnboardingToggle(isOn: viewModel.micGranted) {
                        handleToggle()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(DesignTokens.Surface.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(DesignTokens.Border.subtle, lineWidth: 0.5)
                )
                .padding(.top, 22)

                if !viewModel.micGranted {
                    Text("macOS will ask you to confirm.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(DesignTokens.Text.tertiary)
                        .padding(.top, 8)
                }

                if showMicConfirmation {
                    InlineMessage("Microphone access is on. To turn it off, manage it in System Settings → Privacy.", tone: .neutral)
                        .padding(.top, 10)
                }

                // Language section
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Your main speaking language")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DesignTokens.Text.primary)
                        OnboardingDropdown(
                            selectedID: Binding(
                                get: { viewModel.primaryLocaleID },
                                set: { viewModel.setPrimaryLocale($0) }
                            ),
                            placeholder: "Select language…"
                        )
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Optional second language")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DesignTokens.Text.primary)
                        OnboardingDropdown(
                            selectedID: Binding(
                                get: { viewModel.secondaryLocaleID },
                                set: { viewModel.setSecondaryLocale($0) }
                            ),
                            includeNone: true,
                            noneLabel: "None"
                        )
                    }
                }
                .padding(.top, 22)
                .zIndex(5)

                if let primary = viewModel.primaryLocaleID,
                   let secondary = viewModel.secondaryLocaleID,
                   primary == secondary {
                    InlineMessage("Choose a different language for the second slot.")
                        .padding(.top, 10)
                }

                Text("All processing happens on your Mac. Locto works fully offline and never sends your audio anywhere.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DesignTokens.Text.tertiary)
                    .lineSpacing(6)
                    .padding(.top, 20)
            }
        } footer: {
            ProgressDots(total: 5, current: 2)
            Spacer()
            OnboardingPrimaryButton("Continue", isDisabled: !viewModel.canContinueStep2) {
                viewModel.advance()
            }
        }
    }

    private func handleToggle() {
        if viewModel.micGranted {
            withAnimation { showMicConfirmation = true }
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                withAnimation { showMicConfirmation = false }
            }
        } else {
            withAnimation { showMicConfirmation = false }
            Task { await viewModel.requestMicPermission() }
        }
    }
}
