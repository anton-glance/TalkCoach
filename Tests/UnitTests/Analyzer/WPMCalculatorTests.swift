// swiftlint:disable file_length
import XCTest
@testable import TalkCoach

// MARK: - MockClock

private final class MockClock: @unchecked Sendable {
    var current: Date

    init(reference: TimeInterval = 0) {
        current = Date(timeIntervalSinceReferenceDate: reference)
    }

    func now() -> Date { current }

    func advance(by seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }
}

// MARK: - WPMFakeHideScheduler

@MainActor
private final class WPMFakeHideScheduler: HideScheduler {
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

private func makeToken(_ text: String) -> TranscribedToken {
    TranscribedToken(token: text, startTime: 0, endTime: 0.1, isFinal: true)
}

// MARK: - WPMCalculatorTests

@MainActor
// swiftlint:disable:next type_body_length
final class WPMCalculatorTests: XCTestCase {

    // MARK: AC1 — Warmup discard

    func testWarmupDiscardBeforeCutoff() async {
        let clock = MockClock(reference: 100)
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        // cutoff = t + 0.5
        sut.engineReadyFired(at: clock.current)

        // Open voice interval (sufficient to meet voiced-seconds floor if words counted)
        sut.notifyVADEvent(.speechStarted(sessionTime: 0))

        // now = 100.2 < cutoff 100.5 — token discarded
        clock.advance(by: 0.2)
        await sut.consume(makeToken("one two three four five"))

        // Advance past cutoff and close voice interval
        clock.advance(by: 0.5)
        clock.advance(by: 2.0)
        sut.notifyVADEvent(.speechStopped(sessionTime: 2.7))

        fake.fireNext()
        XCTAssertNil(sut.wpmRaw, "token before cutoff must be discarded")
        XCTAssertNil(sut.wpmVoiced, "token before cutoff must be discarded")
    }

    func testWarmupTokenCountedAfterCutoff() async {
        let clock = MockClock(reference: 100)
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        // cutoff = 100.5
        sut.engineReadyFired(at: clock.current)

        // Advance past cutoff
        clock.advance(by: 1.0)

        // Open voice interval covering >= 2s
        sut.notifyVADEvent(.speechStarted(sessionTime: 0))
        clock.advance(by: 3.0)

        // Feed 5 words — now (104) >= cutoff (100.5) — counted
        await sut.consume(makeToken("one two three four five"))

        fake.fireNext()
        XCTAssertNotNil(sut.wpmRaw, "token after cutoff must be counted")
        XCTAssertNotNil(sut.wpmVoiced, "token after cutoff must be counted")
    }

    // MARK: AC2 — Refresh cadence

    func testRefreshCadenceUsesScheduler() {
        let clock = MockClock()
        let settings = makeSettings()
        settings.wpmRefreshInterval = 3.0
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        XCTAssertEqual(fake.pendingCount, 0, "no scheduling before engineReady")

        sut.engineReadyFired(at: clock.current)

        XCTAssertEqual(fake.pendingCount, 1, "one action scheduled after engineReady")
        XCTAssertEqual(fake.lastDelay, 3.0, accuracy: 0.001)

        // Fire -> compute + re-schedule
        fake.fireNext()
        XCTAssertEqual(fake.pendingCount, 1, "recursive re-schedule after fire")
    }

    func testSessionEndedCancelsRefresh() async {
        let clock = MockClock()
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        sut.engineReadyFired(at: clock.current)
        XCTAssertEqual(fake.pendingCount, 1)

        await sut.sessionEnded()
        XCTAssertEqual(fake.pendingCount, 0, "refresh token cancelled on sessionEnded")
    }

    // MARK: AC3 — Dual math

    func testDualMathNoSilence() async {
        let clock = MockClock(reference: 0)
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        // engineReady at t=-1; cutoff = -0.5; all events are past cutoff
        sut.engineReadyFired(at: clock.current.addingTimeInterval(-1.0))

        // Open voice at t=1
        clock.advance(by: 1.0)
        sut.notifyVADEvent(.speechStarted(sessionTime: 0))

        // Advance 10s; computeAndPublish fires at t=11
        // Window cutoff = t+1; open interval = [t+1, t+11] = exactly 10s
        clock.advance(by: 10.0)
        await sut.consume(makeToken("one two three four five six seven eight nine ten"))

        fake.fireNext()

        // wpmRaw   = round(10 / (10/60)) = round(60) = 60
        // wpmVoiced = round(10 / (10/60)) = 60 (voiced == windowSeconds)
        XCTAssertEqual(sut.wpmRaw, 60)
        XCTAssertEqual(sut.wpmVoiced, 60)
    }

