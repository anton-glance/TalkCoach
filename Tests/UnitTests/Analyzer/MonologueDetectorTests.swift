// swiftlint:disable file_length
import XCTest
@testable import TalkCoach

// MARK: - MonologueMockClock

private final class MonologueMockClock: @unchecked Sendable {
    var current: Date

    init(reference: TimeInterval = 0) {
        current = Date(timeIntervalSinceReferenceDate: reference)
    }

    func now() -> Date { current }

    func advance(by seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }
}

// MARK: - MonologueFakeHideScheduler

@MainActor
private final class MonologueFakeHideScheduler: HideScheduler {
    private struct Entry {
        let token: HideSchedulerToken
        let delay: TimeInterval
        let action: @MainActor @Sendable () -> Void
    }

    private var entries: [Entry] = []
    private(set) var lastDelay: TimeInterval = 0

    var pendingCount: Int { entries.count }

    func schedule(
        delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> HideSchedulerToken {
        lastDelay = delay
        let token = HideSchedulerToken()
        entries.append(Entry(token: token, delay: delay, action: action))
        return token
    }

    func cancel(_ token: HideSchedulerToken) {
        entries.removeAll { $0.token == token }
    }

    func fireNext() {
        guard !entries.isEmpty else { return }
        let entry = entries.removeFirst()
        entry.action()
    }
}

// MARK: - Helpers

@MainActor
private func makeSettings() -> SettingsStore {
    SettingsStore(userDefaults: UserDefaults(suiteName: UUID().uuidString)!)
}

private func speechStarted() -> VADTransitionEvent { .speechStarted(sessionTime: 0) }
private func speechStopped() -> VADTransitionEvent { .speechStopped(sessionTime: 0) }

// MARK: - MonologueDetectorTests

@MainActor
// swiftlint:disable:next type_body_length
final class MonologueDetectorTests: XCTestCase {

    // MARK: AC: No escalation before sessionActivated

    func testNoEscalationBeforeSessionActivated() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.notifyVADEvent(speechStarted())
        clock.advance(by: 70)
        fake.fireNext()

        XCTAssertEqual(sut.monologueLevel, 0, "events before sessionActivated must be ignored")
        XCTAssertEqual(fake.pendingCount, 0, "no timer scheduled before sessionActivated")
    }

    // MARK: AC: Streak starts on first speechStarted

