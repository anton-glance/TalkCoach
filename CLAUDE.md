# Speech Coach — Project Rules for Claude Code

> This file is read at the start of every Claude Code session. **Keep it lean.** Detailed reasoning lives in `docs/`.

---

## What this project is

A macOS menu bar app that runs silently in background, shows a translucent floating widget when the mic activates, and gives real-time speaking-pace + filler-word feedback. Local only, no cloud.

Full product spec: `@docs/02_PRODUCT_SPEC.md`
Architecture: `@docs/03_ARCHITECTURE.md`

---

## Reply formatting — copy-pasteable as a single block (mandatory)

Every text reply you produce in the Xcode chat panel — plans, self-reviews, status reports, diagnostic outputs, AC dispositions, sub-agent reviews, anything that is NOT a code edit to a file — must be copy-pasteable by the user as a single action. Xcode's chat panel does not allow selecting text across fenced-code-block boundaries. If your reply mixes prose paragraphs with separate fenced code blocks for snippets / file paths / commands, the user cannot Cmd+A → Cmd+C → paste the whole reply to the architect. This breaks the audit and smoke-gate evidence workflow.

Pick ONE of these two formats for the entire reply:

(a) Entirely plain prose and indented text. No fenced code blocks anywhere. Inline code uses single backticks only. Multi-line code snippets use 4-space indentation, not fences. File paths and commands in single backticks.

(b) Entirely inside ONE fenced code block. The whole reply, including any prose, lives inside one triple-backtick pair. User can click inside, Cmd+A, Cmd+C in one action.

Never mix. Do not produce a reply that contains prose AND separate fenced blocks. That's the failure mode that breaks the workflow.

Default choice:
- Plans, reviews, status reports, AC dispositions, prose-heavy outputs → format (a)
- Replies that are mostly code, command sequences, or diff output → format (b)
- When unsure, prefer (a) — prose with backtick-quoted code is more readable and still single-selectable.

This rule applies to:
- Text replies in the Xcode chat panel
- Phase 1 plan outputs
- Phase 3 self-review marker block reproductions
- Sub-agent review reports
- Diagnostic outputs the user is expected to paste back to architect
- Any status update the user might need to forward

