import SwiftUI

// Swift port of docs/design/components/widget/tokens.js.
// tokens.js is the design reference — keep values in sync when either file changes.
// Shadow constants from tokens.js are intentionally omitted: they are CSS strings with no
// SwiftUI equivalent, and Widget.jsx does not consume TV2.Shadow (it uses its own shadow stack).
enum DesignTokens {

    // MARK: - Layout (tokens.js lines 8–33)

    enum Layout {
        static let size: CGFloat = 144
        static let cornerRadius: CGFloat = 32
        static let paddingHorizontal: CGFloat = 13
        static let paddingVertical: CGFloat = 11
        static let spectrumHeight: CGFloat = 16
        static let spectrumBarHeight: CGFloat = 2
        static let spectrumBarTopInset: CGFloat = 5
        static let caretWidth: CGFloat = 8
        static let caretHeight: CGFloat = 5
        static let caretTopInset: CGFloat = 9
        static let fillerRowGap: CGFloat = 5
        static let fillerWordColumnWidth: CGFloat = 56
        static let fillerColumnGap: CGFloat = 5
        static let pillarWidth: CGFloat = 2.5
        static let pillarHeight: CGFloat = 9
        static let pillarGap: CGFloat = 2.0
        static let pillarCornerRadius: CGFloat = 1
        static let pillarOpacity: Double = 0.95
        static let maxPillars: Int = 10
        static let stateRowGap: CGFloat = 4
        static let topGapBetweenWPMAndStateRow: CGFloat = 4
        static let hoverYOffset: CGFloat = -3
        static let hoverScale: CGFloat = 1.025
        static let borderWidth: CGFloat = 0.5
    }

    // MARK: - Pace (tokens.js lines 36–42)

    enum Pace {
        static let wpmIdeal: Int = 140
        static let wpmMin: Int = 80
        static let wpmMax: Int = 240
        static let slowThreshold: Int = 115
        static let fastThreshold: Int = 175
    }

    // MARK: - PaceZone (Swift enum replacing JS string literals 'tooSlow'/'ideal'/'tooFast')

    enum PaceZone: Equatable {
        case tooSlow, ideal, tooFast
    }

    // MARK: - Color stops (tokens.js lines 45–51; internal for testability via @testable import)

    enum ColorStops {
        static let slowBase  = SIMD3<Double>(86, 135, 197)
        static let idealBase = SIMD3<Double>(108, 207, 160)
        static let fastBase  = SIMD3<Double>(216, 98, 90)
        static let slowDeep  = SIMD3<Double>(29, 68, 118)
        static let idealDeep = SIMD3<Double>(31, 90, 64)
        static let fastDeep  = SIMD3<Double>(110, 50, 32)
    }

    // MARK: - MonoStops (tokens.js lines 102–109; internal for testability via @testable import)

    enum MonoStops {
        static let greenBase = SIMD3<Double>(108, 207, 160)
        static let goldBase  = SIMD3<Double>(220, 175, 80)
        static let coralBase = SIMD3<Double>(216, 98, 90)
        static let greenDeep = SIMD3<Double>(31, 90, 64)
        static let goldDeep  = SIMD3<Double>(110, 84, 25)
        static let coralDeep = SIMD3<Double>(110, 50, 32)
    }

    // MARK: - Tint and Border (tokens.js lines 54–55)

    enum Tint {
        static let restingAlpha: Double = 0.55
        static let hoverAlpha: Double = 0.72
    }

    enum Border {
        static let restingWhiteOpacity: Double = 0.55
        static let hoverWhiteOpacity: Double = 0.78
    }

    // MARK: - Math helpers (tokens.js lines 62–65)

    static func ease(_ val: Double) -> Double {
        pow(val, 1.6)
    }

    static func clamp01(_ val: Double) -> Double {
        min(1, max(0, val))
    }

    static func mix(
        _ src: SIMD3<Double>,
        _ dst: SIMD3<Double>,
        _ frac: Double
    ) -> SIMD3<Double> {
        src + (dst - src) * frac
    }

    /// Returns a SwiftUI Color from 0–255 RGB components and an alpha in [0,1].
    /// Mirrors tokens.js `rgba(v, a)` — callers apply the desired alpha at use-site via .opacity().
    static func rgba(red: Double, green: Double, blue: Double, alpha: Double) -> Color {
        Color(red: red / 255, green: green / 255, blue: blue / 255, opacity: alpha)
    }

    // MARK: - Pace color functions (tokens.js lines 67–79)

