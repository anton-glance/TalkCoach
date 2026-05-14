// swiftlint:disable file_length
import Combine
import OSLog

enum SessionState: Equatable {
    case idle
    case active(SessionContext)
}

struct SessionContext: Equatable {
    let id: UUID
    let startedAt: Date
}

struct EndedSession: Equatable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
}

// MARK: - SessionWiring

/// Bundles the injectable dependencies for the audio → transcription pipeline.
/// `resumePipelineProvider` is optional: nil means the initial pipeline instance
/// is used for the whole session (no probe-resume support). Pass a provider to
/// enable the disconnect-probe-reconnect algorithm — on IRS=true resume, a NEW
/// AudioPipeline is created from this provider because `stop()` closes the stream
/// and the same instance cannot be restarted.
struct SessionWiring {
    let audioPipeline: AudioPipeline
    let languageDetector: any LanguageDetecting
    let appleBackendFactory: any AppleBackendFactory
    let parakeetBackendFactory: any ParakeetBackendFactory
    let supportedLocalesProvider: any SupportedLocalesProvider
    let resumePipelineProvider: (any AudioEngineProvider)?

    init(
        audioPipeline: AudioPipeline,
        languageDetector: any LanguageDetecting,
        appleBackendFactory: any AppleBackendFactory,
        parakeetBackendFactory: any ParakeetBackendFactory,
        supportedLocalesProvider: any SupportedLocalesProvider,
        resumePipelineProvider: (any AudioEngineProvider)? = nil
    ) {
        self.audioPipeline = audioPipeline
        self.languageDetector = languageDetector
        self.appleBackendFactory = appleBackendFactory
        self.parakeetBackendFactory = parakeetBackendFactory
        self.supportedLocalesProvider = supportedLocalesProvider
        self.resumePipelineProvider = resumePipelineProvider
    }
}

// MARK: - SessionEndReason

enum SessionEndReason: String {
    case silenceAndMicOff = "silence-and-mic-off"
    case xButton = "x-button"
    case quit = "quit"
    case sleep = "sleep"
    case shutdown = "shutdown"
    case micOffListener = "mic-off-listener"
    case coachingDisabled = "coaching-disabled"
    case pipelineRestartFailed = "pipeline-restart-failed"
}

// MARK: - CaptureState

private enum CaptureState {
    case capturing
    case probing
}

// MARK: - SessionCoordinator

/// Orchestrates session lifecycle using the disconnect-probe-reconnect algorithm:
///
///   1. Tokens arrive → inactivity timer resets.
///   2. Silence for `inactivityThresholdSeconds` → probe begins (`captureState = .probing`):
///      a. AudioPipeline torn down (partial teardown — no consumer notification yet).
///      b. 100ms HAL settling wait (Spike #13.5: max observed 38–45ms).
///      c. `MicAvailabilityProbing.probe()` reads `kAudioDevicePropertyDeviceIsRunningSomewhere`.
///      d. IRS=false → no other app using mic → `finalizeSession()`.
///      e. IRS=true  → another app IS using mic → resume with new AudioPipeline + TE.
///
///   `probeInFlight` gates `micDeactivated()` during step c: AudioPipeline teardown drops
///   IRS after ~45ms, which fires MicMonitor's listener and calls `micDeactivated()`. Without
///   this guard, the probe would race against a duplicate finalization.
@MainActor
// swiftlint:disable:next type_body_length
final class SessionCoordinator: ObservableObject {
    @Published private(set) var state: SessionState = .idle
    // Intentionally non-private setter: tests set this directly to verify the idle guard.
    // Production code: only SessionCoordinator sets this property.
    @Published var lastTokenArrival: Date?
    private(set) var lastEndReason: SessionEndReason?
    private(set) var isRunning: Bool = false

    private let micMonitor: MicMonitor
    private let settingsStore: SettingsStore
    private var endedSessionHandlers: [@MainActor (EndedSession) -> Void] = []
    private var coachingEnabledCancellable: AnyCancellable?

    // MARK: Wiring (optional — nil in legacy / pre-M3.7 unit tests)

    var wiring: SessionWiring?
    private var consumers: [any TokenConsumer] = []

    // Exposed as private(set) so tests can `await sut.sessionWiringTask?.value`
    // to synchronise on wiring completion without polling.
    private(set) var sessionWiringTask: Task<Void, Never>?
    private var localeMonitorTask: Task<Void, Never>?
    private var relayTask: Task<Void, Never>?
    private var activeEngine: TranscriptionEngine?
    private var activePipeline: AudioPipeline?

