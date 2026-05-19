import Foundation

public final class RMSVoiceActivityDetector {

    public enum CalibrationState: String {
        case calibrating, calibrated, fallback
    }

    // MARK: - Tunable parameters

    public let calibrationDurationSeconds: Double
    public let speechCeilingDB: Float
    public let staticFallbackThresholdDB: Float
    public let thresholdMarginDB: Float
    public let minNoiseFloorDB: Float
    public let voiceOnHysteresisCount: Int
    public let voiceOffHysteresisCount: Int
    public let silentUpdateAlphaPerSecond: Float
    public let silentHoldForUpdateSeconds: Double

    // MARK: - Observable state

    public private(set) var isVoiceActive: Bool = false
    public private(set) var calibrationFallbackUsed: Bool = false
    public private(set) var noiseFloorDB: Float = -60.0
    public private(set) var thresholdDB: Float = -40.0
    public private(set) var lastRMSDB: Float = -100.0
    public private(set) var calibrationState: CalibrationState = .calibrating

    // MARK: - Internal state

    private var samplesProcessed: Int64 = 0
    private var calibrationWindow: [Float] = []
    private var aboveThresholdCount: Int = 0
    private var belowThresholdCount: Int = 0
    private var consecutiveBelowThresholdBuffers: Int = 0

    // MARK: - Init

    public init(
        calibrationDurationSeconds: Double = 1.0,
        speechCeilingDB: Float = -25.0,
        staticFallbackThresholdDB: Float = -40.0,
        thresholdMarginDB: Float = 15.0,
        minNoiseFloorDB: Float = -60.0,
        voiceOnHysteresisCount: Int = 3,
        voiceOffHysteresisCount: Int = 30,
        silentUpdateAlphaPerSecond: Float = 0.05,
        silentHoldForUpdateSeconds: Double = 0.5
    ) {
        self.calibrationDurationSeconds = calibrationDurationSeconds
        self.speechCeilingDB = speechCeilingDB
        self.staticFallbackThresholdDB = staticFallbackThresholdDB
        self.thresholdMarginDB = thresholdMarginDB
        self.minNoiseFloorDB = minNoiseFloorDB
        self.voiceOnHysteresisCount = voiceOnHysteresisCount
        self.voiceOffHysteresisCount = voiceOffHysteresisCount
        self.silentUpdateAlphaPerSecond = silentUpdateAlphaPerSecond
        self.silentHoldForUpdateSeconds = silentHoldForUpdateSeconds
    }

    // MARK: - Processing

    @discardableResult
    public func process(samples: [Float], sampleRate: Double) -> Bool {
        guard !samples.isEmpty else { return isVoiceActive }

        let frameCount = Int64(samples.count)
        let bufferDurationSeconds = Double(samples.count) / sampleRate

        // Step 1: compute RMS and convert to dBFS
        var sumSq: Float = 0.0
        for s in samples { sumSq += s * s }
        let rms = (sumSq / Float(samples.count)).squareRoot()
        let rmsDB = 20.0 * log10(max(rms, 1e-10))
        lastRMSDB = rmsDB

        samplesProcessed += frameCount

        // Step 2: calibration
        if calibrationState == .calibrating {
            if rmsDB > speechCeilingDB {
                // Ceiling breach — fall back to static threshold
                calibrationFallbackUsed = true
                calibrationState = .fallback
                thresholdDB = staticFallbackThresholdDB
                let msg = "INFO: calibration fallback — ceiling breach at \(String(format: "%.1f", rmsDB)) dBFS " +
                          "(ceiling: \(speechCeilingDB) dBFS), static threshold: \(staticFallbackThresholdDB) dBFS\n"
                FileHandle.standardError.write(Data(msg.utf8))
            } else {
                calibrationWindow.append(rmsDB)
                if Double(samplesProcessed) / sampleRate >= calibrationDurationSeconds {
                    let minVal = calibrationWindow.min() ?? minNoiseFloorDB
                    noiseFloorDB = max(minVal, minNoiseFloorDB)
                    thresholdDB = noiseFloorDB + thresholdMarginDB
                    calibrationState = .calibrated
                    calibrationWindow.removeAll()
                }
            }
        }

        // Step 3: voice/silence hysteresis (runs in all states)
        if rmsDB >= thresholdDB {
            aboveThresholdCount += 1
            belowThresholdCount = 0
            if !isVoiceActive && aboveThresholdCount >= voiceOnHysteresisCount {
                isVoiceActive = true
            }
        } else {
            belowThresholdCount += 1
            aboveThresholdCount = 0
            if isVoiceActive && belowThresholdCount >= voiceOffHysteresisCount {
                isVoiceActive = false
            }
        }

        // Step 4: adaptive noise floor update (calibrated state only, during silence)
        if calibrationState == .calibrated {
            if !isVoiceActive && rmsDB < thresholdDB {
                consecutiveBelowThresholdBuffers += 1
                let silentDuration = Double(consecutiveBelowThresholdBuffers) * bufferDurationSeconds
                if silentDuration >= silentHoldForUpdateSeconds {
                    let alpha = Float(1.0 - pow(1.0 - Double(silentUpdateAlphaPerSecond), bufferDurationSeconds))
                    noiseFloorDB = noiseFloorDB * (1.0 - alpha) + rmsDB * alpha
                    noiseFloorDB = max(noiseFloorDB, minNoiseFloorDB)
                    thresholdDB = noiseFloorDB + thresholdMarginDB
                }
            } else {
                consecutiveBelowThresholdBuffers = 0
            }
        }

        return isVoiceActive
    }
}