    func testDualMathWithPause() async {
        let clock = MockClock(reference: 0)
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        sut.engineReadyFired(at: clock.current.addingTimeInterval(-1.0))

        // Open voice at t=1
        clock.advance(by: 1.0)
        sut.notifyVADEvent(.speechStarted(sessionTime: 0))

        // Close voice at t=7 (6s voiced)
        clock.advance(by: 6.0)
        sut.notifyVADEvent(.speechStopped(sessionTime: 6))

        // Advance to t=11, feed 10 words
        clock.advance(by: 4.0)
        await sut.consume(makeToken("one two three four five six seven eight nine ten"))

        fake.fireNext()

        // Window = [t+1, t+11]; voiced = closed [t+1, t+7] = 6s (floor: 6s >= 2s)
        // wpmRaw   = round(10 / (10/60)) = 60 — flat 10s denominator
        // wpmVoiced = EMA-smoothed raw; first reading seeds to rawWPM = 60 (no prior smoothed)
        XCTAssertEqual(sut.wpmRaw, 60)
        XCTAssertEqual(sut.wpmVoiced, 60, "B seeds to rawWPM on first reading — voiced-seconds denominator removed")
    }

    // MARK: AC4 — Minimum-data floor

    func testBelowMinWordsBothNil() async {
        let clock = MockClock(reference: 0)
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        sut.engineReadyFired(at: clock.current.addingTimeInterval(-1.0))
        clock.advance(by: 1.0)

        sut.notifyVADEvent(.speechStarted(sessionTime: 0))
        clock.advance(by: 5.0)

        // 2 words < minWordsForReading=3
        await sut.consume(makeToken("one two"))

        fake.fireNext()
        XCTAssertNil(sut.wpmRaw, "below min words — both must be nil")
        XCTAssertNil(sut.wpmVoiced, "below min words — both must be nil")
    }

    func testBelowMinVoicedSecondsBothNil() async {
        let clock = MockClock(reference: 0)
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        sut.engineReadyFired(at: clock.current.addingTimeInterval(-1.0))
        clock.advance(by: 1.0)

        // Only 1s voiced < minVoicedSecondsForReading=2.0
        sut.notifyVADEvent(.speechStarted(sessionTime: 0))
        clock.advance(by: 1.0)
        sut.notifyVADEvent(.speechStopped(sessionTime: 1))

        clock.advance(by: 1.0)
        await sut.consume(makeToken("one two three four five"))

        fake.fireNext()
        XCTAssertNil(sut.wpmRaw, "below min voiced seconds — both must be nil")
        XCTAssertNil(sut.wpmVoiced, "below min voiced seconds — both must be nil")
    }

    func testSingleWordProducesNil() async {
        let clock = MockClock(reference: 0)
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        sut.engineReadyFired(at: clock.current.addingTimeInterval(-1.0))
        clock.advance(by: 1.0)

        sut.notifyVADEvent(.speechStarted(sessionTime: 0))
        clock.advance(by: 3.0)

        await sut.consume(makeToken("hello"))

        fake.fireNext()
        XCTAssertNil(sut.wpmRaw, "single word — both must be nil")
        XCTAssertNil(sut.wpmVoiced, "single word — both must be nil")
    }

    // MARK: AC5 — Window eviction

