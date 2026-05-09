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

/// Bundles the five injectable dependencies for the audio → transcription pipeline.
/// Nil by default; set before start() for sessions that require token delivery.
struct SessionWiring {
    let audioPipeline: AudioPipeline
    let languageDetector: any LanguageDetecting
    let appleBackendFactory: any AppleBackendFactory
    let parakeetBackendFactory: any ParakeetBackendFactory
    let supportedLocalesProvider: any SupportedLocalesProvider
}

// MARK: - SessionCoordinator

/// Orchestrates session lifecycle: receives `MicMonitor` activation events,
/// gates session creation on `coachingEnabled`, and exposes session state
/// for SwiftUI consumers and one-shot end-of-session subscribers.
///
/// When `wiring` is set, `micActivated()` also launches the four-step pipeline:
///   AudioPipeline → LanguageDetector → TranscriptionEngine → TokenConsumer fan-out.
@MainActor
final class SessionCoordinator: ObservableObject {
    @Published private(set) var state: SessionState = .idle
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

    // MARK: Init

    var currentSession: SessionContext? {
        if case .active(let ctx) = state { return ctx } else { return nil }
    }

    init(micMonitor: MicMonitor, settingsStore: SettingsStore) {
        self.micMonitor = micMonitor
        self.settingsStore = settingsStore
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
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        Logger.session.info("SessionCoordinator stopping")

        coachingEnabledCancellable = nil

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

    // MARK: Private — session lifecycle

    private func endCurrentSession() {
        guard case .active(let ctx) = state else { return }
        let ended = EndedSession(id: ctx.id, startedAt: ctx.startedAt, endedAt: Date())
        state = .idle
        Logger.session.info("Session ended: \(ended.id) duration \(ended.endedAt.timeIntervalSince(ended.startedAt), format: .fixed(precision: 1))s")
        for handler in endedSessionHandlers {
            handler(ended)
        }

        guard wiring != nil else { return }
        Logger.session.info("SessionCoordinator: micDeactivated — tearing down session")
        Task { [weak self] in await self?.teardownWiring() }
    }

    // MARK: Private — wiring sequence

    private func runSession() async {
        guard let w = wiring else { return }

        // Step 1: AudioPipeline
        do {
            try w.audioPipeline.start()
            Logger.session.info("SessionCoordinator: AudioPipeline started")
        } catch {
            Logger.session.error("SessionCoordinator: wiring failed at AudioPipeline.start: \(error)")
            return
        }

        // Step 2: LanguageDetector
        let locale: Locale
        do {
            locale = try await w.languageDetector.start()
            Logger.session.info("SessionCoordinator: LanguageDetector detected \(locale.identifier)")
        } catch {
            w.audioPipeline.stop()
            Logger.session.error("SessionCoordinator: wiring failed at LanguageDetector.start: \(error)")
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
                audioBufferProvider: AudioPipelineBufferProvider(pipeline: w.audioPipeline),
                appleBackendFactory: w.appleBackendFactory,
                parakeetBackendFactory: w.parakeetBackendFactory,
                supportedLocalesProvider: w.supportedLocalesProvider
            )
        } catch {
            await w.languageDetector.stop()
            w.audioPipeline.stop()
            Logger.session.error("SessionCoordinator: wiring failed at TranscriptionEngine.init: \(error)")
            return
        }

        // Step 4: TranscriptionEngine start
        do {
            try await engine.start()
            Logger.session.info("SessionCoordinator: TranscriptionEngine started [\(locale.identifier)]")
        } catch {
            await engine.stop()
            await w.languageDetector.stop()
            w.audioPipeline.stop()
            Logger.session.error("SessionCoordinator: wiring failed at TranscriptionEngine.start: \(error)")
            return
        }

        activeEngine = engine
        localeMonitorTask = Task { [weak self] in await self?.monitorLocaleChanges() }
        relayTask = Task { [weak self] in await self?.relayTokens(from: engine) }
    }

    private func monitorLocaleChanges() async {
        guard let w = wiring else { return }
        for await newLocale in w.languageDetector.localeChange {
            // Locale-swap live re-routing is deferred to M3.8. Log only.
            Logger.session.info("SessionCoordinator: locale change detected (\(newLocale.identifier)) — deferred to M3.8")
        }
    }

    private func relayTokens(from engine: TranscriptionEngine) async {
        for await token in engine.tokenStream {
            if Task.isCancelled { break }
            Logger.session.debug("SessionCoordinator: token '\(token.token)' t=[\(token.startTime, format: .fixed(precision: 2))–\(token.endTime, format: .fixed(precision: 2))] final=\(token.isFinal)")
            for consumer in consumers {
                await consumer.consume(token)
            }
        }
    }

    private func teardownWiring() async {
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

        if let w = wiring {
            await w.languageDetector.stop()
            w.audioPipeline.stop()
        }

        for consumer in consumers {
            await consumer.sessionEnded()
        }

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
        endCurrentSession()
    }
}