    // Per-session measurement state — reset at start/end of each wiring cycle.
    private var sessionStartTime: Date?
    private var currentLocale: Locale?
    private var sessionTokenCount = 0
    private let inactivityTimer: any InactivityTimer

    // MARK: Probe algorithm state

    private let micProber: (any MicAvailabilityProbing)?
    private var probeInFlight = false
    private var captureState: CaptureState = .capturing
    private var probeCycleTask: Task<Void, Never>?

    // MARK: System events

    private let systemEventObserver: (any SystemEventObserving)?

    // MARK: Init

    var currentSession: SessionContext? {
        if case .active(let ctx) = state { return ctx } else { return nil }
    }

    init(
        micMonitor: MicMonitor,
        settingsStore: SettingsStore,
        inactivityTimer: any InactivityTimer = DispatchInactivityTimer(),
        micProber: (any MicAvailabilityProbing)? = nil,
        systemEventObserver: (any SystemEventObserving)? = nil
    ) {
        self.micMonitor = micMonitor
        self.settingsStore = settingsStore
        self.inactivityTimer = inactivityTimer
        self.micProber = micProber
        self.systemEventObserver = systemEventObserver
    }

    // MARK: Coordinator lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Logger.session.info("SessionCoordinator started")

        micMonitor.delegate = self
        micMonitor.start()

        coachingEnabledCancellable = settingsStore.$coachingEnabled
            .dropFirst()
            .sink { [weak self] newValue in
                guard let self else { return }
                if !newValue, case .active = self.state {
                    Logger.session.info("Coaching disabled mid-session — ending active session")
                    self.endCurrentSession()
                }
            }