    /// Raw RGB components for pace tint and deep color at a given WPM.
    /// Extracted from paceColors() so tests can assert Double component values without Color equality.
    static func paceRGB(wpm: Int) -> (tint: SIMD3<Double>, deep: SIMD3<Double>) {
        let wpmF = Double(wpm)
        let wIdeal = Double(Pace.wpmIdeal)
        let wMin = Double(Pace.wpmMin)
        let wMax = Double(Pace.wpmMax)
        let blend: Double
        let tintRGB: SIMD3<Double>
        let deepRGB: SIMD3<Double>
        if wpmF <= wIdeal {
            blend = ease(clamp01((wIdeal - wpmF) / (wIdeal - wMin)))
            tintRGB = mix(ColorStops.idealBase, ColorStops.slowBase, blend)
            deepRGB = mix(ColorStops.idealDeep, ColorStops.slowDeep, blend)
        } else {
            blend = ease(clamp01((wpmF - wIdeal) / (wMax - wIdeal)))
            tintRGB = mix(ColorStops.idealBase, ColorStops.fastBase, blend)
            deepRGB = mix(ColorStops.idealDeep, ColorStops.fastDeep, blend)
        }
        return (tintRGB, deepRGB)
    }

    static func paceColors(wpm: Int) -> (tint: Color, deep: Color) {
        let rgb = paceRGB(wpm: wpm)
        return (
            rgba(red: rgb.tint.x, green: rgb.tint.y, blue: rgb.tint.z, alpha: 1.0),
            rgba(red: rgb.deep.x, green: rgb.deep.y, blue: rgb.deep.z, alpha: 1.0)
        )
    }

    // MARK: - Monologue color functions (tokens.js lines 111–130)
    //
    // Thresholds are Settings-driven (not hardcoded) per M5.2 locked product decision.
    // tokens.js uses 60/90/120 as defaults; SettingsStore defaults are 60/90/150 seconds.
    //
    // Boundary semantics — strict < at every stage, matching JS:
    //   s < level1Seconds                         → greenBase (pure)
    //   level1Seconds ≤ s < level2Seconds         → mix(green, gold,  (s-l1)/(l2-l1))
    //   level2Seconds ≤ s < level3Seconds         → mix(gold,  coral, (s-l2)/(l3-l2))
    //   s ≥ level3Seconds                         → coralBase (pure)
    //
    // Boundary note: s==level1Seconds enters the second branch at blend=0 (pure green).
    // s==level3Seconds hits the final else (pure coral). Do NOT add equality guards — intentional.

    /// Raw RGB components for monologue tint and deep color.
    /// Extracted from monoColors() so tests can assert Double component values without Color equality.
    static func monoRGB(
        seconds: TimeInterval,
        level1Seconds: TimeInterval,
        level2Seconds: TimeInterval,
        level3Seconds: TimeInterval
    ) -> (tint: SIMD3<Double>, deep: SIMD3<Double>) {
        let elapsed = max(0, seconds)
        let tintRGB: SIMD3<Double>
        let deepRGB: SIMD3<Double>
        if elapsed < level1Seconds {
            tintRGB = MonoStops.greenBase
            deepRGB = MonoStops.greenDeep
        } else if elapsed < level2Seconds {
            let denom = level2Seconds - level1Seconds
            let blend = denom > 0 ? (elapsed - level1Seconds) / denom : 1.0
            tintRGB = mix(MonoStops.greenBase, MonoStops.goldBase, blend)
            deepRGB = mix(MonoStops.greenDeep, MonoStops.goldDeep, blend)
        } else if elapsed < level3Seconds {
            let denom = level3Seconds - level2Seconds
            let blend = denom > 0 ? (elapsed - level2Seconds) / denom : 1.0
            tintRGB = mix(MonoStops.goldBase, MonoStops.coralBase, blend)
            deepRGB = mix(MonoStops.goldDeep, MonoStops.coralDeep, blend)
        } else {
            tintRGB = MonoStops.coralBase
            deepRGB = MonoStops.coralDeep
        }
        return (tintRGB, deepRGB)
    }

    static func monoColors(
        seconds: TimeInterval,
        level1Seconds: TimeInterval,
        level2Seconds: TimeInterval,
        level3Seconds: TimeInterval
    ) -> (tint: Color, deep: Color) {
        let rgb = monoRGB(seconds: seconds, level1Seconds: level1Seconds, level2Seconds: level2Seconds, level3Seconds: level3Seconds)
        return (
            rgba(red: rgb.tint.x, green: rgb.tint.y, blue: rgb.tint.z, alpha: 1.0),
            rgba(red: rgb.deep.x, green: rgb.deep.y, blue: rgb.deep.z, alpha: 1.0)
        )
    }

    // MARK: - Zone helpers (tokens.js lines 81–94)

    static func zoneForWPM(_ wpm: Int) -> PaceZone {
        if wpm < Pace.slowThreshold { return .tooSlow }
        if wpm > Pace.fastThreshold { return .tooFast }
        return .ideal
    }

    static func zoneLabel(_ zone: PaceZone) -> String {
        switch zone {
        case .tooSlow: return "Too slow"
        case .ideal:   return "Ideal"
        case .tooFast: return "Too fast"
        }
    }

    static func spectrumPosition(wpm: Int) -> Double {
        clamp01((Double(wpm) - Double(Pace.wpmMin)) / (Double(Pace.wpmMax) - Double(Pace.wpmMin)))
    }
}