    func testWordsOlderThan10sEvicted() async {
        let clock = MockClock(reference: 0)
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        // cutoff = -0.5; t=0 is past cutoff
        sut.engineReadyFired(at: clock.current.addingTimeInterval(-1.0))

        // Feed 10 words at t=0
        await sut.consume(makeToken("one two three four five six seven eight nine ten"))

        // Open voice at t=0
        sut.notifyVADEvent(.speechStarted(sessionTime: 0))

        // Advance 11s — first batch now outside the 10s window
        clock.advance(by: 11.0)

        // Feed 4 words at t=11
        await sut.consume(makeToken("a b c d"))

        fake.fireNext()
        // Window = [t+1, t+11]; first 10 words at t=0 < t+1 evicted
        // 4 words remain; voiced open interval [t=0, t=11] clipped to [t+1, t+11] = 10s
        // wpmRaw = round(4 / (10/60)) = round(24) = 24
        XCTAssertEqual(sut.wpmRaw, 24)
    }

    // MARK: AC6 — Settings propagation

    func testSettingsStoreRefreshIntervalUsed() {
        let clock = MockClock()
        let settings = makeSettings()
        settings.wpmRefreshInterval = 5.0
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        sut.engineReadyFired(at: clock.current)
        XCTAssertEqual(fake.lastDelay, 5.0, accuracy: 0.001)

        // Change interval; next fire reads updated value
        settings.wpmRefreshInterval = 2.0
        fake.fireNext()
        XCTAssertEqual(fake.lastDelay, 2.0, accuracy: 0.001)
    }

    // MARK: AC7 — sessionEnded clears state

    func testSessionEndedPublishesNil() async {
        let clock = MockClock(reference: 0)
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        // Produce non-nil WPM
        sut.engineReadyFired(at: clock.current.addingTimeInterval(-1.0))
        clock.advance(by: 1.0)
        sut.notifyVADEvent(.speechStarted(sessionTime: 0))
        clock.advance(by: 3.0)
        await sut.consume(makeToken("one two three four five"))
        fake.fireNext()
        XCTAssertNotNil(sut.wpmRaw)

        await sut.sessionEnded()

        XCTAssertNil(sut.wpmRaw, "sessionEnded must clear wpmRaw")
        XCTAssertNil(sut.wpmVoiced, "sessionEnded must clear wpmVoiced")
        XCTAssertEqual(fake.pendingCount, 0, "sessionEnded must cancel pending refresh")
    }

    // MARK: AC8 — Post-teardown guard

    func testPostTeardownNoOpConsume() async {
        let clock = MockClock()
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        // engineReadyCutoff is nil — never called engineReadyFired
        let token = makeToken("one two three four five")
        await sut.consume(token)
        sut.notifyVADEvent(.speechStarted(sessionTime: 0))

        XCTAssertNil(sut.wpmRaw, "no-op before any session — wpmRaw stays nil")
        XCTAssertNil(sut.wpmVoiced)
        XCTAssertEqual(fake.pendingCount, 0, "no scheduling when no session")
    }

    func testPostTeardownNoOpAfterSessionEnded() async {
        let clock = MockClock(reference: 0)
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        sut.engineReadyFired(at: clock.current.addingTimeInterval(-1.0))
        await sut.sessionEnded()  // sets engineReadyCutoff = nil

        // Post-teardown events — must not crash, must not schedule
        let token = makeToken("one two three four five")
        await sut.consume(token)
        sut.notifyVADEvent(.speechStarted(sessionTime: 0))
        sut.notifyVADEvent(.speechStopped(sessionTime: 1))

        XCTAssertNil(sut.wpmRaw)
        XCTAssertNil(sut.wpmVoiced)
        XCTAssertEqual(fake.pendingCount, 0, "no re-scheduling after teardown")
    }

    // MARK: VAD-guard fix — pre-engine-ready recording

    func testVADEventsRecordedBeforeEngineReady() async {
        // speechStarted fires before engineReadyFired; open interval must be preserved
        // so voiced seconds count correctly once engine-ready arms the cutoff.
        let clock = MockClock(reference: 0)
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()

        // speechStarted at t=1, before engine-ready
        clock.advance(by: 1.0)
        sut.notifyVADEvent(.speechStarted(sessionTime: 0))

        // engineReady at t=10 → cutoff=10.5; open interval [t=1,∞] must be preserved
        clock.advance(by: 9.0)
        sut.engineReadyFired(at: clock.current)

        // Advance 5.5s past cutoff; feed words (accepted, t=15.5 > 10.5)
        clock.advance(by: 5.5)
        await sut.consume(makeToken("one two three four five"))

        fake.fireNext()

        // Open interval [1,15.5] clipped to effectiveCutoff [10.5,15.5] = 5s voiced
        XCTAssertNotNil(sut.wpmRaw, "pre-engine-ready speechStarted must produce wpmRaw")
        XCTAssertNotNil(sut.wpmVoiced, "pre-engine-ready speechStarted must produce wpmVoiced")
    }

