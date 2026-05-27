# Backlog — Locto v1

> Module-by-module breakdown. Estimates are **focused effort hours** for someone fluent in iOS Swift, learning macOS-specific APIs. Real elapsed time is typically 2–3× this depending on debugging.
>
> **Status legend:** `📋 todo` · `🔬 spike-blocked` · `🚧 in progress` · `✅ done` · `⏸ parked`

---

## Phase 0 — De-risking (before any production code)

| ID | Spike | Status | Estimate |
|---|---|---|---|
| S10 | Parakeet (NVIDIA) feasibility on macOS 26 / Apple Silicon | ✅ passed Sessions 006–007 | (10h actual) |
| S6 | WPM ground truth on real EN/RU recordings | ✅ passed (EN Session 005, RU Session 007) | (5h actual) |
| S4 | Mic coexistence with Zoom voice processing | ✅ passed Session 008 (browser Meet has recoverable config-change caveat); Phase 2 strict-concurrency tightening ✅ Session 022 (canonical pattern locked, recovery cycle validated 196.9ms) | (3h Phase 1 + ~3h Phase 2) |
| S2 | Language auto-detect mechanism | ✅ passed Session 010 | (6h actual) |
| S8 | Token-arrival robustness across mics & environments | ✅ passed Session 011 | (3h actual) |
| S7 | Power & CPU profiling Architecture Y (Apple baseline + 1hr session) | ✅ conditional pass Session 012 | (4h actual) |
| S9 | Adaptive RMS noise-floor for shouting detection | ❌ invalidated Session 013 (algorithm fundamentally wrong; feature → v2) | (3h actual) |
| S3 | ~~Russian transcription quality on `SpeechAnalyzer`~~ | ❌ superseded by S10 | — |
| S1 | Identifying activating app for blocklist | ⏸ deferred to v2 (blocklist feature deferred) | — |
| S11 | `MonologueDetector` VAD source validation | ⏸ deferred to v1.x (MonologueDetector feature deferred) | — |

**Phase 0 complete.** All architecture-blocking spikes resolved. S1 and S11 deferred with their respective features (Session 014 scope decision).

Detailed spike specs in `05_SPIKES.md`.

---

## Phase 1 — Foundation (skeleton app) — ✅ COMPLETE

Goal: a runnable menu bar app with no real functionality, but all the structural pieces in place. By end of phase, you can launch the app, see the menu bar icon, open Settings, and have the language picker working.

| ID | Module | Status | Estimate | Depends on |
|---|---|---|---|---|
| M1.1 | Xcode project setup, entitlements, Info.plist, code signing | ✅ tag `m1.1-complete` (Session 015, ~30m actual) | 2h | — |
| M1.2 | App lifecycle: `TalkCoachApp`, `LSUIElement`, `MenuBarExtra` skeleton (About, Pause/Resume, Settings…, Quit) | ✅ tag `m1.2-complete` (Session 015, ~15m actual) | 2h | M1.1 |
| M1.3 | Settings window: auto-opens on first launch, language picker (~50 locales, max 2, system locale silent-committed), model download confirmation prompts, `hasCompletedSetup` | ✅ tag `m1.3-complete` (Session 015, ~45m actual) | 4h | M1.2, M1.4 |
| M1.4 | Settings: UserDefaults wrapper + `declaredLocales`, `wpmTargetMin/Max`, `coachingEnabled`, `fillerDict` schema (note: `fillerDict` registered but unused after Session 018 deferral; v2.0 reactivates) | ✅ tag `m1.4-complete` (Session 015, ~10m actual) | 1h | M1.2 |
| M1.5 | SwiftData `Session` schema + empty `SessionStore` | ✅ tag `m1.5-complete` (Session 015, ~30m actual) | 3h | M1.1 |
| M1.6 | Permission request flow for mic + speech (point-of-use, not pre-emptive) | ✅ tag `m1.6-complete` (Session 015, ~50m actual) | 2h | M1.2 |

