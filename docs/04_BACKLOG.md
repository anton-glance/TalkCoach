# Backlog — Speech Coach v1

> Module-by-module breakdown. Estimates are **focused effort hours** for someone fluent in iOS Swift, learning macOS-specific APIs. Real elapsed time is typically 2–3× this depending on debugging.
>
> **Status legend:** `📋 todo` · `🔬 spike-blocked` · `🚧 in progress` · `✅ done` · `⏸ parked`

---

## Phase 0 — De-risking (before any production code)

| ID | Spike | Status | Estimate |
|---|---|---|---|
| S6 | WPM ground truth on real EN/RU recordings (Approach D, no energy VAD) | 🔬 in progress | 4h |
| S7 | Power & CPU profiling during 1hr session | 📋 | 4h |
| S3 | Russian transcription quality on `SpeechAnalyzer` | 📋 | 4h |
| S4 | Mic coexistence with Zoom voice processing | 📋 | 3h |
| S2 | Language auto-detect mechanism (constrained by S7) | 📋 | 6h |
| S8 | Token-arrival robustness across mics & environments | 📋 | 3h |
| S9 | Adaptive RMS noise-floor for shouting detection | 📋 | 2h |
| S1 | Identifying activating app for blocklist | 📋 | 3h |

**Phase 0 total: ~29h.** Run spikes in priority order. Stop if any P0 spike (S6, S7, S3, S4) reveals a fundamental problem — re-plan instead of pushing through.

Detailed spike specs in `05_SPIKES.md`.

---

## Phase 1 — Foundation (skeleton app)

Goal: a runnable menu bar app with no real functionality, but all the structural pieces in place. By end of phase, you can launch the app, see the menu bar icon, and click it to open an empty stats window.

| ID | Module | Status | Estimate | Depends on |
|---|---|---|---|---|
| M1.1 | Xcode project setup, entitlements, Info.plist, code signing | 📋 | 2h | — |
| M1.2 | App lifecycle: `TalkCoachApp`, `LSUIElement`, `MenuBarExtra` skeleton | 📋 | 2h | M1.1 |
| M1.3 | Empty `StatsWindow` opening from menu bar | 📋 | 1h | M1.2 |
| M1.4 | `Settings` (UserDefaults wrapper) skeleton | 📋 | 1h | M1.2 |
| M1.5 | SwiftData `Session` schema + empty `SessionStore` | 📋 | 3h | M1.1 |
| M1.6 | Permission request flow for mic + speech (point-of-use, not pre-emptive) | 📋 | 2h | M1.2 |

**Phase 1 total: ~11h.**

**End-of-phase checkpoint:** App builds, runs, shows menu bar icon, opens empty stats window, requests permissions when needed, exits cleanly.

---

## Phase 2 — Mic detection & session lifecycle

Goal: the app knows when the mic turns on, shows an empty placeholder widget, knows when it turns off, hides the widget, and persists an empty session record.

| ID | Module | Status | Estimate | Depends on |
|---|---|---|---|---|
| M2.1 | `MicMonitor`: Core Audio HAL listener for mic running state | 📋 | 4h | S4 (passed) |
| M2.2 | Activating-app identification for blocklist | 📋 | 3h | S1 (passed) |
| M2.3 | `SessionCoordinator` skeleton: receive mic events, manage session state | 📋 | 3h | M2.1, M2.2 |
| M2.4 | Blocklist UI in settings + check at activation | 📋 | 2h | M2.3 |
| M2.5 | `FloatingPanel`: NSPanel + SwiftUI host, show/hide, "Listening…" placeholder | 📋 | 5h | M2.3 |
| M2.6 | Per-display widget position memory | 📋 | 2h | M2.5 |
| M2.7 | Session persistence (empty metrics) at end of session | 📋 | 1h | M1.5, M2.3 |

**Phase 2 total: ~20h.**

**End-of-phase checkpoint:** Open Zoom → widget appears in chosen position → close Zoom → widget fades out → `~/Library/Application Support/TalkCoach/` shows a session record with timestamps.

---

## Phase 3 — Audio pipeline & speech engine

Goal: while a session is active, audio is being captured, transcribed in the right language, and tokens are flowing.

