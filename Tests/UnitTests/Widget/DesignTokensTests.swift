// REGRESSION ANCHOR
// DesignTokens.swift is the Swift port of docs/design/components/widget/tokens.js.
// If you change a value in DesignTokens.swift, update tokens.js to match (it is the design reference).
// If you change tokens.js, update DesignTokens.swift.
// Pace constants (wpmIdeal, wpmMin, wpmMax, slowThreshold, fastThreshold), color stops,
// and layout values must match exactly.
// Monologue stage boundaries 60/90/120 in tokens.js are SUPERSEDED by live Settings
// thresholds in the Swift port (M5.2 product decision — see CLAUDE.md locked decisions).

import XCTest
@testable import TalkCoach

@MainActor
final class DesignTokensTests: XCTestCase {

    // MARK: - Approximate-equality helper

    private func approxEqual(
        _ lhs: SIMD3<Double>,
        _ rhs: SIMD3<Double>,
        accuracy: Double = 1e-9,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertEqual(lhs.x, rhs.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.y, rhs.y, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(lhs.z, rhs.z, accuracy: accuracy, file: file, line: line)
    }

    // MARK: - Layout constants

    func testLayoutSize() {
        XCTAssertEqual(DesignTokens.Layout.size, 144)
    }

    func testLayoutCornerRadius() {
        XCTAssertEqual(DesignTokens.Layout.cornerRadius, 32)
    }

    func testLayoutPaddingHorizontal() {
        XCTAssertEqual(DesignTokens.Layout.paddingHorizontal, 13)
    }

    func testLayoutPaddingVertical() {
        XCTAssertEqual(DesignTokens.Layout.paddingVertical, 11)
    }

    func testLayoutSpectrumBarHeight() {
        XCTAssertEqual(DesignTokens.Layout.spectrumBarHeight, 2)
    }

    func testLayoutCaretDimensions() {
        XCTAssertEqual(DesignTokens.Layout.caretWidth, 8)
        XCTAssertEqual(DesignTokens.Layout.caretHeight, 5)
    }

    func testLayoutHoverTransform() {
        XCTAssertEqual(DesignTokens.Layout.hoverYOffset, -3)
        XCTAssertEqual(DesignTokens.Layout.hoverScale, 1.025)
    }

    func testLayoutBorderWidth() {
        XCTAssertEqual(DesignTokens.Layout.borderWidth, 0.5)
    }

    // MARK: - Pace constants

    func testPaceConstants() {
        XCTAssertEqual(DesignTokens.Pace.wpmIdeal, 140)
        XCTAssertEqual(DesignTokens.Pace.wpmMin, 80)
        XCTAssertEqual(DesignTokens.Pace.wpmMax, 240)
        XCTAssertEqual(DesignTokens.Pace.slowThreshold, 115)
        XCTAssertEqual(DesignTokens.Pace.fastThreshold, 175)
    }

    // MARK: - Tint and Border constants

    func testTintConstants() {
        XCTAssertEqual(DesignTokens.Tint.restingAlpha, 0.55, accuracy: 1e-9)
        XCTAssertEqual(DesignTokens.Tint.hoverAlpha, 0.72, accuracy: 1e-9)
    }

    func testBorderConstants() {
        XCTAssertEqual(DesignTokens.Border.restingWhiteOpacity, 0.55, accuracy: 1e-9)
        XCTAssertEqual(DesignTokens.Border.hoverWhiteOpacity, 0.78, accuracy: 1e-9)
    }

    // MARK: - ColorStops

    func testColorStopsBase() {
        approxEqual(DesignTokens.ColorStops.slowBase, SIMD3<Double>(86, 135, 197))
        approxEqual(DesignTokens.ColorStops.idealBase, SIMD3<Double>(108, 207, 160))
        approxEqual(DesignTokens.ColorStops.fastBase, SIMD3<Double>(216, 98, 90))
    }

    func testColorStopsDeep() {
        approxEqual(DesignTokens.ColorStops.slowDeep, SIMD3<Double>(29, 68, 118))
        approxEqual(DesignTokens.ColorStops.idealDeep, SIMD3<Double>(31, 90, 64))
        approxEqual(DesignTokens.ColorStops.fastDeep, SIMD3<Double>(110, 50, 32))
    }

    // MARK: - MonoStops

    func testMonoStopsBase() {
        approxEqual(DesignTokens.MonoStops.greenBase, SIMD3<Double>(108, 207, 160))
        approxEqual(DesignTokens.MonoStops.goldBase, SIMD3<Double>(220, 175, 80))
        approxEqual(DesignTokens.MonoStops.coralBase, SIMD3<Double>(216, 98, 90))
    }

    func testMonoStopsDeep() {
        approxEqual(DesignTokens.MonoStops.greenDeep, SIMD3<Double>(31, 90, 64))
        approxEqual(DesignTokens.MonoStops.goldDeep, SIMD3<Double>(110, 84, 25))
        approxEqual(DesignTokens.MonoStops.coralDeep, SIMD3<Double>(110, 50, 32))
    }

    // MARK: - clamp01

    func testClamp01BelowZero() {
        XCTAssertEqual(DesignTokens.clamp01(-1.0), 0.0, accuracy: 1e-9)
    }

    func testClamp01AboveOne() {
        XCTAssertEqual(DesignTokens.clamp01(2.0), 1.0, accuracy: 1e-9)
    }

    func testClamp01MidRange() {
        XCTAssertEqual(DesignTokens.clamp01(0.5), 0.5, accuracy: 1e-9)
    }

    // MARK: - ease

    func testEaseAtZero() {
        XCTAssertEqual(DesignTokens.ease(0.0), 0.0, accuracy: 1e-9)
    }

    func testEaseAtOne() {
        XCTAssertEqual(DesignTokens.ease(1.0), 1.0, accuracy: 1e-9)
    }

    func testEaseAtHalf() {
        XCTAssertEqual(DesignTokens.ease(0.5), pow(0.5, 1.6), accuracy: 1e-9)
    }

    // MARK: - mix

    func testMixAtZero() {
        let start = SIMD3<Double>(0, 0, 0)
        let end   = SIMD3<Double>(100, 100, 100)
        approxEqual(DesignTokens.mix(start, end, 0.0), SIMD3<Double>(0, 0, 0))
    }

    func testMixAtOne() {
        let start = SIMD3<Double>(0, 0, 0)
        let end   = SIMD3<Double>(100, 100, 100)
        approxEqual(DesignTokens.mix(start, end, 1.0), SIMD3<Double>(100, 100, 100))
    }

    func testMixAtHalf() {
        let start = SIMD3<Double>(0, 0, 0)
        let end   = SIMD3<Double>(100, 100, 100)
        approxEqual(DesignTokens.mix(start, end, 0.5), SIMD3<Double>(50, 50, 50))
    }

    // MARK: - zoneForWPM

    func testZoneForWPMTooSlow() {
        XCTAssertEqual(DesignTokens.zoneForWPM(80), .tooSlow)
        XCTAssertEqual(DesignTokens.zoneForWPM(114), .tooSlow)
    }

    func testZoneForWPMIdealAtSlowThreshold() {
        // wpm == slowThreshold is .ideal, not .tooSlow — JS uses strict < 115
        XCTAssertEqual(DesignTokens.zoneForWPM(115), .ideal)
    }

    func testZoneForWPMIdeal() {
        XCTAssertEqual(DesignTokens.zoneForWPM(140), .ideal)
    }

    func testZoneForWPMIdealAtFastThreshold() {
        // wpm == fastThreshold is .ideal, not .tooFast — JS uses strict > 175
        XCTAssertEqual(DesignTokens.zoneForWPM(175), .ideal)
    }

    func testZoneForWPMTooFast() {
        XCTAssertEqual(DesignTokens.zoneForWPM(176), .tooFast)
        XCTAssertEqual(DesignTokens.zoneForWPM(240), .tooFast)
    }

    // MARK: - zoneLabel

    func testZoneLabels() {
        XCTAssertEqual(DesignTokens.zoneLabel(.tooSlow), "Too slow")
        XCTAssertEqual(DesignTokens.zoneLabel(.ideal), "Ideal")
        XCTAssertEqual(DesignTokens.zoneLabel(.tooFast), "Too fast")
    }

    // MARK: - spectrumPosition

    func testSpectrumPositionAtMin() {
        XCTAssertEqual(DesignTokens.spectrumPosition(wpm: 80), 0.0, accuracy: 1e-9)
    }

    func testSpectrumPositionAtMax() {
        XCTAssertEqual(DesignTokens.spectrumPosition(wpm: 240), 1.0, accuracy: 1e-9)
    }

    func testSpectrumPositionAtMidpoint() {
        // (160 - 80) / (240 - 80) = 80/160 = 0.5
        XCTAssertEqual(DesignTokens.spectrumPosition(wpm: 160), 0.5, accuracy: 1e-9)
    }

    // MARK: - paceRGB

    func testPaceRGBAtMinWPMIsPureSlowBase() {
        // wpm=80: blend=ease(1.0)=1.0 → mix(idealBase, slowBase, 1.0) = slowBase
        let result = DesignTokens.paceRGB(wpm: 80)
        approxEqual(result.tint, DesignTokens.ColorStops.slowBase)
        approxEqual(result.deep, DesignTokens.ColorStops.slowDeep)
    }

    func testPaceRGBAtIdealWPMIsPureIdealBase() {
        // wpm=140: blend=ease(0.0)=0.0 → mix(idealBase, slowBase, 0.0) = idealBase
        let result = DesignTokens.paceRGB(wpm: 140)
        approxEqual(result.tint, DesignTokens.ColorStops.idealBase)
        approxEqual(result.deep, DesignTokens.ColorStops.idealDeep)
    }

    func testPaceRGBAtMaxWPMIsPureFastBase() {
        // wpm=240: blend=ease(1.0)=1.0 → mix(idealBase, fastBase, 1.0) = fastBase
        let result = DesignTokens.paceRGB(wpm: 240)
        approxEqual(result.tint, DesignTokens.ColorStops.fastBase)
        approxEqual(result.deep, DesignTokens.ColorStops.fastDeep)
    }

    func testPaceRGBMidSlowMixesCorrectly() {
        // wpm=115, slow-side: blend = pow((140-115)/(140-80), 1.6)
        let blend = pow((140.0 - 115.0) / (140.0 - 80.0), 1.6)
        let expectedTint = DesignTokens.ColorStops.idealBase
            + (DesignTokens.ColorStops.slowBase - DesignTokens.ColorStops.idealBase) * blend
        let expectedDeep = DesignTokens.ColorStops.idealDeep
            + (DesignTokens.ColorStops.slowDeep - DesignTokens.ColorStops.idealDeep) * blend
        let result = DesignTokens.paceRGB(wpm: 115)
        approxEqual(result.tint, expectedTint, accuracy: 1e-6)
        approxEqual(result.deep, expectedDeep, accuracy: 1e-6)
    }

    func testPaceRGBMidFastMixesCorrectly() {
        // wpm=190, fast-side: blend = pow((190-140)/(240-140), 1.6)
        let blend = pow((190.0 - 140.0) / (240.0 - 140.0), 1.6)
        let expectedTint = DesignTokens.ColorStops.idealBase
            + (DesignTokens.ColorStops.fastBase - DesignTokens.ColorStops.idealBase) * blend
        let result = DesignTokens.paceRGB(wpm: 190)
        approxEqual(result.tint, expectedTint, accuracy: 1e-6)
    }

    // MARK: - monoRGB (default SettingsStore thresholds: level1=60s, level2=90s, level3=150s)

    func testMonoRGBAtZeroIsGreen() {
        let result = DesignTokens.monoRGB(seconds: 0, level1Seconds: 60, level2Seconds: 90, level3Seconds: 150)
        approxEqual(result.tint, DesignTokens.MonoStops.greenBase)
        approxEqual(result.deep, DesignTokens.MonoStops.greenDeep)
    }

    func testMonoRGBAtL1BoundaryIsGreen() {
        // s==l1 enters the green→gold branch at t=0; result is pure greenBase.
        // Correct per the JS spec — second branch fires with t=(l1-l1)/(l2-l1)=0.
        let result = DesignTokens.monoRGB(seconds: 60, level1Seconds: 60, level2Seconds: 90, level3Seconds: 150)
        approxEqual(result.tint, DesignTokens.MonoStops.greenBase)
    }

    func testMonoRGBMidwayGreenGold() {
        // s=75, t=(75-60)/30=0.5 → mix(green, gold, 0.5)
        let expected = DesignTokens.MonoStops.greenBase
            + (DesignTokens.MonoStops.goldBase - DesignTokens.MonoStops.greenBase) * 0.5
        let result = DesignTokens.monoRGB(seconds: 75, level1Seconds: 60, level2Seconds: 90, level3Seconds: 150)
        approxEqual(result.tint, expected)
    }

    func testMonoRGBAtL2BoundaryIsGold() {
        // s==l2 enters the gold→coral branch at t=0; result is pure goldBase.
        let result = DesignTokens.monoRGB(seconds: 90, level1Seconds: 60, level2Seconds: 90, level3Seconds: 150)
        approxEqual(result.tint, DesignTokens.MonoStops.goldBase)
    }

    func testMonoRGBMidwayGoldCoral() {
        // s=120, t=(120-90)/60=0.5 → mix(gold, coral, 0.5)
        let expected = DesignTokens.MonoStops.goldBase
            + (DesignTokens.MonoStops.coralBase - DesignTokens.MonoStops.goldBase) * 0.5
        let result = DesignTokens.monoRGB(seconds: 120, level1Seconds: 60, level2Seconds: 90, level3Seconds: 150)
        approxEqual(result.tint, expected)
    }

    func testMonoRGBAtL3BoundaryIsCoralNotMix() {
        // s==l3 hits the final else (pure coral) — strict < means s==l3 is NOT in gold→coral.
        let result = DesignTokens.monoRGB(seconds: 150, level1Seconds: 60, level2Seconds: 90, level3Seconds: 150)
        approxEqual(result.tint, DesignTokens.MonoStops.coralBase)
        approxEqual(result.deep, DesignTokens.MonoStops.coralDeep)
    }

    func testMonoRGBPastL3IsCoral() {
        let result = DesignTokens.monoRGB(seconds: 200, level1Seconds: 60, level2Seconds: 90, level3Seconds: 150)
        approxEqual(result.tint, DesignTokens.MonoStops.coralBase)
    }

    func testMonoRGBNegativeSecondsClampedToGreen() {
        let result = DesignTokens.monoRGB(seconds: -5, level1Seconds: 60, level2Seconds: 90, level3Seconds: 150)
        approxEqual(result.tint, DesignTokens.MonoStops.greenBase)
    }

    func testMonoRGBCustomThresholds() {
        // l1=30, l2=60, l3=90; s=45 is midway in [l1,l2): t=0.5 → mix(green, gold, 0.5)
        let expected = DesignTokens.MonoStops.greenBase
            + (DesignTokens.MonoStops.goldBase - DesignTokens.MonoStops.greenBase) * 0.5
        let result = DesignTokens.monoRGB(seconds: 45, level1Seconds: 30, level2Seconds: 60, level3Seconds: 90)
        approxEqual(result.tint, expected)
    }

    // MARK: - paceColors / monoColors (smoke — verifies Color wrapping compiles and runs)

    func testPaceColorsReturnsTwoColors() {
        let result = DesignTokens.paceColors(wpm: 140)
        _ = result.tint
        _ = result.deep
        // Math correctness is covered by paceRGB tests above.
    }

    func testMonoColorsReturnsTwoColors() {
        let result = DesignTokens.monoColors(seconds: 60, level1Seconds: 60, level2Seconds: 90, level3Seconds: 150)
        _ = result.tint
        _ = result.deep
        // Math correctness is covered by monoRGB tests above.
    }
}
