# Speech Coach — Project Rules for Claude Code

> This file is read at the start of every Claude Code session. **Keep it lean.** Detailed reasoning lives in `docs/`.

---

## What this project is

A macOS menu bar app that runs silently in background, shows a translucent floating widget when the mic activates, and gives real-time speaking-pace + filler-word feedback. Local only, no cloud.

Full product spec: `@docs/02_PRODUCT_SPEC.md`
Architecture: `@docs/03_ARCHITECTURE.md`

---

## Hard requirements (failure modes — uninstall triggers)

These are not negotiable. Every change is evaluated against them.

- **FM1 — No destructive UI.** No flashing, no jitter, no animated reordering. Smooth color transitions only. Glanceable in <500ms peripheral vision.
- **FM2 — No unreliable data.** WPM must reflect speed-up/slow-down within ~3s. Pauses for breath must NOT crash the WPM number.
- **FM3 — No setup.** First launch ≤2 user actions. Permissions requested at point of use. Defaults work out of the box.
- **FM4 — No performance impact.** <5% sustained CPU during 1hr active session on Apple Silicon. <150MB RSS. No mic dropouts in Zoom.

---

## Always do

- **Plan before implementing.** Read context, produce a plan, stop, wait for approval before writing code. The user will explicitly say "Plan approved. Proceed." before any implementation.
- **TDD: tests first, committed, then implementation.** Commit failing tests as `test([module]): add failing tests for [feature]` before writing implementation. Do NOT modify those tests during implementation.
- **Run verification in a loop until green.** `xcodebuild -scheme SpeechCoach -destination 'platform=macOS' test`. Iterate until everything passes. Never report done with failing tests.
- **Self-review before reporting done.** Re-read the implementation against the acceptance criteria in the prompt. Quote each criterion and explain how it's met.
- **Use `os.Logger`** for any persistent diagnostics. The subsystem is `com.speechcoach.app`, with categories per module: `audio`, `speech`, `analyzer`, `widget`, `session`, `mic`.
- **Use `@MainActor`** for all UI updates. Audio work runs off the main thread.
- **Use Swift Concurrency (`async`/`await`, `AsyncStream`)** for streaming work, not Combine or callbacks (except where Apple APIs require callbacks).

## Never do

- **Modify tests committed in the red phase** to make them pass. Fix the implementation.
- **Use `print()`** in production code. `os.Logger` only.
- **Add new dependencies** without flagging in the plan first.
- **Enable Voice Processing IO** (`isVoiceProcessingEnabled`) on `AVAudioEngine.inputNode`. It must stay `false` to coexist with Zoom (see Spike #4 outcome in `@docs/05_SPIKES.md`).
- **Use the legacy `SFSpeechRecognizer`.** Use `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26+ API). Russian on legacy is broken; Russian on modern is supported.
- **Write transcripts to disk.** v1 schema stores metrics only — `Session` schema in `@docs/02_PRODUCT_SPEC.md`.
- **Use the network.** App entitlements have `com.apple.security.network.client = false`. Confirm before any URL session usage that would require enabling it.
- **Add UI for things parked to v1.x** (acoustic non-words, smart fillers, pitch, pauses as user-visible metric).
- **Use `localStorage`, `sessionStorage`, or any web-storage APIs** in any embedded WebViews.

---

## Project layout

```
SpeechCoach/
├── CLAUDE.md                          ← this file
├── docs/
│   ├── 00_COLLABORATION_INSTRUCTIONS.md
│   ├── 01_PROJECT_JOURNAL.md
│   ├── 02_PRODUCT_SPEC.md
│   ├── 03_ARCHITECTURE.md
│   ├── 04_BACKLOG.md
│   └── 05_SPIKES.md
├── SpeechCoach.xcodeproj/
├── Sources/
│   ├── App/                           ← SpeechCoachApp, MenuBarUI
│   ├── Core/                          ← SessionCoordinator, MicMonitor
│   ├── Audio/                         ← AudioPipeline, VAD, RMS
│   ├── Speech/                        ← SpeechEngine, LanguageDetector
│   ├── Analyzer/                      ← WPM, fillers, phrases, shouting
│   ├── Storage/                       ← SwiftData models, SessionStore
│   ├── Widget/                        ← FloatingPanel, WidgetViewModel
│   ├── Stats/                         ← StatsWindow + charts
│   └── Settings/                      ← Settings store, settings views
├── Tests/
│   ├── UnitTests/                     ← XCTest, one folder per Source module
│   └── IntegrationTests/              ← cross-module flow tests
└── Resources/
    ├── FillerDictionaries/            ← seeded EN, RU, ES json
    └── Localizations/
```

---

## Tech stack

- **Language:** Swift 6 (strict concurrency on)
- **Min target:** macOS 26.0 (Apple Silicon only)
- **UI:** SwiftUI (with AppKit interop where needed for `NSPanel`)
- **Audio:** `AVFoundation` (`AVAudioEngine`)
- **Speech:** `Speech` framework — `SpeechAnalyzer`, `SpeechTranscriber`
- **Persistence:** SwiftData
- **Charts:** Swift Charts
- **Logging:** `os.Logger`
- **Testing:** XCTest (Swift Testing acceptable for new code)

---

## Verification commands

```bash
# Run all tests
xcodebuild -scheme SpeechCoach -destination 'platform=macOS' test

# Build only (faster check)
xcodebuild -scheme SpeechCoach -destination 'platform=macOS' build

# Lint (if SwiftLint installed)
swiftlint --strict
```

After every change, run the test command. Iterate until it passes. If it fails, read the failure message and fix — do not skip tests, do not mark them as expected failures, do not mock around them.

---

## Useful Apple references for this project

When working on a module, the agent should fetch and read the relevant Apple docs:

- **`SpeechAnalyzer`:** https://developer.apple.com/documentation/speech/speechanalyzer
- **`SpeechTranscriber`:** https://developer.apple.com/documentation/speech/speechtranscriber
- **`AVAudioEngine`:** https://developer.apple.com/documentation/avfaudio/avaudioengine
- **`NSPanel`:** https://developer.apple.com/documentation/appkit/nspanel
- **`MenuBarExtra`:** https://developer.apple.com/documentation/swiftui/menubarextra
- **SwiftData:** https://developer.apple.com/documentation/swiftdata
- **Core Audio device properties:** https://developer.apple.com/documentation/coreaudio/audioobject_property_selectors

---

## Sub-agent usage

For modules in `Audio/`, `Speech/`, `Analyzer/`, or `Core/` (high-risk), end the work by spawning a reviewer sub-agent:

> *"Read [module path] fresh, without seeing my implementation conversation. Verify against the acceptance criteria from the prompt. Report any issues."*

For all other modules, the standard self-review checklist suffices.

---

## When you're stuck

1. Re-read the relevant doc in `@docs/`.
2. Read the Apple reference linked above.
3. Search the codebase for similar patterns (`Grep` / `Glob`).
4. If still stuck after 3 different approaches, **stop and report a specific blocker** with evidence — don't guess. The user will refine the prompt or open a spike.
