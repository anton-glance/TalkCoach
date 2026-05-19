import XCTest
@testable import Spike16

private let kSampleRate: Double = 16000.0
private let kBufferSize: Int = 160  // 10ms at 16 kHz

private func makeSamples(count: Int, rmsDB: Float) -> [Float] {
    // Constant value gives exact target RMS: rms(constant) = abs(constant)
    let amplitude = pow(10.0 as Float, rmsDB / 20.0)
    return [Float](repeating: amplitude, count: count)
}

private func makeZeroSamples(count: Int) -> [Float] {
    [Float](repeating: 0.0, count: count)
}

// Feed N buffers of the given samples, return the last isVoiceActive value
@discardableResult
private func feedBuffers(_ vad: RMSVoiceActivityDetector, samples: [Float], count: Int) -> Bool {
    var result = false
    for _ in 0..<count {
        result = vad.process(samples: samples, sampleRate: kSampleRate)
    }
    return result
}

final class RMSVADTests: XCTestCase {

    // Test 1: Zero-energy buffers never trigger voice-active
    func testZeroEnergyBuffer_neverVoiceActive() {
        let vad = RMSVoiceActivityDetector()
        let zeros = makeZeroSamples(count: kBufferSize)
        for _ in 0..<500 {
            let active = vad.process(samples: zeros, sampleRate: kSampleRate)
            XCTAssertFalse(active, "Zero-energy buffer should never trigger isVoiceActive")
        }
    }

    // Test 2: High-energy buffers trigger voice-on after 3 consecutive (default hysteresis).
    // The first buffer both triggers calibration fallback AND counts as the first above-threshold
    // buffer (hysteresis runs on the same buffer, after the threshold is set in step 2).
    func testHighEnergyBuffer_voiceOnAfterHysteresis() {
        let vad = RMSVoiceActivityDetector()
        let highEnergy = makeSamples(count: kBufferSize, rmsDB: -5.0)

        // Buffer 1: triggers fallback breach (thresholdDB → -40) AND aboveThresholdCount = 1
        _ = vad.process(samples: highEnergy, sampleRate: kSampleRate)
        XCTAssertFalse(vad.isVoiceActive, "1 above-threshold buffer: not yet active (need 3)")

        // Buffer 2: aboveThresholdCount = 2, still not active
        _ = vad.process(samples: highEnergy, sampleRate: kSampleRate)
        XCTAssertFalse(vad.isVoiceActive, "2 above-threshold buffers: not yet active (need 3)")

        // Buffer 3: aboveThresholdCount = 3, now active
        _ = vad.process(samples: highEnergy, sampleRate: kSampleRate)
        XCTAssertTrue(vad.isVoiceActive, "3 consecutive above-threshold buffers: should flip active")
    }

    // Test 3: Ceiling breach during calibration sets calibrationFallbackUsed = true
    func testCeilingBreachDuringCalibration_setsFallbackFlag() {
        let vad = RMSVoiceActivityDetector()
        let highSamples = makeSamples(count: kBufferSize, rmsDB: -20.0)  // above -25 ceiling
        _ = vad.process(samples: highSamples, sampleRate: kSampleRate)
        XCTAssertTrue(vad.calibrationFallbackUsed, "calibrationFallbackUsed must be true after ceiling breach")
        XCTAssertEqual(vad.calibrationState, .fallback)
    }

    // Test 4: After ceiling breach, threshold is staticFallbackThresholdDB, not adaptive;
    //         further silence buffers do NOT move the threshold
    func testCeilingBreachDuringCalibration_usesFallbackThresholdNotAdaptive() {
        let vad = RMSVoiceActivityDetector()
        let highSamples = makeSamples(count: kBufferSize, rmsDB: -20.0)
        _ = vad.process(samples: highSamples, sampleRate: kSampleRate)

        XCTAssertEqual(vad.thresholdDB, vad.staticFallbackThresholdDB,
                       "Threshold must equal staticFallbackThresholdDB immediately after breach")

        // Feed 200 buffers of silence (well past the 500ms hold)
        let zeros = makeZeroSamples(count: kBufferSize)
        for _ in 0..<200 {
            _ = vad.process(samples: zeros, sampleRate: kSampleRate)
        }
        XCTAssertEqual(vad.thresholdDB, vad.staticFallbackThresholdDB,
                       "Threshold must remain staticFallbackThresholdDB in fallback state — adaptive update must not run")
        XCTAssertEqual(vad.calibrationState, .fallback)
    }

    // Test 5: Clean calibration (no breach) sets adaptive threshold = noiseFloor + margin
    func testCalibrationCompletesWithoutBreach_setsAdaptiveThreshold() {
        let vad = RMSVoiceActivityDetector()
        // -55 dBFS samples are well below the -25 dBFS ceiling
        let quietSamples = makeSamples(count: kBufferSize, rmsDB: -55.0)
        // 100 buffers × 160 samples = 16000 samples = exactly 1.0s at 16 kHz → calibration completes
        for _ in 0..<100 {
            _ = vad.process(samples: quietSamples, sampleRate: kSampleRate)
        }
        XCTAssertEqual(vad.calibrationState, .calibrated, "Calibration must complete after 1.0s of clean samples")
        // noiseFloor = max(-55, -60) = -55; threshold = -55 + 15 = -40
        XCTAssertEqual(vad.noiseFloorDB, -55.0, accuracy: 1.0)
        XCTAssertEqual(vad.thresholdDB, -40.0, accuracy: 1.0)
    }