    func testContinuousSpeechAcrossEngineReadyProducesWPM() async {
        // Exact live-failure scenario: speechStarted before engine-ready (~t=1),
        // no pause, engine-ready fires at t=11, tokens flow after cutoff.
        // Both variants must be non-nil after first refresh.
        let clock = MockClock(reference: 0)
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()

        clock.advance(by: 1.0)
        sut.notifyVADEvent(.speechStarted(sessionTime: 0))  // continuous speech begins

        clock.advance(by: 10.0)
        sut.engineReadyFired(at: clock.current)  // cutoff=11.5; no speechStopped

        // 3s past cutoff; 10 words accepted
        clock.advance(by: 3.0)
        await sut.consume(makeToken("one two three four five six seven eight nine ten"))

        fake.fireNext()

        // Open interval [1,14] clipped to [11.5,14] = 2.5s >= 2.0s floor
        XCTAssertNotNil(sut.wpmRaw, "continuous speech across engine-ready must produce wpmRaw")
        XCTAssertNotNil(sut.wpmVoiced, "continuous speech across engine-ready must produce wpmVoiced")
    }

    func testVoicedSecondsClippedToCutoff() async {
        // Voiced interval spans [t=0, t=7.5]; engine-ready cutoff=3.5.
        // Only the 4s after cutoff must count — not the full 7.5s.
        let clock = MockClock(reference: 0)
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()

        sut.notifyVADEvent(.speechStarted(sessionTime: 0))  // at t=0

        clock.advance(by: 3.0)
        sut.engineReadyFired(at: clock.current)  // cutoff=3.5

        clock.advance(by: 4.5)  // t=7.5
        sut.notifyVADEvent(.speechStopped(sessionTime: 7.5))

        await sut.consume(makeToken("one two three four"))  // 4 words, accepted (7.5 > 3.5)

        fake.fireNext()

        // voicedSec = [0,7.5] clipped to [3.5,7.5] = 4s (floor: 4s >= 2s — clip still matters for floor gate)
        // wpmRaw    = round(4 / (10/60)) = 24 — flat 10s denominator
        // wpmVoiced = EMA-smoothed raw; first reading seeds to rawWPM = 24 (no prior smoothed)
        XCTAssertEqual(sut.wpmRaw, 24)
        XCTAssertEqual(sut.wpmVoiced, 24, "B seeds to rawWPM on first reading — voiced-seconds denominator removed")
    }

    // MARK: EMA-smoothed B — raw vs smoothed A/B spec

    func testRawWPMIsWordsOverTenSeconds() async {
        // A = words / (10/60). Flat 10s denominator — voiced-seconds play no role in A.
        let clock = MockClock(reference: 0)
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        sut.engineReadyFired(at: clock.current.addingTimeInterval(-1.0))

        clock.advance(by: 1.0)
        sut.notifyVADEvent(.speechStarted(sessionTime: 0))
        clock.advance(by: 4.0)  // 4s voiced >= 2s floor

        // 24 words → 24 / (10/60) = 24 * 6 = 144
        await sut.consume(makeToken(
            "one two three four five six seven eight nine ten " +
            "one two three four five six seven eight nine ten " +
            "one two three four"
        ))
        fake.fireNext()

        XCTAssertEqual(sut.wpmRaw, 144, "A must be words / flat-10s, not words / voiced-seconds")
    }

