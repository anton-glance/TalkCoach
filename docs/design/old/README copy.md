# Locto

Ambient AI speech coach for macOS. Auto-appears when your microphone activates. Tracks pace and filler words in real time. Privacy-first: audio never leaves your device.

[locto.io](https://locto.io)

## What's in this repo

- `CLAUDE.md` — orientation for Claude Code agents working on this codebase
- `docs/` — product, design, data-model, and build-phase specs
- `brand/` — visual identity assets and guidelines
- `Locto/` — app source (after Xcode project is set up)

## The product

Two surfaces:

- **Ambient widget.** Auto-appears whenever the Mac's microphone becomes active (any app — Zoom, Meet, browser, podcast tool, anything). Shows live speaking pace (rushing / slow / on-target) and counts filler words ("so", "right", "you know") in real time. Closes when mic deactivates.
- **Dashboard.** Opened from the menu bar icon. Deeper post-session analysis, trends over time, plain-English coach notes.

## Tech stance

- **macOS native** (Swift, SwiftUI, AppKit where needed). No Electron.
- **On-device transcription.** Audio never leaves the Mac. Non-negotiable.
- **Mac App Store + direct download** distribution. Same binary, different signing/notarization paths.

## Quick start

(Set up after Xcode project is initialized.)

```sh
open Locto.xcodeproj
# Build and run from Xcode
```

Or from CLI:

```sh
xcodebuild -scheme Locto -configuration Debug build
```

## Brand

`brand/locto-brand-guidelines.html` is the visual identity source of truth. Open in any browser. Brand teal `#0F6E56`. Inter type stack. State palette (slate / sage / coral) for in-product feedback only — never as brand identity.

## Documentation map

| File | Read when |
|---|---|
| `CLAUDE.md` | Onboarding to the codebase. Read first. |
| `docs/01-product.md` | You need to know what to build. |
| `docs/02-design-spec.md` | You're implementing a UI surface or component. |
| `docs/03-data-model.md` | You're touching persistence or analytics. |
| `docs/04-build-phases.md` | You're scoping a feature — is it MVP, v1.0, or later? |
| `docs/05-open-questions.md` | You hit a decision that needs the founder. |
| `brand/locto-brand-guidelines.html` | You need a color, type size, or component spec. |

## License

(Decision pending — see `docs/05-open-questions.md`. For a closed-source commercial product, this section can be omitted and an "All rights reserved" notice added to source files.)
