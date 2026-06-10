import AppKit
import AVFoundation
import SwiftUI

struct StepSetup: View {
    @ObservedObject var viewModel: OnboardingViewModel

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
                    if viewModel.micGranted {
                        MicGrantedIndicator()
                    } else {
                        OnboardingToggle(isOn: false) {
                            handleToggle()
                        }
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

                if !viewModel.micGranted && !viewModel.micDenied {
                    Text("macOS will ask you to confirm.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(DesignTokens.Text.tertiary)
                        .padding(.top, 8)
                }

                if viewModel.micDenied {
                    MicDeniedCard()
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
        Task { await viewModel.requestMicPermission() }
    }
}

// MARK: - Private subviews

private struct MicGrantedIndicator: View {
    var body: some View {
        ZStack {
            Circle()
                .frame(width: 26, height: 26)
                .foregroundStyle(DesignTokens.Brand.brand)
            Canvas { ctx, size in
                let scale = size.width / 24
                var path = Path()
                path.move(to: CGPoint(x: 5 * scale, y: 12 * scale))
                path.addLine(to: CGPoint(x: 10 * scale, y: 17 * scale))
                path.addLine(to: CGPoint(x: 20 * scale, y: 7 * scale))
                ctx.stroke(
                    path, with: .color(.white),
                    style: StrokeStyle(lineWidth: 2.5 * scale, lineCap: .round, lineJoin: .round)
                )
            }
            .frame(width: 14, height: 14)
        }
        .accessibilityLabel("Microphone access granted")
    }
}

private let kDeniedTextColor = Color(red: 92 / 255, green: 44 / 255, blue: 31 / 255)

private struct MicDeniedCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("To enable microphone access, go to System Settings → Privacy & Security → Microphone.")
                .font(.system(size: 13))
                .foregroundStyle(kDeniedTextColor)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            OpenMicSettingsButton()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(
            LinearGradient(
                colors: [DesignTokens.Surface.coralLight, DesignTokens.Surface.coralMid],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(kDeniedTextColor.opacity(0.28), lineWidth: 0.5)
        )
    }
}

private struct OpenMicSettingsButton: View {
    var body: some View {
        Button {
            // Deep-link to Microphone privacy pane in System Settings
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            )
        } label: {
            HStack(spacing: 4) {
                Text("Open Settings")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(kDeniedTextColor)
                    .underline()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(kDeniedTextColor)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open System Settings to Microphone privacy")
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}
