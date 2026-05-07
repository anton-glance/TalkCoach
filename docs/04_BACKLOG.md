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
| S4 | Mic coexistence with Zoom voice processing | ✅ passed Session 008 (browser Meet has recoverable config-change caveat) | (3h actual) |
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
| M3.1 | `AudioPipeline`: AVAudioEngine setup, voice-processing-OFF, raw input tap | 📋 | 4h | S4 (passed) |
| M3.2 | `SpeakingActivityTracker`: derive speaking duration from token timestamps | 📋 | 2h | M3.5, S6/S8 (passed) |
| M3.4 | `LanguageDetector`: N=1 trivial path + N=2 script-aware hybrid (3 strategies: NLLanguageRecognizer, word-count, Whisper-tiny LID) | 📋 | 4–6h | S2 (passed), M1.3 |
| M3.5 | `TranscriptionEngine` routing layer: locale → backend selection, unified token stream output | 📋 | 4h | M3.5a, M3.5b, M3.4 |
| M3.5a | `AppleTranscriberBackend`: `SpeechAnalyzer` + `SpeechTranscriber`, locale init | 📋 | 4h | M3.4 |
| M3.5b | `ParakeetTranscriberBackend`: Core ML model load, inference loop, timestamp normalization | 📋 | 8–12h | S10 (passed) |
| M3.6 | Model download flow — Apple `AssetInventory` + Parakeet CDN fetch (triggered from Settings confirmation) | 📋 | 4h | M3.5a, M3.5b |
| M3.7 | Token stream wiring: audio → engine → unified token output | 📋 | 3h | M3.1, M3.5 |
| M3.8 | Mid-session language re-detection / swap (if Spike #2 mechanism supports it) | 📋 | 4h | M3.4, M3.5 |

**Phase 3 total: ~37–43h.**

**End-of-phase checkpoint:** Speak English → Apple backend transcribes; speak Russian → Parakeet backend transcribes; first-time Russian shows download confirmation in Settings. Token streams from both backends look identical to downstream consumers.

---

## Phase 4 — Analyzer (the brain)

Goal: tokens turn into meaningful real-time metrics.

| ID | Module | Status | Estimate | Depends on |
|---|---|---|---|---|
| M4.1 | `WPMCalculator`: sliding window, token-arrival speaking duration, EMA smoothing | 📋 | 4h | S6 (passed), M3.7, M3.2 |
| M4.6 | `EffectiveSpeakingDuration`: accumulate from `SpeakingActivityTracker` | 📋 | 1h | M3.2 |
| M4.7 | Final session aggregation at session end | 📋 | 2h | M4.1, M4.6 |

**Phase 4 total: ~7h** (was ~17h before Session 018; M4.2 `FillerDetector` ~4h, M4.3 filler dictionary editor ~3h, and M4.4 `RepeatedPhraseDetector` ~3h all deferred to v2.0).

**End-of-phase checkpoint:** End a session → `SessionStore` shows accurate `totalWords`, `averageWPM`, `wpmSamples` array, `effectiveSpeakingDuration`. Numbers match a manual stopwatch + count on the same recording. Filler counts and repeated-phrase detection are deferred to v2.0 per Session 018.

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
