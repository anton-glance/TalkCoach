# Time Ledger — Locto v1

> Tracks wall-clock time per session and per module so the architect can refine effort estimates with actual data and the product owner can plan calendar realistically. The "Pace observations" section near the top is the quick read; tables below are the underlying data.
>
> **Convention:** "wall-clock" means total elapsed time from session start to session end on the user's calendar (architect conversation + agent implementation + smoke gate + close-out). "Commit-spread" is the time between first and last git commit in the session — a lower bound on actual wall-clock.
>
> **Updates land in the same session that updates the journal.**

## Pace observations (refresh each session close-out)

**Sessions 015–020 (Phase 1 close + Phase 2 progression to M2.6):**

- Cumulative wall-clock: ~13.7 hours over 6 sessions.
- Estimate vs actual aggregate: ~27h estimated, ~13.7h actual = **0.51x overall**. User runs at roughly half of nominal estimates on average.
- **Greenfield/skeleton modules (M1.1–M1.6) ran 0.12–0.42x estimate.** User is 2–8x faster on integration of architecturally-validated patterns. Spike work has already de-risked the API surface and the agent's scaffolding is fast.
- **Skeleton modules with new architectural patterns (M2.1, M2.3, M2.5) ran 0.4–0.75x estimate.** Still significantly faster than estimates.
- **M2.6 ran 2.25x estimate** (2h plan, ~4.5h actual). Two smoke-gate-caught fix rounds for `mouseDown` async-handoff and `NSScreen.main` semantics. The smoke gate itself was the risk-detection mechanism that worked as designed; the cost of the fix rounds is the cost of fixing what the smoke gate found.

**Pattern: skeleton work runs 2–4x faster than estimates; OS-integration with real-AppKit dependencies can run 2x slower when smoke gates surface real bugs.** The variance is asymmetric — skeleton work always faster, integration work sometimes much slower. Average comes out near 0.5x but the underlying distribution is bimodal.

**Estimate-adjustment guidance for upcoming modules:**