**Phase 1 total: ~14h estimate, met. ✅ tag `phase-1-complete`.**

**End-of-phase achieved (Session 015).** App builds, runs, shows menu bar icon with About / Pause-Resume Coaching / Settings… / Quit, opens Settings window automatically on first launch with language picker (50 locales, system locale silent-committed when supported, max-2 selection enforced), requests mic + speech permissions point-of-use. SwiftData `Session` schema versioned with `MigrationPlanV1` scaffolding; `SessionStore` `@ModelActor` exposes `Sendable` record types as the boundary surface.

**69 tests passing across 19+ files, 0 lint violations.** Seven architectural conventions established (Info.plist mechanism, Swift 6 strict concurrency, AppKit `NSWindow` for LSUIElement Settings, `UserDefaults.didChangeNotification` live-sync, `nonisolated Sendable` records crossing `@ModelActor`, `PermissionStatusProvider` injection, `AppDelegate.current` static-reference) — see `01_PROJECT_JOURNAL.md` Session 015 and `CLAUDE.md` Project Conventions.

**M1.3 dependency note:** the Settings window UI binds to `SettingsStore`, so M1.3 also depends on M1.4. Execution order in Session 015 was M1.1 → M1.2 → M1.4 → M1.3 → M1.5 → M1.6.

---

## Phase 2 — Mic detection & session lifecycle

Goal: the app knows when the mic turns on, shows an empty placeholder widget, knows when it turns off, hides the widget, and persists an empty session record.

| ID | Module | Status | Estimate | Depends on |
|---|---|---|---|---|
| M2.1 | `MicMonitor`: Core Audio HAL listener for mic running state | ✅ tag `m2.1-complete` (Session 016, ~1.75h actual) | 4h | S4 (passed) |
| M2.3 | `SessionCoordinator` skeleton: receive mic events, manage session state, check `coachingEnabled` | ✅ tag `m2.3-complete` (Session 017, ~1.5h actual) | 3h | M2.1 |
| M2.5 | `FloatingPanel`: NSPanel + SwiftUI host, show on mic-active / persistent during session with "Listening…" placeholder / hide 5s after mic-off, dismissable with confirmation alert (per Sessions 013 + 018) | ✅ tag `m2.5-complete` (Session 019, ~3h actual) | 4h | M2.3 |
| M2.6 | Per-display widget position memory + last-used-display preference + drag-trigger reliability | ✅ tag `m2.6-complete` (Session 020, ~4.5h actual incl. 2 fix rounds) | 2h + ~1.5h fixes | M2.5 |
| M2.7 | Session persistence (empty metrics) at end of session | ✅ tag `m2.7-complete` (Session 021, ~3h actual incl. overnight break) | 1h | M1.5, M2.3 |

**Phase 2 total: ~14h.**

**End-of-phase checkpoint:** Open Zoom → speak → widget appears in chosen position → close Zoom → widget hides → `~/Library/Application Support/TalkCoach/` shows a session record with timestamps.

---

## Phase 3 — Audio pipeline & transcription engine

Goal: while a session is active, audio is being captured, transcribed in the right language via the right backend, and tokens are flowing.

