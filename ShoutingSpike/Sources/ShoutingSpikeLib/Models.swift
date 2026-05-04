import Foundation

/// Single-hop observation from the adaptive noise-floor algorithm.
public struct Tick: Sendable {
    public let timeSeconds: Double
    public let dBFS: Double
    public let floorDBFS: Double
    public let thresholdDBFS: Double
    public let isAboveThreshold: Bool
    public let eventFired: Bool

    public init(
        timeSeconds: Double,
        dBFS: Double,
        floorDBFS: Double,
        thresholdDBFS: Double,
        isAboveThreshold: Bool,
        eventFired: Bool
    ) {
        self.timeSeconds = timeSeconds
        self.dBFS = dBFS
        self.floorDBFS = floorDBFS
        self.thresholdDBFS = thresholdDBFS
        self.isAboveThreshold = isAboveThreshold
        self.eventFired = eventFired
    }

    public static var csvHeader: String {
        "time_s,dbfs,floor_dbfs,threshold_dbfs,is_above_threshold,event_fired"
    }

    public var csvLine: String {
        let floorStr = floorDBFS.isNaN ? "" : String(format: "%.2f", floorDBFS)
        let thresholdStr = thresholdDBFS.isNaN ? "" : String(format: "%.2f", thresholdDBFS)
        return [
            String(format: "%.3f", timeSeconds),
            String(format: "%.2f", dBFS),
            floorStr,
            thresholdStr,
            isAboveThreshold ? "1" : "0",
            eventFired ? "1" : "0"
        ].joined(separator: ",")
    }
}

/// Point-in-time shouting onset event.
public struct ShoutingEvent: Sendable {
    public let onsetTimeSeconds: Double

    public init(onsetTimeSeconds: Double) {
        self.onsetTimeSeconds = onsetTimeSeconds
    }
}

/// Per-clip aggregate for the summary CSV.
public struct ClipSummary: Sendable {
    public let clipName: String
    public let durationSeconds: Double
    public let nEvents: Int
    public let firstEventTimeSeconds: Double?
    public let floorMinDBFS: Double
    public let floorMaxDBFS: Double
    public let floorMeanDBFS: Double
    public let peakDBFS: Double

    public static var csvHeader: String {
        "clip_name,duration_s,n_events,first_event_t_s,floor_min_dbfs,floor_max_dbfs,floor_mean_dbfs,peak_dbfs"
    }

    public var csvLine: String {
        let firstEvent = firstEventTimeSeconds.map { String(format: "%.2f", $0) } ?? ""
        let floorMin = floorMinDBFS.isNaN ? "" : String(format: "%.2f", floorMinDBFS)
        let floorMax = floorMaxDBFS.isNaN ? "" : String(format: "%.2f", floorMaxDBFS)
        let floorMean = floorMeanDBFS.isNaN ? "" : String(format: "%.2f", floorMeanDBFS)
        let peak = peakDBFS.isInfinite ? "" : String(format: "%.2f", peakDBFS)
        return [
            clipName,
            String(format: "%.2f", durationSeconds),
            "\(nEvents)",
            firstEvent,
            floorMin,
            floorMax,
            floorMean,
            peak
        ].joined(separator: ",")
    }
}
