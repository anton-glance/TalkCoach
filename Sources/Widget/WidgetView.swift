import AppKit
import SwiftUI

struct WidgetView: View {
    @ObservedObject var viewModel: WidgetViewModel
    var onDismiss: () -> Void

    // Injected for testability; defaults to the real system value.
    var reducedMotionProvider: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // Animated caret positions — driven by .onChange in body, interpolated by withAnimation.
    @State private var animatedPacePos: Double = 0.5
    @State private var animatedMonoPos: Double = 0.0

    // Widget.jsx hardcodes tintAlpha=0.78 and borderAlpha=0.45, overriding tokens.js's
    // Tint.restingAlpha=0.55 / Border.restingWhiteOpacity=0.55. Following Widget.jsx: those
    // values were the final polish step ("state colours hold on any substrate"). tokens.js
    // values are pre-iteration and stale.
    private static let tintAlpha: Double = 0.78
    private static let borderAlpha: Double = 0.45

    // Widget.jsx padding '10px 14px' (10 vertical, 14 horizontal).
    // DesignTokens.Layout.paddingHorizontal=13 / paddingVertical=11 are stale relative to JSX.
    private static let paddingH: CGFloat = 14
    private static let paddingV: CGFloat = 10

    // Widget.jsx idleTintRGB = [191, 196, 199] — neutral slate-grey for both zones when idle.
    // Not in tokens.js or DesignTokens.swift; sourced from Widget.jsx line 46.
    private static let idleTint = DesignTokens.rgba(red: 191, green: 196, blue: 199, alpha: 1.0)

    // MARK: - Testable helpers

    /// Returns 0 when Reduce Motion is enabled, otherwise returns `spec`.
    nonisolated static func effectiveDuration(_ spec: Double, reducedMotion: Bool) -> Double {
        reducedMotion ? 0 : spec
    }

    /// True when the cold-start mark (pulsing Locto ring) should replace the live numbers.
    /// Covers both .warming (engine loading, ~10s) and .counting-before-first-WPM so the mark
    /// appears immediately at session start and stays until real data arrives.
    static func showColdStartMark(
        activityState: WidgetActivityState,
        hasReceivedWPM: Bool
    ) -> Bool {
        (activityState == .warming || activityState == .counting) && !hasReceivedWPM
    }

    // L2 boundary is inclusive on the urgent side: streakSeconds < l2Seconds → MONOLOGUE;
    // streakSeconds >= l2Seconds → TAKE A PAUSE. The cluster opacity ramp reaches 1.0 at L2
    // so the label flip coincides with full opacity.
    // Do NOT change to streakSeconds > l2Seconds; the inclusive-L2-urgent boundary is intentional.
    static func monoLabelText(streakSeconds: TimeInterval, l2Seconds: TimeInterval) -> String {
        // Defensive: l2 ≤ 0 means any streak is past the threshold.
        guard l2Seconds > 0 else { return "TAKE A PAUSE" }
        return streakSeconds < l2Seconds ? "MONOLOGUE" : "TAKE A PAUSE"
    }

    // L3 boundary: streakSeconds >= l3Seconds means caret is at the right edge (clamped to 1.0).
    // The L3 pulse animation lands in M5.6.
    static func monoCaretFraction(streakSeconds: TimeInterval, l3Seconds: TimeInterval) -> Double {
        // Defensive: zero or negative l3 would divide by zero — return 0 (caret at left edge).
        guard l3Seconds > 0 else { return 0.0 }
        return DesignTokens.clamp01(streakSeconds / l3Seconds)
    }

    static func formatMonoTime(_ seconds: TimeInterval) -> (minutes: String, seconds: String) {
        let totalSeconds = max(0, floor(seconds))
        let minutes = Int(totalSeconds) / 60
        let remainingSeconds = Int(totalSeconds) % 60
        return ("\(minutes)", String(format: "%02d", remainingSeconds))
    }

