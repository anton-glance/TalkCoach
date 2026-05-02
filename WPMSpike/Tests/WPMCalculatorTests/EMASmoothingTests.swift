import Testing
@testable import WPMCalculatorLib

struct EMASmoothingTests {

    @Test func singleSpike_decaysOverTime() {
        // Alpha 0.3. Input: [0, 0, 100, 0, 0, 0, 0, 0].
        // After the spike (index 2), each subsequent output is strictly less
        // than the previous. Output at index 7 < 5.0 (decayed).
        var ema = EMASmoother(alpha: 0.3)
        let inputs: [Double] = [0, 0, 100, 0, 0, 0, 0, 0]
        var outputs: [Double] = []

        for value in inputs {
            outputs.append(ema.smooth(value))
        }

        // After spike at index 2, outputs[3..7] should be strictly decreasing
        for i in 3..<outputs.count {
            #expect(
                outputs[i] < outputs[i - 1],
                "Output at index \(i) (\(outputs[i])) should be < index \(i - 1) (\(outputs[i - 1]))"
            )
        }
        #expect(
            outputs[7] < 5.0,
            "Spike should have decayed to < 5.0 by index 7, got \(outputs[7])"
        )
    }

    @Test func constantInput_convergesToInput() {
        // Alpha 0.3. 20 values all equal to 50.0.
        // Final output within 0.1% of 50.0.
        var ema = EMASmoother(alpha: 0.3)
        var lastOutput = 0.0

        for _ in 0..<20 {
            lastOutput = ema.smooth(50.0)
        }

        let tolerance = 50.0 * 0.001
        #expect(
            abs(lastOutput - 50.0) < tolerance,
            "After 20 constant inputs of 50.0, output should converge to 50.0 ± 0.1%, got \(lastOutput)"
        )
    }

    @Test func alpha03_reducesNoiseFiftyPercent() {
        // Alpha 0.3. 100 values with deterministic noise.
        // First 50: base 100 + noise. Last 50: base 200 + noise (step change).
        // (1) Smoothed variance <= 50% of raw variance.
        // (2) Within 4 samples after step (index 54), smoothed >= 170.
        var ema = EMASmoother(alpha: 0.3)

        // Deterministic pseudo-noise using a simple LCG seeded at 42
        var seed: UInt64 = 42
        func nextNoise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let normalized = Double(seed >> 33) / Double(UInt32.max) // 0..1
            return (normalized - 0.5) * 40.0 // range [-20, 20]
        }

        var rawValues: [Double] = []
        var smoothedValues: [Double] = []

        for i in 0..<100 {
            let base: Double = i < 50 ? 100.0 : 200.0
            let raw = base + nextNoise()
            rawValues.append(raw)
            smoothedValues.append(ema.smooth(raw))
        }

        // Compute variance for the first 50 samples (stable segment)
        func variance(_ values: ArraySlice<Double>) -> Double {
            let mean = values.reduce(0.0, +) / Double(values.count)
            return values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        }

        let rawVariance = variance(rawValues[0..<50])
        let smoothedVariance = variance(smoothedValues[5..<50]) // skip warm-up

        #expect(
            smoothedVariance <= rawVariance * 0.5,
            "Smoothed variance (\(smoothedVariance)) should be <= 50% of raw variance (\(rawVariance))"
        )

        // Step change tracking: at index 54 (4 samples after step), smoothed >= 170
        #expect(
            smoothedValues[54] >= 170.0,
            "Within 4 samples of step change, smoothed should be >= 170, got \(smoothedValues[54])"
        )
    }
}
