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
struct SessionWiring {
    let audioPipeline: AudioPipeline
    let languageDetector: any LanguageDetecting
    let appleBackendFactory: any AppleBackendFactory
    let parakeetBackendFactory: any ParakeetBackendFactory
    let supportedLocalesProvider: any SupportedLocalesProvider
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
    case micFreedExternally = "mic-freed-externally"
}

// MARK: - CaptureActivityState

enum CaptureActivityState: Equatable {
    case waiting
}

// MARK: - SessionCoordinator

/// Orchestrates session lifecycle. When the mic activates, wires the audio pipeline,
/// language detector, and transcription engine. While active, polls `AudioProcessProber`
/// every `probePollIntervalSeconds`: if an external reader appears (another app claims
/// the mic), ends the session with `.micFreedExternally`.
@MainActor
// swiftlint:disable:next type_body_length
final class SessionCoordinator: ObservableObject {
    @Published private(set) var state: SessionState = .idle
    // Intentionally non-private setter: tests set this directly to verify the idle guard.
    // Production code: only SessionCoordinator sets this property.
    @Published var lastTokenArrival: Date?
    @Published var lastEngineReadyAt: Date?
    @Published var isInTokenSilence: Bool = false
    @Published private(set) var captureActivityState: CaptureActivityState = .waiting
    @Published private(set) var isRecovering: Bool = false
    private(set) var lastEndReason: SessionEndReason?
    private(set) var isRunning: Bool = false

    private let micMonitor: MicMonitor
    private let settingsStore: SettingsStore
    private let tokenSilenceScheduler: any HideScheduler
    private var tokenSilenceToken: HideSchedulerToken?
    private var endedSessionHandlers: [@MainActor (EndedSession) -> Void] = []
    private var coachingEnabledCancellable: AnyCancellable?

    // MARK: Wiring (optional — nil in unit tests that skip the audio pipeline)

    var wiring: SessionWiring?
    private var consumers: [any TokenConsumer] = []

    // Exposed as private(set) so tests can `await sut.sessionWiringTask?.value`
    // to synchronise on wiring completion without polling.
    private(set) var sessionWiringTask: Task<Void, Never>?
    private(set) var engineReadyTask: Task<Void, Never>?
    private var localeMonitorTask: Task<Void, Never>?
    private var relayTask: Task<Void, Never>?
    private var activeEngine: TranscriptionEngine?
    private var activePipeline: AudioPipeline?

    // Per-session measurement state — reset at start/end of each wiring cycle.
    private var sessionStartTime: Date?
    private var currentLocale: Locale?
    private var sessionTokenCount = 0

    // MARK: Poll state

    let audioProcessProber: (any AudioProcessProber)?
    private(set) var pollTask: Task<Void, Never>?

    // MARK: System events

    private let systemEventObserver: (any SystemEventObserving)?

    // MARK: Init

    var currentSession: SessionContext? {
        if case .active(let ctx) = state { return ctx } else { return nil }
    }

