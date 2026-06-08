import SwiftUI

struct StepMenuBar: View {
    @ObservedObject var viewModel: OnboardingViewModel
    var body: some View {
        ModalSheet(align: .center) {
            VStack(alignment: .leading, spacing: 0) {
                Eyebrow(text: "Menu bar")
                Text("Locto lives up here.")
                    .font(.custom("InterDisplay-Medium", size: 26))
                    .tracking(-0.6)
                    .foregroundStyle(DesignTokens.Text.primary)
                    .padding(.top, 12)
                Text("Look for the ring in your menu bar, top-right. Click it any time to pause coaching or open settings.")
                    .font(.system(size: 14))
                    .foregroundStyle(DesignTokens.Text.secondary)
                    .lineSpacing(7)
                    .padding(.top, 6)
                    .padding(.bottom, 18)
                MenuBarCrop()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } footer: {
            ProgressDots(total: 5, current: 3)
            Spacer()
            OnboardingPrimaryButton("Next") { viewModel.advance() }
        }
    }
}

// MARK: - MenuBarCrop

private struct MenuBarCrop: View {
    var body: some View {
        ScreenCrop(height: 190, caption: "Your menu bar, top-right of the screen") {
            // Menu bar strip
            HStack {
                // Left: faux app menus
                HStack(spacing: 14) {
                    Text("Zoom").font(.system(size: 12, weight: .semibold))
                    Text("Edit").font(.system(size: 12))
                    Text("Meeting").font(.system(size: 12))
                }
                .foregroundStyle(DesignTokens.Text.primary.opacity(0.5))
                Spacer()
                // Right: Locto ring + system icons
                HStack(spacing: 14) {
                    LoctoMenuBarChip()
                    BatteryGlyph()
                    WifiGlyph()
                    Text("9:41")
                        .font(.system(size: 12.5))
                        .foregroundStyle(DesignTokens.Text.primary.opacity(0.86))
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 32)
            .background(Color(red: 247/255, green: 245/255, blue: 239/255).opacity(0.96))
            .overlay(alignment: .bottom) {
                Divider().opacity(0.12)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct LoctoMenuBarChip: View {
    var body: some View {
        // The green ring chip itself
        ZStack {
            Circle()
                .strokeBorder(Color.white, lineWidth: 3.6 * 16 / 64)
                .frame(width: 16, height: 16)
            Circle()
                .frame(width: 16 * 0.172, height: 16 * 0.172)
                .foregroundStyle(Color.white)
        }
        .frame(width: 26, height: 26)
        .background(DesignTokens.Brand.brand)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: DesignTokens.Brand.brand.opacity(0.42), radius: 8)
        .shadow(color: DesignTokens.Brand.brand.opacity(0.20), radius: 1)
        // Dropdown positioned BELOW the chip via overlay — does not participate in strip layout
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                // Spacer pushes content to chip.bottom + 3pt (caret top)
                Color.clear.frame(height: 26 + 3)
                // Diamond caret
                Rectangle()
                    .frame(width: 12, height: 12)
                    .foregroundStyle(Color(red: 252/255, green: 250/255, blue: 245/255))
                    .rotationEffect(.degrees(45))
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                    .shadow(color: .black.opacity(0.04), radius: 1, x: -1, y: -1)
                    .offset(y: 4)   // half-height overlap so card hides caret bottom half
                // Dropdown card at chip.bottom + 8pt
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 7) {
                        Circle()
                            .frame(width: 7, height: 7)
                            .foregroundStyle(DesignTokens.Brand.brand)
                            .shadow(color: DesignTokens.Brand.brand.opacity(0.5), radius: 3)
                        Text("Active").font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(DesignTokens.Text.primary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 5).padding(.bottom, 6)
                    Divider().opacity(0.10).padding(.horizontal, 4)
                    ForEach(["Pause coaching", "Settings…"], id: \.self) { item in
                        Text(item).font(.system(size: 12.5))
                            .foregroundStyle(DesignTokens.Text.primary)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                    }
                    Divider().opacity(0.10).padding(.horizontal, 4)
                    Text("Quit Locto").font(.system(size: 12.5))
                        .foregroundStyle(DesignTokens.Text.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                }
                .frame(width: 178)
                .background(Color(red: 252/255, green: 250/255, blue: 245/255).opacity(0.98))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color.black.opacity(0.10), lineWidth: 0.5)
                )
                .shadow(color: Color(red: 20/255, green: 30/255, blue: 28/255).opacity(0.22), radius: 19, y: 8)
            }
            .frame(width: 178)
        }
        .zIndex(10)
    }
}

private struct BatteryGlyph: View {
    var body: some View {
        Image(systemName: "battery.75")
            .font(.system(size: 13))
            .foregroundStyle(DesignTokens.Text.primary.opacity(0.78))
    }
}

private struct WifiGlyph: View {
    var body: some View {
        Image(systemName: "wifi")
            .font(.system(size: 12))
            .foregroundStyle(DesignTokens.Text.primary.opacity(0.78))
    }
}