    func testStreakStartsOnFirstSpeechStarted() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())
        XCTAssertEqual(fake.pendingCount, 1, "timer armed on first speechStarted")

        clock.advance(by: 0.5)
        fake.fireNext()

        XCTAssertEqual(sut.monologueLevel, 0)
        XCTAssertEqual(sut.streakSeconds, 0.5, accuracy: 0.001)
    }

    // MARK: AC: Level escalation at configured thresholds

    func testStreakCrossesLevel1AtThreshold() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()  // L1=1.0min → 60s
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())
        clock.advance(by: 61)
        fake.fireNext()

        XCTAssertEqual(sut.monologueLevel, 1, "streak of 61s must cross L1 (60s)")
    }

    func testStreakCrossesLevel2AtThreshold() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()  // L2=1.5min → 90s
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())
        clock.advance(by: 91)
        fake.fireNext()

        XCTAssertEqual(sut.monologueLevel, 2, "streak of 91s must cross L2 (90s)")
    }

    func testStreakCrossesLevel3AtThreshold() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()  // L3=2.5min → 150s
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())
        clock.advance(by: 151)
        fake.fireNext()

        XCTAssertEqual(sut.monologueLevel, 3, "streak of 151s must cross L3 (150s)")
    }

    // MARK: AC: Sub-threshold pause bridges the streak

    func testSubThresholdPauseDoesNotResetStreak() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()  // pauseThreshold=2.5s, L1=60s
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())
        clock.advance(by: 40)
        sut.notifyVADEvent(speechStopped())
        clock.advance(by: 2)  // 2s pause < 2.5s threshold — bridged
        sut.notifyVADEvent(speechStarted())
        clock.advance(by: 21)  // 40 + 2 + 21 = 63s elapsed from original streakStart
        fake.fireNext()

        XCTAssertEqual(sut.monologueLevel, 1,
            "sub-threshold pause must be bridged; 63s total elapsed → level 1")
    }

    func testSubThresholdPauseTimeCountsTowardStreak() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())
        clock.advance(by: 55)
        sut.notifyVADEvent(speechStopped())
        clock.advance(by: 2)   // bridged pause: 2s < 2.5s
        sut.notifyVADEvent(speechStarted())
        clock.advance(by: 4)   // total elapsed = 55 + 2 + 4 = 61s
        fake.fireNext()

        XCTAssertEqual(sut.streakSeconds, 61, accuracy: 0.1,
            "pause time is included in streak elapsed — 55+2+4 = 61s")
        XCTAssertEqual(sut.monologueLevel, 1)
    }

    // MARK: AC: Supra-threshold pause resets streak

    func testSupraThresholdPauseResetsStreakOnSpeechStarted() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()  // pauseThreshold=2.5s
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())
        clock.advance(by: 70)
        sut.notifyVADEvent(speechStopped())
        clock.advance(by: 3)  // 3s > 2.5s threshold
        sut.notifyVADEvent(speechStarted())  // path A reset

        // After reset, streakSeconds should be near 0 (just started)
        XCTAssertEqual(sut.monologueLevel, 0, "supra-threshold pause must reset level to 0")
        XCTAssertLessThan(sut.streakSeconds, 1.0, "streakSeconds must reset to ~0 after streak restart")

        // Timer should be freshly armed (one pending entry)
        XCTAssertEqual(fake.pendingCount, 1, "fresh timer must be armed after reset")

        // Firing the timer must work correctly (no stale token collision)
        clock.advance(by: 0.5)
        fake.fireNext()
        XCTAssertEqual(sut.monologueLevel, 0)
        XCTAssertEqual(sut.streakSeconds, 0.5, accuracy: 0.1)
    }

    func testTimerDetectsSupraThresholdPauseWithNoNewSpeechStarted() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())
        clock.advance(by: 70)
        // Let timer fire to get to level 1
        fake.fireNext()
        XCTAssertEqual(sut.monologueLevel, 1)

        sut.notifyVADEvent(speechStopped())
        clock.advance(by: 3)  // 3s > 2.5s threshold
        fake.fireNext()       // path B: timer detects oversized pause

        XCTAssertEqual(sut.monologueLevel, 0, "timer must detect oversized pause and reset")
        XCTAssertEqual(sut.streakSeconds, 0)
        XCTAssertEqual(fake.pendingCount, 0, "timer must NOT re-arm after idle reset")
    }

    // MARK: AC: Conversational pattern does not falsely escalate

    func testConversationalPatternDoesNotFalselyEscalate() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()  // pauseThreshold=2.5s
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        // 20 cycles: 2s speech, 3s pause (each pause > 2.5s threshold → resets streak)
        for _ in 0..<20 {
            sut.notifyVADEvent(speechStarted())
            clock.advance(by: 2)
            sut.notifyVADEvent(speechStopped())
            clock.advance(by: 3)
            fake.fireNext()  // timer fires during pause, detects reset
            // Drain any re-queued timers from after a potential speechStarted
            while fake.pendingCount > 0 { fake.fireNext() }
        }

        XCTAssertEqual(sut.monologueLevel, 0,
            "conversational pattern with supra-threshold gaps must never escalate")
    }

    func testConversationalYieldResetsLevelAfterEscalation() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())
        clock.advance(by: 70)
        fake.fireNext()
        XCTAssertEqual(sut.monologueLevel, 1, "setup: must reach level 1")

        sut.notifyVADEvent(speechStopped())
        clock.advance(by: 3)  // supra-threshold
        fake.fireNext()

        XCTAssertEqual(sut.monologueLevel, 0, "supra-threshold pause must reset level to 0")
    }

    // MARK: AC: Mis-ordered thresholds handled gracefully

    func testMisorderedThresholdsHandledGracefully() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()
        settings.monologueLevel1Minutes = 2.5  // 150s
        settings.monologueLevel2Minutes = 1.0  // 60s
        settings.monologueLevel3Minutes = 1.5  // 90s
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())
        clock.advance(by: 90)
        fake.fireNext()

        // Crossed L2(60s) and L3(90s) but not L1(150s) → level 2
        XCTAssertEqual(sut.monologueLevel, 2,
            "mis-ordered thresholds: filter count must be 2 (crossed 60s and 90s, not 150s)")
    }

    // MARK: AC: Timer-driven escalation with no new VAD event

    func testTimerDrivenEscalationWithNoNewVADEvent() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()  // L1=60s
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())  // ONE event only

        // No further VAD events; advance clock and drive ONLY the fake scheduler
        clock.advance(by: 61)
        fake.fireNext()  // reevaluate fires; detects 61s elapsed → level 1

        XCTAssertEqual(sut.monologueLevel, 1,
            "timer must escalate level with no VAD events after initial speechStarted")
        XCTAssertEqual(fake.pendingCount, 1, "timer must re-arm after escalation")
    }

    // MARK: AC: enterWaiting clears streak

    func testEnterWaitingClearsStreak() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())
        clock.advance(by: 70)
        fake.fireNext()
        XCTAssertEqual(sut.monologueLevel, 1, "setup: must reach level 1")

        sut.enterWaiting()

        XCTAssertEqual(sut.monologueLevel, 0, "enterWaiting must reset level to 0")
        XCTAssertEqual(sut.streakSeconds, 0)
        XCTAssertEqual(fake.pendingCount, 0, "enterWaiting must cancel timer token")
    }

    func testTimerIsNoOpAfterEnterWaiting() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())
        clock.advance(by: 70)
        sut.enterWaiting()
        // pendingCount is 0 after enterWaiting cancels; fireNext is safe but a no-op
        fake.fireNext()
        XCTAssertEqual(sut.monologueLevel, 0)
    }

    // MARK: AC: sessionEnded clears streak

    func testSessionEndedClearsStreak() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())
        clock.advance(by: 70)
        fake.fireNext()
        XCTAssertEqual(sut.monologueLevel, 1, "setup: must reach level 1")

        sut.sessionEnded()

        XCTAssertEqual(sut.monologueLevel, 0, "sessionEnded must reset level to 0")
        XCTAssertEqual(sut.streakSeconds, 0)
        XCTAssertEqual(fake.pendingCount, 0, "sessionEnded must cancel timer token")
    }

    func testTimerIsNoOpAfterSessionEnded() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())
        clock.advance(by: 70)
        sut.sessionEnded()
        // isActive is false; any stale timer fire is guarded
        fake.fireNext()
        XCTAssertEqual(sut.monologueLevel, 0)
        XCTAssertEqual(fake.pendingCount, 0)
    }

    // MARK: AC: Live settings change reflected on next evaluation

    func testLiveSettingsChangeReflectedOnNextEvaluation() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()
        settings.monologueLevel1Minutes = 1.0  // 60s
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())

        // Raise L1 to 2.0min (120s) mid-session
        settings.monologueLevel1Minutes = 2.0

        clock.advance(by: 70)  // 70s: would have been level 1 at 60s, but not at new 120s
        fake.fireNext()
        XCTAssertEqual(sut.monologueLevel, 0,
            "raised L1 to 120s; 70s elapsed must not trigger level 1")

        clock.advance(by: 55)  // 125s elapsed total > 120s new threshold
        fake.fireNext()
        // 125s crosses both L1=120s and L2=90s (defaults) → level 2, not 1
        XCTAssertEqual(sut.monologueLevel, 2,
            "125s elapsed crosses L1 (120s) and L2 (90s) → level 2; live settings change reflected")
    }

    // MARK: AC: Second session per launch (S039 lifecycle lesson)

    func testSecondSessionPerLaunchEscalatesCorrectly() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        // Session 1
        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())
        clock.advance(by: 70)
        fake.fireNext()
        XCTAssertEqual(sut.monologueLevel, 1, "session 1: must reach level 1")
        sut.sessionEnded()
        XCTAssertEqual(sut.monologueLevel, 0, "session 1 ended: level must be 0")
        XCTAssertEqual(fake.pendingCount, 0, "session 1 ended: no pending timer")

        // Session 2 — must behave identically to session 1
        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())
        clock.advance(by: 70)
        fake.fireNext()
        XCTAssertEqual(sut.monologueLevel, 1,
            "session 2: must escalate correctly — no stale state from session 1")
    }

    // MARK: AC: streakSeconds tracks elapsed

    func testStreakSecondsTracksElapsedTime() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())
        clock.advance(by: 30)
        fake.fireNext()

        XCTAssertEqual(sut.streakSeconds, 30.0, accuracy: 0.001)
    }

    // MARK: Required Change 2: armTimer is a no-op when token already pending

    func testArmTimerIsNoOpWhenTokenAlreadyPending() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())  // arms timer → pendingCount 1
        XCTAssertEqual(fake.pendingCount, 1, "speechStarted must arm timer")

        sut.notifyVADEvent(speechStopped())   // calls armTimer unconditionally
        XCTAssertEqual(fake.pendingCount, 1,
            "speechStopped must not double-arm; guard in armTimer makes it a no-op")
    }

    // MARK: Required Change 1: supra-threshold reset cancels stale pending token

    func testSupraThresholdResetCancelsStalePendingToken() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())   // pendingCount 1
        XCTAssertEqual(fake.pendingCount, 1)

        sut.notifyVADEvent(speechStopped())   // pendingCount still 1
        XCTAssertEqual(fake.pendingCount, 1)

        clock.advance(by: 3)  // 3s > pauseThreshold(2.5s)
        sut.notifyVADEvent(speechStarted())  // path A: cancel stale, nil, rearm

        XCTAssertEqual(fake.pendingCount, 1,
            "path A reset must cancel stale token and arm exactly one fresh token")
        XCTAssertEqual(sut.monologueLevel, 0, "level must be 0 after reset")
    }

    // MARK: Required Change 4: Sub-threshold gaps sustained over 70s reach level 1
    // (documented limitation — see Risks in plan)

    func testSubThresholdGapsSustainedOver70sReachesLevel1() {
        // This is a DOCUMENTED LIMITATION: two speakers alternating with sub-threshold
        // inter-turn gaps (each gap < 2.5s) are indistinguishable from one speaker's
        // breath pauses. The streak bridges and escalates. Speaker diarization (v2/Spike #11)
        // is required to distinguish these cases. This test documents the INTENDED behavior.
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()  // pauseThreshold=2.5s, L1=60s
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        // 10 cycles: 5s speech, 2s gap (< 2.5s threshold → bridged)
        // Total elapsed from first streakStart: 10 × (5 + 2) = 70s
        for i in 0..<10 {
            sut.notifyVADEvent(speechStarted())
            clock.advance(by: 5)
            if i < 9 {  // no speechStopped on last cycle — leave speech active
                sut.notifyVADEvent(speechStopped())
                clock.advance(by: 2)
            }
        }
        fake.fireNext()

        XCTAssertEqual(sut.monologueLevel, 1,
            "sub-threshold gaps bridged: 70s elapsed from first streakStart must reach level 1 " +
            "(documented limitation: v1 cannot distinguish multi-speaker from single-speaker breath pauses)")
    }

    // MARK: AC: Post-sessionEnded VAD events are no-ops

    func testPostSessionEndedVADEventsAreNoOps() {
        let clock = MonologueMockClock()
        let fake = MonologueFakeHideScheduler()
        let settings = makeSettings()
        let sut = MonologueDetector(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.notifyVADEvent(speechStarted())
        clock.advance(by: 10)
        sut.sessionEnded()

        sut.notifyVADEvent(speechStarted())  // must be no-op (isActive = false)
        clock.advance(by: 70)
        fake.fireNext()

        XCTAssertEqual(sut.monologueLevel, 0,
            "VAD events after sessionEnded must be ignored (isActive guard)")
        XCTAssertEqual(fake.pendingCount, 0)
    }
}