| ID | Module | Status | Estimate | Depends on |
|---|---|---|---|---|
| M3.1 | `AudioPipeline`: AVAudioEngine setup, voice-processing-OFF, raw input tap | ✅ code-complete tag `m3.1-code-complete` (Session 023, ~3.5h actual); AC11 smoke gate deferred to M3.7 wiring | 4h | S4 (passed Phase 1 + Phase 2) |
| M3.2 | `SpeakingActivityTracker`: derive speaking duration from token timestamps | 📋 | 2h | M3.5, S6/S8 (passed) |
| M3.4 | `LanguageDetector`: N=1 trivial path + N=2 script-aware hybrid (3 strategies: NLLanguageRecognizer, word-count, Whisper-tiny LID) | ✅ code-complete tag `m3.4-code-complete` (Session 024, ~2.5–3h actual); SG1–SG5 deferred to M3.7 wiring | 4–6h | S2 (passed), M1.3 |
| M3.5 | `TranscriptionEngine` routing layer: locale → backend selection, unified token stream output | ✅ code-complete tag `m3.5-code-complete` (Session 025, ~3-4h actual against 4h estimate); shipped with M3.5a | 4h | M3.5a, M3.5b, M3.4 |
| M3.5a | `AppleTranscriberBackend`: `SpeechAnalyzer` + `SpeechTranscriber`, locale init | ✅ code-complete tag `m3.5-code-complete` (Session 025); 5 Convention-6 seams; AC7 finding: use `SpeechTranscriber.supportedLocales` LIST not `supportedLocale(equivalentTo:)` HELPER | 4h | M3.4 |
| M3.5b | `ParakeetTranscriberBackend`: Core ML model load, inference loop, timestamp normalization | 📋 DEFERRED post-WPM-milestone per EN-first sprint (Session 024, reaffirmed 025) | 8–12h | S10 (passed) |
| M3.6 | Model download flow — Apple `AssetInventory` + Parakeet CDN fetch (triggered from Settings confirmation) | 📋 DEFERRED post-WPM-milestone per EN-first sprint | 4h | M3.5a, M3.5b |
| M3.7 | Token stream wiring: audio → engine → unified token output | 🔄 PARTIAL CLOSE pending whisper.cpp integration (Sessions 026–033, ~60–83h actual against 3h estimate = ~20–28x). First speech tokens emitted Session 026. **Spike #13 CLOSED Session 030**; **Spike #14 REJECTED + Spike #15 SUPPORTED Session 031** (engine-always-warm + 1Hz HAL polling architecture). **Fix #5 ships engine-always-warm at commit `b892020`.** **Fix #6 + fix #7 (Session 033)** ship 7-state widget model (idle/warming/counting/waiting/wrapping/recovering/dismissed) at commit `7670867` with structured `widget-state:` log emission. UX visually validated on real hardware (fade-out, 50% translucency, linger, X-button, Phase G all confirmed). **CSV pivot of smoke logs reveals Apple SpeechAnalyzer architectural problem:** tokenStream emits in 2–4s bursts at internal commit boundaries, not real-time. Widget's `isInTokenSilence` state subscribes to a transcription-hypothesis-revision stream batched at commit boundaries, NOT a speaking-activity stream. Architectural fix required: real-time VAD on audio buffers BEFORE transcription. **Four-spike STT engine search (Spikes #16, #17.1, #17.1.5, #17.2, #17.3 — see `05_SPIKES.md`):** all engines have architectural latency floors above the 200ms C4 budget. Energy-based VAD architecturally dead on far-field mic (#16). FluidAudio SlidingWindow is batch mode (#17.1). FluidAudio StreamingEou has 2s cache warmup (#17.1.5). Whisper.cpp has 30s mel context floor (#17.2 + #17.3) at 304-453ms warm. **Anton's product call (Session 033):** relax C4 budget to "whatever-best-possible," ship whisper-small + Silero VAD at kLengthMs=1000, validate UX via 14-step smoke gate, retreat to Sherpa-ONNX / two-engine / further relaxation only if UX is unacceptable. M3.7 closes only after whisper.cpp integration commit + 14-step smoke gate validates the UX. | 3h estimate + Spike #13/14/15/16/17.1/17.1.5/17.2/17.3 budgets exhausted (~60-83h M3.7 cumulative) | M3.1, M3.5 |
| M3.7.3 | Engine-always-warm session lifecycle + 1Hz HAL process-list polling + 7-state widget model | ✅ shipped (Sessions 031 + 032 + 033 fix #6 + fix #7 at commit `7670867`). Fix #5 shipped engine-always-warm: AVAudioEngine + SpeechAnalyzer run for entire session, warm up exactly once. `SystemAudioProcessProber` queries `kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningInput`, filters out `getpid()` and `baselineBundleIDs = ["com.apple.CoreSpeech"]`. When poll returns empty, session ends with `SessionEndReason.micFreedExternally`. Fix #6 + fix #7 ship 7-state widget model (idle / warming / counting / waiting / wrapping / recovering / dismissed) with structured `widget-state: <ISO8601> <prev>→<next> reason=<reason>` log emission via single `setActivityState(_:reason:)` writer. Widget visible from mic-on through entire session plus 3s lingerFull + 2s lingerFade. Panel opacity 0.5 in `.waiting` (whole panel, animated 300ms via `animator().alphaValue`), 1.0 elsewhere. `sessionStartedAt` anchored at mic-on. Bug B-prime (`panel?.alphaValue = X` inside `NSAnimationContext.runAnimationGroup` snaps instead of animating) discovered and fixed across three rounds — must use `animator().alphaValue`. Architect now grep-verifies the pattern explicitly. `tools/state-timeline.py` produces CSV pivot with ^/v markers. **Smoke gate on real hardware (Voice Memos) confirmed UX works for widget visibility/animations. CSV pivot of state-transition logs exposed the Apple SpeechAnalyzer batching gap that drove the four-spike engine search.** | 6–10h estimate, ~12–14h actual through Session 033 fix #7 | M3.7, M2.7, Spike #14, Spike #15 |
| M3.7.4 | Parakeet TDT v3 int8 (`parakeet-rs`) integration into production transcriber stack | ✅ COMPLETE (Session 036, tagged `m3.7.4-complete`). Engine integration proven on live audio across multiple sessions: full path mic→resample→RollingAudioWindow→Parakeet(static-ORT)→tokens→widget. Speaking-activity time-offset bug fixed (`speaking=true` confirmed live). Warm-load persists (7.9→5.6→4.5s across sessions). 386 tests (385 pass, 1 skip). Loader reads sandbox-container Application Support. **SCOPE = engine integration ONLY.** Voice-gating, WPM display (Phase 5), and the structurally-~10-14s widget-dim latency are explicitly OUT of scope — dim latency moved to M3.7.6 (window-only detection can't beat hop+window-clear; needs real-time VAD). **Engine REVERSED Session 034 (Spike #18): whisper.cpp OUT, Parakeet IN.** | done | M3.7.3, Spike #18 |
| M3.7.5 | Settings: Download-Model button (first-launch model fetch) | 📋 NEW (Session 035, product-owner scoped). v1 Settings gets a Download-Model control: fetches the Parakeet int8 model set from HF `istupakov/parakeet-tdt-0.6b-v3-onnx` with progress/done/failed states. **MUST write to the sandbox CONTAINER Application Support** (`~/Library/Containers/com.antonglance.TalkCoach/Data/Library/Application Support/TalkCoach/Models/parakeet-tdt-v3-int8/`), NOT `~/Library/Application Support/` — the app writing its own container needs no special entitlement. Required files: `encoder-model.int8.onnx` (~652MB), `decoder_joint-model.int8.onnx`, `vocab.txt`, `nemo128.onnx`. **SCOPE GUARD:** NO language dropdown (English-only lock holds — zero validated non-EN WPM accuracy on this engine), NO tuning variables (minimal-settings lock; hop interval stays a code-injectable dev knob). | 4–6h estimate | M3.7.4 |
| M3.7.6 | VAD master-clock gate infrastructure (Silero) — raw gated transitions, M4-ready | ✅ COMPLETE (Session 038, tagged `m3.7.6-complete`). FULL PIPELINE validated on live natural speech: Parakeet + Silero gate + AudioBufferBroadcaster fan-out + 2s UI silence-hold all working together. `AudioBufferBroadcaster` actor fans single-consumer bufferStream (SE-0314) to both consumers (snapshot-of-Sendable-continuations, proven on live teardown). `SileroVADGate` actor: Silero v5 via the EXISTING parakeet-bridge staticlib (ORT compiled once, two sessions one runtime — two-ORT-models risk resolved by single-staticlib design), own resample, jitter-debounce, emits RAW `VADTransitionEvent.speechStarted/stopped`. `sl_*` added to existing CParakeetBridge.h (no separate module). `speakingActivityStream` fully removed. **Close-criterion test `testGateM3CloseCriterionTwoStubSubscribers` PASSED** (WPM-stub@2s + Monologue-stub@2.5s diverge on 2.08s gap from one raw stream = M4-ready, no surprises). **Integration bug live-smoke caught:** stale tokens dragged widget back to counting after gate set waiting — fixed (gate is sole authority for counting↔waiting; token guarded out; subscription bidirectional). **2s UI silence-hold** added (TEMPORARY `static let`, M4 replaces with WPM-pause-threshold setting): gate detects every pause at 160ms backend; widget holds 2s before fading so breaths don't flicker. State flow validated live: Warming→Counting→[>2s]→Waiting(50%)→[voice]→Counting→[mic off]→Wrapping. 403 tests (402 pass, 1 skip). **PHASE 3 DONE — speech-pipeline research risk retired.** | done | Spike #19, M3.7.4 |
| Spike #19 | Silero VAD far-field validation through existing ONNX bridge | ✅ PASS (Session 037). Silero v5 VAD validated as the voice-activity master-clock and LOCKED. Onset ~32ms (1 frame, target ≤100ms); offset clean within 1-2 frames; NO mid-sentence fragmentation (drops only on genuine inter-word/breath pauses); ZERO false-positives in a live Starbucks run (the exact Spike #16 far-field+noise killer scenario where energy-VAD died) and 0/467 frames room-at-rest; soft far-field speech held reliably. Pipeline: 48kHz cpal → rubato 3:1 → Silero v5 ONNX (512-sample/32ms frames) via `ort` 2.0.0-rc.12. Tried v5 first per architect Revision 3; no v4 fallback. Keyboard/HVAC WAV gates left unrun — the live Starbucks run answered the false-positive question more convincingly than controlled recordings would. **KEY LEARNING:** the 2s grace serves TWO jobs — bridges inter-word VAD dips (keeps metrics running through a sentence) AND defines end-of-turn; M3.7.6 implements it as a SINGLE debounce. | done | M3.7.4 |
| M3.8 | Mid-session language re-detection / swap (if Spike #2 mechanism supports it) | 📋 deferred to v1.5+ (Locto V1 ships single-language sessions; multi-language switching is V1.5 follow-up validated separately) | 4h | M3.4, M3.5 |

**Phase 3 total (EN-first sprint scope): M3.7 IN PROGRESS — fix #6 (engine-ready widget trigger + linger sequence + silence-detection event) deferred to Session 033 per Session 032 design lock. M3.2 remaining at 2h estimate after M3.7 closes. M3.5b + M3.6 deferred to post-WPM-milestone.**

**End-of-phase checkpoint:** Speak English → Apple backend transcribes; speak Russian → Parakeet backend transcribes; first-time Russian shows download confirmation in Settings. Token streams from both backends look identical to downstream consumers.

---

## Phase 4 — Analyzer (the brain) — SPEC LOCKED Session 038

Goal: the M3.7.6 gate's raw transition stream turns into the two v1 metrics: WPM + Monologue. Both subscribe to `SileroVADGate.transitionStream` and apply their OWN pause-threshold; the gate is untouched (M3.7.6 proved this via the two-stub close-criterion test).

**Two INDEPENDENT settings** (kept separate — may not feel right at the same value):
- `wpmPauseThreshold` (default ~2s): pause beyond this excludes the gap from WPM and stops aggregation; the widget fade ALSO uses this (replaces M3.7.6's temporary 2s UI hold timer).
- `monologuePauseThreshold` (default ~2.5-3s): pause beyond this ZEROS the monologue streak.

**Settings consolidation (M4.4, Session 040):** Settings is now the single source of truth for every adjustable behavior. Live user-facing settings: language [locked en_US, picker removed M4.4b], coaching toggle, WPM (refresh interval, pause threshold, EMA alpha), Monologue (3 level thresholds + pause threshold), Widget Behavior (waiting opacity, lingerFull, lingerFade, recovery grace), Session (mic poll interval). Deleted dead settings: `wpmTargetMin/Max` (rebuild in M5.2), `fillerDict` (v2.0), `inactivityThresholdSeconds`, `widgetHideDelaySeconds`, `wpmMedianWindowHops` (now a code constant). Warmup is NOT settable (engine-ready-event-driven). All widget timings now read from Settings, not hardcoded literals.

| ID | Module | Status | Estimate | Depends on |
|---|---|---|---|---|
| M4.1 | `WPMCalculator` on the gate stream → single live WPM number on the widget. | ✅ COMPLETE (Session 039, tagged `m4.1-complete`). **Formula CORRECTED from the original plan:** raw per-hop WPM = latest hop's `word_count × 6` (60s ÷ 10s window), **NO cross-hop accumulation** (the accumulating form caused 3–4× inflation). Floor `minWordsForReading=3` + `minVoicedSecondsForReading=2.0` (code constants) → "---" below floor. Warmup discard by arrival time vs engine-ready cutoff. **Smoothing bake-off → EMA chosen, `wpmEmaAlpha` default 0.70** (median `wpmMedianWindowHops` default 3 also built + live-tunable, but removed from the widget display; median computation + log line KEPT for future comparison). Widget shows ONE WPM number (EMA) at the top. Both smoothers reset on enterWaiting/sessionEnded. **Validated live across unlimited sessions per launch** after resolving a six-bug multi-session lifecycle cascade (VAD-guard, VADGate finish(), RollingAudioWindow buffer reset, ParakeetBackend engine keep-alive, hopStream + tokenStream recreation) + a deterministic widget linger-race crash (cancel-linger-restore-warming). Spike #20 (Parakeet/ORT multi-session) folded in. 445 tests (444 pass, 1 skip). | done | M3.7.6, M3.7.4 |
| M4.2 | `MonologueDetector` on the gate stream: continuous-speaking-streak timer with THREE-tier escalation (levels 1/2/3) via three USER-CONFIGURABLE thresholds `monologueLevel1/2/3Minutes` (defaults 60/90/150s) + configurable `monologuePauseThreshold` (2.5s); sub-threshold pauses bridge, a pause beyond it zeros the streak. Publishes `monologueLevel: Int (0…3)`. | ✅ COMPLETE (Session 040, tag `m4.2-complete`). Live-validated: full 0→1→2→3 escalation on a 90s continuous run; natural micro-gaps bridged; clean reset + re-escalation. Minimal `MONO L{n}` widget indicator added (M4.2b) for validation; polished display is M5. **Spike #11 CLOSED as SUPERSEDED** (premise died with M3.7.6's SpeakingActivityTracker removal + Silero lock; two-stub close test already proved the derivation). Documented v1 limit: no speaker diarization (v2). | done | M3.7.6 |
| M4.3 | Wire the widget fade to `wpmPauseThreshold` (replace M3.7.6's TEMPORARY 2s `static let` UI hold with the real setting-driven signal). | ✅ COMPLETE (Session 040, folded into M4.4). `silenceHoldSeconds=2.0` static let removed; counting→waiting hold now reads the live `wpmPauseThreshold` setting. | done | M4.1 |
| M4.6 | `EffectiveSpeakingDuration`: accumulate gated speaking time from the transition stream. | 📋 | 1h | M3.7.6 |
| M4.7 | Final session aggregation at session end (totalWords, averageWPM, wpmSamples, effectiveSpeakingDuration, monologue stats). | 📋 | 2h | M4.1, M4.2, M4.6 |

**End-of-phase checkpoint:** End a session → `SessionStore` shows accurate WPM samples and monologue stats matching a manual stopwatch+count on the same recording. The widget shows a live WPM number (Phase 5 renders it; M4 computes it). Filler counts and repeated-phrase detection deferred to v2.0 (Session 018). Speech-balance (talk/pause %) and the WPM/time analytic graph → v1.5/v2.

**M4 transcription-quality items:**
- ~~Investigate forcing English-only decode (Russian fragment on hop 1)~~ — RETIRED Session 040: the apparent non-English tokens were background family speech (real, countable words), NOT a decode bug. Not an issue for normal use.
- WPM should discard or down-weight the first (cold-start) hop — its tokens are low-quality. (Still open; minor.)

---

## Phase 5 — Widget UI (the part you see)

Goal: replace the placeholder widget with the real glanceable display per the `docs/design/` package visual spec (Session 018 — superseded the earlier `design/` package).

| ID | Module | Status | Estimate | Depends on |
|---|---|---|---|---|
| M5.1 | `WidgetViewModel`: ObservableObject wiring `Analyzer` → SwiftUI | 📋 | 2h | M4.7 |
| M5.2 | WPM display: hero number (Inter, weight 300, tabular figures) + state row (Too slow / Ideal / Too fast + avg) + pace bar with caret | 📋 | 4h | M5.1 |
| M5.3 | Smooth color interpolation (FM1 — anti-jitter), pace-zone tinting per design tokens (slate-blue / sage-green / warm-coral inks per `docs/design/02-brand-guidelines.html`) | 📋 | 3h | M5.2 |
| M5.7 | Liquid Glass material styling + Reduce Transparency fallback + hover saturation shift | 📋 | 4h | M5.2 |
| M5.8 | Drag-to-move with snap-to-screen-edge | 📋 | 3h | M2.5 |
| M5.9 | Fade in/out animations on session start/end + hover state | 📋 | 2h | M2.5 |
| M5.10 | Accessibility: Reduce Motion clamp, Increase Contrast adjustments, VoiceOver combined label | 📋 | 2h | M5.2 |

**Phase 5 total: ~20h** (was ~23h before Session 018; M5.5 `Filler bars` ~3h deferred to v2.0).

**End-of-phase checkpoint:** Real-world test in a 30-min Zoom call. Widget is glanceable, doesn't pull attention when nothing changes, smoothly indicates pace shifts. Self-test against FM1 ("destructive UI") criteria and the `docs/design/01-design-spec.md` testing checklist.

---

## Phase 6 — Polish & ship-readiness

Goal: take the working app to personal-use quality.

| ID | Module | Status | Estimate | Depends on |
|---|---|---|---|---|
| M6.1 | Manual language override in menu bar (read-only display + dropdown for session language) | 📋 | 2h | M3.4 |
| M6.2 | Settings sheet polish: WPM band slider | 📋 | 2h | M4.7 |
| M6.3 | Accessibility audit: VoiceOver labels on widget, keyboard navigation in Settings | 📋 | 3h | All UI |
| M6.4 | Dark mode / light mode visual check (design tokens calibrated for both, verify) | 📋 | 2h | All UI |
| M6.5 | First-launch defaults verified end-to-end (FM3 — minimal setup) | 📋 | 2h | All |
| M6.6 | Performance pass: re-run S7 measurements on real build | 📋 | 3h | All |
| M6.7 | Notarization & DMG creation script (or App Store Connect setup) | 📋 | 4h | All |

**Phase 6 total: ~18h** (was ~19h; M6.2 trimmed by 1h after filler editor deferral).

**End-of-phase checkpoint:** A signed, notarized DMG exists. App passes all three success criteria from `02_PRODUCT_SPEC.md` after 2 weeks of personal use.

---

## Summary

| Phase | Goal | Estimate |
|---|---|---|
| 0 | Spikes (all resolved) | 34h actual |
| 1 | Foundation (Settings + language picker) | 14h |
| 2 | Mic detection + session lifecycle | 14h |
| 3 | Audio pipeline + transcription engine (Architecture Y) | 37–43h |
| 4 | Analyzer (WPM + monologue prep) | 7h |
| 5 | Widget UI (`docs/design/` visual spec) | 20h |
| 6 | Polish & ship | 18h |
| **Total** | **v1 complete** | **~110–116h focused effort** |

Session 018 scope reduction vs Session 014 (124–130h → 110–116h, ~10% cut on top of Session 014's already-reduced scope):
- Removed: M4.2 `FillerDetector` (−4h), M4.3 filler dictionary editor (−3h), M4.4 `RepeatedPhraseDetector` (−3h), M5.5 filler bars in widget (−3h), filler editor UI in M6.2 polish (−1h)
- Total Session 018 cut: −14h
- Filler tracking + repeated-phrase detection promoted to v2.0 alongside the rich post-session dashboard

Multiplier for "macOS new to user" learning curve: ~1.3–1.5×. Realistic calendar:

- **At 8h/week (hobby pace):** 4 months
- **At 20h/week (serious side project):** 6–8 weeks
- **At 40h/week (full-time):** 3–4 weeks

---

## Recommended order of attack

1. Phase 0 complete — all architecture-blocking spikes resolved
2. Build Phases 1 → 2 → 3 in order (each unlocks the next)
3. Phase 4 can begin as soon as Phase 3 produces token streams
4. Phase 5 begins after Phase 4's session aggregation is stable (working on Phase 5 with broken metrics is a waste — you can't tune visual feedback for inputs you can't trust)
5. Phase 6 is the final pass — don't mix it with feature work

---

## What gets dropped if time pressure is real

In order of "drop first":

1. M3.8 (mid-session language swap) — accept the "first session per app per language is wrong, then sticky" UX
2. M5.8 (drag-to-move) — pin to top-right corner
3. M2.6 (per-display position memory)
4. M6.1 (manual language override in menu bar)
5. M6.3 (accessibility audit) — defer to v1.1

What does NOT get dropped:
- M3.6 (model download with confirmation) — directly serves FM3 (minimal setup)
- M5.3 (smooth color interpolation) — directly serves FM1 (destructive UI)
- M4.1's VAD-aware WPM math — directly serves FM2 (unreliable data)
- Anything in M6.5, M6.6 (final perf + setup verification)

---

## Deferred features (not in v1 backlog)

### v1.x
- **MonologueDetector** — algorithm designed (Session 013), needs Spike #11 (VAD source validation) before implementation. Modules: M4.5, M4.5a (Silero contingent), M5.6 (widget indicator). Estimate: ~7–11h.
- **Acoustic non-word detection** — Spike #5 (paired with v2.0 filler tracking)
- **UI localization** (EN, RU, ES)

### v2.0 (deferred Session 018 — paired with the rich post-session dashboard)
- **Filler-word tracking** — `FillerDetector` (M4.2 ~4h), filler dictionary editor in Settings (M4.3 ~3h), filler bars on widget (M5.5 ~3h), filler editor UI polish in M6.2 (~1h). Includes seeded dictionaries for high-priority languages (EN/RU/ES at minimum), per-language editor, and `MigrationPlanV2` schema addition for `fillerCounts`.
- **Repeated-phrase detection** — `RepeatedPhraseDetector` (M4.4 ~3h). Sliding 4-word window over finalized tokens detecting 2–4 word phrase repetition within ~5s. `MigrationPlanV2` schema addition for `repeatedPhrases`.
- **Auto-learn fillers** — was v1.x, regrouped to v2.0 alongside the rest of filler work.

### v2 (full)
- **Per-app blocklist** — needs Spike #1 (activating app identification). Modules: M2.2, M2.4. Estimate: ~5h.
- **StatsWindow** — session list, WPM trend chart, monologue timeline, per-session detail, manual relabel, plus the v2.0 filler/phrase analytics. Estimate: ~16h.
- **Hotkey** (Cmd+Shift+M)
- **Session-end summary UX**
- **Trail-off detector** — Spike #12 (parked)
- **Shouting detector** — needs multi-signal model (pitch, spectral tilt, onset rate)
- **Speaker diarization**
