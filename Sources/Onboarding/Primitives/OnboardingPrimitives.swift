// swiftlint:disable file_length
import SwiftUI

// MARK: - ModalSheet

enum ContentAlignment { case top, center }

struct ModalSheet<Content: View, Footer: View>: View {
    let align: ContentAlignment
    let onClose: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    init(
        align: ContentAlignment = .top,
        onClose: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer
    ) {
        self.align = align
        self.onClose = onClose
        self.content = content
        self.footer = footer
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 0) {
                    if align == .center {
                        Spacer(minLength: 0)
                    }
                    content()
                    if align == .center {
                        Spacer(minLength: 0)
                    }
                }
                if let onClose {
                    Button(action: onClose) {
                        Canvas { ctx, size in
                            let s = size.width / 24
                            var p1 = Path()
                            p1.move(to: CGPoint(x: 6 * s, y: 6 * s))
                            p1.addLine(to: CGPoint(x: 18 * s, y: 18 * s))
                            var p2 = Path()
                            p2.move(to: CGPoint(x: 18 * s, y: 6 * s))
                            p2.addLine(to: CGPoint(x: 6 * s, y: 18 * s))
                            let style = StrokeStyle(lineWidth: 2 * s, lineCap: .round)
                            ctx.stroke(p1, with: .color(DesignTokens.Text.secondary), style: style)
                            ctx.stroke(p2, with: .color(DesignTokens.Text.secondary), style: style)
                        }
                        .frame(width: 14, height: 14)
                        .frame(width: 28, height: 28)
                        .background(DesignTokens.Surface.surface2)
                        .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 48)
            .padding(.top, 44)

            HStack {
                footer()
            }
            .padding(.horizontal, 48)
            .padding(.top, 24)
            .padding(.bottom, 30)
        }
    }
}

// MARK: - ModalSheet with no footer convenience init

extension ModalSheet where Footer == EmptyView {
    init(
        align: ContentAlignment = .top,
        onClose: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(align: align, onClose: onClose, content: content, footer: { EmptyView() })
    }
}

// MARK: - Eyebrow

struct Eyebrow: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .frame(width: 18, height: 1)
                .foregroundStyle(DesignTokens.Text.tertiary.opacity(0.7))
            Text(text.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.54) // 0.14em × 11pt
                .foregroundStyle(DesignTokens.Text.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

// MARK: - ProgressDots

struct ProgressDots: View {
    let total: Int
    let current: Int
    var body: some View {
        HStack(spacing: 7) {
            ForEach(1...total, id: \.self) { step in
                Capsule()
                    .frame(width: step == current ? 20 : 6, height: 6)
                    .foregroundStyle(
                        step == current ? DesignTokens.Brand.brand :
                        step < current  ? DesignTokens.Brand.teal200 :
                        DesignTokens.Border.strong
                    )
                    .animation(.easeOut(duration: DesignTokens.Motion.base), value: current)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current) of \(total)")
    }
}

// MARK: - OnboardingToggle

struct OnboardingToggle: View {
    let isOn: Bool
    let onToggle: () -> Void
    var body: some View {
        Button(action: onToggle) {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .frame(width: 42, height: 26)
                    .foregroundStyle(isOn ? DesignTokens.Brand.brand : Color(red: 216/255, green: 213/255, blue: 204/255))
                Circle()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(Color.white)
                    .shadow(color: .black.opacity(0.22), radius: 1.5, y: 1)
                    .padding(2)
            }
            .animation(.easeOut(duration: DesignTokens.Motion.base), value: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "Microphone on" : "Microphone off")
    }
}

// MARK: - OnboardingPrimaryButton

struct OnboardingPrimaryButton: View {
    let title: String
    let isDisabled: Bool
    let action: () -> Void
    @State private var isHovered = false

    init(_ title: String, isDisabled: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(
            action: { if !isDisabled { action() } },
            label: {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isDisabled ? DesignTokens.Text.tertiary : Color.white)
                    .frame(minWidth: 132, minHeight: 44)
                    .padding(.horizontal, 22)
                    .background(
                        isDisabled ? DesignTokens.Surface.surface2 :
                        isHovered  ? DesignTokens.Brand.brandDark :
                        DesignTokens.Brand.brand
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .shadow(
                        color: isDisabled ? .clear : Color(red: 15/255, green: 110/255, blue: 86/255)
                            .opacity(isHovered ? 0.26 : 0.18),
                        radius: isHovered ? 9 : 4,
                        y: isHovered ? 3 : 1
                    )
                    .offset(y: (!isDisabled && isHovered) ? -1 : 0)
            }
        )
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DesignTokens.Motion.fast), value: isHovered)
    }
}