        systemEventObserver?.start(
            onSleep: { [weak self] in
                guard let self else { return }
                Logger.session.info("SessionCoordinator: system sleep — ending active session")
                self.endCurrentSession()
            },
            onShutdown: { [weak self] in
                guard let self else { return }
                Logger.session.info("SessionCoordinator: system shutdown — ending active session")
                self.endCurrentSession()
            }
        )
    }

    func stop() {
        inactivityTimer.cancel()
        guard isRunning else { return }
        isRunning = false
        Logger.session.info("SessionCoordinator stopping")

        coachingEnabledCancellable = nil
        systemEventObserver?.stop()

        if case .active = state {
            endCurrentSession()
        }

        micMonitor.stop()
        micMonitor.delegate = nil
    }

    func onSessionEnded(_ handler: @escaping @MainActor (EndedSession) -> Void) {
        endedSessionHandlers.append(handler)
    }

    func addConsumer(_ consumer: any TokenConsumer) {
        consumers.append(consumer)
    }

    /// Ends the current session immediately. Called from the widget X-button (AC-13).
    func requestFinalize() {
        guard case .active = state else { return }
        Logger.session.info("SessionCoordinator: requestFinalize() — ending session on user request")
        endCurrentSession()
    }

    // MARK: Private — inactivity and probe

    private func handleInactivityTimeout() {
        Logger.session.info("SessionCoordinator: inactivity timeout fired")

        guard let prober = micProber, wiring != nil else {
            // No prober or no wiring → direct finalize (backward compat / no-wiring sessions)
            Logger.session.info("SessionCoordinator: no prober/wiring — finalizing immediately")
            endCurrentSession()
            return
        }

        guard case .active = state else { return }
        guard !probeInFlight else {
            Logger.session.info("SessionCoordinator: inactivity fired but probe already in flight — ignoring")
            return
        }

        probeInFlight = true
        captureState = .probing

        probeCycleTask = Task { [weak self] in
            await self?.runProbeCycle(prober: prober)
        }
    }

    private func runProbeCycle(prober: any MicAvailabilityProbing) async {
        guard let capturedWiring = wiring else {
            probeInFlight = false
            captureState = .capturing
            return
        }

        Logger.session.info("SessionCoordinator: probe cycle — partial teardown starting")

        // Partial teardown: stop pipeline so IRS drops, but do NOT notify consumers yet.
        sessionWiringTask?.cancel()
        localeMonitorTask?.cancel()
        relayTask?.cancel()

        await activeEngine?.stop()
        activeEngine = nil

        await relayTask?.value
        relayTask = nil
        localeMonitorTask = nil
        sessionWiringTask = nil

        activePipeline?.stop()
        activePipeline = nil

        // HAL settling wait: 100ms (Spike #13.5: max observed 38–45ms; 100ms is safe margin).
        // After AudioPipeline.stop(), IRS needs ~45ms to reflect the true value.
        try? await Task.sleep(for: .milliseconds(100))

        if Task.isCancelled {
            probeInFlight = false
            captureState = .capturing
            return
        }

        let irsTrue = await prober.probe()
        Logger.session.info("SessionCoordinator: probe result IRS=\(irsTrue) (true=another app using mic)")

        if Task.isCancelled {
            probeInFlight = false
            captureState = .capturing
            return
        }

        if irsTrue {
            // IRS=true → another app IS using the mic → resume into same session
            Logger.session.info("SessionCoordinator: IRS=true — resuming session (mic in use by another app)")
            await resumeSession(wiring: capturedWiring)
        } else {
            // IRS=false → no other app using mic → finalize session
            Logger.session.info("SessionCoordinator: IRS=false — finalizing session (mic is free)")
            finalizeAfterProbe(wiring: capturedWiring)
        }

        probeInFlight = false
        captureState = .capturing
    }

    // swiftlint:disable:next function_body_length
    private func resumeSession(wiring: SessionWiring) async {
        guard case .active = state else { return }

        // Resume requires a NEW AudioPipeline — stop() closes the AsyncStream continuation
        // and sets isStopped=true; the same instance cannot be restarted.
        let newPipeline: AudioPipeline
        if let provider = wiring.resumePipelineProvider {
            newPipeline = AudioPipeline(provider: provider)
        } else {
            newPipeline = AudioPipeline()
        }
        activePipeline = newPipeline

        // Resume wiring: use cached locale (skip LD.start() — deferred to M3.8)
        guard let locale = currentLocale else {
            Logger.session.error("SessionCoordinator: resume failed — no cached locale")
            finalizeAfterProbe(wiring: wiring)
            return
        }

        do {
            try newPipeline.start()
            Logger.session.info("SessionCoordinator: resume — new AudioPipeline started")
        } catch {
            Logger.session.error("SessionCoordinator: resume — AudioPipeline.start() failed: \(error)")
            finalizeAfterProbe(wiring: wiring)
            return
        }

        let engine: TranscriptionEngine
        do {
            engine = try await TranscriptionEngine(
                locale: locale,
                audioBufferProvider: AudioPipelineBufferProvider(pipeline: newPipeline),
                appleBackendFactory: wiring.appleBackendFactory,
                parakeetBackendFactory: wiring.parakeetBackendFactory,
                supportedLocalesProvider: wiring.supportedLocalesProvider
            )
        } catch {
            Logger.session.error("SessionCoordinator: resume — TranscriptionEngine.init failed: \(error)")
            newPipeline.stop()
            finalizeAfterProbe(wiring: wiring)
            return
        }

        do {
            try await engine.start()
            Logger.session.info("SessionCoordinator: resume — TranscriptionEngine started [\(locale.identifier)]")
        } catch {
            Logger.session.error("SessionCoordinator: resume — TranscriptionEngine.start() failed: \(error)")
            await engine.stop()
            newPipeline.stop()
            finalizeAfterProbe(wiring: wiring)
            return
        }

        activeEngine = engine
        localeMonitorTask = Task { [weak self] in await self?.monitorLocaleChanges() }
        relayTask = Task { [weak self] in await self?.relayTokens(from: engine) }

        let threshold = settingsStore.inactivityThresholdSeconds
        inactivityTimer.schedule(after: threshold) { [weak self] in
            self?.handleInactivityTimeout()
        }
        Logger.session.info("SessionCoordinator: resume complete [\(locale.identifier)] — inactivity timer rearmed for \(threshold)s")
    }

    private func finalizeAfterProbe(wiring: SessionWiring) {
        guard case .active(let ctx) = state else { return }
        let ended = EndedSession(id: ctx.id, startedAt: ctx.startedAt, endedAt: Date())
        state = .idle
        lastTokenArrival = nil
        Logger.session.info("Session ended (probe-finalize): \(ended.id) duration \(ended.endedAt.timeIntervalSince(ended.startedAt), format: .fixed(precision: 1))s")
        for handler in endedSessionHandlers { handler(ended) }

        Task { [weak self] in await self?.completeTeardown(wiring: wiring) }
    }

    // MARK: Private — session lifecycle

    private func endCurrentSession() {
        inactivityTimer.cancel()
        guard case .active(let ctx) = state else { return }
        let ended = EndedSession(id: ctx.id, startedAt: ctx.startedAt, endedAt: Date())
        state = .idle
        lastTokenArrival = nil
        Logger.session.info("Session ended: \(ended.id) duration \(ended.endedAt.timeIntervalSince(ended.startedAt), format: .fixed(precision: 1))s")
        for handler in endedSessionHandlers {
            handler(ended)
        }

        guard wiring != nil else { return }
        Logger.session.info("SessionCoordinator: micDeactivated — tearing down session")
        Task { [weak self] in await self?.teardownWiring() }
    }

    // MARK: Private — wiring sequence

    // swiftlint:disable:next function_body_length
    private func runSession() async {
        guard let capturedWiring = wiring else { return }
        let wiringStart = Date()
        sessionStartTime = wiringStart
        sessionTokenCount = 0

        let threshold = settingsStore.inactivityThresholdSeconds
        inactivityTimer.schedule(after: threshold) { [weak self] in
            self?.handleInactivityTimeout()
        }

        // Step 1: AudioPipeline
        do {
            try capturedWiring.audioPipeline.start()
            activePipeline = capturedWiring.audioPipeline
            Logger.session.info("SessionCoordinator: AudioPipeline started")
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(wiringStart) * 1000)
            Logger.session.error("SessionCoordinator: wiring failed at AudioPipeline.start after \(elapsedMs)ms: \(error). Rollback complete in 0ms.")
            sessionStartTime = nil
            return
        }

        // Step 2: LanguageDetector
        let locale: Locale
        do {
            locale = try await capturedWiring.languageDetector.start()
            Logger.session.info("SessionCoordinator: LanguageDetector detected \(locale.identifier)")
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(wiringStart) * 1000)
            let rollbackStart = Date()
            capturedWiring.audioPipeline.stop()
            activePipeline = nil
            let rollbackMs = Int(Date().timeIntervalSince(rollbackStart) * 1000)
            Logger.session.error("SessionCoordinator: wiring failed at LanguageDetector.start after \(elapsedMs)ms: \(error). Rollback complete in \(rollbackMs)ms.")
            sessionStartTime = nil
            return
        }

        // Step 3: TranscriptionEngine init
        // Sequential consumption invariant: LD.start() has returned above.
        // Strategy 3 (WhisperLID, isBlocking=true) is the only strategy that consumes
        // AudioPipeline.bufferStream; Strategies 1 & 2 use PartialTranscriptProvider only.
        // AudioPipeline.bufferStream is unicast — TranscriptionEngine subscribes safely here.
        let engine: TranscriptionEngine
        do {
            engine = try await TranscriptionEngine(
                locale: locale,
                audioBufferProvider: AudioPipelineBufferProvider(pipeline: capturedWiring.audioPipeline),
                appleBackendFactory: capturedWiring.appleBackendFactory,
                parakeetBackendFactory: capturedWiring.parakeetBackendFactory,
                supportedLocalesProvider: capturedWiring.supportedLocalesProvider
            )
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(wiringStart) * 1000)
            let rollbackStart = Date()
            await capturedWiring.languageDetector.stop()
            capturedWiring.audioPipeline.stop()
            activePipeline = nil
            let rollbackMs = Int(Date().timeIntervalSince(rollbackStart) * 1000)
            Logger.session.error("SessionCoordinator: wiring failed at TranscriptionEngine.init after \(elapsedMs)ms: \(error). Rollback complete in \(rollbackMs)ms.")
            sessionStartTime = nil
            return
        }

        // Step 4: TranscriptionEngine start
        do {
            try await engine.start()
            Logger.session.info("SessionCoordinator: TranscriptionEngine started [\(locale.identifier)]")
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(wiringStart) * 1000)
            let rollbackStart = Date()
            await engine.stop()
            await capturedWiring.languageDetector.stop()
            capturedWiring.audioPipeline.stop()
            activePipeline = nil
            let rollbackMs = Int(Date().timeIntervalSince(rollbackStart) * 1000)
            Logger.session.error("SessionCoordinator: wiring failed at TranscriptionEngine.start after \(elapsedMs)ms: \(error). Rollback complete in \(rollbackMs)ms.")
            sessionStartTime = nil
            return
        }

        activeEngine = engine
        currentLocale = locale
        localeMonitorTask = Task { [weak self] in await self?.monitorLocaleChanges() }
        relayTask = Task { [weak self] in await self?.relayTokens(from: engine) }

        let setupMs = Int(Date().timeIntervalSince(wiringStart) * 1000)
        Logger.session.info("SessionCoordinator: wiring complete in \(setupMs)ms — locale=\(locale.identifier), backend=\(engine.backendName)")
    }

    private func monitorLocaleChanges() async {
        guard let capturedWiring = wiring else { return }
        for await newLocale in capturedWiring.languageDetector.localeChange {
            let prevIdentifier = currentLocale?.identifier ?? "none"
            let elapsedMs = sessionStartTime.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0
            Logger.session.info("SessionCoordinator: locale change \(prevIdentifier)→\(newLocale.identifier) at \(elapsedMs)ms session time — deferred to M3.8")
            currentLocale = newLocale
        }
    }

    private func relayTokens(from engine: TranscriptionEngine) async {
        var windowStart = Date()
        var tokensInWindow = 0

        for await token in engine.tokenStream {
            if Task.isCancelled { break }
            Logger.session.debug("SessionCoordinator: token '\(token.token)' t=[\(token.startTime, format: .fixed(precision: 2))–\(token.endTime, format: .fixed(precision: 2))] final=\(token.isFinal)")
            sessionTokenCount += 1
            tokensInWindow += 1
            lastTokenArrival = Date()

            let threshold = settingsStore.inactivityThresholdSeconds
            inactivityTimer.schedule(after: threshold) { [weak self] in
                self?.handleInactivityTimeout()
            }
            for consumer in consumers {
                await consumer.consume(token)
            }

            let elapsed = Date().timeIntervalSince(windowStart)
            if elapsed >= 5.0 {
                let windowMs = Int(elapsed * 1000)
                let rate = Double(tokensInWindow) / elapsed
                Logger.session.info("SessionCoordinator: token rate = \(tokensInWindow) tokens in \(windowMs)ms (\(String(format: "%.1f", rate)) tok/s)")
                tokensInWindow = 0
                windowStart = Date()
            }
        }
    }

    private func teardownWiring() async {
        let teardownStart = Date()
        let sessionMs = sessionStartTime.map { Int(teardownStart.timeIntervalSince($0) * 1000) } ?? 0

        probeCycleTask?.cancel()
        sessionWiringTask?.cancel()
        localeMonitorTask?.cancel()
        relayTask?.cancel()

        // Stop engine first: engine.stop() finishes tokenStream, unblocking the relay loop.
        // Then await relay completion so any in-flight consume() call drains before sessionEnded.
        await activeEngine?.stop()
        activeEngine = nil

        await relayTask?.value
        relayTask = nil
        localeMonitorTask = nil
        sessionWiringTask = nil
        probeCycleTask = nil

        if let capturedWiring = wiring {
            await capturedWiring.languageDetector.stop()
        }
        activePipeline?.stop()
        activePipeline = nil

        for consumer in consumers {
            await consumer.sessionEnded()
        }

        let teardownMs = Int(Date().timeIntervalSince(teardownStart) * 1000)
        let totalTokens = sessionTokenCount
        let avgRate = sessionMs > 0 ? Double(totalTokens) / (Double(sessionMs) / 1000.0) : 0.0
        Logger.session.info("SessionCoordinator: session ended — duration=\(sessionMs)ms, total tokens=\(totalTokens), avg rate=\(String(format: "%.1f", avgRate)) tok/s, teardown=\(teardownMs)ms")

        sessionStartTime = nil
        currentLocale = nil
        sessionTokenCount = 0

        Logger.session.info("SessionCoordinator: session teardown complete")
    }

    private func completeTeardown(wiring: SessionWiring) async {
        // Called after probe-finalize: engine already stopped by probe cycle.
        // Only LD and consumer notification remain.
        await wiring.languageDetector.stop()
        for consumer in consumers {
            await consumer.sessionEnded()
        }
        sessionStartTime = nil
        currentLocale = nil
        sessionTokenCount = 0
        Logger.session.info("SessionCoordinator: probe-finalize teardown complete")
    }
}

// MARK: - MicMonitorDelegate

extension SessionCoordinator: MicMonitorDelegate {
    func micActivated() {
        guard settingsStore.coachingEnabled else {
            Logger.session.info("Mic activated, coaching disabled — ignoring")
            return
        }
        guard case .idle = state else {
            Logger.session.info("Mic activated but session already active — ignoring")
            return
        }
        let ctx = SessionContext(id: UUID(), startedAt: Date())
        state = .active(ctx)
        Logger.session.info("Session started: \(ctx.id) at \(ctx.startedAt)")

        guard wiring != nil else { return }
        Logger.session.info("SessionCoordinator: micActivated — starting wiring sequence")
        sessionWiringTask = Task { [weak self] in
            await self?.runSession()
        }
    }

    func micDeactivated() {
        guard !probeInFlight else {
            Logger.session.info("SessionCoordinator: micDeactivated suppressed — probe in flight (IRS settling after pipeline stop)")
            return
        }
        guard case .active = state else { return }
        endCurrentSession()
    }
}
