# Time Ledger — Locto v1

> Tracks wall-clock time per session and per module so the architect can refine effort estimates with actual data and the product owner can plan calendar realistically. The "Pace observations" section near the top is the quick read; tables below are the underlying data.
>
> **Convention:** "wall-clock" means total elapsed time from session start to session end on the user's calendar (architect conversation + agent implementation + smoke gate + close-out). "Commit-spread" is the time between first and last git commit in the session — a lower bound on actual wall-clock.
>
> **Updates land in the same session that updates the journal.**

## Pace observations (refresh each session close-out)

**Sessions 015–024 (Phase 1 close + Phase 2 complete + Phase 3 prep micro-spike + Phase 3 modules M3.1, M3.4):**

- Cumulative wall-clock: ~26h over 10 sessions.
- Estimate vs actual aggregate: ~38–40h estimated, ~26h actual = **~0.66x overall**. User runs at roughly 65% of nominal estimates on average.
- **Greenfield/skeleton modules (M1.1–M1.6) ran 0.12–0.42x estimate.** User is 2–8x faster on integration of architecturally-validated patterns. Spike work has already de-risked the API surface and the agent's scaffolding is fast.
- **Skeleton modules with new architectural patterns (M2.1, M2.3, M2.5) ran 0.4–0.75x estimate.** Still significantly faster than estimates.
- **M2.6 ran 2.25x estimate** (2h plan, ~4.5h actual). Two smoke-gate-caught fix rounds for `mouseDown` async-handoff and `NSScreen.main` semantics. Outlier driven by real-OS-API surprises.
- **M2.7 ran 2.5–3x estimate** (1h plan, ~2.5–3h actual). The implementation itself ran on-estimate; the +1.5h overage was the milestone-closing close-out work (journal entry summarizing Phase 2, ledger update, architecture-doc consideration, multiple commits). Pure glue modules at phase boundaries should budget +1h for close-out.
- **Spike #4 Phase 2 ran 2x estimate** (1.5h plan, ~3h actual). The plan ran on-estimate; the +1.5h overage was the S4 trigger-debug round (Chrome Meet didn't reproduce Phase 1's config-change behavior; input-device switch trigger validated the recovery code path instead). Smoke-gate-equivalent pattern: micro-spikes that exercise OS-API behavior carry the same +1.5h trigger-debug-or-fix-round risk as integration modules. The trigger problem also surfaced a real Phase 1 → Phase 2 reproducibility gap that's now documented as a finding for M3.1.
- **M3.1 ran 0.75–1.0x against canonical estimate** (4h estimate × 1.0–1.5 OS-API guidance = 4–6h adjusted band; ~3.5–4h actual = on the fast end of adjusted, near canonical). Spike-pre-validated module: agent copied AudioTapBridge.swift's production form directly, no re-derivation. Marker-block drift on first self-review (third session under template, first regression after 021–022 ran clean) cost ~25 min corrective; sub-agent finding (recover-after-stop guard) + class-level doc comment cost ~15 min additive tightening. AC11 smoke deferred to M3.7 — the smoke-gate fix-round risk that the OS-API guidance allocated for is shifted to M3.7, not absorbed in M3.1.
- **M3.4 ran 0.5–0.7x against canonical estimate** (4–6h estimate × 0.5–0.8 spike-pre-validated guidance = 2.5–4h adjusted band; ~2.5–3h actual = on the low end of adjusted). Spike-pre-validated module: three-strategy dispatch transferred clean from Spike #2's Session 010 validation. Marker-block drift on first self-review (second consecutive drift after M3.1 — pattern is now expected, not exception) cost ~25 min corrective; first false-positive sub-agent finding required architect judgment to dismiss (~15 min). Three real architect-relevant findings surfaced: prompt drift on Apple API names (`languageHints` vs `languageConstraints`); subsystem convention is `com.talkcoach.app` not `com.locto.<area>`; sub-agent findings need architect-level judgment, not blanket apply. SG1–SG5 all deferred to M3.7 wiring — M3.7 now inherits 8 smoke scenarios (M3.1's 3 + M3.4's 5).
- **M3.5 + M3.5a (Session 025) ran 0.5x estimate** (8h combined estimate, ~3-4h actual). Spike-pre-validated: PowerSpike's `LiveTranscriptionRunner.swift:99-104` transferred clean as the canonical SpeechAnalyzer live-streaming form. Five Convention-6 seams in one module — highest count in project history. **First Apple-framework runtime-discovery finding** (`SpeechTranscriber.supportedLocales` LIST vs `supportedLocale(equivalentTo:)` HELPER) caught by agent. Eight-in-a-row substantive sub-agent reviews.
- **M3.7 Session 026 (wiring landed) ran on-estimate for its session slice** (~3h). Three commits (`85ffba9`, `d9d9683`, `fb6d98f`) landed wiring + measurement-logging + production-providers. **Second Apple-framework runtime-discovery finding** (`assetInstallationRequest` non-nil for installed models) caught by empirical bypass test in <15 min. Architect's first proposed Mirror-reflection fix correctly rejected by agent; clean `isInstalled(locale:) -> Bool` landed in `SystemAssetInventoryStatusProvider`. **First-ever speech token from green pipeline emitted**: `token '.' t=[0.00–15.49] final=false` — project-level milestone. **Smoke-gate-evidence convention locked.**
- **M3.7 Session 027 already over the 3h estimate** (~3-4h wall-clock). M3.7 smoke surfaced MicMonitor/AudioPipeline composition bug (kAudioDevicePropertyDeviceIsRunningSomewhere stays true while ANY process holds the device — including us — so `IsRunningSomewhere=false` never fires while we're a reader). **Three HAL probes** established `kAudioHardwarePropertyProcessObjectList` IS observable but `kAudioProcessPropertyIsRunningInput` listener never fires (**third Apple-framework runtime-discovery finding**). M3.7.1 polling architecture designed as listener-fallback. **Reply-formatting + architect-terminal-commands conventions locked** in `00_COLLABORATION_INSTRUCTIONS.md` + `CLAUDE.md`. Smoke-gate fix-round risk shifted from M3.7 to M3.7.1.
- **M3.7 Session 028 (M3.7.2 inactivity-timer ships INTERIM; product-UX miss caught at close; Spike #13 opened)** — ~3h wall-clock. M3.7 cumulative across Sessions 026 + 027 + 028: **~8–10h actual against 3h estimate = ~2.7–3.3x estimate, M3.7 STILL OPEN.** Driver: four Apple-framework runtime-discovery findings + one architect-side product-fit miss. M3.7.1 polling reverted (net -475 lines after M3.7.2 lands). M3.7.2 InactivityTimer Convention-6 (DispatchInactivityTimer + FakeInactivityTimer with regression-guard recording) ships interim. Smoke gate passed both inactivity + X-button scenarios but **product UX MISMATCH caught at session close** — inactivity-timer breaks the hour-long-call-with-10-min-pitch use case. **Spike #13 opened** for correct external-mic-detection signal (3 gated probes, 4–6h budget). **Nine-in-a-row sub-agent reviews** with substantive findings.
- **Spike #13 Probe A Session 029 (KVO observer + Probe A-prime polling extension; both FAILED across six manual choreography runs)** — ~2.5–3.5h wall-clock. Two standalone Swift packages built and tested: `spike/13-probe-a` (commit `279152f`, KVO-only) and `spike/13-probe-a-prime` (commit `4ada2c7`, KVO + 1Hz polling alongside on additive-only diff). **Result: 0 KVO state-change callbacks AND 0 polled-read transitions across 186 polled reads spanning three runs.** Property `AVCaptureDevice.isInUseByAnotherApplication` is INERT at runtime from sandbox — **fifth Apple-framework runtime-discovery finding** locked with tighter wording than spec predicted (property itself broken, not just KVO event delivery). M3.7 cumulative across Sessions 026 + 027 + 028 + 029: **~10.5–13.5h actual against 3h estimate = ~3.5–4.5x estimate, M3.7 STILL OPEN.** Spike #13 cumulative: ~2.5–3.5h of original 4–6h budget consumed. **Probe B (Core Audio process tap) drafts Session 030.** Probe B path estimate: 5–7h. Two architect prompt-engineering misses caught by agent (boot-smoke condition contradicted approved plan; `timeout` is not GNU-portable to macOS) — both surfaced transparently in self-review with correct rationale. **Polling-disambiguation pattern locked as architectural decision**: any future event-driven probe that fails on event delivery gets a 1Hz polling extension before being declared dead.
- **Spike #13 closes (Sessions 030, marathon ~7–9h wall-clock) + Spike #13.5 measurement spike (single-session, ~1h within Session 030).** Six probes built and executed across Session 030: Probe B (aggregate-device + AVAudioEngine), Probe B-prime (additive startup-restart observer), Probe C (AVCaptureSession via CMIO), Probe C-prime (additive pre-session IRS baseline + weak-delegate retention fix across two commits), Probe D (cascading multi-candidate SCK + HAL-scan + CMIOExtension), and Spike #13.5 (HAL stop-settling measurement). **All four Spike #13 probe paths FAILED across six probe executions; six locked Apple-framework runtime-discovery findings** establish no standard signal distinguishes our capture from external at HAL level. **NO-SKIPPING rule locked Session 030 as project-level convention**: if data is incomplete or ambiguous, STOP and report rather than locking verdict on bad data. The rule operated four substantive STOP-and-report cycles in Session 030 alone (Probe C zero-buffers; Probe D Phase 3 reporting-time cascade-ordering bug; Probe C-prime hypothesis-direction inversion in sub-agent; the Probe D Bash-tool-sync limitation). **Architect pivoted to disconnect-probe-reconnect algorithm** proposed by product owner — algorithm sidesteps the entire HAL-distinguishability problem by removing Locto from the set of HAL readers during the probe step. Spike #13.5 measured the algorithm parameter: max 45ms stop-settling, tight 6.5ms-spread distribution, production parameter 100ms with safety margin. **M3.7 cumulative across Sessions 026 + 027 + 028 + 029 + 030: ~17–22h actual against 3h estimate = ~5.5–7x estimate, M3.7 STILL OPEN pending M3.7.3.** **Spike #13 cumulative: ~10–13h actual against 4–6h budget = ~2.0–2.5x estimate, but closes with working architectural path (algorithm) not documented limitation.** Eight-of-eight sub-agent reviews + six-of-six self-reviews held the NO-SKIPPING + credibility-evidence + reply-formatting standards across the marathon. M3.7.3 (algorithm implementation + inactivity-threshold-as-settings + smoke gate) targets Session 031 at ~6–8h estimate.

**Pattern: skeleton work runs 2–4x faster than estimates; integration and OS-API spike work hits 1.5–2x slower when smoke gates surface real OS-API behavior; milestone-closing modules add ~1h of close-out beyond their nominal scope; spike-pre-validated modules with deferred smoke run near canonical; modules touching unfamiliar Apple HAL/Speech APIs without probe-spike validation can hit 2.7–3.3x estimate (M3.7 case).** The variance has five modes (skeleton-fast, integration-on-or-slower, milestone-overhead, spike-pre-validated-with-deferred-smoke, HAL/Speech-API-without-probe-spike). Average across Phase 1–early-Phase 3 came out near 0.69x; M3.7 marathon pushed cumulative variance higher.

**Estimate-adjustment guidance for upcoming modules:**

- Pure skeleton / integration of validated patterns: **estimate × 0.3–0.5**
- Module with one real OS-API dependency (AVAudioEngine, SpeechAnalyzer, NSScreen): **estimate × 1.0** (one fix round in worst case, near-zero in best case)
- Module with multiple real OS-API dependencies + multi-state behavior: **estimate × 1.5–2.0** (one or two fix rounds)
- Modules following spike pre-validation (M2.1 after Spike #4): **estimate × 0.5** (the spike absorbed the risk)
- **Spike-pre-validated module with smoke gate deferred to a downstream wiring module: estimate × 0.75–1.0** (M3.1 pattern; smoke fix-round risk shifts to the wiring module's actual)
- Micro-spikes that exercise OS-API behavior at runtime: **estimate × 1.5–2.0** (S4-equivalent trigger-debug risk)
- **Phase-closing modules: add +1h to estimate for close-out** (journal milestone framing, ledger refresh, architecture-doc consolidation)
- **Wiring modules that inherit deferred smoke from upstream: add +0.5–1h to estimate for the inherited smoke scenarios** (M3.7 will inherit M3.1's SG1/SG2/SG3 + buffer-count counter check on top of its own ACs)
- **NEW (Session 028 lesson): Modules with user-visible session semantics get a mandatory product-fit audit before Phase 2.** The audit asks: "does this implementation match the product UX across the v1 use cases (long calls, multi-app workflows, mid-session device changes)?" Architect's Phase 1 plan audit now includes this step explicitly. **Cost of skipping: M3.7.2 case ~3h wasted on wrong-solution Phase 2.**
- **NEW (Session 028 lesson): Add 2–3x multiplier specifically for polling-or-listener-semantics validation work** on modules touching unfamiliar Apple HAL/Speech APIs. Spike-first if at all possible. The **four-finding Apple-framework runtime-trap inventory is project-level pattern.** Future prompts reference the inventory and require probe-spike validation. Spike #13 is the first formalized application of this pattern.

**Calendar pace:**

- Typical session: 2–4h wall-clock active, 1 module per session
- Phase 1 was an exception: 6 modules in ~3h on May 5 morning (all greenfield with locked architecture, all spike-pre-validated)
- Multi-fix sessions (M2.6) ran 4.5–5h with two distinct smoke-gate cycles
- Phase-closing sessions (M2.7 / Session 021) add ~1h of close-out work beyond the module itself
- Daily cadence: ~1 session per day; sometimes two on a heavy day (May 5 had three)
- Multi-day modules (M2.7 spanned an overnight break) are fine — agent's commits land asynchronously, architect picks up in the next conversation; the calendar span isn't a useful metric, the active wall-clock is

**Projected remaining to Phase 5 (real UI + meaningful data):**

Per release plan: ~57–63h estimate from now (Phase 3 + Phase 4 + Phase 5).

Adjusted by observed pace breakdown:

- Phase 3 (transcription) — many real OS-API integrations, high smoke-gate risk: estimate × 1.0–1.2 = ~37–50h
- Phase 4 (analyzer) — algorithmic, low OS-API surface: estimate × 0.5 = ~3.5h
- Phase 5 (widget UI) — design implementation, moderate OS-API: estimate × 0.7 = ~14h
- **Adjusted total: ~55–68h.**

At ~3h/session active and ~1 session/day, **~18–22 working days** to Phase 5. At 5 sessions/week = ~4–5 calendar weeks. Heavier weeks (8–10h/week) push toward 6 weeks; lighter weeks (4–5h/week) toward ~10–12 weeks.

**Phase 2 actual cost (Sessions 015–021):** ~14h actual against ~17h estimated = **0.82x**. Phase 2 included the M2.6 smoke-gate outlier; without it the phase ratio would have been ~0.5x, consistent with Phase 1's pattern.

---

## Per-session wall-clock (Sessions 015–024)

| Session | Date (Mexico, -05:00) | Commit span | Wall-clock | Modules | Notes |
|---|---|---|---|---|---|
| 014 | uncertain (May 4–6) | uncommitted until May 6 17:23 | unknown | docs only | Release plan introduction. User can backfill if remembered. |
| 015 | 2026-05-05 | 07:30 → 11:21 (3h 51m) | ~4.5h | M1.1, M1.2, M1.3, M1.4, M1.5, M1.6 | Six modules in one push. Phase 1 closed. |
| 016 | 2026-05-05 | 12:13 → 13:04 (51m) | ~1.5–2h | M2.1 | MicMonitor. Spike #4 + #9 pre-validated HAL approach. |
| 017 | 2026-05-05 | 18:24 → 18:54 (30m) | ~1.5h | M2.3 | SessionCoordinator skeleton + termination cleanup fix. |
| 018 | uncertain (May 5–6) | uncommitted until May 6 17:23 | unknown | docs only | Locto rebrand + filler deferral. User can backfill. |
| 019 | 2026-05-06 | 06:50 → 08:10 (impl) + 17:21 → 17:23 (close) | ~3h split (~2h impl + ~1h close-out) | M2.5 | FloatingPanel. Sub-agent caught TokenStorage leak. |
| 020 | 2026-05-06 | 18:19 → 22:17 (3h 58m) | ~4.5h | M2.6 + 2 fix rounds | Per-display position memory; smoke caught two real bugs. |
| 021 | 2026-05-06 → 2026-05-07 | aef1ba3 → 6d87536 (overnight) + smoke 09:15 -05:00 | ~2.5–3h active (10.5h calendar incl. overnight break) | M2.7 | Session persistence. Phase 2 closes. First session under marker-block prompt template — no checklist drift. Agent caught 3 prompt errors before implementing. Smoke uneventful. |
| 022 | 2026-05-08 | spike commits (TBD by user push) | ~3h | Spike #4 Phase 2 + 00_COLLABORATION_INSTRUCTIONS.md edit | Strict-concurrency tap pattern micro-spike. All 5 scenarios PASS. S4 trigger-debug round (Chrome Meet did not reproduce Phase 1 trigger; input-device switch validated recovery instead). Marker-block template promoted to standard prompt template; second session running with no checklist drift. |
| 023 | 2026-05-08 | e9891f1 (red) → 16a7932 (green) + tightening commit | ~3.5–4h active (~5.5h elapsed incl. ~1h silent-agent / UI-frozen interval) | M3.1 | AudioPipeline. First Phase 3 module. Canonical pattern from Spike #4 Phase 2 transferred clean. Marker-block drift on first self-review (third session under template, first regression after 021–022 ran clean) corrected via per-AC drift-map prompt; sub-agent finding (recover-after-stop guard) folded in additively. AC11 smoke deferred to M3.7 (no runtime path to exercise AudioPipeline until M3.7 wires it). 179/179 tests green. |
| 024 | 2026-05-08 | dc0475b (red) → a9179f6 (green) → 26ed849 (sub-agent fix) | ~2.5–3h active (~3.5h elapsed; wall-clock continuous with Session 023) | M3.4 | LanguageDetector. Spike-pre-validated three-strategy dispatch transferred clean from Spike #2's Session 010 validation. Marker-block drift on first self-review again (second consecutive drift; pattern now expected). Three architect-relevant findings: agent caught prompt's wrong API name (`languageHints` → `languageConstraints` from spike); subsystem convention is `com.talkcoach.app` not `com.locto.<area>`; first false-positive sub-agent finding required architect judgment to dismiss. Sub-agent caught real over-broad catch (`is WhisperLIDProviderError` → `.modelUnavailable`). 228/228 tests green; 49 new. SG1–SG5 deferred to M3.7. |
| 029 | 2026-05-13 | spike/13-probe-a `279152f` (KVO probe) + spike/13-probe-a-prime `4ada2c7` (polling extension) | ~2.5–3.5h active | Spike #13 Probe A + Probe A-prime | Probe A (KVO observer on `AVCaptureDevice.isInUseByAnotherApplication`) plus Probe A-prime (additive-only 1Hz polling extension on new branch off Probe A's commit). Six manual choreography runs total across two binaries (Voice Memos on built-in mic, Locto-in-parallel idle baseline, AirPods device switch). **0 KVO state-change callbacks AND 0 polled-read transitions across 186 reads**. Property is inert from sandbox — fifth Apple-framework runtime-discovery finding. Default-device-change listener pattern and KVO re-attach pattern proven reusable for future probes. Probe B (Core Audio process tap) drafts Session 030. Two architect prompt misses caught by agent (boot-smoke condition vs approved plan; `timeout` not GNU-portable). |
| 030 | 2026-05-13 | spike/13-probe-b `f52a7cc` + spike/13-probe-b-prime + spike/13-probe-c `52ba826` + spike/13-probe-c-prime (`4908310` + `33498b2`) + spike/13-probe-d + spike/13.5-hal-stop-settling | ~7–9h active (~14h calendar window with breaks; marathon ending ~10:40pm local) | Spike #13 closure (all four probe paths FAILED) + Spike #13.5 measurement | Six probes in one session across four spike branches. Probe B (aggregate-device + AVAudioEngine, config-change-at-startup discovery), Probe B-prime (additive startup-restart, IRS=true 0.01s after restart success, hypothesis FALSIFIED), Probe C (AVCaptureSession via CMIO, zero buffers blocking diagnostic), Probe C-prime (two-commit additive: pre-session IRS baseline + weak-delegate retention fix; 5627 buffers, IRS false→true at session start, hypothesis FALSIFIED), Probe D (cascade SCK + HAL-scan + CMIOExtension; SCK requires Screen Recording TCC architectural disqualifier; cascade-ordering bug caught at Phase 3 reporting time; Bash-tool-sync prevents CHOREO participation), Spike #13.5 (10-cycle HAL stop-settling measurement, max 45ms tight distribution, production parameter 100ms with safety margin). **NO-SKIPPING rule locked as project convention** — operated four substantive STOP-and-report cycles in this session alone. **Six locked Apple-framework runtime-discovery findings establish no standard signal distinguishes our capture from external at HAL level.** Architect pivoted to disconnect-probe-reconnect algorithm proposed by product owner. M3.7.3 (algorithm + inactivity-threshold-as-settings + smoke gate) targets Session 031. |

## Per-module estimate vs actual (Sessions 015–024)

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
| M2.7 | 021 | aef1ba3 → 6d87536 (overnight) | ~2.5–3h active | 1h | +150–200% | Session persistence. Implementation on-estimate; close-out for milestone-closing module added ~1.5h beyond M2.7's nominal 1h scope. |
| Spike #4 Phase 2 | 022 | TBD by user push | ~3h | 1.5h | +100% | Strict-concurrency tap pattern + recovery cycle. Plan + impl on-estimate; +1.5h overage was S4 trigger-debug round (Chrome Meet did not reproduce Phase 1 trigger; input-device switch validated recovery instead). All 5 scenarios PASS. |
| M3.1 | 023 | e9891f1 → 16a7932 + tightening | ~3.5–4h active | 4h | -10 to 0% | AudioPipeline. Spike-pre-validated module: canonical pattern from Spike #4 Phase 2 transferred clean. Marker-block drift on first self-review corrected (~25 min). Sub-agent finding (recover-after-stop guard) folded in additively (~15 min). AC11 smoke deferred to M3.7 (no runtime path until M3.7 wires it); smoke fix-round risk shifted to M3.7's actual. 179/179 tests green. |
| M3.4 | 024 | dc0475b → a9179f6 → 26ed849 | ~2.5–3h active | 4–6h | -50 to -25% | LanguageDetector. Spike-pre-validated module: three-strategy dispatch from Spike #2 transferred clean. Three Convention-6 protocol seams in one module (PartialTranscript / WhisperLID / AudioBuffer). Marker-block drift on first self-review (second consecutive) corrected (~25 min). First false-positive sub-agent finding (Logger.lang access from nonisolated context — architect dismissed) (~15 min). Real sub-agent finding fixed (over-broad WhisperLIDProviderError catch). SG1–SG5 deferred to M3.7. 228/228 tests green; 49 new. |
| Spike #13 path | 029 + 030 | spike/13-probe-{a, a-prime, b, b-prime, c, c-prime, d} + spike/13.5-hal-stop-settling | ~10–13h cumulative across two sessions | 4–6h | +67–117% | Spike #13 closure across all four formal probe paths. Six probes built (A, B, C, D plus three additive-only extensions A-prime, B-prime, C-prime) + Spike #13.5 measurement spike. All four probe paths FAILED empirically. Six locked Apple-framework runtime-discovery findings. NO-SKIPPING rule locked as project convention; operated four STOP-and-report cycles. Architect pivoted to disconnect-probe-reconnect algorithm (product-owner-proposed) which sidesteps the entire HAL-distinguishability problem. Spike #13.5 measured the algorithm parameter: max 45ms HAL stop-settling, production parameter 100ms with safety margin. Budget overrun bought a working architectural path (algorithm) instead of a documented limitation. |

**Aggregate (Sessions 015–024):** ~38–40h estimated, ~26h actual = **~0.66x ratio**. M3.4's 0.5–0.7x landed near the low end of the spike-pre-validated band, confirming the guidance. Skeleton work alone still runs 0.12–0.50x. The multi-modal pattern (skeleton-fast / OS-API-spike-slow / milestone-overhead / spike-pre-validated-with-deferred-smoke-near-canonical) is now well-fitted.

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

## Project totals (current state, end of Session 030)

- Calendar days from project start (May 1) to current: **13 days**
- Approximate total wall-clock: **~75–85h** (Phase 0 spikes ~30h + Phase 1+2 modules ~17h + Spike #4 Phase 2 ~3h + M3.1 ~3.5h + M3.4 ~2.5–3h + M3.7 (Sessions 026 + 027 + 028 + 029 + 030) ~17–22h + Spike #13.5 inside Session 030)
- Tagged modules complete: 13 (M1.1, M1.2, M1.3, M1.4, M1.5, M1.6, M2.1, M2.3, M2.5, M2.6, M2.7, M3.1, M3.4) + Spike #4 Phase 2. **M3.1 + M3.4 code-complete with smoke deferred to M3.7. M3.7 pipeline-complete with M3.7.3 pending Session 031.**
- Spikes resolved: 8 (S2, S4, S6, S7, S8, S9, S10, **Spike #13**) + Spike #13.5 measurement landed. Two deferred (S1 v2, S11 v1.x), one parked (S12), one superseded (S3), one v1.x (S5).
- Modules remaining for v1: ~10 (Phase 3 modules ex-M3.1/M3.4 plus M3.7.3 + Phase 4 + Phase 5 + Phase 6)

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