// MARK: - InlineMessage

enum InlineMessageTone { case coral, neutral }

struct InlineMessage: View {
    let text: String
    let tone: InlineMessageTone
    init(_ text: String, tone: InlineMessageTone = .coral) {
        self.text = text
        self.tone = tone
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(
                    tone == .coral
                    ? Color(red: 92/255, green: 44/255, blue: 31/255)
                    : DesignTokens.Text.secondary
                )
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(
            tone == .coral
            ? LinearGradient(
                colors: [DesignTokens.Surface.coralLight, DesignTokens.Surface.coralMid],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [DesignTokens.Surface.surface2, DesignTokens.Surface.surface2],
                             startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    tone == .coral
                    ? Color(red: 92/255, green: 44/255, blue: 31/255).opacity(0.28)
                    : DesignTokens.Border.subtle,
                    lineWidth: 0.5
                )
        )
    }
}

// MARK: - ScreenCrop

private let cropWallpaper = LinearGradient(
    stops: [
        .init(color: Color(red: 236/255, green: 230/255, blue: 216/255), location: 0),
        .init(color: Color(red: 228/255, green: 221/255, blue: 205/255), location: 0.52),
        .init(color: Color(red: 218/255, green: 213/255, blue: 200/255), location: 1)
    ],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
)

struct ScreenCrop<Content: View>: View {
    let height: CGFloat
    let caption: String?
    @ViewBuilder let content: () -> Content

    init(height: CGFloat, caption: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.height = height
        self.caption = caption
        self.content = content
    }

    var body: some View {
        VStack(spacing: 9) {
            ZStack(alignment: .topLeading) {
                cropWallpaper
                content()
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.black.opacity(0.14), lineWidth: 0.5)
            )
            .shadow(color: Color(red: 20/255, green: 30/255, blue: 28/255).opacity(0.16), radius: 15, y: 6)
            if let caption {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(DesignTokens.Text.tertiary)
            }
        }
    }
}

// MARK: - Lockup (ring mark + wordmark)

struct OnboardingLockup: View {
    let markSize: CGFloat
    init(markSize: CGFloat = 30) { self.markSize = markSize }
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .strokeBorder(DesignTokens.Brand.brand, lineWidth: markSize * 0.09)
                    .frame(width: markSize, height: markSize)
                Circle()
                    .frame(width: markSize * 0.172, height: markSize * 0.172)
                    .foregroundStyle(DesignTokens.Brand.brand)
            }
            .frame(width: markSize, height: markSize)
            Text("locto")
                .font(.custom("InterDisplay-Medium", size: markSize * 0.92))
                .tracking(-2)
                .foregroundStyle(DesignTokens.Brand.brand)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Locto")
    }
}

// MARK: - OnboardingDropdown

struct OnboardingDropdown: View {
    @Binding var selectedID: String?
    let placeholder: String
    let includeNone: Bool
    let noneLabel: String
    @State private var isOpen = false
    @State private var hoveredID: String? = nil  // nil means none-row hover

    init(
        selectedID: Binding<String?>,
        placeholder: String = "Select…",
        includeNone: Bool = false,
        noneLabel: String = "None"
    ) {
        self._selectedID = selectedID
        self.placeholder = placeholder
        self.includeNone = includeNone
        self.noneLabel = noneLabel
    }

    private var displayName: String {
        if let id = selectedID,
           let entry = LocaleRegistry.parakeetSupportedLocales.first(where: { $0.identifier == id }) {
            return entry.displayName
        }
        return includeNone ? noneLabel : placeholder
    }

    private var isPlaceholder: Bool { selectedID == nil }

