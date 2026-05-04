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
│                      │  │  (script-aware hybrid)      │  │   │
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
- **Voice Processing IO disabled** (`isVoiceProcessingEnabled = false`) — set before `prepare()`/`start()`. Validated stable across all 10 Spike #4 scenarios; macOS never overrode it.
- **Tap installed with `format: nil`** — lets the system provide whatever format the device negotiates. Required because Safari Meet changes input channel count from 1→3 mid-session (Spike #4); a hardcoded format would crash on that transition.
- **Subscribe to `AVAudioEngineConfigurationChange` notifications.** When fired (browser-based Meet joining mid-session is the known trigger), the engine has stopped — re-fetch the input format, reinstall the tap with `format: nil`, and call `engine.start()` again. Native conferencing apps (Zoom, FaceTime) do not trigger this; only browser-based audio stacks do, and they only trigger it in the harness-first ordering. Recovery is a routine Apple pattern, not an exception case.
- Tap callback delivers buffers to a fan-out:
  - → `TranscriptionEngine` (forwarded to whichever backend serves the active locale)
  - → RMS calculation (~10×/sec, fed to `ShoutingDetector` for adaptive noise-floor tracking)

**Swift 6 concurrency requirement (Spike #4 finding):**
The audio tap callback runs on Core Audio's `RealtimeMessenger.mServiceQueue`. If the closure is defined in a `@MainActor`-isolated context (e.g., inside `@main struct` body or `main.swift` top level), Swift 6's runtime checks crash with `_dispatch_assert_queue_fail` because the closure inherits main-actor isolation. Define tap closures in a separate non-main-actor source file. `AVAudioEngine`/`AVAudioInputNode` are non-Sendable; when captured in such closures, annotate with `nonisolated(unsafe)`. The compiler does NOT warn — this only surfaces at runtime.

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
- Wraps NVIDIA's `parakeet-tdt-0.6b-v3` multilingual model (Core ML conversion by FluidInference, distributed via FluidAudio Swift SDK — selected and validated in Spike #10)
- Used for any locale NOT in `SpeechTranscriber.supportedLocales` but in Parakeet's supported list (notably `ru_RU` for v1; 25 European languages total)
- Model file size on disk: ~1.2 GB (FP16, ANE-optimized). INT8 alternative exists but forces CPU-only execution and was rejected (Spike #10 — ANE offload preserves CPU/GPU headroom for Zoom)
- Downloaded on first use of any non-Apple locale via FluidAudio's Hugging Face fetch on first invocation, with widget showing "Preparing [language] model…" toast. M3.6 may relocate this to a self-hosted CDN before launch — TBD.
- Cold-start (validated Spike #10): three tiers — first-ever download ~53s on broadband (one-time, M3.6 toast covers this); recompile after cache eviction ~16s; warm subsequent runs 0.4s
- Real-time factor (validated Spike #10): 0.011 mean, 0.032 worst (≈90× real-time) — well under the 0.5 budget gate
- Peak working memory (validated Spike #10): 133 MB — far under the 800 MB budget. Architecture's earlier estimate was conservative by ~6×.
- Sustained-run validation (Spike #10 Phase E): 185 iterations, no memory leak, RSS flat
- Russian transcription quality (validated Spike #10 + Session 007 addendum): WER 9.4% on clean and noisy speech at ~110 WPM (gate <15%); WER 26.8% on fast speech at ~205 WPM (marginal — fast Russian is the actual quality cliff, not noise); filler recognition 70–93% (gate ≥70%); WPM accuracy <2% error in normal-pace conditions
- Word-level timestamps confirmed (Spike #10 Phase D) — feed directly into `SpeakingActivityTracker`, no proportional-estimation fallback needed

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
- Word-level vs phrase-level timestamps: `SpeechAnalyzer` produces word-level. Parakeet's Core ML port (FluidAudio) was validated word-level in Spike #10 Phase D — `ASRResult.tokenTimings` provides per-token `startTime`/`endTime` after BPE subword tokens are merged. The proportional-estimation fallback designed in Session 006 is not needed and is dropped from `ParakeetTranscriberBackend`'s scope.
- First use of any locale triggers a model download — handled silently with widget toast.
- Apple's `AssetInventory.status(forModules:)` returns `.unsupported` for locales the platform actually doesn't support, even if `supportedLocale(equivalentTo:)` returns the locale. The routing layer must check `supportedLocales` (the list), not `supportedLocale(equivalentTo:)` (the misleading helper). Spike #6 / Session 006 found this the hard way.

---

### 5. `LanguageDetector` (locked Session 010, Spike #2)
**Job:** Decide which of the user's declared locales to initialize `TranscriptionEngine` with for the current session.

**Inputs:**
- `declaredLocales: [Locale]` from `Settings` (1 or 2 entries — locked at onboarding, editable in settings)
- For Strategy 1 & 2: partial transcript from `TranscriptionEngine` (first ~5s)
- For Strategy 3: raw audio buffers from `AudioPipeline` (first ~3s)

**Behavior by N (count of declared languages):**

**N=1 (most common case):**
- No detection runs. `LanguageDetector` returns the single declared locale immediately.
- `TranscriptionEngine` routes to the locale's backend. No swap ever happens — only one language is in scope.
- This path is correct by construction; no spike validation needed for N=1.

**N=2 (bilingual users) — script-aware hybrid:**
- Binary classifier between exactly the two declared locales. Detection strategy selected at onboarding based on the Unicode script properties of the two languages. Three strategies, each empirically validated in Spike #2 at 100% accuracy:

**Strategy selection at onboarding (one-time):**
```
dominantScript(locale) → .latin | .cyrillic | .cjk | .arabic | .devanagari | ...

if script1 == script2           → Strategy 1 (NLLanguageRecognizer)
if script1.isCJK || script2.isCJK → Strategy 3 (Whisper audio LID)
else                             → Strategy 2 (word-count threshold)
```

**Strategy 1 — NLLanguageRecognizer (same-script pairs, e.g., EN+ES):**
- Initialize transcription with best-guess locale (last-used → `declaredLocales[0]`)
- After ~5s of partials, run `NLLanguageRecognizer` constrained to `{locale1, locale2}`
- If detected language ≠ current → swap `TranscriptionEngine` backend
- Validated: 100% accuracy on EN+ES (16/16 evaluations). Cost: zero model overhead; ~5s of wrong-language words if initial guess was wrong.

**Strategy 2 — Word-count threshold (cross-script non-CJK pairs, e.g., EN+RU):**
- Initialize transcription with best-guess locale
- After ~5s of partials, count words emitted
- If word count < threshold (empirically: 13 words) → current locale is wrong → swap
- Validated: 100% accuracy on EN+RU (16/16 evaluations). The wrong-locale transcriber produces dramatically fewer words (0–6 vs 14–42). Cost: zero model overhead; ~5s swap window.

**Strategy 3 — Whisper-tiny audio LID (Latin↔CJK pairs, e.g., EN+JA):**
- Widget shows "Listening…"
- Buffer first 3s of audio
- Run `openai_whisper-tiny` language detection via WhisperKit Core ML, constrained to `{locale1, locale2}`
- Commit to detected locale → start `TranscriptionEngine`
- Validated: 100% accuracy on EN+JA at both 3s and 5s (16/16 evaluations). Cost: 75.5 MB model (downloaded on first CJK-language use); ~600ms inference + ~3s audio buffering.
- The "two transcribers in parallel" approach (Option A) remains **disqualified** by power budget (FM4).

**What each user pays (decided at onboarding, not runtime):**

| Declared pair type | Model cost | Detection latency | Wrong-start risk |
|--------------------|-----------|-------------------|-----------------|
| N=1                | None      | 0ms               | None            |
| Same-script (EN+ES)| None      | ~5s (background)  | ~5s wrong-lang  |
| Cross-script (EN+RU)| None     | ~5s (background)  | ~5s wrong-lang  |
| Latin↔CJK (EN+JA) | 75.5 MB   | ~3s (blocking)    | None            |

**Whisper-tiny model details (Strategy 3 only):**
- Model: `openai_whisper-tiny` via WhisperKit (Argmax), pre-converted Core ML
- Size: 75.5 MB (~25 MB compressed in app bundle)
- Compute units: `.cpuAndNeuralEngine` (ANE requested, same as Parakeet)
- Inference: ~600ms mean, independent of audio window length (fixed encoder pass)
- Downloaded on first use of a CJK language, consistent with Parakeet model download flow (M3.6)
- Detection is pair-constrained in production: logits suppressed for all languages outside the declared pair

**Architecture Y interaction (Session 006, refined Session 008, concrete Session 010):**
- `LanguageDetector` outputs a `Locale`, not a backend choice. `TranscriptionEngine` decides routing per the locale → backend rule.
- A swap (Strategy 1 or 2 only) may cross the backend boundary if the two declared locales are served by different backends (e.g., English via Apple, Russian via Parakeet). `TranscriptionEngine` handles the actual backend swap; `LanguageDetector` just emits the new locale.
- Both backends are pre-known at onboarding (the user's two declared locales determine which backends ever get loaded). Models for both are downloaded on first session per backend, never speculatively.
- Strategy 3 (Whisper) runs before transcription starts, so no backend swap occurs — the locale is committed before `TranscriptionEngine` initializes.

**Outputs:** A `Locale` to use for the session. For Strategies 1 & 2, the initial locale may be revised after ~5s (emitted as a locale-change event to `SessionCoordinator`). For Strategy 3, the locale is final.

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
- **Speaking duration source:** `SpeakingActivityTracker.speakingDuration(in:)` — i.e., the active backend's speech/non-speech classification, not energy VAD. For Apple backend this comes from `SpeechAnalyzer`'s ML-based classification; for Parakeet backend, from word-level token timestamps (validated Spike #10 Phase D — both backends produce the same `(startTime, endTime)` schema natively).
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
- `declaredLocales` ([String], 1–2 entries, locale identifiers like "en_US", "ru_RU"). Set at onboarding; editable from Settings. No default — onboarding requires the user to pick at least one. System locale pre-checked at onboarding.
- `wpmTargetMin`, `wpmTargetMax` (Int, defaults 130, 170)
- `blocklistAppBundleIDs` ([String])
- `fillerDict[<localeIdentifier>]` ([String], one entry per declared locale, merged with bundled seed if available for that locale; empty otherwise)
- `widgetPositionByDisplay` ([String: CGPoint])
- `coachingEnabled` (Bool, default true)
- `hotkeyEnabled` (Bool, default true)
- `hasCompletedOnboarding` (Bool, default false; set to true after the user picks their declared languages)

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
     │         ├──► LanguageDetector: identify locale (script-aware hybrid)
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
| Which auto-detect mechanism for N=2 declared-locale binary classification? | Spike #2 ✅ passed Session 010 (script-aware hybrid: NLLanguageRecognizer + word-count + Whisper-tiny) |
| Mic coexistence with Zoom voice processing? | Spike #4 ✅ passed Session 008 (browser Meet has recoverable config-change caveat) |
| WPM accuracy vs ground truth? | Spike #6 (English ✅ passed Session 005; Russian ✅ passed Session 007) |
| Architecture Y power envelope (Apple + Parakeet)? | Spike #7 (Parakeet portion already characterized in Spike #10 Phase E; Apple portion still open) |
| Token-arrival robustness across mics/environments? | Spike #8 |
| Adaptive RMS noise-floor for shouting? | Spike #9 |
| Parakeet feasibility on macOS for Russian? | Spike #10 ✅ passed Session 006–007 |

Spike #10 closed Architecture Y as feasible. Spike #4 closed mic coexistence. Spike #2 closed language auto-detect with a script-aware hybrid mechanism. Remaining open spikes: #8, #9, #1, plus #7's full power profiling. If any of those fail, implementation details may shift but Architecture Y and the language detection design are now locked.
