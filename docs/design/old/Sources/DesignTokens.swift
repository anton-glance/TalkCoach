//
//  DesignTokens.swift
//  TalkingCoach
//
//  Single source of truth for all design constants. Mirrors §3, §5, §6, §9 of
//  the design package README. Do NOT hard-code these values anywhere else —
//  views and services must read them from here.
//

import SwiftUI

enum DesignTokens {

    // MARK: - Geometry

    enum Layout {
        /// Widget is a square. macOS small-widget scale.
        static let size: CGFloat = 144
        static let cornerRadius: CGFloat = 32
        static let paddingHorizontal: CGFloat = 13
        static let paddingVertical: CGFloat = 11

        // Spectrum
        static let spectrumHeight: CGFloat = 16
        static let spectrumBarHeight: CGFloat = 2
        static let spectrumBarTopInset: CGFloat = 5
        static let caretWidth: CGFloat = 8
        static let caretHeight: CGFloat = 5
        static let caretTopInset: CGFloat = 9   // measured from top of spectrum region

        // Filler bars (winning treatment: trimmed)
        static let fillerRowGap: CGFloat = 5
        static let fillerWordColumnWidth: CGFloat = 56
        static let fillerColumnGap: CGFloat = 5
        static let pillarWidth: CGFloat = 2.5
        static let pillarHeight: CGFloat = 9
        static let pillarGap: CGFloat = 2.0
        static let pillarCornerRadius: CGFloat = 1
        static let pillarOpacity: Double = 0.95

        /// Cap on rendered pillars per row. If a count exceeds this, render
        /// `MAX_PILLARS` pillars and append a "+" glyph.
        static let maxPillars: Int = 10

        // State row
        static let stateRowGap: CGFloat = 4
        static let topGapBetweenWPMAndStateRow: CGFloat = 4

        // Hover transform
        static let hoverYOffset: CGFloat = -3
        static let hoverScale: CGFloat = 1.025

        // Border
        static let borderWidth: CGFloat = 0.5
        static let borderWidthHover: CGFloat = 0.5  // width unchanged; opacity changes
    }

    // MARK: - Pace

    enum Pace {
        static let wpmIdeal: Double = 140
        static let wpmMin: Double = 80
        static let wpmMax: Double = 240
        static let slowThreshold: Double = 115
        static let fastThreshold: Double = 175

        /// Sliding window for "current WPM".
        static let currentWPMWindowSeconds: Double = 30

        /// How often to recompute current WPM (seconds).
        static let currentWPMRecomputeInterval: Double = 0.5
    }

    // MARK: - Color

    /// Three RGB stops for the pace gradient. Mixed via `mix()` in PaceColors.
    enum ColorStops {
        // Tint stops (drive glass tint, spectrum bar, pillar fallback color)
        static let slowBase  = SIMD3<Double>(86,  135, 197)
        static let idealBase = SIMD3<Double>(108, 207, 160)
        static let fastBase  = SIMD3<Double>(216, 98,  90)

        // Deep stops (drive text, caret, pillars)
        static let slowDeep  = SIMD3<Double>(29,  68,  118)
        static let idealDeep = SIMD3<Double>(31,  90,  64)
        static let fastDeep  = SIMD3<Double>(110, 50,  32)
    }

    enum Tint {
        static let restingAlpha: Double = 0.42
        static let hoverAlpha: Double = 0.62
    }

    enum Border {
        static let restingWhiteOpacity: Double = 0.55
        static let hoverWhiteOpacity: Double = 0.78
    }

    enum Shadow {
        static let outerColor = Color.black.opacity(0.18)
        static let outerRadius: CGFloat = 28
        static let outerYOffset: CGFloat = 8

        static let outerColorHover = Color.black.opacity(0.26)
        static let outerRadiusHover: CGFloat = 42
        static let outerYOffsetHover: CGFloat = 14
    }

    // MARK: - Typography
    //
    // SF Pro / SF Mono via system fonts. Tracking values are in points
    // (CSS em → pt = em * fontSize).

    enum Type {
        static func wpm() -> Font {
            .system(size: 34, weight: .light, design: .default)
        }
        static let wpmTracking: CGFloat = -1.87  // -0.055em * 34pt

        static func state() -> Font {
            .system(size: 8.5, weight: .bold, design: .default)
        }
        static let stateTracking: CGFloat = 1.36  // 0.16em * 8.5pt

        static func avg() -> Font {
            .system(size: 8.5, weight: .regular, design: .default)
        }
        static let avgTracking: CGFloat = 0.34   // 0.04em * 8.5pt

