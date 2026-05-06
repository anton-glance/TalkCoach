# Locto — project context for Claude Code

Locto is an ambient AI speech coach for macOS. It auto-appears whenever the Mac's microphone becomes active (Zoom, Meet, browser, any app), shows live speaking pace and counts filler words in real time, and offers deeper post-session analytics in a dashboard.

This file orients a Claude Code agent to the project. Read it first.

## Mission

Help users become better speakers by giving them ambient, real-time, private feedback during the conversations they're already having. No per-session setup. No audio leaving the device.

## Non-negotiables

These shape every implementation decision. Violating any of them is a regression even if the code compiles.

1. **Audio never leaves the Mac.** Transcription is fully on-device. No cloud APIs for speech recognition (OpenAI Whisper API, Deepgram, AssemblyAI, etc.). Use Apple Speech framework, whisper.cpp, or another fully-local model. The on-device story is the load-bearing differentiator and the privacy promise — break it and the product loses its reason to exist.
2. **Mac-native.** No Electron. No web views for primary UI. SwiftUI for greenfield surfaces; AppKit where SwiftUI doesn't cover (NSStatusItem for menu bar, NSPanel for the floating widget).
3. **Auto-trigger.** The widget appears automatically when the system microphone goes hot. Zero user action required to start a session. Use CoreAudio process monitoring or AVAudioEngine to detect mic activity.
4. **No telemetry that exfiltrates user content.** Anonymous crash reports and aggregate usage counters are fine. Transcripts, audio buffers, or any session content leaving the device is not.

## Project layout

The design source-of-truth lives alongside the code. Recommended structure:

```
/                                       — repo root
├── CLAUDE.md                           (this file)
├── README.md                           (general project README)
├── docs/
│   ├── 01-product.md                   (product spec, scope, user flow)
│   ├── 02-design-spec.md               (component specs, IA, motion, edge cases)
│   ├── 03-data-model.md                (entity schema, persistence, privacy boundary)
│   ├── 04-build-phases.md              (MVP → v1.0 → v1.1 phasing)
│   └── 05-open-questions.md            (decisions still pending)
├── brand/
│   ├── locto-brand-guidelines.html     (visual identity — open in browser)
│   ├── locto-mark.svg
│   ├── locto-menubar.svg
│   ├── locto-app-icon.svg
│   ├── locto-wordmark.svg
│   └── locto-lockup.svg
├── Locto.xcodeproj
├── Locto/                              (app source)
│   ├── App/                            (entry point, app delegate, status item)
│   ├── Features/
│   │   ├── Widget/                     (ambient pace widget)
│   │   ├── Dashboard/                  (analytics window)
│   │   ├── Onboarding/                 (first-run flow + permissions)
│   │   └── Settings/
│   ├── Shared/
│   │   ├── Audio/                      (mic activity detection, VAD)
│   │   ├── Transcription/              (on-device speech-to-text)
│   │   ├── Analytics/                  (pace, filler computation)
│   │   ├── Persistence/                (SQLite via GRDB or Core Data)
│   │   └── DesignSystem/               (Color+, Font+, components)
│   └── Resources/
│       └── Assets.xcassets             (brand assets imported)
└── LoctoTests/
```

Exact code structure is at the engineer's discretion, but `docs/` and `brand/` travel with the repo.

## Where to look

- **For visual specs (any color, type size, component measurement):** `brand/locto-brand-guidelines.html` is the single source of truth. Open it in a browser. Hex values, type ramp, component padding, all pixel-exact.
- **For what to build:** `docs/01-product.md` for scope, `docs/02-design-spec.md` for component-level behavior.
- **For what's still undecided:** `docs/05-open-questions.md`. Surface these to Anton before assuming.
- **For phasing:** `docs/04-build-phases.md`. Don't pull Phase 2 features into MVP.

## Coding conventions

- **Swift only.** No Objective-C unless interfacing with a legacy framework that requires it.
- **SwiftUI first.** AppKit only where SwiftUI doesn't cover.
- **Async/await for concurrency.** No completion handlers in new code; wrap legacy APIs if needed.
- **No force-unwraps on production paths.** `guard let` / `if let`.
- **One feature, one folder.** Each `Features/<feature>/` contains its own views, view models, feature-local utilities, and tests.
- **Design tokens in code.** Colors, type sizes, spacing live in `Shared/DesignSystem/` as Swift constants. Never hardcoded hex in feature code. Constants must match `brand/locto-brand-guidelines.html` exactly.
- **Privacy in code.** Anything that touches transcripts, audio buffers, or user content has `// privacy: …` comments explaining the boundary. Reviewers should reject changes that send user content over the network.

## What NOT to add

- Any analytics or telemetry SDK that ships transcripts or audio off-device.
- Cloud-based speech recognition.
- Sign-in / account systems for MVP. The product is local-first; accounts come post-PMF.
- Electron wrappers or web views for primary UI.
- Tracking pixels in marketing emails.
- Notifications that interrupt the user's flow during an active mic session — feedback is in the widget, not in NotificationCenter.

## Surfacing open questions

Before implementing major decisions (which transcription engine, which persistence layer, dark-mode treatment, multilingual roadmap), check `docs/05-open-questions.md`. If a question isn't answered there and is blocking your work, ask Anton — don't pick the answer yourself.

## Build, test, run

(Fill in after Xcode project is set up.)

```sh
# Build
xcodebuild -scheme Locto -configuration Debug build

# Test
xcodebuild -scheme Locto test

# Run
open ./build/Debug/Locto.app
```

## Brand quick reference

- Brand teal: `#0F6E56`
- Type: Inter, weights 300 / 400 / 500 / 600
- See `brand/locto-brand-guidelines.html` for everything else.
