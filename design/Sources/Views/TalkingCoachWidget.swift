//
//  TalkingCoachWidget.swift
//  TalkingCoach
//
//  Root SwiftUI view tree for the floating widget. The view is a pure
//  function of `WidgetState`. All numeric / color values come from
//  DesignTokens.swift — never hard-code here.
//
//  Visual reference: ../../widget-reference.html
//

import SwiftUI

// MARK: - State model

struct WidgetState: Equatable {
    var isMicActive: Bool = false
    var currentWPM: Int = 0
    var averageWPM: Int = 0
    var topFillers: [FillerEntry] = []

    var paceZone: PaceZone {
        PaceColors.zone(forWPM: Double(currentWPM))
    }
}

struct FillerEntry: Equatable, Identifiable {
    let word: String
    let count: Int
    var id: String { word }
}

// MARK: - Root widget

struct TalkingCoachWidget: View {
    let state: WidgetState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    @State private var isHovering = false

    private var paceColors: (tint: Color, deep: Color) {
        PaceColors.colors(forWPM: Double(state.currentWPM))
    }

    private var tintAlpha: Double {
        isHovering ? DesignTokens.Tint.hoverAlpha : DesignTokens.Tint.restingAlpha
    }

    private var borderOpacity: Double {
        isHovering
            ? DesignTokens.Border.hoverWhiteOpacity
            : DesignTokens.Border.restingWhiteOpacity
    }

    var body: some View {
        let (tint, deep) = paceColors
        // Re-tint at the live alpha (the helper produces the resting-alpha tint by default).
        let liveTint = tint.opacity(tintAlpha / DesignTokens.Tint.restingAlpha)
        let shape = RoundedRectangle(cornerRadius: DesignTokens.Layout.cornerRadius, style: .continuous)

        VStack(spacing: 0) {
            TopBlock(
                wpm: state.currentWPM,
                averageWPM: state.averageWPM,
                paceZone: state.paceZone,
                deepColor: deep
            )
            Spacer(minLength: 0)
            SpectrumView(
                wpm: state.currentWPM,
                deepColor: deep
            )
            Spacer(minLength: 0)
            FillerBarsView(
                fillers: state.topFillers,
                deepColor: deep
            )
        }
        .padding(.horizontal, DesignTokens.Layout.paddingHorizontal)
        .padding(.vertical, DesignTokens.Layout.paddingVertical)
        .frame(width: DesignTokens.Layout.size, height: DesignTokens.Layout.size)
        .background(
            // Liquid Glass with reduce-transparency fallback.
            Group {
                if reduceTransparency {
                    shape.fill(liveTint.opacity(1.0))
                } else {
                    shape
                        .fill(.clear)
                        .glassEffect(.regular.tint(liveTint), in: shape)
                }
            }
        )
        .overlay(
            shape.stroke(.white.opacity(borderOpacity),
                         lineWidth: DesignTokens.Layout.borderWidth)
        )
        .shadow(
            color: isHovering ? DesignTokens.Shadow.outerColorHover : DesignTokens.Shadow.outerColor,
            radius: isHovering ? DesignTokens.Shadow.outerRadiusHover : DesignTokens.Shadow.outerRadius,
            x: 0,
            y: isHovering ? DesignTokens.Shadow.outerYOffsetHover : DesignTokens.Shadow.outerYOffset
        )
        .scaleEffect(isHovering ? DesignTokens.Layout.hoverScale : 1.0, anchor: .center)
        .offset(y: isHovering ? DesignTokens.Layout.hoverYOffset : 0)
        .animation(
            DesignTokens.Animation.fade(DesignTokens.Animation.colorFadeDuration, reduceMotion: reduceMotion),
            value: state.currentWPM
        )
        .animation(
            reduceMotion ? nil : .easeOut(duration: DesignTokens.Animation.hoverDuration),
            value: isHovering
        )
        .onHover { hovering in
            isHovering = hovering
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let fillerStr = state.topFillers
            .prefix(3)
            .map { "\($0.word) said \($0.count) times" }
            .joined(separator: ", ")
        let zone = state.paceZone.label.lowercased()
        return "Talking coach. \(zone) pace at \(state.currentWPM) words per minute, average \(state.averageWPM). Top fillers: \(fillerStr)."
    }
}

// MARK: - Top block (WPM + state row)

private struct TopBlock: View {
    let wpm: Int
    let averageWPM: Int
    let paceZone: PaceZone
    let deepColor: Color