    func testSmoothedWPMAppliesEMA() async {
        // B = alpha * rawWPM + (1 - alpha) * prevB, alpha = 0.4.
        // First reading seeds to rawWPM (no prior smoothed value).
        let clock = MockClock(reference: 0)
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        sut.engineReadyFired(at: clock.current.addingTimeInterval(-1.0))

        clock.advance(by: 1.0)  // t=1
        sut.notifyVADEvent(.speechStarted(sessionTime: 0))

        // Hop 1: 10 words at t=5 → rawWPM1 = 60; B seeds to 60 (no prior)
        clock.advance(by: 4.0)  // t=5; voiced open from t=1 = 4s >= 2s floor
        await sut.consume(makeToken("one two three four five six seven eight nine ten"))
        fake.fireNext()

        XCTAssertEqual(sut.wpmRaw, 60, "hop-1 rawWPM")
        XCTAssertEqual(sut.wpmVoiced, 60, "hop-1 B seeds to rawWPM — no prior smoothed value")

        // Hop 2: 20 words at t=8 → rawWPM2 = 120; B = 0.4*120 + 0.6*60 = 48+36 = 84
        clock.advance(by: 3.0)  // t=8; voiced open from t=1 = 7s >= 2s floor
        await sut.consume(makeToken(
            "one two three four five six seven eight nine ten " +
            "one two three four five six seven eight nine twenty"
        ))
        fake.fireNext()

        XCTAssertEqual(sut.wpmRaw, 120, "hop-2 rawWPM")
        XCTAssertEqual(sut.wpmVoiced, 84, "hop-2 B = 0.4*120 + 0.6*60 = 84")
    }

    func testSmoothedResetsAfterWaiting() async {
        // After enterWaiting(), previousSmoothedWPM is cleared.
        // The first reading after resume seeds B to rawWPM (no carryover from pre-waiting B).
        let clock = MockClock(reference: 0)
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.engineReadyFired(at: clock.current.addingTimeInterval(-1.0))

        clock.advance(by: 1.0)  // t=1
        sut.notifyVADEvent(.speechStarted(sessionTime: 0))

        // Hop 1: seed B = 60
        clock.advance(by: 4.0)  // t=5
        await sut.consume(makeToken("one two three four five six seven eight nine ten"))
        fake.fireNext()

        // Hop 2: push B to 84 (0.4*120 + 0.6*60)
        clock.advance(by: 3.0)  // t=8
        await sut.consume(makeToken(
            "one two three four five six seven eight nine ten " +
            "one two three four five six seven eight nine twenty"
        ))
        fake.fireNext()
        XCTAssertEqual(sut.wpmVoiced, 84, "setup: B should be 84 before waiting")

        // Enter waiting — clears EMA state
        sut.enterWaiting()

        // Resume: speechStarted restarts the loop
        clock.advance(by: 2.0)  // t=10
        sut.notifyVADEvent(.speechStarted(sessionTime: 0))

        // 10 words at t=14 (4s voiced since resume >= 2s floor)
        clock.advance(by: 4.0)  // t=14
        await sut.consume(makeToken("one two three four five six seven eight nine ten"))
        fake.fireNext()

        // rawWPM = 60; previousSmoothedWPM was cleared by enterWaiting → seeds to 60, not EMA from 84
        XCTAssertEqual(sut.wpmRaw, 60)
        XCTAssertEqual(sut.wpmVoiced, 60, "B must re-seed after waiting — no carryover of pre-waiting smoothed value")
    }

    // MARK: D1 — Snapshot-replace (overlapping hops must not multiply word count)

    func testOverlappingHopsDoNotMultiplyWordCount() async {
        // Parakeet 3s-hop re-transcribes the full 10s window on each hop.
        // Two tokens of 10 words each must not accumulate to 20 — the second
        // token replaces the first (snapshot model).
        let clock = MockClock(reference: 0)
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        sut.engineReadyFired(at: clock.current.addingTimeInterval(-1.0))

        clock.advance(by: 1.0)
        sut.notifyVADEvent(.speechStarted(sessionTime: 0))
        clock.advance(by: 10.0)  // t=11

        // First hop
        await sut.consume(makeToken("one two three four five six seven eight nine ten"))

        // Second hop 3s later — same 10 words re-transcribed from overlapping window
        clock.advance(by: 3.0)  // t=14
        await sut.consume(makeToken("one two three four five six seven eight nine ten"))

        fake.fireNext()

        // Snapshot model: latest token replaces previous — 10 words, not 20
        // wpmRaw = round(10 / (10/60)) = 60
        XCTAssertEqual(sut.wpmRaw, 60, "overlapping hops must not multiply word count — snapshot replaces")
    }

