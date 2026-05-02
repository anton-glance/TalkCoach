# Architecture — Speech Coach v1

> **Locked.** Changes require explicit decision logged in `01_PROJECT_JOURNAL.md`.

---

## High-level structure

```
┌──────────────────────────────────────────────────────────────┐
│  TalkCoachApp (LSUIElement = true, .accessory)             │
│                                                              │
│  ┌──────────────┐    ┌───────────────────────────────────┐   │
│  │ MenuBarUI    │    │  CoreServices (singletons)        │   │
│  │ (SwiftUI)    │◄──►│                                   │   │
│  └──────────────┘    │  ┌─────────────────────────────┐  │   │
│         │            │  │ MicMonitor                  │  │   │
│         │            │  │  (Core Audio HAL listener)  │  │   │
│  ┌──────▼──────┐     │  └─────────────────────────────┘  │   │
│  │ FloatingPanel │   │  ┌─────────────────────────────┐  │   │
│  │ (NSPanel +   │◄──►│  │ SessionCoordinator          │  │   │
│  │  SwiftUI)    │    │  │  (orchestrates a session)   │  │   │
│  └──────────────┘    │  └─────────────────────────────┘  │   │
│         │            │  ┌─────────────────────────────┐  │   │
│  ┌──────▼──────┐     │  │ TranscriptionEngine         │  │   │
│  │ StatsWindow │     │  │  (SpeechAnalyzer +          │  │   │
│  │ (SwiftUI)   │◄────┼──┤   SpeechTranscriber)        │  │   │
│  └─────────────┘     │  └─────────────────────────────┘  │   │
│                      │  ┌─────────────────────────────┐  │   │
│                      │  │ AudioPipeline               │  │   │
│                      │  │  (AVAudioEngine, VAD, RMS)  │  │   │
│                      │  └─────────────────────────────┘  │   │
│                      │  ┌─────────────────────────────┐  │   │
│                      │  │ Analyzer                    │  │   │
│                      │  │  (WPM, fillers, n-grams)    │  │   │
│                      │  └─────────────────────────────┘  │   │
│                      │  ┌─────────────────────────────┐  │   │
│                      │  │ LanguageDetector            │  │   │
│                      │  │  (Spike #2 outcome)         │  │   │
│                      │  └─────────────────────────────┘  │   │
│                      │  ┌─────────────────────────────┐  │   │
│                      │  │ SessionStore (SwiftData)    │  │   │
│                      │  └─────────────────────────────┘  │   │
│                      │  ┌─────────────────────────────┐  │   │
│                      │  │ Settings (UserDefaults)     │  │   │
│                      │  └─────────────────────────────┘  │   │
│                      └───────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────┘
```

---

## Modules

### 1. `MicMonitor`
**Job:** Detect when the system mic activates / deactivates, fire callbacks.

