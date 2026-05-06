# Talking Coach — design package

A floating macOS 26 utility widget that listens to the active microphone, computes your speaking pace in words-per-minute, and surfaces your three most-used filler words. Glass tile, color-coded by pace, sits on top of all windows.

This package is the source of truth for engineering. Everything below is a directive — names, sizes, colors, thresholds, and code shapes are fixed unless flagged otherwise.

---

## 0. Audience & ground rules

**Audience.** A coding agent working in Xcode 26+ with Swift 6 and SwiftUI. Target platform: macOS 26 (Tahoe) or later — Liquid Glass and `SpeechAnalyzer` are required.

**Apple guidelines this package is built against.**
- [Human Interface Guidelines — Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [HIG — Color](https://developer.apple.com/design/human-interface-guidelines/color)
- [HIG — Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- [HIG — Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [HIG — Privacy](https://developer.apple.com/design/human-interface-guidelines/privacy)
- [SwiftUI — Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views)
- [`glassEffect(_:in:)`](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:))
- [WWDC25 — Build a SwiftUI app with the new design (323)](https://developer.apple.com/videos/play/wwdc2025/323/)
- [WWDC25 — Bring advanced speech-to-text to your app with SpeechAnalyzer (277)](https://developer.apple.com/videos/play/wwdc2025/277/)
- [`SpeechAnalyzer`](https://developer.apple.com/documentation/speech/speechanalyzer)
- [`NSPanel.StyleMask.nonactivatingPanel`](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)

**Non-negotiables.**
1. Honor `Reduce Transparency`. Liquid Glass collapses to a solid surface fallback when the user has it on (re-enabled in 26.3 — verify per release).
2. Honor `Reduce Motion`. All transition durations clamp to `0` when this is on.
3. Microphone and speech recognition are gated by user permission. The widget never appears before authorization completes.
4. The widget never steals focus. It is a non-activating panel.
5. The widget has no Dock icon. The app is `LSUIElement`.

---

## 1. Product summary

**What it does.** When the system microphone becomes active and the user is speaking, the widget appears in the upper-right of the active display. It shows three things:

- A live words-per-minute number (current pace).
- A pace state — `TOO SLOW`, `IDEAL`, or `TOO FAST` — and the running session average.
- A spectrum bar that gradually shifts blue → green → red as pace deviates from ideal, with a caret pointer marking current pace.
- A list of the user's three most-used filler words, with horizontal bar lengths proportional to count.

**What it doesn't do.** Record audio. Save transcripts. Send anything off-device. There is no settings UI in v1.

**Form factor.** A 144×144pt floating glass tile. Anchored to the upper-right corner of the active screen by default; user can drag to reposition (position persists per display).

**When it shows.** Visible while the microphone is active *and* the app has speech-recognition authorization. Hidden when the mic is off.

---

## 2. Final visual design

The full reference is `widget-reference.html` in this package — open it in Safari/Chrome to see all three pace states (TOO SLOW / IDEAL / TOO FAST) and to inspect the rendered geometry.

```
┌─────────────────────────────┐
│                             │
│            168              │  ← WPM (SF Pro Display, 34pt, weight .light)
│   IDEAL · avg 142           │  ← state · separator · avg (8.5pt)
│  ─────────────▼───────────  │  ← spectrum bar + caret pointer below
│                             │
│  uh         ▮▮▮▮▮▮▮         │  ← word + trimmed pillars
│  right      ▮▮▮▮            │
│  basically  ▮▮              │
│                             │
└─────────────────────────────┘
                                  144 × 144 pt, corner radius 32pt
                                  Liquid Glass tinted by pace zone
```

### 2.1 Layout (top → bottom)

| Region | Height | Notes |
|---|---|---|
| Padding top | 11pt | |
| WPM number | 34pt | SF Pro Display, weight `.light`, tracking -1.87pt, line-height 1.0 |
| Gap | 4pt | |
| State row | ~10pt | `STATE · avg N` single line, baseline-aligned, see §2.3 |
| Gap (auto) | flexes | grid `auto auto 1fr` distributes |
| Spectrum block | 16pt | bar + caret region (see §2.4) |
| Gap (auto) | flexes | |
| Bottom block | flexes (~46pt) | 3 filler rows, see §2.5 |
| Padding bottom | 11pt | |

Total: 144pt. Horizontal padding: 13pt. Use `Grid` with `gridCellAnchor(.center)` or `VStack` with `Spacer()` between regions for the auto distribution.

### 2.2 WPM number

- Font: `system(size: 34, weight: .light, design: .default)` (SF Pro Display)
- Tracking: `-1.87` pt (≈ -0.055em at 34pt)
- Line height: `1.0`
- Color: `textDeep` (interpolates with pace, see §3)
- Tabular numerals: yes — apply `.monospacedDigit()` so width doesn't jitter as the value changes

### 2.3 State row

A single horizontal row, centered, baseline-aligned. Three children:

| Element | Font / size | Weight | Tracking | Opacity | Casing |
|---|---|---|---|---|---|
| State | 8.5pt | `.bold` (700) | 1.36pt (≈ 0.16em) | 0.85 | UPPERCASE |
| Separator `·` | 8.5pt | `.regular` | — | 0.32 | — |
| Avg | 8.5pt | `.regular` | 0.34pt (≈ 0.04em) | 0.50 | "avg ###" |

State strings: `"TOO SLOW"`, `"IDEAL"`, `"TOO FAST"`. Avg format: `"avg \(roundedAvg)"`.

### 2.4 Spectrum + caret

Container region is 16pt tall, full inner width.

- **Spectrum bar.** 2pt tall, top-inset 5pt within the region, full width. Linear gradient left → right with three stops:
  - 0% — `slowBase` (rgb 86,135,197) at α 0.78
  - 37.5% — `idealBase` (rgb 108,207,160) at α 0.78
  - 100% — `fastBase` (rgb 216,98,90) at α 0.78
  - Corner radius 99pt (capsule).
- **Caret.** An equilateral-ish upward triangle, 8pt wide × 5pt tall, positioned with `top: 9pt` (≈ 2pt below the bar), centered horizontally on the WPM-mapped percentage. Filled with `textDeep` (current pace color). Render with `Path` or as a `Shape`.

Caret X position (% of inner spectrum width):
```
pct = clamp((wpm - 80) / (240 - 80), 0, 1)
x   = pct * spectrumInnerWidth
```

### 2.5 Filler rows (Bars · Trimmed — the winning treatment)

Three rows, vertical stack, gap 5pt, vertically centered in the bottom block.

Each row: `[ word | pillars ]` two-column grid:

- **Word column.** Fixed 56pt wide. SF Pro, 8.5pt, weight `.medium`, opacity 0.88. Truncate with ellipsis if a word is longer than the column (`basically` is the longest expected single-word filler).
- **Pillars column.** Horizontal stack of pillars, left-aligned (`leading`), gap 2pt.
  - Pillar size: 2.5pt wide × 9pt tall.
  - Pillar shape: `RoundedRectangle(cornerRadius: 1)`.
  - Pillar fill: `textDeep` at α 0.95.
  - **Number of pillars rendered = `min(count, MAX_PILLARS)`. No empty / dim pillars.**
  - `MAX_PILLARS = 10`. If `count > MAX_PILLARS`, render 10 pillars and append a `+` glyph (8pt, opacity 0.6) immediately after the last pillar.

Selection of which 3 words to show: take the top 3 by count, descending. Tie-break: alphabetical.

---

## 3. Color system

Color is the primary signal. Glass tint, text "deep" color, and pillar color all derive from a single function `colorsFor(wpm:)`.

### 3.1 Constants

| Token | RGB | Used for |
|---|---|---|
| `slowBase` | 86, 135, 197 | Tint at far slow |
| `idealBase` | 108, 207, 160 | Tint at ideal target (140 wpm) |
| `fastBase` | 216, 98, 90 | Tint at far fast |
| `slowDeep` | 29, 68, 118 | Text/caret/pillars at far slow |
| `idealDeep` | 31, 90, 64 | Text/caret/pillars at ideal |
| `fastDeep` | 110, 50, 32 | Text/caret/pillars at far fast |

### 3.2 Pace constants

| Token | Value |
|---|---|
| `wpmIdeal` | 140 |
| `wpmMin` | 80 |
| `wpmMax` | 240 |
| `slowThreshold` | 115 |
| `fastThreshold` | 175 |

State logic:
```
wpm < 115             →  "TOO SLOW"
115 <= wpm <= 175     →  "IDEAL"
wpm > 175             →  "TOO FAST"
```

### 3.3 Color interpolation

Continuous, eased fade so colors stay near green inside the IDEAL band:

```swift
// pseudo
let ease: (Double) -> Double = { pow($0, 1.6) }

if wpm <= 140 {
  let t = ease( clamp((140 - wpm) / (140 - 80), 0, 1) )
  tint = mix(idealBase, slowBase, t)
  deep = mix(idealDeep, slowDeep, t)
} else {
  let t = ease( clamp((wpm - 140) / (240 - 140), 0, 1) )
  tint = mix(idealBase, fastBase, t)
  deep = mix(idealDeep, fastDeep, t)
}
```

Glass tint alpha:
- Resting: `0.42`
- Hover (cursor over widget): `0.62`

### 3.4 Light vs dark mode

The colors above are calibrated for light mode and read correctly against any wallpaper because the glass material absorbs and scatters the backdrop. They also work in dark mode without modification — the dark backdrop just makes the tile feel slightly more saturated, which is acceptable. **Do not** introduce a separate dark palette in v1.

### 3.5 Reduce Transparency fallback

When `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency` is true:
- Replace `.glassEffect(.regular.tint(...), in: ...)` with a solid fill of `tint` at α `1.0` (use the underlying base color, not the glass-tinted variant).
- Drop the inner highlights and `backdrop-blur`.
- Keep the outer drop shadow so the tile still reads as a separate object.
- Subscribe to `NSWorkspace.didChangeAccessibilityDisplayOptionsNotification` and re-render.

---

## 4. Liquid Glass usage

Apply `glassEffect` directly to the widget's root view. Do **not** wrap multiple sibling glass views — there's only one glass surface in this widget.

```swift
RoundedRectangle(cornerRadius: 32, style: .continuous)
  .fill(.clear)
  .glassEffect(.regular.tint(zoneTint), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
```

- Use `Glass.regular`. Do not use `.clear` (we need the material to read as a tile, not an outline) or `.identity` (that's for transitions).
- The `tint` is the live `Color(rgb: tint, opacity: 0.42)`.
- Animate the tint with `.animation(.easeInOut(duration: 0.45), value: zoneTint)` on the wrapping container.
- Outer shadow is added separately via `.shadow(color: .black.opacity(0.18), radius: 28, x: 0, y: 8)` on the outer container (not the glass view itself, to avoid clipping).
- Border hairline: a `RoundedRectangle(cornerRadius: 32, style: .continuous).stroke(.white.opacity(0.55), lineWidth: 0.5)` overlay. Increase to `0.78` on hover.

`GlassEffectContainer` is unused — there is only one glass element. Do not introduce one prematurely.

---

## 5. Typography

Use system fonts. Do not bundle custom fonts.

| Token | SwiftUI |
|---|---|
| `wpmFont` | `.system(size: 34, weight: .light, design: .default)` + `.monospacedDigit()` |
| `stateFont` | `.system(size: 8.5, weight: .bold, design: .default)` |
| `avgFont` | `.system(size: 8.5, weight: .regular, design: .default).monospacedDigit()` |
| `fillerWordFont` | `.system(size: 8.5, weight: .medium, design: .default)` |

**Dynamic Type.** This widget uses fixed sizes by design — it must fit in 144×144pt. Do not bind to Dynamic Type. If accessibility scaling is critical, expose an "Accessibility size" preference in v2 that swaps to a 200×200pt tile with proportionally larger type.

**Tracking conversion (CSS em → SwiftUI tracking).** Multiply by font size in points: `tracking_pt = em * fontSize`. Examples for this widget:
- WPM `letter-spacing: -0.055em` at 34pt → `.tracking(-1.87)`
- State `letter-spacing: 0.16em` at 8.5pt → `.tracking(1.36)`
- Avg `letter-spacing: 0.04em` at 8.5pt → `.tracking(0.34)`

---

## 6. Animations

| Property | Duration | Curve |
|---|---|---|
| Tint / deep color | 0.45s | `easeInOut` |
| Caret position | 0.35s | spring `(response: 0.45, dampingFraction: 0.8)` or `easeInOut` |
| WPM number value (numeric tween) | 0.30s | `easeOut` |
| Hover transform / shadow | 0.28s | `easeOut` |
| Show / hide entire widget | 0.35s | `easeInOut` (fade + 4pt y-offset) |

Clamp all durations to `0` when `accessibilityReduceMotion` is on.

For the WPM number, use `.contentTransition(.numericText(value: Double(wpm)))` so digits roll smoothly.

---

## 7. State model

The widget consumes a single `WidgetState` value:

```swift
struct WidgetState: Equatable {
  var isMicActive: Bool          // mic on/off → drives visibility
  var currentWPM: Int            // live pace
  var averageWPM: Int            // session running average
  var topFillers: [FillerEntry]  // top 3 by count, descending
  var paceZone: PaceZone         // .tooSlow | .ideal | .tooFast
}

struct FillerEntry: Equatable, Identifiable {
  let id: String       // the word itself
  let word: String
  let count: Int
}

enum PaceZone { case tooSlow, ideal, tooFast }
```

Visibility is derived: `widget.isHidden = !state.isMicActive`.

---

## 8. Architecture

### 8.1 Module layout

```
TalkingCoach/
├── TalkingCoachApp.swift          ← @main, wires the panel
├── DesignTokens.swift             ← all numeric / color constants
├── Views/
│   └── TalkingCoachWidget.swift   ← root view + 3 subviews
├── Services/
│   └── SpeechAnalyzerService.swift← SpeechAnalyzer + pace + filler logic
├── Window/
│   └── FloatingPanel.swift        ← NSPanel subclass + controller
└── Info-keys.md                   ← what to add to Info.plist
```

### 8.2 Data flow

```
[mic] → AVAudioEngine
        ↓
SpeechTranscriber  →  word stream w/ timestamps
        ↓
PaceCalculator     →  current WPM (sliding 30s window) + avg WPM
FillerDetector     →  top-3 filler counts
        ↓
@Published state on SpeechAnalyzerService (ObservableObject)
        ↓
TalkingCoachWidgetView observes via @StateObject
```

The view is a pure function of state — no logic in views.

### 8.3 Threading

- `AVAudioEngine` and `SpeechAnalyzer` run off the main thread (use a dedicated `Task` actor).
- All state mutations on the service are dispatched to `@MainActor` before publishing.
- Views read `@Published` properties; they re-render on the main thread automatically.

---

## 9. Speech analysis

Use **`SpeechAnalyzer` + `SpeechTranscriber`** (macOS 26+). Do not use the legacy `SFSpeechRecognizer` for this app — `SpeechAnalyzer` is faster, fully on-device, and handles long-form audio without dropping out.

### 9.1 Authorization flow

1. On app launch, check `AVCaptureDevice.authorizationStatus(for: .audio)` and `SFSpeechRecognizer.authorizationStatus()` (the new APIs delegate to the same TCC entitlement family — verify against current docs).
2. If `.notDetermined`, request both, in order: mic first, speech second.
3. If either is denied, show a one-time menu-bar item that opens System Settings → Privacy.
4. The widget panel never opens until both are `.authorized`.

### 9.2 WPM calculation

- **Words.** Each word from `SpeechTranscriber` arrives with a timestamp. Append to a ring buffer keyed by timestamp.
- **Current WPM.** Count words in the trailing 30-second window, multiply by 2. Recompute every 500ms via a `Timer` or `Task.sleep` loop. Don't recompute on every word — that creates jitter.
- **Average WPM.** `totalWords / sessionMinutes` where `sessionMinutes` is mic-active time only. Reset on mic-off-then-on.

### 9.3 Filler detection

Match against a hard-coded set (case-insensitive, word-boundary):

```swift
static let fillers: Set<String> = [
  "uh", "um", "ah", "er", "hmm",
  "like", "so", "well", "right", "just",
  "basically", "actually", "literally", "totally",
  "kinda", "sorta", "anyway"
]
```

Multi-word fillers (`"you know"`, `"i mean"`, `"sort of"`) are **out of scope for v1**. Note this in code with `// TODO: n-gram filler detection`.

For each transcribed word, lowercase and check membership. Increment a `[String: Int]` counter. Top-3 = sort by value desc, take first 3.

### 9.4 Privacy posture

- Set `requiresOnDeviceRecognition = true` (or the SpeechAnalyzer equivalent — `SpeechTranscriber.locale` with on-device capability check). No audio leaves the device.
- Do not persist transcripts. Hold the word ring buffer in memory only; clear on mic-off.
- Microphone usage description in Info.plist must be specific: see §11.

---

## 10. Window & panel configuration

The widget is a `NSPanel` subclass hosting SwiftUI via `NSHostingView`.

```swift
final class FloatingPanel: NSPanel {
  init(contentView: NSView) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 144, height: 144),
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered, defer: false
    )
    self.contentView = contentView
    self.isMovableByWindowBackground = true
    self.becomesKeyOnlyIfNeeded = true
    self.hidesOnDeactivate = false
    self.isReleasedWhenClosed = false
    self.level = .floating
    self.backgroundColor = .clear
    self.hasShadow = false      // we draw our own via SwiftUI
    self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
  }
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}
```

**Position.** On first show, place top-right of the active screen with a 16pt inset from the edges. Persist last user-dragged position per-display in `UserDefaults` keyed by `NSScreen.localizedName`.

**Hover detection.** Use a `.onHover { hovering in ... }` modifier on the widget's root view. Hover state drives the contrast bump (alpha 0.42 → 0.62, border 0.55 → 0.78, transform `translateY(-3) scale(1.025)`).

**Show/hide animation.** Drive panel `alphaValue` via `NSAnimationContext` over 0.35s alongside a 4pt y-offset, when `state.isMicActive` flips.

---

## 11. Info.plist & entitlements

Add to `Info.plist`:

```xml
<key>LSUIElement</key>
<true/>

<key>LSApplicationCategoryType</key>
<string>public.app-category.productivity</string>

<key>NSMicrophoneUsageDescription</key>
<string>Talking Coach listens to your microphone to measure your speaking pace and detect filler words. Audio never leaves this device.</string>

<key>NSSpeechRecognitionUsageDescription</key>
<string>Talking Coach uses on-device speech recognition to count words and identify fillers. Speech is never sent to Apple or anyone else.</string>
```

App Sandbox entitlements (`*.entitlements`):
- `com.apple.security.app-sandbox` = YES
- `com.apple.security.device.audio-input` = YES
- `com.apple.security.device.microphone` = YES (alias of audio-input on macOS, set both for clarity)

No network entitlement. No file-access entitlement. The app is fully sandboxed and offline.

---

## 12. Accessibility

| Surface | Treatment |
|---|---|
| Widget root | `.accessibilityElement(children: .combine)` + `.accessibilityLabel("Talking coach. \(state) pace at \(wpm) words per minute, average \(avg). Top fillers: \(filler descriptions).")` — recomputed on state change |
| WPM number | implicit via combined label |
| State / avg row | implicit via combined label |
| Spectrum + caret | `.accessibilityHidden(true)` — color-only signal is redundant with the spoken state label |
| Filler list | implicit via combined label |
| Reduce Transparency | falls back to solid fill, see §3.5 |
| Reduce Motion | clamps animation durations to 0, see §6 |
| Increase Contrast | bump border `lineWidth` from 0.5 → 1.0 and pillar opacity from 0.95 → 1.0 |

VoiceOver users get a single rotor stop that reads the whole status. The widget is never the focused element when the user is in another app — it's announced on demand.

---

## 13. Build & run

- Xcode 26+
- Swift 6, strict concurrency
- macOS deployment target: **macOS 26.0**
- Frameworks: `SwiftUI`, `AppKit`, `AVFoundation`, `Speech` (for `SpeechAnalyzer`)
- Architectures: arm64 (Apple Silicon required for on-device `SpeechTranscriber` perf)

Run target: a single-target macOS app. No app extensions. No widgets (this is *not* a WidgetKit widget — that's a different product surface).

---

## 14. Testing checklist

- [ ] Mic permission flow on a fresh user account.
- [ ] Speech permission flow on a fresh user account.
- [ ] Widget appears within 1.5s of starting to speak; hides within 1.5s of mic going idle.
- [ ] WPM converges within 5 seconds of sustained speech.
- [ ] State label flips at 115 / 175 wpm boundaries.
- [ ] Color fade is continuous, no visible "snapping" at thresholds.
- [ ] Caret sits over the correct % position for any wpm in [80, 240].
- [ ] Pillars never show empty / dim trailing slots.
- [ ] `Reduce Transparency` produces a legible solid-fill fallback.
- [ ] `Reduce Motion` removes all transitions.
- [ ] `Increase Contrast` thickens borders and intensifies pillars.
- [ ] Drag-to-reposition sticks across app restarts and across displays.
- [ ] Widget stays visible across Mission Control / Spaces (`.canJoinAllSpaces`).
- [ ] Widget survives sleep / wake and display changes.
- [ ] No focus stolen — typing in another app continues uninterrupted while widget is visible.
- [ ] No mic recording while widget is hidden (mic released when not in use).
- [ ] VoiceOver reads the combined accessibility label.

---

## 15. File manifest

| File | Purpose |
|---|---|
| `README.md` | This document. Source of truth. |
| `widget-reference.html` | Visual reference — renders the final design with a slider for all pace states. |
| `Sources/TalkingCoachApp.swift` | `@main` app, panel wiring, lifecycle. |
| `Sources/DesignTokens.swift` | All design constants — colors, sizes, durations, pace thresholds, filler set. |
| `Sources/Views/TalkingCoachWidget.swift` | Root SwiftUI view + `SpectrumView`, `FillerBarsView`, `StateRowView`. |
| `Sources/Services/SpeechAnalyzerService.swift` | `SpeechAnalyzer` + `SpeechTranscriber` integration, pace + filler logic, `@MainActor` published state. |
| `Sources/Window/FloatingPanel.swift` | `NSPanel` subclass + window controller. |
| `Sources/Info-keys.md` | Required Info.plist additions and entitlements (mirror of §11). |

---

## 16. Out of scope (v2 backlog)

- Settings UI (custom ideal pace, custom filler list, position lock).
- Multi-word filler n-grams.
- Per-language tuning (currently English only).
- Session history / dashboard.
- Menu-bar item to pause / resume.
- Dynamic Type accessibility tile size.
- Cross-device sync.