This rule does NOT apply to:
- Actual code edits you make to files in the repo (those use whatever Swift/Markdown/etc. format the file requires)
- Tool calls you make (those use the tool's required structured format)

If you find yourself instinctively reaching for a fenced block in the middle of a prose reply, stop. Re-read this section. Convert the snippet to an indented block within the prose, OR convert the entire reply into format (b). Never both formats in one reply.

---

## Hard requirements (failure modes — uninstall triggers)

These are not negotiable. Every change is evaluated against them.

- **FM1 — No destructive UI.** No flashing, no jitter, no animated reordering. Smooth color transitions only. Glanceable in <500ms peripheral vision.
- **FM2 — No unreliable data.** WPM must reflect speed-up/slow-down within ~3s. Pauses for breath must NOT crash the WPM number.
- **FM3 — Minimal setup.** Settings window auto-opens on first launch with language picker (1–2 languages from ~50 supported, system locale pre-checked). Mic permission grant at first session start. Model downloads require user confirmation in Settings. No tutorials, no further configuration. See `@docs/02_PRODUCT_SPEC.md`.
- **FM4 — No performance impact.** <5% sustained CPU during 1hr active session on Apple Silicon. <150MB RSS. No mic dropouts in Zoom.

---

## Always do

- **Plan before implementing.** Read context, produce a plan, stop, wait for approval before writing code. The user will explicitly say "Plan approved. Proceed." before any implementation.
- **TDD: tests first, committed, then implementation.** Commit failing tests as `test([module]): add failing tests for [feature]` before writing implementation. Do NOT modify those tests during implementation.
- **Run verification in a loop until green.** `xcodebuild -scheme TalkCoach -destination 'platform=macOS' test`. Iterate until everything passes. Never report done with failing tests.
- **Self-review before reporting done.** Re-read the implementation against the acceptance criteria in the prompt. Quote each criterion and explain how it's met.
- **Use `os.Logger`** for any persistent diagnostics. The subsystem is `com.talkcoach.app`, with categories per module: `audio`, `speech`, `analyzer`, `widget`, `session`, `mic`.
- **Use `@MainActor`** for all UI updates. Audio work runs off the main thread.
- **Use Swift Concurrency (`async`/`await`, `AsyncStream`)** for streaming work, not Combine or callbacks (except where Apple APIs require callbacks).
- **Define audio tap closures in non-main-actor source files.** Audio tap callbacks run on Core Audio's `RealtimeMessenger.mServiceQueue`. Closures defined in `@MainActor`-isolated context (e.g., `@main struct` body, `main.swift` top level) crash at runtime under Swift 6 strict concurrency with `_dispatch_assert_queue_fail` — no compile warning. Capture non-Sendable types like `AVAudioEngine`/`AVAudioInputNode` with `nonisolated(unsafe)`. (Spike #4 finding, Session 008.)
- **Observe `AVAudioEngineConfigurationChange`** in any module that installs an `AVAudioEngine` input tap. Browser-based conferencing (Chrome/Safari Meet) joining mid-session triggers this notification and stops the engine. Recovery is restart engine + reinstall tap with `format: nil`. Routine Apple pattern, not an exception case. (Spike #4 finding, Session 008.)
- **Install audio taps with `format: nil`.** Never hardcode channel count or sample rate. Safari Meet changes input from 1→3 channels mid-session; a hardcoded format crashes on that transition. (Spike #4 finding.)

## Never do

- **Modify tests committed in the red phase** to make them pass. Fix the implementation.
- **Use `print()`** in production code. `os.Logger` only.
- **Add new dependencies** without flagging in the plan first.
- **Enable Voice Processing IO** (`isVoiceProcessingEnabled`) on `AVAudioEngine.inputNode`. It must stay `false` to coexist with Zoom (see Spike #4 outcome in `@docs/05_SPIKES.md`).
- **Use the legacy `SFSpeechRecognizer`.** Use `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26+ API) for Apple-supported locales, route Russian (and other Apple-unsupported locales) to `ParakeetTranscriberBackend` per Architecture Y.
- **Assume Apple supports a locale based on `supportedLocale(equivalentTo:)`.** That helper returns misleadingly successful results for locales like `ru_RU` that are NOT actually in `SpeechTranscriber.supportedLocales`. Always check the explicit enumeration. (Session 006 lesson.)
- **Write transcripts to disk.** v1 schema stores metrics only — `Session` schema in `@docs/02_PRODUCT_SPEC.md`.
- **Use the network during a session.** App entitlements have `com.apple.security.network.client = true` ONLY for one-time model downloads at first use of a declared language: Apple `AssetInventory` locale models, Parakeet model from CDN (Architecture Y, Session 006), and Whisper-tiny LID model for Latin↔CJK pairs (Session 010). NEVER call the network during a session — no telemetry, no transcripts uploaded, no remote config, no analytics. Audio never leaves the device.
- **Add UI for things parked to v1.x** (acoustic non-words, smart fillers, pitch, pauses as user-visible metric, monologue detector, UI localization).
- **Add UI for things parked to v2** (per-app blocklist, StatsWindow/session history, hotkey, session-end summary, shouting detector, trail-off detector).
- **Use `localStorage`, `sessionStorage`, or any web-storage APIs** in any embedded WebViews.

---

## Project conventions (Phase 1)

These seven patterns were established and tested across Phase 1's six modules. They are project-wide rules — every new module applies them. See `@docs/01_PROJECT_JOURNAL.md` Session 015 for the full rationale.

1. **Info.plist mechanism.** The physical file at `Sources/App/Info.plist` is the single source of truth. `GENERATE_INFOPLIST_FILE = YES` + `INFOPLIST_FILE = Sources/App/Info.plist` + zero `INFOPLIST_KEY_*` build settings. New plist keys (usage descriptions, URL schemes) edit the physical file directly. (M1.1)

2. **Swift 6 strict concurrency.** `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set project-wide. Top-level declarations are implicitly `@MainActor`. For tests calling into MainActor-isolated code, annotate the test class itself: `@MainActor final class FooTests: XCTestCase`. For pure functions or constants needing both-context callability, mark them explicitly `nonisolated`. For `@ModelActor` types, tests stay non-MainActor and use `await` with `async throws` test methods. (M1.2)

3. **AppKit `NSWindow` via `NSHostingController` for any window beyond MenuBarExtra.** SwiftUI `Window(id:)` + `openWindow` is unreliable in `LSUIElement` apps. The standard pattern: `NSHostingController(rootView: SomeView())` wrapped in an `NSWindow` owned by `AppDelegate`, opened via `AppDelegate.current?.openSomeWindow()`. Use `NSAlert.runModal()` for app-level alerts (no host window required). (M1.3)

4. **`AppDelegate.current` static-reference accessor.** Reach the AppDelegate from anywhere via `AppDelegate.current`, declared as `static private(set) weak var current: AppDelegate?` and set to `self` in `override init()`. Do NOT use `NSApp.delegate as? AppDelegate` — `@NSApplicationDelegateAdaptor` registers SwiftUI's proxy class as `NSApp.delegate`, so the cast always returns nil. Locked by `testAppDelegateCurrentIsSetAfterInit`. (M1.6 fix)

5. **`UserDefaults.didChangeNotification` live-sync.** Stores wrapping `UserDefaults` (like `SettingsStore`) need to react to external writers (e.g., `@AppStorage` toggles in `MenuBarContent` while a downstream consumer reads through the store). Pattern: `NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { ... }` registered in `init`, observer token stored as `nonisolated(unsafe) private var observer: (any NSObjectProtocol)?`, removed in `deinit`. An `isSyncing` guard inside the closure prevents feedback loops. (M1.4)

6. **`nonisolated Sendable` record types as the `@ModelActor` boundary.** SwiftData `@Model` types are non-Sendable. `SessionStore`'s public API exposes `nonisolated struct Sendable` record types (`SessionRecord`, `WPMSampleRecord`, `FillerCountRecord`, `RepeatedPhraseRecord`) that cross the actor boundary safely. `@Model` instances are constructed inside the actor from records on `save()` and converted back to records before crossing out on `fetch...()`. Production callers work with records, never `@Model` directly. (M1.5)

7. **Protocol injection for system-API testing.** System APIs that show real OS dialogs or query OS state (e.g., `AVCaptureDevice.requestAccess`, `SFSpeechRecognizer.requestAuthorization`, future `MicMonitor` / `AVAudioEngine` calls) cannot be unit-tested directly. Pattern: define a `XStatusProvider: Sendable` protocol; production implementation is a struct (stateless, trivially Sendable) wrapping the real APIs via `withCheckedContinuation` for callback-to-async; test implementation is a class (`@unchecked Sendable`) recording calls and returning configurable values. (M1.6, generalizes to Phase 2's `MicMonitor` and Phase 3's audio path.)

**Manual smoke gate for OS integrations.** Modules wrapping OS-level integrations (window management, permissions, audio, speech, system events) require a manual smoke gate before `git tag -a mX.Y-complete`. Mocked unit tests verify *logic*; manual smoke verifies *wiring*. The M1.6 `AppDelegate.current` bug existed for three modules before manual smoke caught it.

---

## Project layout

```
TalkCoach/
├── CLAUDE.md                          ← this file
├── docs/
│   ├── 00_COLLABORATION_INSTRUCTIONS.md
│   ├── 01_PROJECT_JOURNAL.md
│   ├── 02_PRODUCT_SPEC.md
│   ├── 03_ARCHITECTURE.md
│   ├── 04_BACKLOG.md
│   └── 05_SPIKES.md
├── design/                            ← visual source of truth for widget ONLY (see note below)
│   ├── README.md                      ← full visual spec
│   ├── widget-reference.html          ← interactive visual reference
│   └── Sources/                       ← reference SwiftUI: DesignTokens, Views, Window
├── TalkCoach.xcodeproj/
├── Sources/
│   ├── App/                           ← TalkCoachApp, MenuBarUI
│   ├── Core/                          ← SessionCoordinator, MicMonitor
│   ├── Audio/                         ← AudioPipeline (buffer transport only, no RMS)
│   ├── Speech/                        ← TranscriptionEngine, AppleTranscriberBackend, ParakeetTranscriberBackend, LanguageDetector
│   ├── Analyzer/                      ← SpeakingActivityTracker, WPM, fillers, phrases
│   ├── Storage/                       ← SwiftData models, SessionStore
│   ├── Widget/                        ← FloatingPanel, WidgetViewModel
│   └── Settings/                      ← Settings store, settings views
├── Tests/
│   ├── UnitTests/                     ← XCTest, one folder per Source module
│   └── IntegrationTests/              ← cross-module flow tests
├── Resources/
│   ├── FillerDictionaries/            ← seeded EN, RU, ES json (others empty until user adds)
│   └── Localizations/
└── [throwaway spike directories at repo root: WPMSpike/, ParakeetSpike/, MicCoexistSpike/, LangDetectSpike/]
```

**`design/` package note:** The design directory is the visual source of truth for the widget (layout, typography, colors, animations, accessibility). Its architecture section (§8), speech analysis logic (§9), WPM calculation (§9.2), filler detection set (§9.3), and scope assumptions (§16) are **superseded** by `@docs/02_PRODUCT_SPEC.md` and `@docs/03_ARCHITECTURE.md`. When design and docs disagree on anything other than visual treatment, docs win.

---

## Tech stack

- **Language:** Swift 6 (strict concurrency on)
- **Min target:** macOS 26.0 (Apple Silicon only)
- **UI:** SwiftUI (with AppKit interop where needed for `NSPanel`)
- **Audio:** `AVFoundation` (`AVAudioEngine`)
- **Speech:** `Speech` framework — `SpeechAnalyzer`, `SpeechTranscriber` (Apple path); FluidAudio + Parakeet Core ML (non-Apple locales like Russian); WhisperKit + Whisper-tiny (LID for Latin↔CJK pairs)
- **Persistence:** SwiftData
- **Logging:** `os.Logger`
- **Testing:** XCTest (Swift Testing acceptable for new code)

---

## Verification commands

```bash
# Run all tests
xcodebuild -scheme TalkCoach -destination 'platform=macOS' test

# Build only (faster check)
xcodebuild -scheme TalkCoach -destination 'platform=macOS' build

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
- **`AVAudioEngineConfigurationChange`:** https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchange
- **`NSPanel`:** https://developer.apple.com/documentation/appkit/nspanel
- **`MenuBarExtra`:** https://developer.apple.com/documentation/swiftui/menubarextra
- **`NLLanguageRecognizer`:** https://developer.apple.com/documentation/naturallanguage/nllanguagerecognizer
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