    // swiftlint:disable:next function_body_length
    var body: some View {
        let wpm = viewModel.currentWPMVoiced ?? DesignTokens.Pace.wpmIdeal
        let streak = viewModel.streakSeconds
        // isFrozen suppresses isIdle so last-known values stay visible during linger/wrapping.
        let idle = viewModel.isIdle && !viewModel.isFrozen
        let showColdStart = WidgetView.showColdStartMark(
            activityState: viewModel.activityState,
            hasReceivedWPM: viewModel.hasReceivedWPM
        )
        let reducedMotion = reducedMotionProvider()

        let wpmTint = idle ? Self.idleTint
            : DesignTokens.paceColors(wpm: wpm).tint
        let monoTint = idle ? Self.idleTint
            : DesignTokens.monoColors(
                seconds: streak,
                level1Seconds: viewModel.monoL1Seconds,
                level2Seconds: viewModel.monoL2Seconds,
                level3Seconds: viewModel.monoL3Seconds
            ).tint

        // Linear gradient with 0/32/68/100% stops mirrors Widget.jsx's
        // 'linear-gradient(180deg, wpmTint 0%, wpmTint 32%, monoTint 68%, monoTint 100%)'.
        let gradient = LinearGradient(
            stops: [
                .init(color: wpmTint.opacity(Self.tintAlpha), location: 0.0),
                .init(color: wpmTint.opacity(Self.tintAlpha), location: 0.32),
                .init(color: monoTint.opacity(Self.tintAlpha), location: 0.68),
                .init(color: monoTint.opacity(Self.tintAlpha), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )

        ZStack(alignment: .topTrailing) {
            // During cold-start, show ONLY the pulsing Locto mark — no numbers, no bar, no dashes.
            // Sequential crossfade: mark exits (0.3s easeOut), then content enters (0.4s easeIn + 0.3s delay).
            // .id(sessionStartedAt) forces ColdStartMarkView recreation on each new session so the
            // @State pulse animation restarts from scratch.
            if showColdStart {
                ColdStartMarkView(reducedMotion: reducedMotion)
                    .id(viewModel.sessionStartedAt)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeIn(duration: WidgetView.effectiveDuration(0.4, reducedMotion: reducedMotion))),
                        removal: .opacity.animation(.easeOut(duration: WidgetView.effectiveDuration(0.3, reducedMotion: reducedMotion)))
                    ))
            } else {
                // Three-section space-between layout mirrors CSS flex column + justifyContent:space-between.
                VStack(spacing: 0) {
                    topCluster(wpm: wpm, idle: idle, reducedMotion: reducedMotion)
                    Spacer(minLength: 0)
                    barZone(wpm: wpm, streak: streak, idle: idle)
                    Spacer(minLength: 0)
                    bottomCluster(streak: streak, idle: idle, reducedMotion: reducedMotion)
                }
                .padding(.horizontal, Self.paddingH)
                .padding(.vertical, Self.paddingV)
                .transition(.asymmetric(
                    insertion: .opacity.animation(
                        .easeIn(duration: WidgetView.effectiveDuration(0.4, reducedMotion: reducedMotion))
                        .delay(WidgetView.effectiveDuration(0.3, reducedMotion: reducedMotion))
                    ),
                    removal: .opacity.animation(.easeOut(duration: WidgetView.effectiveDuration(0.3, reducedMotion: reducedMotion)))
                ))
            }

            // Close button — M5.7 replaces with hover-only affordance.
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        .frame(width: DesignTokens.Layout.size, height: DesignTokens.Layout.size)
        .background(gradient)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Layout.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Layout.cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(Self.borderAlpha), lineWidth: DesignTokens.Layout.borderWidth)
        )
        // Sync animated caret positions on first appear (no animation — snap to initial state).
        .onAppear {
            animatedPacePos = DesignTokens.spectrumPosition(wpm: wpm)
            animatedMonoPos = WidgetView.monoCaretFraction(
                streakSeconds: streak, l3Seconds: viewModel.monoL3Seconds
            )
        }
        // Animate pace caret to new WPM position — 400ms easeOut per design spec.
        .onChange(of: wpm) { _, newWPM in
            let newPos = DesignTokens.spectrumPosition(wpm: newWPM)
            withAnimation(.easeOut(duration: WidgetView.effectiveDuration(0.4, reducedMotion: reducedMotion))) {
                animatedPacePos = newPos
            }
        }
        // Animate mono caret to new streak position — 400ms easeOut per design spec.
        .onChange(of: streak) { _, newStreak in
            let newPos = WidgetView.monoCaretFraction(
                streakSeconds: newStreak, l3Seconds: viewModel.monoL3Seconds
            )
            withAnimation(.easeOut(duration: WidgetView.effectiveDuration(0.4, reducedMotion: reducedMotion))) {
                animatedMonoPos = newPos
            }
        }
    }

    // MARK: - Top cluster (pace half)

    @ViewBuilder
    private func topCluster(wpm: Int, idle: Bool, reducedMotion: Bool) -> some View {
        let displayWPM = idle ? "---" : "\(wpm)"
        VStack(spacing: 2) {
            // Widget.jsx inline-flex baseline row: hidden left "wpm" mirrors the visible right "wpm"
            // so the digit block stays optically centered between them. HStack lastTextBaseline
            // aligns the 8pt unit text to the 36pt digit baseline.
            HStack(alignment: .lastTextBaseline, spacing: 1) {
                Text("WPM")
                    .font(.custom("InterDisplay-Medium", size: 8))
                    .tracking(0.32) // 0.04em × 8pt
                    .hidden()
                // .id() + asymmetric transition: fade-out 80ms / fade-in 120ms + 1pt drift.
                Text(displayWPM)
                    .id(displayWPM)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 1))
                            .animation(.easeOut(duration: WidgetView.effectiveDuration(0.12, reducedMotion: reducedMotion))),
                        removal: .opacity
                            .animation(.easeIn(duration: WidgetView.effectiveDuration(0.08, reducedMotion: reducedMotion)))
                    ))
                    .font(.custom("InterDisplay-Light", size: 36))
                    .tracking(-1.8)
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.94))
                Text("WPM")
                    .font(.custom("InterDisplay-Medium", size: 8))
                    .tracking(0.32)
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            // Widget.jsx visibility:hidden when idle — .opacity preserves layout space.
            Text(DesignTokens.zoneLabel(DesignTokens.zoneForWPM(wpm)).uppercased())
                .font(.custom("InterDisplay-SemiBold", size: 9))
                .tracking(1.26) // 0.14em × 9pt
                .foregroundStyle(Color.white.opacity(0.68))
                .opacity(idle ? 0 : 1)
        }
    }

    // MARK: - Middle bar zone

    @ViewBuilder
    private func barZone(wpm: Int, streak: TimeInterval, idle: Bool) -> some View {
        let caretW = DesignTokens.Layout.caretWidth
        let caretH = DesignTokens.Layout.caretHeight
        let showCarets = !idle

        // GeometryReader provides bar width for caret x-positioning.
        // Carets are SwiftUI Shape views with .offset() so withAnimation can interpolate them —
        // Canvas drawing does not participate in SwiftUI's animation interpolation.
        GeometryReader { geo in
            let barWidth = geo.size.width
            ZStack(alignment: .topLeading) {
                // Bar — always visible, 2px height at y=6.
                Canvas { ctx, size in
                    ctx.fill(
                        Path(roundedRect: CGRect(x: 0, y: 6, width: size.width, height: 2), cornerRadius: 1),
                        with: .color(.white.opacity(0.62))
                    )
                }

                if showCarets {
                    // Down-pointing caret (pace) — top edge at y=0, above the bar.
                    PaceCaretShape()
                        .fill(Color.white.opacity(0.82))
                        .frame(width: caretW, height: caretH)
                        .offset(x: animatedPacePos * barWidth - caretW / 2, y: 0)

                    // Up-pointing caret (mono) — top edge at y=9, below the bar.
                    MonoCaretShape()
                        .fill(Color.white.opacity(0.82))
                        .frame(width: caretW, height: caretH)
                        .offset(x: animatedMonoPos * barWidth - caretW / 2, y: 9)
                }
            }
        }
        .frame(height: 14)
    }

    // MARK: - Bottom cluster (monologue half)

    @ViewBuilder
    private func bottomCluster(streak: TimeInterval, idle: Bool, reducedMotion: Bool) -> some View {
        let level2Seconds = viewModel.monoL2Seconds

        // Cluster opacity ramps 0.6 → 1.0 as streak approaches L2, matching Widget.jsx monoOpacity.
        // Uses live monoL2Seconds instead of JSX's hardcoded 90. Guard prevents divide-by-zero.
        let monoOpacity: Double = (idle || level2Seconds <= 0) ? 1.0
            : 0.6 + DesignTokens.clamp01(streak / level2Seconds) * 0.4

        let parts: (String, String) = idle ? ("-", "--") : {
            let timeParts = Self.formatMonoTime(streak)
            return (timeParts.minutes, timeParts.seconds)
        }()
        let displayKey = idle ? "-:--" : "\(parts.0):\(parts.1)"

        VStack(spacing: 2) {
            // Colon nudged -0.09em × 36pt ≈ -3.24pt upward to sit at the digit optical centre.
            // Widget.jsx uses translateY(-0.09em) on the colon span; .offset(y:) in SwiftUI is
            // negative-up in the coordinate system, so -3.24 moves the colon up. ✓
            HStack(spacing: 0) {
                Text(parts.0)
                Text(":")
                    .offset(y: -3.24)
                Text(parts.1)
            }
            .id(displayKey)
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 1))
                    .animation(.easeOut(duration: WidgetView.effectiveDuration(0.12, reducedMotion: reducedMotion))),
                removal: .opacity
                    .animation(.easeIn(duration: WidgetView.effectiveDuration(0.08, reducedMotion: reducedMotion)))
            ))
            .font(.custom("InterDisplay-Light", size: 36))
            .tracking(-1.8)
            .monospacedDigit()
            .foregroundStyle(Color.white.opacity(0.94))

            // L2 boundary semantics: streakSeconds < L2 → MONOLOGUE; ≥ L2 → TAKE A PAUSE.
            // Label flip coincides with monoOpacity reaching 1.0 at L2.
            // Do NOT change to streakSeconds > L2; inclusive-L2-urgent is intentional per M5.3 spec.
            let labelText = idle ? "MONOLOGUE"
                : Self.monoLabelText(streakSeconds: streak, l2Seconds: level2Seconds)
            // Weight stays .semibold always: InterDisplay-Bold is not bundled in M5.3,
            // and digital bold synthesis on a SemiBold base looks worse than staying SemiBold.
            // Real 700-weight lands in M5.6 when InterDisplay-Bold.otf is bundled.
            Text(labelText)
                .font(.custom("InterDisplay-SemiBold", size: 9))
                .tracking(1.26)
                .foregroundStyle(Color.white.opacity(0.68))
                .opacity(idle ? 0 : 1)
        }
        .opacity(monoOpacity)
    }
}