- Pure skeleton / integration of validated patterns: **estimate × 0.3–0.5**
- Module with one real OS-API dependency (AVAudioEngine, SpeechAnalyzer, NSScreen): **estimate × 1.0** (assumes one fix round in worst case, near-zero in best case)
- Module with multiple real OS-API dependencies + multi-state behavior: **estimate × 1.5–2.0** (assumes one or two fix rounds)
- Modules following spike pre-validation (M2.1 after Spike #4): **estimate × 0.5** (the spike absorbed the risk)

**Calendar pace:**

- Typical session: 2–4h wall-clock, 1 module per session
- Phase 1 was an exception: 6 modules in ~3h on May 5 morning (all greenfield with locked architecture, all spike-pre-validated)
- Multi-fix sessions (M2.6) ran 4.5–5h with two distinct smoke-gate cycles
- Daily cadence: ~1 session per day, sometimes two on a heavy day (May 5 had three: morning Phase 1 close, afternoon M2.1, evening M2.3)

**Projected remaining to Phase 5 (real UI + meaningful data):**

Per release plan: ~65–71h estimate from now.
Adjusted by observed pace breakdown:

- Phase 3 (transcription) — many real OS-API integrations, high smoke-gate risk: estimate × 1.0 = ~37–43h
- Phase 4 (analyzer) — algorithmic, low OS-API surface: estimate × 0.5 = ~3.5h
- Phase 5 (widget UI) — design implementation, moderate OS-API: estimate × 0.7 = ~14h
- **Adjusted total: ~55–60h.**

At ~1 session/day × 3h average, **~18–20 working days** to Phase 5. At 5 sessions/week = 4 calendar weeks. Heavier weeks (8–10h/week) push to 6–7 weeks. Lighter weeks (4–5h/week) push to ~12 weeks.

---

## Per-session wall-clock (Sessions 015–020)

| Session | Date (Mexico, -05:00) | Commit span | Wall-clock | Modules | Notes |
|---|---|---|---|---|---|
| 014 | uncertain (May 4–6) | uncommitted until May 6 17:23 | unknown | docs only | Release plan introduction. User can backfill if remembered. |
| 015 | 2026-05-05 | 07:30 → 11:21 (3h 51m) | ~4.5h | M1.1, M1.2, M1.3, M1.4, M1.5, M1.6 | Six modules in one push. Phase 1 closed. |
| 016 | 2026-05-05 | 12:13 → 13:04 (51m) | ~1.5–2h | M2.1 | MicMonitor. Spike #4 + #9 pre-validated HAL approach. |
| 017 | 2026-05-05 | 18:24 → 18:54 (30m) | ~1.5h | M2.3 | SessionCoordinator skeleton + termination cleanup fix. |
| 018 | uncertain (May 5–6) | uncommitted until May 6 17:23 | unknown | docs only | Locto rebrand + filler deferral. User can backfill. |
| 019 | 2026-05-06 | 06:50 → 08:10 (impl) + 17:21 → 17:23 (close) | ~3h split (~2h impl + ~1h close-out) | M2.5 | FloatingPanel. Sub-agent caught TokenStorage leak. |
| 020 | 2026-05-06 | 18:19 → 22:17 (3h 58m) | ~4.5h | M2.6 + 2 fix rounds | Per-display position memory; smoke caught two real bugs. |

## Per-module estimate vs actual (Sessions 015–020)

| Module | Session | Commit span | Actual wall-clock | Estimate (canonical) | Variance | Path |
|---|---|---|---|---|---|---|
| M1.1 | 015 | 07:30 → 07:51 (21m) | ~30 min | 2h | -75% | Build setup |
| M1.2 | 015 | 08:06 → 08:10 (4m) | ~15 min | 2h | -88% | MenuBarExtra |
| M1.4 | 015 | 08:28 → 08:32 (4m) | ~10 min | 1h | -83% | SettingsStore |
| M1.3 | 015 | 09:10 → 09:49 (39m) | ~45 min | 4h | -81% | Settings window |
| M1.5 | 015 | 09:56 → 10:20 (24m) | ~30 min | 3h | -83% | SwiftData |
| M1.6 | 015 | 10:36 → 11:21 (45m) | ~50 min | 2h | -58% | PermissionManager (incl. diag round trip for AppDelegate.current) |
| M2.1 | 016 | 12:13 → 13:04 (51m) | ~1.75h | 4h | -56% | MicMonitor (HAL listener, Spike #4 pre-validated) |
| M2.3 | 017 | 18:24 → 18:54 (30m) | ~1.5h | 3h | -50% | SessionCoordinator skeleton |
| M2.5 | 019 | 06:50 → 08:10 + close 17:21 | ~3h | 4h | -25% | FloatingPanel skeleton |
| M2.6 | 020 | 18:19 → 22:17 (3h 58m) | ~4.5h | 2h | +125% | Per-display position + 2 fix rounds (mouseDown async-handoff + NSScreen.main semantics) |

**Aggregate (Sessions 015–020):** ~27h estimated, ~13.7h actual = **0.51x ratio**. User runs at roughly half of nominal estimates on average, with a single significant outlier (M2.6) where smoke-gate fix rounds drove actual above estimate.

**Notes:**
- Per-module actual = git commit span + ~15–30 min architect-side time before first commit (plan + approval) + ~10–20 min close-out time after last commit. Multi-module sessions (Session 015) divide the surrounding time across modules touched.
- Sessions with smoke-gate failures (M2.6) do NOT divide the fix-round time across modules; the fix rounds are part of that module's actual cost.

---

## Phase 0 spike work (April–May 1–4)

Aggregate, not per-session: ~35 commits across May 1–4 covering 9 spikes (#2, #4, #7, #8, #9, #10 + WPM spike + Architecture pivot work).

Approximate wall-clock per the commit timeline:
- May 1 (project start + WPM spike kickoff): ~3–4h
- May 2 (WPM spike + Architecture Y pivot + Spike #10 + Spike #4 + Spike #2 Phase A): ~10h across multiple sub-sessions
- May 3 (Spike #2 Phase B/C + Spike #8): ~8h
- May 4 (Spike #7 + Spike #9 + M1.1 prep): ~8h

**Total Phase 0 wall-clock: ~28–32h** across 4 calendar days. Per-session breakdown not backfilled — module-mode tracking starts at Session 015.

---

## Project totals (current state, end of Session 020)

- Calendar days from project start (May 1) to current: **6 days**
- Approximate total wall-clock: **45–50h** (Phase 0 spikes ~30h + Phase 1+2 modules ~17h)
- Tagged modules complete: 9 (M1.1, M1.2, M1.3, M1.4, M1.5, M1.6, M2.1, M2.3, M2.5, M2.6)
- Modules remaining for v1: ~12 (M2.7 + Phase 3 modules + Phase 4 + Phase 5 + Phase 6)

---

## Going forward

Each new session's journal entry includes a `### Time accounting` block with:

- Session start (UTC + local with timezone)
- Session end (UTC + local with timezone)
- Wall-clock total
- Per-module breakdown if multi-module or multi-fix-round
- Variance against estimate

The architect captures session start with a `date` bash call at the first message of each conversation that establishes a session, and end at journal-write time. The ledger is updated during close-out by appending the new row to the per-session and per-module tables, and refreshing the pace observations.

If a session has no commits (docs-only or planning-only), the architect captures wall-clock from conversation timestamps directly.
