import CoreAudio
import OSLog

/// Monitors the system's default input device for running-state transitions
/// and fires delegate callbacks marshaled to `@MainActor`.
@MainActor
final class MicMonitor {
    weak var delegate: (any MicMonitorDelegate)?
    private(set) var isRunning: Bool = false

    private let provider: CoreAudioDeviceProvider
    private var lastKnownRunningState: Bool = false
    private var monitoredDeviceID: AudioObjectID?
    // Set to now+2s when a default-device change fires. Suppresses handleIsRunningChanged()
    // within the window to prevent a double-rebuild race (AC-SW5).
    private var deviceChangeUntil: Date = .distantPast
    // nonisolated(unsafe) because deinit needs access for cleanup and AnyObject is non-Sendable.
    // Mutation only occurs on @MainActor (start/stop); deinit has exclusive ownership.
    nonisolated(unsafe) private var isRunningListenerToken: AnyObject?
    nonisolated(unsafe) private var defaultDeviceListenerToken: AnyObject?

    init(provider: CoreAudioDeviceProvider = SystemCoreAudioDeviceProvider()) {
        self.provider = provider
    }

    deinit {
        if let token = isRunningListenerToken, let deviceID = monitoredDeviceID {
            provider.removeIsRunningListener(device: deviceID, token: token)
        }
        if let token = defaultDeviceListenerToken {
            provider.removeDefaultDeviceListener(token: token)
        }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Logger.mic.info("MicMonitor starting")

        attachDefaultDeviceListener()

        guard let deviceID = provider.defaultInputDeviceID() else {
            Logger.mic.info("No default input device available at start")
            return
        }

        monitoredDeviceID = deviceID
        let running = provider.isDeviceRunningSomewhere(deviceID) ?? false
        lastKnownRunningState = running

        if running {
            Logger.mic.info("Device \(deviceID) already running at start — emitting micActivated")
            delegate?.micActivated()
        }

        attachIsRunningListener(to: deviceID)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        Logger.mic.info("MicMonitor stopping")
        cleanUpListeners()
        lastKnownRunningState = false
        monitoredDeviceID = nil
    }

    // MARK: - Handlers

    private func handleIsRunningChanged() {
        guard isRunning else { return }
        // Suppress within the device-change settle window to prevent a double-rebuild race (AC-SW5).
        guard Date() >= deviceChangeUntil else { return }
        guard let deviceID = monitoredDeviceID else { return }
        let running = provider.isDeviceRunningSomewhere(deviceID) ?? false
        guard running != lastKnownRunningState else { return }
        lastKnownRunningState = running
        Logger.mic.info("IsRunningSomewhere changed to \(running) on device \(deviceID)")
        emitStateChange(running: running)
    }

    private func handleDefaultDeviceChanged() {
        guard isRunning else { return }

        // Arm the settle window unconditionally — suppresses handleIsRunningChanged() for 2s (AC-SW5).
        deviceChangeUntil = Date().addingTimeInterval(2.0)

        let newDeviceID = provider.defaultInputDeviceID()

        if newDeviceID == nil {
            Logger.mic.info("Default input device removed (AC-SW6) — routing via micDeviceChanged")
            detachIsRunningListener()
            monitoredDeviceID = nil
            delegate?.micDeviceChanged()
            return
        }

        guard newDeviceID != monitoredDeviceID else { return }

        Logger.mic.info("Default input device changed from \(String(describing: self.monitoredDeviceID)) to \(newDeviceID!) (AC-SW6)")

        detachIsRunningListener()
        monitoredDeviceID = newDeviceID
        attachIsRunningListener(to: newDeviceID!)

        // Route via micDeviceChanged() so coordinator drives the switch (AC-SW6).
        delegate?.micDeviceChanged()
    }

    // MARK: - Listener Management

    private func attachIsRunningListener(to deviceID: AudioObjectID) {
        isRunningListenerToken = provider.addIsRunningListener(device: deviceID) { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleIsRunningChanged()
            }
        }
        if isRunningListenerToken == nil {
            Logger.mic.warning("Failed to attach IsRunning listener on device \(deviceID)")
        }
    }

    private func detachIsRunningListener() {
        guard let token = isRunningListenerToken, let deviceID = monitoredDeviceID else { return }
        provider.removeIsRunningListener(device: deviceID, token: token)
        isRunningListenerToken = nil
    }

    private func attachDefaultDeviceListener() {
        defaultDeviceListenerToken = provider.addDefaultDeviceListener { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleDefaultDeviceChanged()
            }
        }
        if defaultDeviceListenerToken == nil {
            Logger.mic.warning("Failed to attach default-device listener")
        }
    }

    private func cleanUpListeners() {
        detachIsRunningListener()
        if let token = defaultDeviceListenerToken {
            provider.removeDefaultDeviceListener(token: token)
            defaultDeviceListenerToken = nil
        }
    }

    // MARK: - Emission

    private func emitStateChange(running: Bool) {
        if running {
            delegate?.micActivated()
        } else {
            delegate?.micDeactivated()
        }
    }

}