| ID | Module | Status | Estimate | Depends on |
|---|---|---|---|---|
| M3.1 | `AudioPipeline`: AVAudioEngine setup, voice-processing-OFF, raw input tap | 📋 | 4h | S4 (passed) |
| M3.2 | `SpeakingActivityTracker`: derive speaking duration from `SpeechAnalyzer` token timestamps | 📋 | 2h | M3.5, S6/S8 (passed) |
| M3.3 | RMS calculation on audio buffers | 📋 | 1h | M3.1 |
| M3.4 | `LanguageDetector` (mechanism per Spike #2) | 📋 | 6–10h | S2 (passed) |
| M3.5 | `SpeechEngine`: `SpeechAnalyzer` + `SpeechTranscriber`, locale init | 📋 | 5h | S3 (passed), M3.4 |
| M3.6 | `AssetInventory` model download flow with widget toast | 📋 | 3h | M3.5 |
| M3.7 | Token stream wiring: audio → engine → token output | 📋 | 3h | M3.1, M3.5 |
| M3.8 | Mid-session language re-detection / swap (if Spike #2 mechanism supports it) | 📋 | 3h | M3.4, M3.5 |

**Phase 3 total: ~28–32h.**

**End-of-phase checkpoint:** Speak into mic during a session → console logs show timestamped tokens streaming in correct language → first-time RU/ES use shows toast and downloads model silently.

---

## Phase 4 — Analyzer (the brain)

Goal: tokens + VAD + RMS turn into meaningful real-time metrics.

| ID | Module | Status | Estimate | Depends on |
|---|---|---|---|---|
| M4.1 | `WPMCalculator`: sliding window, token-arrival speaking duration, EMA smoothing | 📋 | 4h | S6 (passed), M3.7, M3.2 |
| M4.2 | `FillerDetector`: seeded dictionaries (EN/RU/ES), match logic | 📋 | 4h | M3.7 |
| M4.3 | Filler dictionary editor in settings (per language) | 📋 | 3h | M4.2 |
| M4.4 | `RepeatedPhraseDetector`: n-gram window | 📋 | 3h | M3.7 |
| M4.5 | `ShoutingDetector`: adaptive noise-floor (10th percentile rolling window) + threshold | 📋 | 3h | M3.3, S9 (passed) |
| M4.6 | `EffectiveSpeakingDuration`: accumulate from `SpeakingActivityTracker` | 📋 | 1h | M3.2 |
| M4.7 | Final session aggregation at session end | 📋 | 2h | M4.1–M4.6 |

**Phase 4 total: ~19h.**

**End-of-phase checkpoint:** End a session → `SessionStore` shows accurate `totalWords`, `averageWPM`, `wpmSamples` array, `fillerCounts`, `repeatedPhrases`, `shoutingEvents`, `effectiveSpeakingDuration`. Numbers match a manual stopwatch + count on the same recording.

---

## Phase 5 — Widget UI (the part you see)

Goal: replace the placeholder widget with the real glanceable display.

| ID | Module | Status | Estimate | Depends on |
|---|---|---|---|---|
| M5.1 | `WidgetViewModel`: ObservableObject wiring `Analyzer` → SwiftUI | 📋 | 2h | M4.7 |
| M5.2 | WPM display: large number + color band + arrow | 📋 | 3h | M5.1 |
| M5.3 | Smooth color interpolation (FM1 — anti-jitter) | 📋 | 3h | M5.2 |
| M5.4 | Average WPM display under primary | 📋 | 1h | M5.2 |
| M5.5 | Filler list: append-only, no reorder, count updates in place | 📋 | 3h | M5.1 |
| M5.6 | Shouting indicator icon | 📋 | 1h | M5.1 |
| M5.7 | Liquid Glass material styling (macOS 26 native) | 📋 | 4h | M5.2 |
| M5.8 | Drag-to-move with snap-to-screen-edge | 📋 | 3h | M2.5 |
| M5.9 | Fade in/out animations on session start/end | 📋 | 2h | M2.5 |

**Phase 5 total: ~22h.**

**End-of-phase checkpoint:** Real-world test in a 30-min Zoom call. Widget is glanceable, doesn't pull attention when nothing changes, smoothly indicates pace shifts. Self-test against FM1 ("destructive UI") criteria.

---

## Phase 6 — Stats window

Goal: see historical data, track progress.

| ID | Module | Status | Estimate | Depends on |
|---|---|---|---|---|
| M6.1 | Session list table (sortable, filterable by language) | 📋 | 3h | M1.3, M4.7 |
| M6.2 | Session detail view (metrics, edit label) | 📋 | 3h | M6.1 |
| M6.3 | WPM trend chart (Swift Charts) | 📋 | 4h | M6.1 |
| M6.4 | Filler frequency chart per language (Swift Charts) | 📋 | 4h | M6.1 |
| M6.5 | Date-range filter | 📋 | 2h | M6.3, M6.4 |

**Phase 6 total: ~16h.**

**End-of-phase checkpoint:** After ~1 week of personal use, stats window shows enough data to spot a trend (or absence of one). Charts are readable.

---

## Phase 7 — Polish & ship-readiness

Goal: take the working app to public-release quality.

| ID | Module | Status | Estimate | Depends on |
|---|---|---|---|---|
| M7.1 | Hotkey toggle (Cmd+Shift+M) for manual coaching on/off | 📋 | 2h | M2.3 |
| M7.2 | Manual language override in menu bar | 📋 | 2h | M3.4 |
| M7.3 | Session-end UX: show brief summary, allow immediate label | 📋 | 3h | M4.7 |
| M7.4 | Settings sheet polish: target WPM band slider, blocklist UI, filler editor | 📋 | 4h | M4.3, M2.4 |
| M7.5 | Accessibility audit: VoiceOver labels on widget, Dynamic Type in stats | 📋 | 3h | All UI |
| M7.6 | Dark mode / light mode visual check | 📋 | 2h | All UI |
| M7.7 | First-launch defaults verified end-to-end (FM3 — no setup) | 📋 | 2h | All |
| M7.8 | Performance pass: re-run S7 measurements on real build | 📋 | 3h | All |
| M7.9 | Localized strings for app UI (EN, RU, ES) | 📋 | 4h | All UI |
| M7.10 | Notarization & DMG creation script (or App Store Connect setup) | 📋 | 4h | All |

**Phase 7 total: ~29h.**

**End-of-phase checkpoint:** A signed, notarized DMG exists. App passes all four success criteria from `02_PRODUCT_SPEC.md` after 2 weeks of personal use.

---

## Summary

| Phase | Goal | Estimate |
|---|---|---|
| 0 | Spikes | 24h |
| 1 | Foundation | 11h |
| 2 | Mic detection + session lifecycle | 20h |
| 3 | Audio pipeline + speech engine | 28–32h |
| 4 | Analyzer | 19h |
| 5 | Widget UI | 22h |
| 6 | Stats window | 16h |
| 7 | Polish & ship | 29h |
| **Total** | **v1 complete** | **~169–173h focused effort** |

Multiplier for "macOS new to user" learning curve: ~1.3–1.5×. Realistic calendar:

- **At 8h/week (hobby pace):** 5–6 months
- **At 20h/week (serious side project):** 9–11 weeks
- **At 40h/week (full-time):** 5–6 weeks

This is **not a 1–2 week sprint**. The right reframe per Session 001 is "module by module, decide pace later."

---

## Recommended order of attack

1. Run all Phase 0 spikes (P0 first: S6, S7, S3, S4)
2. If P0 spikes pass, build Phases 1 → 2 → 3 in order (each unlocks the next)
3. Phase 4 can begin as soon as Phase 3 produces token streams
4. Phase 5 begins after Phase 4's session aggregation is stable (working on Phase 5 with broken metrics is a waste — you can't tune visual feedback for inputs you can't trust)
5. Phase 6 can run in parallel with later Phase 5 tasks
6. Phase 7 is the final pass — don't mix it with feature work

---

## What gets dropped if time pressure is real

In order of "drop first":

1. M7.9 (localized UI strings) — ship EN-only UI first
2. M6.5 (date-range filter)
3. M3.8 (mid-session language swap) — accept the "first session per app per language is wrong, then sticky" UX
4. M5.8 (drag-to-move) — pin to top-right corner
5. M2.6 (per-display position memory)
6. M7.2 (manual language override in menu bar) — power-users get the hotkey only

What does NOT get dropped:
- Anything in Phase 0 (skipping spikes is expensive later)
- M3.6 (silent model download with toast) — directly serves FM3 (no setup)
- M5.3 (smooth color interpolation) — directly serves FM1 (destructive UI)
- M4.1's VAD-aware WPM math — directly serves FM2 (unreliable data)
- Anything in M7.7, M7.8 (final perf + setup verification)
