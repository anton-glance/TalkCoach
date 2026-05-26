import Combine
import Foundation
import OSLog

/// Continuous-speaking-streak detector driven by Silero VAD transitions.
///
/// Emits monologueLevel (0…3) when the user has been speaking without a
/// supra-threshold yield. Sub-threshold pauses bridge the streak; supra-threshold
/// pauses reset it. Level thresholds are read live from SettingsStore each tick.
///
/// v1 limitation: sub-threshold gaps between speakers are indistinguishable from
/// single-speaker breath pauses and will bridge the streak (see Spike #11 / v2 diarization).
@MainActor
final class MonologueDetector {

    // MARK: - Dependencies

    private let settings: SettingsStore
    private let scheduler: any HideScheduler
    private let now: () -> Date

    // MARK: - Session state

    private var isActive = false
    private var streakStart: Date?
    private var pauseStartedAt: Date?
    private var timerToken: HideSchedulerToken?

    // MARK: - Published output

    @Published private(set) var monologueLevel: Int = 0
    @Published private(set) var streakSeconds: TimeInterval = 0

    // MARK: - Init

    init(
        settings: SettingsStore,
        scheduler: any HideScheduler,
        now: @escaping () -> Date = { Date() }
    ) {
        self.settings = settings
        self.scheduler = scheduler
        self.now = now
    }

    // MARK: - Session lifecycle

    func sessionActivated() {
        isActive = true
    }

    func enterWaiting() {
        cancelTimer()
        streakStart = nil
        pauseStartedAt = nil
        streakSeconds = 0
        monologueLevel = 0
    }

    func sessionEnded() {
        isActive = false
        cancelTimer()
        streakStart = nil
        pauseStartedAt = nil
        streakSeconds = 0
        monologueLevel = 0
    }

    // MARK: - VAD events

    func notifyVADEvent(_ event: VADTransitionEvent) {
        switch event {
        case .speechStarted:
            guard isActive else { return }
            if let pauseStart = pauseStartedAt {
                let pauseLength = now().timeIntervalSince(pauseStart)
                if pauseLength > settings.monologuePauseThreshold {
                    // Path A: supra-threshold pause — cancel stale token, reset streak
                    cancelTimer()
                    streakStart = nil
                    streakSeconds = 0
                    monologueLevel = 0
                    Logger.analyzer.info(
                        "monologue-vad: path-A reset; pauseLength=\(pauseLength, format: .fixed(precision: 1))s"
                    )
                }
                pauseStartedAt = nil
            }
            if streakStart == nil {
                streakStart = now()
            }
            armTimer()

        case .speechStopped:
            guard isActive else { return }
            pauseStartedAt = now()
            armTimer()  // no-op if already pending (guard in armTimer)
        }
    }

    // MARK: - Timer

    private func armTimer() {
        guard timerToken == nil else { return }
        timerToken = scheduler.schedule(delay: 1.0) { [weak self] in
            self?.onTimerFired()
        }
    }

    private func cancelTimer() {
        if let token = timerToken {
            scheduler.cancel(token)
            timerToken = nil
        }
    }

    private func onTimerFired() {
        timerToken = nil
        guard isActive else { return }
        guard let start = streakStart else { return }

        // Path B: timer detects a supra-threshold pause with no new speechStarted
        if let pauseStart = pauseStartedAt {
            let pauseLength = now().timeIntervalSince(pauseStart)
            if pauseLength > settings.monologuePauseThreshold {
                streakStart = nil
                pauseStartedAt = nil
                streakSeconds = 0
                monologueLevel = 0
                Logger.analyzer.info(
                    "monologue-timer: path-B reset; pauseLength=\(pauseLength, format: .fixed(precision: 1))s"
                )
                return  // do NOT re-arm — idle until next speechStarted
            }
        }

        let elapsed = now().timeIntervalSince(start)
        streakSeconds = elapsed
        let newLevel = computeLevel(elapsed)
        let prevLevel = monologueLevel
        monologueLevel = newLevel
        Logger.analyzer.info(
            "monologue-timer: elapsed=\(elapsed, format: .fixed(precision: 1))s level=\(newLevel) prevLevel=\(prevLevel)"
        )
        armTimer()  // re-arm for next 1s cycle
    }

    // MARK: - Level computation

    private func computeLevel(_ elapsed: TimeInterval) -> Int {
        let l1 = settings.monologueLevel1Minutes * 60
        let l2 = settings.monologueLevel2Minutes * 60
        let l3 = settings.monologueLevel3Minutes * 60
        return [l1, l2, l3].filter { elapsed >= $0 }.count
    }
}