    // Test 6: Voice-off hysteresis does NOT flip before 30 consecutive below-threshold buffers
    func testVoiceOffHysteresis_doesNotFlipBeforeCount() {
        let vad = RMSVoiceActivityDetector()
        // Get into fallback + voice-active
        let highSamples = makeSamples(count: kBufferSize, rmsDB: -10.0)
        feedBuffers(vad, samples: highSamples, count: 4)  // 1 breach + 3 hysteresis
        XCTAssertTrue(vad.isVoiceActive, "Precondition: voice must be active before testing off-hysteresis")

        let zeros = makeZeroSamples(count: kBufferSize)
        feedBuffers(vad, samples: zeros, count: 29)
        XCTAssertTrue(vad.isVoiceActive,
                      "Voice must remain active after 29 below-threshold buffers (off-hysteresis count is 30)")
    }

    // Test 7: Voice-off hysteresis flips at exactly 30 below-threshold buffers
    func testVoiceOffHysteresis_flipsAtCount() {
        let vad = RMSVoiceActivityDetector()
        let highSamples = makeSamples(count: kBufferSize, rmsDB: -10.0)
        feedBuffers(vad, samples: highSamples, count: 4)
        XCTAssertTrue(vad.isVoiceActive)

        let zeros = makeZeroSamples(count: kBufferSize)
        feedBuffers(vad, samples: zeros, count: 29)
        _ = vad.process(samples: zeros, sampleRate: kSampleRate)  // 30th
        XCTAssertFalse(vad.isVoiceActive,
                       "Voice must flip off after exactly 30 consecutive below-threshold buffers")
    }

    // Test 8: Voice-on counter resets when interrupted by a single below-threshold buffer.
    // Setup: after breach (aboveCount=1) feed one zero buffer to clear the counter, then
    // count 2 above-threshold, interrupt with zero, count 2 more — still not 3 consecutive.
    func testVoiceOnConsecutiveRequirement_resetByOneSilentBuffer() {
        let vad = RMSVoiceActivityDetector()
        // Force fallback state
        let highSamples = makeSamples(count: kBufferSize, rmsDB: -10.0)
        _ = vad.process(samples: highSamples, sampleRate: kSampleRate)  // breach; aboveCount=1
        XCTAssertEqual(vad.calibrationState, .fallback)

        // Reset aboveThresholdCount to 0 with one zero buffer
        let zeros = makeZeroSamples(count: kBufferSize)
        _ = vad.process(samples: zeros, sampleRate: kSampleRate)
        XCTAssertFalse(vad.isVoiceActive, "Precondition: voice must be inactive")

        // Feed 2 consecutive above-threshold buffers (aboveCount reaches 2 — one short of 3)
        let aboveThreshold = makeSamples(count: kBufferSize, rmsDB: -10.0)
        _ = vad.process(samples: aboveThreshold, sampleRate: kSampleRate)  // aboveCount=1
        _ = vad.process(samples: aboveThreshold, sampleRate: kSampleRate)  // aboveCount=2
        XCTAssertFalse(vad.isVoiceActive, "2 consecutive above-threshold: not yet active")

        // One below-threshold buffer resets the counter (aboveCount → 0)
        _ = vad.process(samples: zeros, sampleRate: kSampleRate)

        // Two more above-threshold: aboveCount reaches 2 again, not 3 — must remain inactive
        _ = vad.process(samples: aboveThreshold, sampleRate: kSampleRate)  // aboveCount=1
        _ = vad.process(samples: aboveThreshold, sampleRate: kSampleRate)  // aboveCount=2
        XCTAssertFalse(vad.isVoiceActive,
                       "Voice must not activate: on-counter was reset mid-sequence, never reached 3")
    }

    // Test 9: Noise floor does NOT update during voice-active periods
    func testNoiseFloor_doesNotUpdateDuringVoiceActive() {
        let vad = RMSVoiceActivityDetector()
        // Complete calibration cleanly
        let quietSamples = makeSamples(count: kBufferSize, rmsDB: -55.0)
        feedBuffers(vad, samples: quietSamples, count: 100)
        XCTAssertEqual(vad.calibrationState, .calibrated)

        let noiseFloorBefore = vad.noiseFloorDB

        // Make voice active
        let highSamples = makeSamples(count: kBufferSize, rmsDB: -10.0)
        feedBuffers(vad, samples: highSamples, count: 4)
        XCTAssertTrue(vad.isVoiceActive)

        // Feed 200 more high-energy buffers (well past 500ms hold)
        feedBuffers(vad, samples: highSamples, count: 200)

        XCTAssertEqual(vad.noiseFloorDB, noiseFloorBefore,
                       "Noise floor must not change while voice is active")
    }

    // Test 10: Noise floor updates after extended silence (> 500ms) and respects minimum bound
    func testNoiseFloor_updatesAfterExtendedSilence() {
        let vad = RMSVoiceActivityDetector()
        // Complete calibration cleanly with noiseFloor at -55 dBFS
        let quietSamples = makeSamples(count: kBufferSize, rmsDB: -55.0)
        feedBuffers(vad, samples: quietSamples, count: 100)
        XCTAssertEqual(vad.calibrationState, .calibrated)

        let noiseFloorBefore = vad.noiseFloorDB

        // Feed 60 zero-energy buffers = 600ms silence (> 500ms hold threshold)
        let zeros = makeZeroSamples(count: kBufferSize)
        feedBuffers(vad, samples: zeros, count: 60)

        // Noise floor should have moved downward (toward -100 dBFS of silence)
        // and must remain at or above minNoiseFloorDB (-60 dBFS)
        XCTAssertLessThan(vad.noiseFloorDB, noiseFloorBefore,
                          "Noise floor must decrease when fed sustained silence")
        XCTAssertGreaterThanOrEqual(vad.noiseFloorDB, vad.minNoiseFloorDB,
                                    "Noise floor must never drop below minNoiseFloorDB")
    }
}