**Implementation:**
- `AudioObjectPropertyAddress` for `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device
- `AudioObjectAddPropertyListener` for change notifications
- Also listens for default-input-device changes (`kAudioHardwarePropertyDefaultInputDevice`) so we re-attach the listener if the user switches mics

**Inputs:** none (subscribes to system events)
**Outputs:** `micActivated()`, `micDeactivated()` delegate callbacks

**Risks:** Spike #1 — also need to identify which app activated the mic for the blocklist check.

---

### 2. `SessionCoordinator`
**Job:** Orchestrate the full lifecycle of a coaching session.

**Lifecycle:**
1. `MicMonitor` reports activation
2. Check if foreground app is in blocklist → if yes, do nothing
3. Show floating widget in "Listening…" state (language detection in progress)
4. Start `AudioPipeline` and `LanguageDetector`
5. Once language is detected, start `TranscriptionEngine` with that locale
6. Wire `TranscriptionEngine` and `AudioPipeline` outputs into `Analyzer`
7. Wire `Analyzer` outputs into the floating widget's view model (every 3s)
8. On `MicMonitor` deactivation:
   - Hold widget for 5s
   - Stop pipeline and engine
   - Persist session via `SessionStore`
   - Fade out widget

**Inputs:** `MicMonitor` events
**Outputs:** Updates to widget view model, `Session` records to `SessionStore`

---

### 3. `AudioPipeline`
**Job:** Capture mic audio and provide raw buffers (for `TranscriptionEngine`) plus RMS samples (for `ShoutingDetector`).

**Implementation:**
- `AVAudioEngine` with `inputNode` tap
- **Voice Processing IO disabled** (`isVoiceProcessingEnabled = false`) — avoids fighting Zoom's echo cancellation
- Tap callback delivers buffers to a fan-out:
  - → `TranscriptionEngine` (forwarded to whichever backend serves the active locale)
  - → RMS calculation (~10×/sec, fed to `ShoutingDetector` for adaptive noise-floor tracking)

**Outputs:**
- Audio buffers (for `TranscriptionEngine`)
- `currentRMS: Float` samples (~10×/sec, for `ShoutingDetector`)

**Design note (locked Session 004):**
The previous design included a standalone VAD module (energy-based or `SoundAnalysis`-based) feeding `isSpeaking` events to the WPM calculator. This was replaced by deriving speaking activity from `SpeechAnalyzer` token arrival timestamps directly (see `SpeakingActivityTracker` in the `Analyzer` module). Reasons:
1. `SpeechAnalyzer` already does ML-based speech/non-speech classification internally — energy VAD would be redundant and weaker
2. Energy VAD requires noise-floor calibration, which fails when mic AGC adjusts during silence and breaks across environments/mics (FM3 violation)
3. Removing one entire module reduces CPU, removes a setup step, and removes a class of bugs

---

### 4. `TranscriptionEngine` (Architecture Y)

**Job:** Convert audio buffers to timestamped word tokens. Routes to one of two backends based on locale, normalizing their outputs to a single token stream format.

**Architecture pivot (locked Session 006):** the previous single-backend `SpeechEngine` module was renamed `TranscriptionEngine` and split into two backends. Reason: `SpeechTranscriber.supportedLocales` on macOS 26.4.1 does not include `ru_RU`, and Russian is a primary v1 language. Architecture Y (Apple where supported, Parakeet for the rest) is the resolution. See Session 006 in `01_PROJECT_JOURNAL.md`.

**Backend A — `AppleTranscriberBackend` (the default):**
- Wraps `SpeechAnalyzer` with `SpeechTranscriber` module
- Used for any locale in `SpeechTranscriber.supportedLocales` (currently 27 locales on macOS 26.4.1, including English, Spanish, French, German, Italian, Portuguese, Korean, Japanese, several Chinese variants)
- Configured with:
  - `transcriptionOptions: []`
  - `reportingOptions: [.volatileResults]` — for live partials
  - `attributeOptions: [.audioTimeRange]` — timestamps per token
- Uses `AssetInventory.assetInstallationRequest(supporting:)` to download the locale's model on first use
- Streams `AnalyzerInput` via `AsyncStream`
- This is essentially "Apple does it for free" — minimal CPU/memory cost (validated in Spike #7 Phase A)

**Backend B — `ParakeetTranscriberBackend` (fallback for locales Apple doesn't cover):**
- Wraps an NVIDIA Parakeet v3 multilingual Core ML model (variant and quantization tier locked by Spike #10 outcome)
- Used for any locale NOT in `SpeechTranscriber.supportedLocales` but in Parakeet's supported list (notably `ru_RU` for v1)
- Realistic model size: 600 MB (INT8) to 1.2 GB (FP16); Spike #10 picks the tier
- Downloaded on first use of any non-Apple locale, similar UX to Apple's first-use download (widget shows "Preparing [language] model…" toast). Self-hosted on a CDN we control; no analytics on the download.
- Cold-start: <30s on first session (validated in Spike #10)
- Real-time factor: <0.5 at chosen tier (i.e., processes 60s of audio in <30s; 2× real-time leaves headroom; validated in Spike #10)
- Resource budget materially higher than Apple's: <15% CPU, <800 MB memory (validated in Spike #7 Phase B)

**Routing layer — `TranscriptionEngine` itself:**
- Receives detected locale from `LanguageDetector`
- Asks: is this locale in `SpeechTranscriber.supportedLocales`?
  - Yes → instantiate `AppleTranscriberBackend(locale:)`
  - No, but Parakeet supports it → instantiate `ParakeetTranscriberBackend(locale:)`
  - No to both → log unsupported, surface error to the user (rare in practice; covered locale set is the union of Apple's 27 + Parakeet v3's 25)
- Normalizes both backends' outputs into a unified `(token: String, startTime: TimeInterval, endTime: TimeInterval, isFinal: Bool)` stream
- Handles backend swap when language detection updates mid-session — pause input briefly, swap backend, resume; aim <500ms gap
- The two backends never run simultaneously in v1 (rules out by Spike #7 power budget; v1.x can revisit if needed)

**Outputs:** Stream of `(token, startTime, endTime, isFinal)` records — identical schema regardless of backend; downstream `SpeakingActivityTracker` and `Analyzer` are unaware of which backend produced them.

**Caveats:**
- Word-level vs phrase-level timestamps: `SpeechAnalyzer` produces word-level. Parakeet-Core-ML may produce phrase-level (Spike #10 Phase D validates). If Parakeet emits phrase-level only, `ParakeetTranscriberBackend` does proportional estimation within phrases (N words over T seconds → each word `T/N` duration centered in the phrase) before emitting tokens. WPM accuracy may degrade slightly for Russian sessions; documented as known limitation in journal if so.
- First use of any locale triggers a model download — handled silently with widget toast.
- Apple's `AssetInventory.status(forModules:)` returns `.unsupported` for locales the platform actually doesn't support, even if `supportedLocale(equivalentTo:)` returns the locale. The routing layer must check `supportedLocales` (the list), not `supportedLocale(equivalentTo:)` (the misleading helper). Spike #6 / Session 006 found this the hard way.

---

### 5. `LanguageDetector`
**Job:** Decide which locale to initialize `TranscriptionEngine` with.

**Implementation:** TBD — to be selected by Spike #2. Options on the table:
- **Option B:** Best-guess (last-used or system locale) → transcribe → use `NLLanguageRecognizer` on the partial transcript → swap if wrong
- **Option C:** Small audio language-ID model (Whisper-tiny LID head as Core ML, or alternative)

The "two transcribers in parallel" approach (Option A) is **disqualified** by power budget (FM4).

**Architecture Y interaction (Session 006):**
- `LanguageDetector` outputs a `Locale`, not a backend choice. `TranscriptionEngine` decides routing.
- For Option B (best-guess + swap): the "best guess" must be a locale Apple supports if at all reasonable, since Apple's path is materially cheaper. Defaults: last-used locale → system locale → `en_US`. Only escalate to a Parakeet locale if `NLLanguageRecognizer` confidently detects one.
- For Option C: language-ID model output feeds `TranscriptionEngine`'s router; same routing rules.
- A swap mid-session may cross the backend boundary (e.g., user starts in English, switches to Russian). `TranscriptionEngine` handles the actual backend swap; `LanguageDetector` just emits the new locale.

**Outputs:** A `Locale` to use for the session, possibly with a "low confidence, re-evaluate after 5s" flag.

---

### 6. `Analyzer`
**Job:** Take token stream + VAD + RMS → produce metrics for widget and session record.

**Sub-components:**

#### `SpeakingActivityTracker`
- Consumes the `TranscriptionEngine` token stream
- Maintains a record of `[(tokenStart, tokenEnd)]` time intervals from `.audioTimeRange` attributes
- Provides `speakingDuration(in window: TimeRange) -> TimeInterval` — sum of token interval lengths intersected with the window
- Provides `isCurrentlySpeaking(asOf timestamp:) -> Bool` — true if any token's end time is within `tokenSilenceTimeout` (default 1.5s) of the query time
- This replaces the old standalone VAD module. No audio energy involvement.

#### `WPMCalculator`
- Maintains a sliding window of (token timestamp, word count) pairs
- Window length: 5–8 seconds (final value tuned in Spike #6)
- **Speaking duration source:** `SpeakingActivityTracker.speakingDuration(in:)` — i.e., the active backend's speech/non-speech classification, not energy VAD. For Apple backend this comes from `SpeechAnalyzer`'s ML-based classification; for Parakeet backend, from token arrival timestamps in the same `(startTime, endTime)` schema (with proportional estimation within phrases if Spike #10 finds Parakeet emits phrase-level only).
- When `speakingDuration` is 0 in the window, return last smoothed value (hold-on-disagreement, prevents jitter)
- Smooths with EMA (alpha ~0.3) to prevent jitter
- Emits short-window WPM and running session average

#### `FillerDetector`
- Loaded with seed dictionary for the active language
- Tokenizes finalized speech segments only (not partials, to avoid double-counting)
- Lowercase + punctuation-strip
- Matches single-word and multi-word fillers
- Increments counts per session

#### `RepeatedPhraseDetector`
- Sliding 4-word window over finalized tokens
- Detects repetition of 2–4 word phrases within ~5 seconds
- Increments counts per session

#### `ShoutingDetector`
- Subscribes to `AudioPipeline.currentRMS` samples
- **Adaptive noise-floor tracking:** maintains a rolling 5-second buffer of recent RMS samples; current noise floor = 10th percentile of buffer
- Shouting threshold: `noiseFloor + threshold_dB` (default `threshold_dB = 25.0`, sustained for 0.5s+)
- This replaces fixed-dBFS thresholding; works in any environment without calibration
- Emits a "shouting event" with timestamp

#### `EffectiveSpeakingDuration`
- Accumulates `SpeakingActivityTracker.speakingDuration` over the entire session for the `effectiveSpeakingDuration` field in `Session`

**Outputs:** Updates to widget view model (rate-limited to every 3s for the WPM display, immediate for filler/shouting events) and final `Session` aggregate at session end.

---

### 7. `SessionStore`
**Job:** Persist session metrics, query for stats window.

**Implementation:**
- SwiftData (macOS 14+ → in our case macOS 26)
- Single-store local file in `~/Library/Application Support/TalkCoach/`
- Schema as defined in `02_PRODUCT_SPEC.md`
- Provides queries: `sessionsByDateRange`, `fillerTrendByLanguage`, `wpmTrendByDateRange`

**Migration plan:** v1 schema is locked. Any future schema changes use SwiftData's migration plan — version every `Schema` from day 1.

---

### 8. `FloatingPanel`
**Job:** The translucent, draggable, always-on-top widget.

**Implementation:**
- `NSPanel` subclass with:
  - `styleMask: [.nonactivatingPanel, .hudWindow, .borderless]`
  - `level: .statusBar` (above fullscreen Zoom)
  - `collectionBehavior: [.canJoinAllSpaces, .stationary, .ignoresCycle]`
  - `isMovableByWindowBackground = true`
- Hosts a SwiftUI view via `NSHostingView`
- View uses `.background(.ultraThinMaterial)` (macOS 13+) or Liquid Glass material (macOS 26)
- Saves position per-display in UserDefaults: `[NSScreen.localizedName: CGPoint]`
- Snap-to-screen logic if a saved display is disconnected

**View model:** `WidgetViewModel` (ObservableObject) with `currentWPM`, `averageWPM`, `wpmState (slow/onPace/fast)`, `fillerCounts`, `isShouting`.

**Visual rules (failure-mode-driven):**
- Color transitions interpolate over 600ms
- Filler list never reorders; new entries append; counts update in place
- No flash, no pulse on detection events
- Out-of-range arrow fades in over 400ms, fades out over 800ms

---

### 9. `MenuBarUI`
**Job:** Status item, quick controls, settings access.

**Implementation:**
- `MenuBarExtra` (SwiftUI, macOS 13+)
- Items:
  - "Coaching: ON / OFF" toggle (override auto)
  - Current language (read-only display + dropdown to override session language)
  - "Open Stats…" → opens `StatsWindow`
  - "Settings…" → opens settings sheet
  - "Quit"

---

### 10. `StatsWindow`
**Job:** Expanded view of historical session data.

**Implementation:**
- Separate SwiftUI `WindowGroup`
- Sections:
  - Session list (table with sortable columns)
  - WPM trend chart (Swift Charts line chart)
  - Filler frequency chart (Swift Charts, per-language)
  - Selected session detail panel (metrics + label edit)

---

### 11. `Settings`
**Job:** UserDefaults-backed preferences.

**Keys:**
- `wpmTargetMin`, `wpmTargetMax` (Int, defaults 130, 170)
- `blocklistAppBundleIDs` ([String])
- `fillerDictEN`, `fillerDictRU`, `fillerDictES` ([String], merged with seed if empty)
- `widgetPositionByDisplay` ([String: CGPoint])
- `coachingEnabled` (Bool, default true)
- `hotkeyEnabled` (Bool, default true)

---

## Data flow (single session)

```
User joins Zoom call
     │
     ▼