    var body: some View {
        // Pill button with overlay for the open list — list does NOT participate in layout
        Button {
            withAnimation(.easeOut(duration: DesignTokens.Motion.fast)) { isOpen.toggle() }
        } label: {
            HStack(spacing: 10) {
                Text(displayName)
                    .font(.system(size: 14))
                    .foregroundStyle(isPlaceholder ? DesignTokens.Text.tertiary : DesignTokens.Text.primary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DesignTokens.Text.tertiary)
                    .rotationEffect(isOpen ? .degrees(180) : .degrees(0))
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(Color.white)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(
                        isOpen ? DesignTokens.Brand.brand : DesignTokens.Border.strong,
                        lineWidth: isOpen ? 1.0 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            // Open list: anchored to top of pill, offset down by pill height + 6pt gap
            if isOpen {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if includeNone {
                            dropdownRow(id: nil, label: noneLabel)
                        }
                        ForEach(LocaleRegistry.parakeetSupportedLocales, id: \.identifier) { entry in
                            dropdownRow(id: entry.identifier, label: entry.displayName)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 232)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(DesignTokens.Border.strong, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.16), radius: 18, y: 6)
                .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                .offset(y: 42 + 6)  // pill height (42) + 6pt gap
                .zIndex(10)
            }
        }
        .zIndex(isOpen ? 10 : 0)
        .accessibilityLabel(placeholder)
    }

    private func dropdownRow(id: String?, label: String) -> some View {
        let isSelected: Bool = id == nil ? (selectedID == nil && includeNone) : (selectedID == id)
        let rowID = id ?? "__none__"
        return Button {
            selectedID = id
            withAnimation(.easeOut(duration: DesignTokens.Motion.fast)) { isOpen = false }
        } label: {
            HStack {
                Text(label)
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? Color.white : (id == nil ? DesignTokens.Text.secondary : DesignTokens.Text.primary))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                isSelected ? DesignTokens.Brand.brand :
                hoveredID == rowID ? Color.black.opacity(0.04) : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredID = hovering ? rowID : nil
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - AppParadeView

private let appParadeItems: [(name: String, symbolName: String)] = [
    ("Zoom", "video"),
    ("Teams", "person.3"),
    ("Meet", "video.fill"),
    ("FaceTime", "phone.fill"),
    ("Slack", "message"),
    ("Discord", "headphones"),
    ("Webex", "circle.grid.3x3"),
    ("Skype", "bubble.left"),
    ("WhatsApp", "message.fill"),
    ("Telegram", "paperplane")
]

struct AppParadeView: View {
    @State private var offset: CGFloat = 0
    let reducedMotion: Bool
    private let tileWidth: CGFloat = 92
    private let tileSpacing: CGFloat = 6
    private var singleSetWidth: CGFloat { CGFloat(appParadeItems.count) * tileWidth + CGFloat(appParadeItems.count - 1) * tileSpacing }

    var body: some View {
        ZStack {
            HStack(spacing: tileSpacing) {
                ForEach(0..<appParadeItems.count * 2, id: \.self) { index in
                    let item = appParadeItems[index % appParadeItems.count]
                    VStack(spacing: 8) {
                        Image(systemName: item.symbolName)
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(DesignTokens.Text.secondary)
                            .frame(width: 60, height: 60)
                            .background(DesignTokens.Surface.surface2)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(DesignTokens.Border.subtle, lineWidth: 0.5)
                            )
                        Text(item.name)
                            .font(.system(size: 11.5))
                            .foregroundStyle(DesignTokens.Text.tertiary)
                    }
                    .frame(width: tileWidth)
                }
            }
            .offset(x: offset)
            .onAppear {
                if !reducedMotion {
                    withAnimation(.linear(duration: 26).repeatForever(autoreverses: false)) {
                        offset = -singleSetWidth - tileSpacing
                    }
                }
            }
            // Edge fades
            HStack {
                LinearGradient(
                    colors: [DesignTokens.Surface.surface, .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: 48)
                Spacer()
                LinearGradient(
                    colors: [.clear, DesignTokens.Surface.surface],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: 48)
            }
            .allowsHitTesting(false)
        }
        .clipped()
    }
}
