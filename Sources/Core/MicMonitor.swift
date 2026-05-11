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
    // nonisolated(unsafe) because deinit needs access for cleanup and AnyObject is non-Sendable.
    // Mutation only occurs on @MainActor (start/stop); deinit has exclusive ownership.
    nonisolated(unsafe) private var isRunningListenerToken: AnyObject?
    nonisolated(unsafe) private var defaultDeviceListenerToken: AnyObject?
    nonisolated(unsafe) private var processListToken: AnyObject?

    // MARK: External process tracking state (M3.7.1)

    private var externalTrackingActive: Bool = false
    private var externalMicState: ExternalMicState = .unknown
    private var pollTask: Task<Void, Never>?

    private enum ExternalMicState {
        case unknown, active, inactive
    }

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
        if let token = processListToken {
            provider.removeProcessObjectListListener(token: token)
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
        endExternalProcessTracking()
        cleanUpListeners()
        lastKnownRunningState = false
        monitoredDeviceID = nil
    }

    // MARK: - Handlers

    private func handleIsRunningChanged() {
        guard isRunning else { return }
        // When external tracking is active, the poll loop is the authoritative
        // signal. IsRunningSomewhere always returns true while AudioPipeline holds
        // its own I/O proc, so the listener adds no information in that mode.
        guard !externalTrackingActive else { return }
        guard let deviceID = monitoredDeviceID else { return }
        let running = provider.isDeviceRunningSomewhere(deviceID) ?? false
        guard running != lastKnownRunningState else { return }
        lastKnownRunningState = running
        Logger.mic.info("IsRunningSomewhere changed to \(running) on device \(deviceID)")
        emitStateChange(running: running)
    }

    private func handleDefaultDeviceChanged() {
        guard isRunning else { return }
        let newDeviceID = provider.defaultInputDeviceID()

        if newDeviceID == nil {
            Logger.mic.info("Default input device removed")
            detachIsRunningListener()
            monitoredDeviceID = nil
            if lastKnownRunningState {
                lastKnownRunningState = false
                emitStateChange(running: false)
            }
            return
        }

        guard newDeviceID != monitoredDeviceID else { return }

        Logger.mic.info("Default input device changed from \(String(describing: self.monitoredDeviceID)) to \(newDeviceID!)")

        detachIsRunningListener()
        monitoredDeviceID = newDeviceID
        let running = provider.isDeviceRunningSomewhere(newDeviceID!) ?? false
        attachIsRunningListener(to: newDeviceID!)

        if running != lastKnownRunningState {
            lastKnownRunningState = running
            emitStateChange(running: running)
        }
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

    // MARK: - External Process Tracking (M3.7.1)

    /// Called by SessionCoordinator after AudioPipeline.start() completes.
    /// Starts a 1 Hz poll of kAudioHardwarePropertyProcessObjectList to detect
    /// when all external processes release the mic without quitting (e.g., QuickTime
    /// stops recording but stays open). Also registers a ProcessObjectList listener
    /// for faster response to process joins/leaves.
    ///
    /// Empirical finding (Session 028 probes): kAudioProcessPropertyIsRunningInput
    /// accepts listener registration (addStatus=0) but never fires callbacks.
    /// kAudioDevicePropertyDeviceIsRunningSomewhere stays true while AudioPipeline
    /// holds its own I/O proc, making the existing listener useless during sessions.
    /// Polling at 1 Hz is the only reliable detection path.
    func beginExternalProcessTracking() {
        guard !externalTrackingActive else { return }
        externalTrackingActive = true
        externalMicState = .unknown

        processListToken = provider.addProcessObjectListListener { [weak self] in
            Task { @MainActor [weak self] in
                self?.executePollTick()
            }
        }

        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
                guard self != nil else { break }
                self?.executePollTick()
            }
        }
    }

    /// Called by SessionCoordinator in teardownWiring before AudioPipeline.stop().
    func endExternalProcessTracking() {
        guard externalTrackingActive else { return }
        externalTrackingActive = false

        pollTask?.cancel()
        pollTask = nil

        if let token = processListToken {
            provider.removeProcessObjectListListener(token: token)
            processListToken = nil
        }

        externalMicState = .unknown

        // Resync lastKnownRunningState so handleIsRunningChanged works correctly
        // after tracking ends (prevents spurious micDeactivated from the listener).
        if let deviceID = monitoredDeviceID {
            lastKnownRunningState = provider.isDeviceRunningSomewhere(deviceID) ?? false
        }
    }

    /// Performs one external-process poll tick. Internal access lets tests drive
    /// ticks directly without real timers.
    func executePollTick() {
        guard externalTrackingActive else { return }
        let active = checkExternalMicActive()
        updateExternalMicState(active)
    }

    // MARK: Private — external process detection

    private func checkExternalMicActive() -> Bool {
        let objs = provider.processObjects()
        let myPID = provider.selfPID()

        if objs.isEmpty {
            // BlackHole fallback: if the HAL process list is unavailable but
            // isDeviceRunningSomewhere is true, treat as "external reader present"
            // to avoid a false micDeactivated. Handles edge cases where process
            // enumeration is not supported or returns nothing unexpectedly.
            return provider.isDeviceRunningSomewhere(monitoredDeviceID ?? 0) ?? false
        }

        // Re-enumerate on every tick (Correction 3): mid-session joiner is detected
        // without waiting for a ProcessObjectList notification.
        for obj in objs {
            guard let p = provider.pid(of: obj), p != myPID else { continue }
            if provider.isProcessRunningInput(obj) { return true }
        }
        return false
    }

    private func updateExternalMicState(_ active: Bool) {
        switch externalMicState {
        case .unknown:
            externalMicState = active ? .active : .inactive
            if !active {
                Logger.mic.info("External tracking: no external readers on first tick — ending session")
                lastKnownRunningState = false
                delegate?.micDeactivated()
            }
        case .active:
            if !active {
                externalMicState = .inactive
                Logger.mic.info("External tracking: all external readers released mic")
                lastKnownRunningState = false
                delegate?.micDeactivated()
            }
        case .inactive:
            if active {
                externalMicState = .active
                Logger.mic.info("External tracking: new external reader joined mid-session")
                // Already in an active session — no micActivated emission
            }
        }
    }
}