    var body: some View {
        VStack(spacing: DesignTokens.Layout.topGapBetweenWPMAndStateRow) {
            Text("\(wpm)")
                .font(DesignTokens.Type.wpm())
                .tracking(DesignTokens.Type.wpmTracking)
                .monospacedDigit()
                .foregroundStyle(deepColor)
                .lineLimit(1)
                .contentTransition(.numericText(value: Double(wpm)))

            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Layout.stateRowGap) {
                Text(paceZone.label)
                    .font(DesignTokens.Type.state())
                    .tracking(DesignTokens.Type.stateTracking)
                    .foregroundStyle(deepColor.opacity(DesignTokens.Type.stateOpacity))

                Text("·")
                    .font(DesignTokens.Type.separator())
                    .foregroundStyle(deepColor.opacity(DesignTokens.Type.separatorOpacity))

                Text("avg \(averageWPM)")
                    .font(DesignTokens.Type.avg())
                    .tracking(DesignTokens.Type.avgTracking)
                    .monospacedDigit()
                    .foregroundStyle(deepColor.opacity(DesignTokens.Type.avgOpacity))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Spectrum + caret

struct SpectrumView: View {
    let wpm: Int
    let deepColor: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pct: Double {
        PaceColors.spectrumPosition(forWPM: Double(wpm))
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width

            ZStack(alignment: .topLeading) {
                // Bar
                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color(.sRGB, red: 86/255,  green: 135/255, blue: 197/255, opacity: 0.78), location: 0.0),
                                .init(color: Color(.sRGB, red: 108/255, green: 207/255, blue: 160/255, opacity: 0.78), location: 0.375),
                                .init(color: Color(.sRGB, red: 216/255, green: 98/255,  blue: 90/255,  opacity: 0.78), location: 1.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: DesignTokens.Layout.spectrumBarHeight)
                    .offset(y: DesignTokens.Layout.spectrumBarTopInset)

                // Caret — upward triangle below the bar
                CaretShape()
                    .fill(deepColor)
                    .frame(width: DesignTokens.Layout.caretWidth,
                           height: DesignTokens.Layout.caretHeight)
                    .offset(
                        x: max(0, width * pct - DesignTokens.Layout.caretWidth / 2),
                        y: DesignTokens.Layout.caretTopInset
                    )
                    .animation(
                        DesignTokens.Animation.caret(reduceMotion: reduceMotion),
                        value: pct
                    )
            }
        }
        .frame(height: DesignTokens.Layout.spectrumHeight)
        .accessibilityHidden(true)  // redundant with combined label
    }
}

private struct CaretShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Filler bars (Bars · Trimmed)

struct FillerBarsView: View {
    let fillers: [FillerEntry]
    let deepColor: Color

    var body: some View {
        VStack(spacing: DesignTokens.Layout.fillerRowGap) {
            ForEach(fillers.prefix(DesignTokens.Fillers.topNToShow)) { entry in
                FillerRow(entry: entry, deepColor: deepColor)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FillerRow: View {
    let entry: FillerEntry
    let deepColor: Color

    var body: some View {
        HStack(spacing: DesignTokens.Layout.fillerColumnGap) {
            Text(entry.word)
                .font(DesignTokens.Type.fillerWord())
                .foregroundStyle(deepColor.opacity(DesignTokens.Type.fillerWordOpacity))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: DesignTokens.Layout.fillerWordColumnWidth, alignment: .leading)

            HStack(spacing: DesignTokens.Layout.pillarGap) {
                let renderedCount = min(entry.count, DesignTokens.Layout.maxPillars)
                ForEach(0..<renderedCount, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: DesignTokens.Layout.pillarCornerRadius)
                        .fill(deepColor.opacity(DesignTokens.Layout.pillarOpacity))
                        .frame(width: DesignTokens.Layout.pillarWidth,
                               height: DesignTokens.Layout.pillarHeight)
                }
                if entry.count > DesignTokens.Layout.maxPillars {
                    Text("+")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(deepColor.opacity(0.6))
                }
                Spacer(minLength: 0)
            }
            .frame(height: DesignTokens.Layout.pillarHeight)
        }
    }
}

// MARK: - Preview

#Preview("Ideal pace") {
    TalkingCoachWidget(state: .preview(wpm: 168, avg: 142))
        .padding(40)
        .background(.gray.opacity(0.3))
}

#Preview("Too slow") {
    TalkingCoachWidget(state: .preview(wpm: 95, avg: 142))
        .padding(40)
        .background(.gray.opacity(0.3))
}

#Preview("Too fast") {
    TalkingCoachWidget(state: .preview(wpm: 210, avg: 142))
        .padding(40)
        .background(.gray.opacity(0.3))
}

#if DEBUG
extension WidgetState {
    static func preview(wpm: Int, avg: Int) -> WidgetState {
        WidgetState(
            isMicActive: true,
            currentWPM: wpm,
            averageWPM: avg,
            topFillers: [
                FillerEntry(word: "uh",        count: 7),
                FillerEntry(word: "right",     count: 4),
                FillerEntry(word: "basically", count: 2)
            ]
        )
    }
}
#endif