        static func separator() -> Font {
            .system(size: 8.5, weight: .regular, design: .default)
        }

        static func fillerWord() -> Font {
            .system(size: 8.5, weight: .medium, design: .default)
        }

        static let stateOpacity: Double = 0.85
        static let separatorOpacity: Double = 0.32
        static let avgOpacity: Double = 0.50
        static let fillerWordOpacity: Double = 0.88
    }

    // MARK: - Animation

    enum Animation {
        static let colorFadeDuration: Double = 0.45
        static let caretMoveDuration: Double = 0.35
        static let wpmNumericDuration: Double = 0.30
        static let hoverDuration: Double = 0.28
        static let showHideDuration: Double = 0.35

        /// Returns a SwiftUI Animation, clamped to no-op when Reduce Motion is on.
        static func fade(_ duration: Double, reduceMotion: Bool) -> SwiftUI.Animation? {
            reduceMotion ? nil : .easeInOut(duration: duration)
        }

        static func caret(reduceMotion: Bool) -> SwiftUI.Animation? {
            reduceMotion ? nil : .spring(response: caretMoveDuration, dampingFraction: 0.8)
        }
    }

    // MARK: - Filler vocabulary
    //
    // Single-word fillers only in v1. Multi-word ("you know", "i mean")
    // tracked in v2 backlog.

    enum Fillers {
        static let words: Set<String> = [
            "uh", "um", "ah", "er", "hmm",
            "like", "so", "well", "right", "just",
            "basically", "actually", "literally", "totally",
            "kinda", "sorta", "anyway"
        ]

        /// How many to surface in the widget.
        static let topNToShow: Int = 3
    }

    // MARK: - Window placement

    enum Window {
        /// Inset from screen edges when the user hasn't dragged the widget.
        static let defaultEdgeInset: CGFloat = 16
    }
}

// MARK: - Pace color computation

enum PaceColors {

    static func colors(forWPM wpm: Double) -> (tint: Color, deep: Color) {
        let ideal = DesignTokens.Pace.wpmIdeal
        let smin = DesignTokens.Pace.wpmMin
        let smax = DesignTokens.Pace.wpmMax

        let tintRGB: SIMD3<Double>
        let deepRGB: SIMD3<Double>

        if wpm <= ideal {
            let raw = (ideal - wpm) / (ideal - smin)
            let t = ease(min(max(raw, 0), 1))
            tintRGB = mix(DesignTokens.ColorStops.idealBase,
                          DesignTokens.ColorStops.slowBase, t: t)
            deepRGB = mix(DesignTokens.ColorStops.idealDeep,
                          DesignTokens.ColorStops.slowDeep, t: t)
        } else {
            let raw = (wpm - ideal) / (smax - ideal)
            let t = ease(min(max(raw, 0), 1))
            tintRGB = mix(DesignTokens.ColorStops.idealBase,
                          DesignTokens.ColorStops.fastBase, t: t)
            deepRGB = mix(DesignTokens.ColorStops.idealDeep,
                          DesignTokens.ColorStops.fastDeep, t: t)
        }

        return (tint: rgb(tintRGB, alpha: DesignTokens.Tint.restingAlpha),
                deep: rgb(deepRGB, alpha: 1.0))
    }

    static func zone(forWPM wpm: Double) -> PaceZone {
        if wpm < DesignTokens.Pace.slowThreshold { return .tooSlow }
        if wpm > DesignTokens.Pace.fastThreshold { return .tooFast }
        return .ideal
    }

    /// Position of the caret on the spectrum, in [0, 1].
    static func spectrumPosition(forWPM wpm: Double) -> Double {
        let smin = DesignTokens.Pace.wpmMin
        let smax = DesignTokens.Pace.wpmMax
        return min(max((wpm - smin) / (smax - smin), 0), 1)
    }

    // MARK: - Helpers

    private static func ease(_ t: Double) -> Double {
        pow(t, 1.6)
    }

    private static func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, t: Double) -> SIMD3<Double> {
        a + (b - a) * t
    }

    private static func rgb(_ v: SIMD3<Double>, alpha: Double) -> Color {
        Color(.sRGB,
              red: v.x / 255.0,
              green: v.y / 255.0,
              blue: v.z / 255.0,
              opacity: alpha)
    }
}

enum PaceZone: Equatable {
    case tooSlow
    case ideal
    case tooFast

    var label: String {
        switch self {
        case .tooSlow: return "TOO SLOW"
        case .ideal:   return "IDEAL"
        case .tooFast: return "TOO FAST"
        }
    }
}