// MARK: - Cold-start mark

/// Pulsing Locto mark shown while the engine warms up before the first WPM reading arrives.
/// Drawn from mark.svg geometry: ring r=22, dot r=5.5 on 64-pt viewBox, scaled to 56pt.
/// Correction #2: .id(sessionStartedAt) at the call site forces recreation on each new session,
/// so @State visible resets and .onAppear re-fires the pulse animation.
private struct ColdStartMarkView: View {
    let reducedMotion: Bool
    @State private var visible = false

    private let markSize: CGFloat = 56
    private var scale: CGFloat { markSize / 64 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.94), lineWidth: 3 * scale)
                .frame(width: 44 * scale, height: 44 * scale)
            Circle()
                .fill(Color.white.opacity(0.94))
                .frame(width: 11 * scale, height: 11 * scale)
        }
        .opacity(visible ? 0.94 : 0.2)
        .onAppear {
            guard !reducedMotion else {
                visible = true
                return
            }
            withAnimation(.easeInOut(duration: 1.25).repeatForever(autoreverses: true)) {
                visible = true
            }
        }
    }
}

// MARK: - Caret shapes

/// Down-pointing triangle: pace caret above the shared bar.
private struct PaceCaretShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width / 2, y: rect.height))
        path.closeSubpath()
        return path
    }
}

/// Up-pointing triangle: mono caret below the shared bar.
private struct MonoCaretShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.width / 2, y: 0))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.closeSubpath()
        return path
    }
}
