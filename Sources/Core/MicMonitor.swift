import CoreAudio
import OSLog

@MainActor
final class MicMonitor {
    weak var delegate: (any MicMonitorDelegate)?
    private(set) var isRunning: Bool = false

    private let provider: CoreAudioDeviceProvider

    init(provider: CoreAudioDeviceProvider) {
        self.provider = provider
    }

    func start() {}
    func stop() {}
}
