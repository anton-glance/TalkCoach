import Foundation

/// Adaptive noise-floor tracker for shouting detection.
///
/// Maintains a rolling buffer of dBFS samples. The noise floor is the Nth
/// percentile of the buffer. A shouting event fires when dBFS exceeds
/// floor + thresholdDB for at least `minEventDurationSeconds` consecutive
/// hops. After an event, the algorithm enters cooldown and will not fire
/// again until dBFS drops below threshold for an equal number of
/// consecutive hops. The floor self-balances: sustained loud input raises
/// the percentile, naturally ending threshold crossings.
public struct AdaptiveNoiseFloor: Sendable {
    private let bufferCapacity: Int
    private let percentile: Double
    private let thresholdDB: Double
    private let sustainCount: Int
    private let cooldownCount: Int
    private let hopSeconds: Double
    private let warmupThreshold: Int = 10

    private var buffer: [Double]
    private var bufferIndex: Int = 0
    private var sampleCount: Int = 0

    private var consecutiveAboveCount: Int = 0
    private var crossingOnsetTime: Double = 0.0
    private var inCooldown: Bool = false
    private var consecutiveBelowCount: Int = 0

    public private(set) var events: [ShoutingEvent] = []

    private var floorMin: Double = .infinity
    private var floorMax: Double = -.infinity
    private var floorSum: Double = 0.0
    private var floorCount: Int = 0
    private var _peakDBFS: Double = -.infinity

    public init(
        bufferLengthSeconds: Double = 5.0,
        percentile: Double = 10.0,
        thresholdDB: Double = 25.0,
        minEventDurationSeconds: Double = 0.5,
        hopSeconds: Double = 0.1
    ) {
        self.bufferCapacity = Int(bufferLengthSeconds / hopSeconds)
        self.percentile = percentile
        self.thresholdDB = thresholdDB
        self.sustainCount = Int(minEventDurationSeconds / hopSeconds)
        self.cooldownCount = Int(minEventDurationSeconds / hopSeconds)
        self.hopSeconds = hopSeconds
        self.buffer = Array(repeating: 0.0, count: Int(bufferLengthSeconds / hopSeconds))
    }

    public mutating func process(sample: Double, atTimeSeconds: Double) -> Tick {
        if sample > _peakDBFS { _peakDBFS = sample }

        buffer[bufferIndex] = sample
        bufferIndex = (bufferIndex + 1) % bufferCapacity
        sampleCount += 1

        let currentCount = min(sampleCount, bufferCapacity)

        guard currentCount >= warmupThreshold else {
            return Tick(
                timeSeconds: atTimeSeconds,
                dBFS: sample,
                floorDBFS: .nan,
                thresholdDBFS: .nan,
                isAboveThreshold: false,
                eventFired: false
            )
        }

        let activeSlice: [Double]
        if sampleCount >= bufferCapacity {
            activeSlice = buffer
        } else {
            activeSlice = Array(buffer[0..<currentCount])
        }
        let sorted = activeSlice.sorted()

        // 10th percentile with linear interpolation: p = percentile/100 * (N-1)
        let p = (percentile / 100.0) * Double(sorted.count - 1)
        let lo = Int(p)
        let hi = min(lo + 1, sorted.count - 1)
        let frac = p - Double(lo)
        let floor = sorted[lo] + frac * (sorted[hi] - sorted[lo])

        let threshold = floor + thresholdDB
        let isAbove = sample > threshold

        floorMin = min(floorMin, floor)
        floorMax = max(floorMax, floor)
        floorSum += floor
        floorCount += 1

        var eventFired = false

        if inCooldown {
            if isAbove {
                consecutiveBelowCount = 0
            } else {
                consecutiveBelowCount += 1
                if consecutiveBelowCount >= cooldownCount {
                    inCooldown = false
                    consecutiveAboveCount = 0
                }
            }
        } else {
            if isAbove {
                if consecutiveAboveCount == 0 {
                    crossingOnsetTime = atTimeSeconds
                }
                consecutiveAboveCount += 1
                if consecutiveAboveCount >= sustainCount {
                    events.append(ShoutingEvent(onsetTimeSeconds: crossingOnsetTime))
                    eventFired = true
                    inCooldown = true
                    consecutiveBelowCount = 0
                }
            } else {
                consecutiveAboveCount = 0
            }
        }

        return Tick(
            timeSeconds: atTimeSeconds,
            dBFS: sample,
            floorDBFS: floor,
            thresholdDBFS: threshold,
            isAboveThreshold: isAbove,
            eventFired: eventFired
        )
    }

    public func summary(clipName: String, durationSeconds: Double) -> ClipSummary {
        ClipSummary(
            clipName: clipName,
            durationSeconds: durationSeconds,
            nEvents: events.count,
            firstEventTimeSeconds: events.first?.onsetTimeSeconds,
            floorMinDBFS: floorCount > 0 ? floorMin : .nan,
            floorMaxDBFS: floorCount > 0 ? floorMax : .nan,
            floorMeanDBFS: floorCount > 0 ? floorSum / Double(floorCount) : .nan,
            peakDBFS: _peakDBFS
        )
    }
}