MicMonitor: kAudioDevicePropertyDeviceIsRunningSomewhere → true
     │
     ▼
SessionCoordinator: blocklist check → not blocked → start session
     │
     ├──► FloatingPanel: show "Listening…"
     │
     ├──► AudioPipeline: start AVAudioEngine tap
     │         │
     │         ├──► LanguageDetector: identify locale (Spike #2 method)
     │         │         │
     │         │         ▼
     │         │    Locale decided (e.g., ru-RU)
     │         │
     │         ├──► TranscriptionEngine:
     │         │         locale ru-RU not in SpeechTranscriber.supportedLocales
     │         │         → route to ParakeetTranscriberBackend
     │         │         (first use → download model, show "Preparing Russian…" toast)
     │         │         start streaming
     │         │         │
     │         │         ▼
     │         │    Token stream with timestamps
     │         │    (word-level if available; else estimated within phrase)
     │         │         │
     │         │         ▼
     │         │    SpeakingActivityTracker: derives speaking duration
     │         │
     │         └──► RMS samples (~10×/sec) → ShoutingDetector
     │                                      (adaptive noise-floor from 5s rolling buffer)
     │
     ▼
Analyzer: consumes tokens + speaking duration + RMS
     │
     ├──► WPMCalculator → wpmShort, wpmAvg
     ├──► FillerDetector → fillerCounts
     ├──► RepeatedPhraseDetector → repeatedPhrases
     ├──► ShoutingDetector → shoutingEvents
     │
     ▼
WidgetViewModel updates (every 3s for WPM, immediate for fillers/shouting)
     │
     ▼
FloatingPanel renders
     │
     ⋮  (continues until mic deactivates)
     │
     ▼
MicMonitor: kAudioDevicePropertyDeviceIsRunningSomewhere → false
     │
     ▼
SessionCoordinator: hold widget 5s → fade out → finalize Session
     │
     ▼
SessionStore: persist Session via SwiftData
```

---

## Threading model

- `MicMonitor` callback fires on a Core Audio thread → marshal to main actor
- `AudioPipeline` tap fires on a real-time audio thread → never block, dispatch heavy work to a `DispatchQueue` for `Analyzer`
- `SpeechAnalyzer` uses Swift concurrency (`AsyncStream`) → consume on a background `Task`
- `ParakeetTranscriberBackend` runs Core ML inference on a dedicated background `Task`. Compute units = `.cpuAndNeuralEngine` by default; Spike #7 may revise based on contention measurements.
- All UI updates on `@MainActor`
- SwiftData writes on a background `ModelActor`

---

## Permissions / entitlements

```xml
<!-- Info.plist -->
<key>NSMicrophoneUsageDescription</key>
<string>Speech Coach analyzes your speaking pace and filler words during meetings, fully on-device.</string>

<key>NSSpeechRecognitionUsageDescription</key>
<string>Speech Coach uses on-device speech recognition to count words and detect filler words. No audio leaves your Mac.</string>

<key>LSUIElement</key>
<true/>
```

```xml
<!-- App.entitlements -->
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.device.audio-input</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>  <!-- Required for Parakeet model download from CDN. NOT used during sessions. See "Network policy" below. -->
```

### Network policy (Architecture Y, Session 006)
- The app uses the network **only** for two purposes:
  1. Downloading the Parakeet Core ML model on first use of a Parakeet-routed locale (e.g., user's first Russian session). Self-hosted CDN, single file fetch, no analytics.
  2. Apple's `AssetInventory` may contact Apple's asset servers to download `SpeechTranscriber` locale models. This is Apple's normal first-use behavior and is consistent with the privacy policy.
- The app makes **no other** network calls: no telemetry, no crash reporting, no remote config, no transcripts uploaded. Audio never leaves the device.
- The privacy promise ("fully on-device") remains accurate. The model file is static; transmitting your voice is what we're avoiding, and that doesn't happen.

---

## Build targets

- **Single app target** — no helper apps, no extensions, no bundled frameworks for v1
- **Min deployment:** macOS 26.0 (`SpeechAnalyzer` requirement)
- **Architecture:** Apple Silicon only for v1 (Intel support is deferred — `SpeechAnalyzer` performance on Intel is uncertain and not worth complicating v1)
- **Hardened Runtime:** enabled
- **Notarization:** required for direct download path; App Store handles separately

---

## Open architecture questions (deferred to spikes)

| Question | Resolved by |
|---|---|
| How to identify the app activating the mic? | Spike #1 |
| Which language auto-detect approach? | Spike #2 |
| Mic coexistence with Zoom voice processing? | Spike #4 |
| WPM accuracy vs ground truth? | Spike #6 (English ✅ passed Session 005; Russian validated via Spike #10) |
| Architecture Y power envelope (Apple + Parakeet)? | Spike #7 (revised Session 006) |
| Token-arrival robustness across mics/environments? | Spike #8 |
| Adaptive RMS noise-floor for shouting? | Spike #9 |
| Parakeet feasibility on macOS for Russian? | Spike #10 (replaces Spike #3) |

If any of Spike #4, #6 (Russian leg), #7, or #10 fail, this architecture changes meaningfully. Run #10 first — it gates Architecture Y.
