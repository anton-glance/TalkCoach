import AppKit
import SwiftUI

extension WidgetView {

    // Tint alpha split for M5.5:
    //   glassTintAlpha (0.60): glass mode — lower so Liquid Glass lensing shows through the tint.
    //     Midpoint of spec's 0.55–0.65 suggested range. Landed at 0.60 for smoke review.
    //   solidTintAlpha (0.78): solid/reduce-transparency mode — Widget.jsx value, sized for opaque substrate.
    // Widget.jsx hardcoded 0.78 (overriding tokens.js Tint.restingAlpha=0.55 which is stale).
    // M5.5 retains 0.78 for solid and introduces 0.60 for glass.
    private static let glassTintAlpha: Double = 0.60
    private static let solidTintAlpha: Double = 0.78

    // MARK: - Testable helpers

    /// Returns 0 when Reduce Motion is enabled, otherwise returns `spec`.
    nonisolated static func effectiveDuration(_ spec: Double, reducedMotion: Bool) -> Double {
        reducedMotion ? 0 : spec
    }

    /// True when the cold-start mark (pulsing Locto ring) should replace the live numbers.
    /// Covers .idle (panel pre-show / between sessions), .warming (engine loading, ~10s), and
    /// .counting-before-first-WPM so the mark appears immediately at session start and stays
    /// until real data arrives. Including .idle ensures the backing store never holds a dashes
    /// frame: SwiftUI renders the mark into the offscreen backing store while the panel is hidden,
    /// so the very first visible frame is already the mark — never dashes.
    static func showColdStartMark(
        activityState: WidgetActivityState,
        hasReceivedWPM: Bool
    ) -> Bool {
        (activityState == .idle || activityState == .warming || activityState == .counting) && !hasReceivedWPM
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

    // MARK: - M5.5 hover helpers

    /// Scale factor for the tile on hover. Reduce Motion snaps to resting (1.0) — no animation.
    /// Spec value: 1.02. DesignTokens.Layout.hoverScale=1.025 is pre-iteration stale.
    nonisolated static func hoverScale(isHovered: Bool, reducedMotion: Bool) -> CGFloat {
        reducedMotion ? 1.0 : (isHovered ? 1.02 : 1.0)
    }

    /// Y-offset for hover lift. Spec: +1pt lift = y: -1 (negative-up in SwiftUI coordinate).
    /// Reduce Motion snaps to 0 — no lift, no animation.
    /// DesignTokens.Layout.hoverYOffset=-3 is pre-iteration stale; spec value is -1.
    nonisolated static func hoverYOffset(isHovered: Bool, reducedMotion: Bool) -> CGFloat {
        reducedMotion ? 0 : (isHovered ? -1 : 0)
    }

    /// Opacity of the X close button. Visible only on hover.
    /// Reduce Motion does NOT suppress the reveal — the affordance must always appear on hover.
    /// Only the kinetic lift (hoverScale/hoverYOffset) is suppressed by Reduce Motion.
    nonisolated static func xButtonOpacity(isHovered: Bool) -> Double {
        isHovered ? 1.0 : 0.0
    }

    /// Tint alpha appropriate for the current background mode.
    /// Glass mode uses a lower alpha so Liquid Glass lensing is visible through the colour signal.
    /// Solid mode retains the Widget.jsx value sized for an opaque substrate.
    static func effectiveTintAlpha(reduceTransparency: Bool) -> Double {
        reduceTransparency ? solidTintAlpha : glassTintAlpha
    }

    // MARK: - M5.6 pulse predicate

    /// True when the bottom cluster (M:SS + label) should breathe 1↔0.5 at 2s period.
    /// Fires only at L3 (monologueLevel == 3) while .counting, with Reduce Motion suppression.
    ///
    /// Scope note: the spec called for the mono caret (in barZone) to pulse alongside M:SS + label.
    /// The caret lives in barZone, not bottomCluster; splitting barZone to isolate it is out of scope
    /// for M5.6. The pulse covers M:SS + label only. The caret already animates on streak changes
    /// (400ms easeOut), keeping the L3 signal legible without the additional pulse.
    static func shouldPulseBottomCluster(
        monologueLevel: Int,
        reducedMotion: Bool,
        activityState: WidgetActivityState
    ) -> Bool {
        monologueLevel == 3 && !reducedMotion && activityState == .counting
    }
}
