import CoreAudio
import OSLog

/// Probes whether any other process is using the default input device.
/// Returns `true` if the mic is in use (another app has it open), `false` if free.
///
/// Called after AudioPipeline teardown + HAL settling wait. The distinction drives
/// the disconnect-probe-reconnect decision:
///   false → no other app using mic → finalize session
///   true  → another app IS using mic → resume session into same SessionRecord
protocol MicAvailabilityProbing: Sendable {
    func probe() async -> Bool
}

// MARK: - Production Implementation

struct SystemMicAvailabilityProber: MicAvailabilityProbing {
    private let provider: CoreAudioDeviceProvider

    init(provider: CoreAudioDeviceProvider = SystemCoreAudioDeviceProvider()) {
        self.provider = provider
    }

    func probe() async -> Bool {
        guard let deviceID = provider.defaultInputDeviceID() else {
            Logger.mic.info("MicAvailabilityProber: no default input device — treating as free")
            return false
        }
        let running = provider.isDeviceRunningSomewhere(deviceID) ?? false
        Logger.mic.info("MicAvailabilityProber: IRS=\(running) on device \(deviceID)")
        return running
    }
}
