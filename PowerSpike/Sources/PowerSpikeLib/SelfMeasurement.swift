import Darwin
import Foundation

public struct MeasurementRow: Sendable {
    public let elapsedSeconds: TimeInterval
    public let cpuUserPercent: Double
    public let cpuSystemPercent: Double
    public let cpuTotalPercent: Double
    public let rssMB: Double
    public let wordsTotal: Int
    public let speakingDurationSeconds: Double
    public let avgWPM: Double
    public let rmsAvg: Double
    public let thermalState: Int
    public let marker: String

    public init(
        elapsedSeconds: TimeInterval,
        cpuUserPercent: Double,
        cpuSystemPercent: Double,
        cpuTotalPercent: Double,
        rssMB: Double,
        wordsTotal: Int,
        speakingDurationSeconds: Double,
        avgWPM: Double,
        rmsAvg: Double,
        thermalState: Int,
        marker: String
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.cpuUserPercent = cpuUserPercent
        self.cpuSystemPercent = cpuSystemPercent
        self.cpuTotalPercent = cpuTotalPercent
        self.rssMB = rssMB
        self.wordsTotal = wordsTotal
        self.speakingDurationSeconds = speakingDurationSeconds
        self.avgWPM = avgWPM
        self.rmsAvg = rmsAvg
        self.thermalState = thermalState
        self.marker = marker
    }

    public var csvLine: String {
        let fields: [String] = [
            String(format: "%.1f", elapsedSeconds),
            String(format: "%.2f", cpuUserPercent),
            String(format: "%.2f", cpuSystemPercent),
            String(format: "%.2f", cpuTotalPercent),
            String(format: "%.1f", rssMB),
            "\(wordsTotal)",
            String(format: "%.1f", speakingDurationSeconds),
            String(format: "%.1f", avgWPM),
            String(format: "%.6f", rmsAvg),
            "\(thermalState)",
            marker,
        ]
        return fields.joined(separator: ",")
    }

    public static let csvHeader =
        "elapsed_s,cpu_user_pct,cpu_system_pct,cpu_total_pct,rss_mb,words_total,speaking_duration_s,avg_wpm,rms_avg,thermal_state,marker"
}

public struct CPUSnapshot: Sendable {
    public let userTimeMicroseconds: UInt64
    public let systemTimeMicroseconds: UInt64
    public let wallTime: TimeInterval

    public init() {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(
                to: integer_t.self, capacity: Int(count)
            ) { intPtr in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    intPtr,
                    &count
                )
            }
        }
        if result == KERN_SUCCESS {
            userTimeMicroseconds =
                UInt64(info.user_time.seconds) * 1_000_000
                + UInt64(info.user_time.microseconds)
            systemTimeMicroseconds =
                UInt64(info.system_time.seconds) * 1_000_000
                + UInt64(info.system_time.microseconds)
        } else {
            userTimeMicroseconds = 0
            systemTimeMicroseconds = 0
        }
        wallTime = ProcessInfo.processInfo.systemUptime
    }
}

public struct SelfMeasurement: Sendable {
    private let logicalCores: Int

    public init() {
        logicalCores = ProcessInfo.processInfo.activeProcessorCount
    }

    public func cpuPercent(
        from previous: CPUSnapshot, to current: CPUSnapshot
    ) -> (user: Double, system: Double) {
        let wallDelta = current.wallTime - previous.wallTime
        guard wallDelta > 0 else { return (0, 0) }

        let userDelta = Double(
            current.userTimeMicroseconds - previous.userTimeMicroseconds
        ) / 1_000_000.0
        let systemDelta = Double(
            current.systemTimeMicroseconds - previous.systemTimeMicroseconds
        ) / 1_000_000.0

        let userPct = (userDelta / wallDelta) * 100.0
        let systemPct = (systemDelta / wallDelta) * 100.0
        return (userPct, systemPct)
    }

    public func rssMB() -> Double {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(
                to: integer_t.self, capacity: Int(count)
            ) { intPtr in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    intPtr,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / (1024.0 * 1024.0)
    }

    public func thermalState() -> Int {
        ProcessInfo.processInfo.thermalState.rawValue
    }
}