    init(
        micMonitor: MicMonitor,
        settingsStore: SettingsStore,
        audioProcessProber: (any AudioProcessProber)? = nil,
        systemEventObserver: (any SystemEventObserving)? = nil,
        tokenSilenceScheduler: any HideScheduler = DispatchHideScheduler()
    ) {
        self.micMonitor = micMonitor
        self.settingsStore = settingsStore
        self.audioProcessProber = audioProcessProber
        self.systemEventObserver = systemEventObserver
        self.tokenSilenceScheduler = tokenSilenceScheduler
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
                    self.endCurrentSession(reason: .coachingDisabled)
                }
            }

        systemEventObserver?.start(
            onSleep: { [weak self] in
                guard let self else { return }
                Logger.session.info("SessionCoordinator: system sleep — ending active session")
                self.endCurrentSession(reason: .sleep)
            },
            onShutdown: { [weak self] in
                guard let self else { return }
                Logger.session.info("SessionCoordinator: system shutdown — ending active session")
                self.endCurrentSession(reason: .shutdown)
            }
        )
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        Logger.session.info("SessionCoordinator stopping")

        coachingEnabledCancellable = nil
        systemEventObserver?.stop()

        if case .active = state {
            endCurrentSession(reason: .quit)
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

    /// Called by AudioPipeline when a recovery cycle begins.
    func audioPipelineDidBeginRecovery() {
        isRecovering = true
    }

    /// Called by AudioPipeline when a recovery cycle completes.
    func audioPipelineDidEndRecovery() {
        isRecovering = false
    }

    /// Ends the current session immediately. Called from the widget X-button (AC-13).
    func requestFinalize() {
        guard case .active = state else { return }
        Logger.session.info("SessionCoordinator: requestFinalize() — ending session on user request")
        endCurrentSession(reason: .xButton)
    }

    // MARK: Private — poll timer

    private func startPollTimer() {
        guard let prober = audioProcessProber else { return }
        let ourPID = getpid()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                let interval = self.settingsStore.probePollIntervalSeconds
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                guard case .active = self.state else { break }
                let readers = await prober.externalReaders(excluding: ourPID)
                if Task.isCancelled { break }
                if readers.isEmpty {
                    Logger.session.info("SessionCoordinator: poll — no external readers → ending session (.micFreedExternally)")
                    self.endCurrentSession(reason: .micFreedExternally)
                    break
                }
                Logger.session.debug("SessionCoordinator: poll — \(readers.count) external reader(s) present — session continues")
            }
        }
    }

    private func stopPollTimer() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Private — session lifecycle

    private func endCurrentSession(reason: SessionEndReason = .micOffListener) {
        stopPollTimer()
        if let token = tokenSilenceToken {
            tokenSilenceScheduler.cancel(token)
            tokenSilenceToken = nil
        }
        isInTokenSilence = false
        guard case .active(let ctx) = state else { return }
        let ended = EndedSession(id: ctx.id, startedAt: ctx.startedAt, endedAt: Date())
        state = .idle
        lastTokenArrival = nil
        captureActivityState = .waiting
        lastEndReason = reason
        Logger.session.info("Session ended: \(ended.id) reason=\(reason.rawValue) duration \(ended.endedAt.timeIntervalSince(ended.startedAt), format: .fixed(precision: 1))s")
        for handler in endedSessionHandlers {
            handler(ended)
        }

        guard wiring != nil else { return }
        Task { [weak self] in await self?.teardownWiring() }
    }

    // MARK: Private — wiring sequence

    // swiftlint:disable:next function_body_length
    private func runSession() async {
        guard let capturedWiring = wiring else { return }
        let wiringStart = Date()
        sessionStartTime = wiringStart
        sessionTokenCount = 0

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

        // Spawn engineReadyTask in parallel with relay/locale/poll so runSession() exits
        // immediately after engine.start() — relayTask and pollTask are not gated on engine-ready.
        engineReadyTask = Task { [weak self] in
            for await _ in engine.engineReadyStream {
                self?.handleEngineReadyEvent()
                break
            }
        }
        localeMonitorTask = Task { [weak self] in await self?.monitorLocaleChanges() }
        relayTask = Task { [weak self] in await self?.relayTokens(from: engine) }
        startPollTimer()

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
            let t0Ns = DispatchTime.now().uptimeNanoseconds
            lastTokenArrival = Date()
            isInTokenSilence = false

            // Cancel old silence timer, arm new 2s one.
            if let prev = tokenSilenceToken { tokenSilenceScheduler.cancel(prev) }
            tokenSilenceToken = tokenSilenceScheduler.schedule(delay: 2.0) { [weak self] in
                self?.isInTokenSilence = true
            }

            Logger.session.info("Token observed at coordinator: t0=\(t0Ns)ns token='\(token.token)' isFinal=\(token.isFinal)")

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

    private func handleEngineReadyEvent() {
        lastEngineReadyAt = Date()
        Logger.session.info("SessionCoordinator: engine-ready event received from backend")
    }

    private func teardownWiring() async {
        let teardownStart = Date()
        let sessionMs = sessionStartTime.map { Int(teardownStart.timeIntervalSince($0) * 1000) } ?? 0

        sessionWiringTask?.cancel()
        engineReadyTask?.cancel()
        engineReadyTask = nil
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
        guard case .active = state else { return }
        endCurrentSession(reason: .micOffListener)
    }
}