    // MARK: D2 — enterWaiting() blanks output and pauses refresh

    func testEnterWaitingBlanksAndClears() async {
        let clock = MockClock(reference: 0)
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.engineReadyFired(at: clock.current.addingTimeInterval(-1.0))

        clock.advance(by: 1.0)
        sut.notifyVADEvent(.speechStarted(sessionTime: 0))
        clock.advance(by: 3.0)
        await sut.consume(makeToken("one two three four five"))
        fake.fireNext()
        XCTAssertNotNil(sut.wpmRaw, "setup: must have non-nil WPM before enterWaiting")

        sut.enterWaiting()

        XCTAssertNil(sut.wpmRaw, "enterWaiting must blank wpmRaw")
        XCTAssertNil(sut.wpmVoiced, "enterWaiting must blank wpmVoiced")
        XCTAssertEqual(fake.pendingCount, 0, "enterWaiting must cancel the refresh loop")
    }

    func testResumeAfterWaitingStartsFresh() async {
        // After enterWaiting() clears state, speechStarted restarts the loop
        // and a subsequent token produces WPM from the clean window only.
        let clock = MockClock(reference: 0)
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()
        sut.engineReadyFired(at: clock.current.addingTimeInterval(-1.0))

        clock.advance(by: 1.0)
        sut.notifyVADEvent(.speechStarted(sessionTime: 0))
        clock.advance(by: 3.0)
        await sut.consume(makeToken("one two three four five"))
        fake.fireNext()
        XCTAssertNotNil(sut.wpmRaw, "setup: produce non-nil WPM before waiting")

        sut.enterWaiting()
        XCTAssertEqual(fake.pendingCount, 0, "enterWaiting must cancel refresh")

        // Resume: speechStarted restarts the refresh loop
        clock.advance(by: 1.0)
        sut.notifyVADEvent(.speechStarted(sessionTime: 0))
        XCTAssertEqual(fake.pendingCount, 1, "speechStarted after waiting must restart refresh loop")

        // Feed new words in the fresh window
        clock.advance(by: 3.0)
        await sut.consume(makeToken("one two three four five"))
        fake.fireNext()
        XCTAssertNotNil(sut.wpmRaw, "fresh window after resume must produce wpmRaw")
    }

    // MARK: AC8-isActive — post-teardown guard via isActive flag

    func testPostTeardownVADIsNoOpViaIsActive() async {
        // Full lifecycle via sessionActivated(): activate → produce WPM → sessionEnded → no-op.
        let clock = MockClock(reference: 0)
        let settings = makeSettings()
        let fake = WPMFakeHideScheduler()
        let sut = WPMCalculator(settings: settings, scheduler: fake, now: clock.now)

        sut.sessionActivated()

        // Pre-engine-ready VAD (new behavior: accepted)
        sut.notifyVADEvent(.speechStarted(sessionTime: 0))

        clock.advance(by: 3.0)
        sut.engineReadyFired(at: clock.current)  // cutoff=3.5; open interval preserved

        clock.advance(by: 5.0)  // t=8
        sut.notifyVADEvent(.speechStopped(sessionTime: 8))

        await sut.consume(makeToken("one two three four five"))  // accepted (8 > 3.5)

        fake.fireNext()
        // voiced = [0,8] clipped to [3.5,8] = 4.5s >= 2.0 — must produce WPM
        XCTAssertNotNil(sut.wpmVoiced, "setup: session must produce wpmVoiced before teardown")

        await sut.sessionEnded()
        XCTAssertNil(sut.wpmRaw, "sessionEnded must clear wpmRaw")
        XCTAssertNil(sut.wpmVoiced, "sessionEnded must clear wpmVoiced")

        // Post-teardown VAD — isActive=false, must be no-op
        sut.notifyVADEvent(.speechStarted(sessionTime: 0))
        clock.advance(by: 5.0)
        sut.notifyVADEvent(.speechStopped(sessionTime: 5))
        XCTAssertEqual(fake.pendingCount, 0, "no re-scheduling after teardown via isActive")
    }
}
