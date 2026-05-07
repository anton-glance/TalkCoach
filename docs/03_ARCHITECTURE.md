# Architecture — Locto v1

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
│                      │  ┌─────────────────────────────┐  │   │
│                      │  │ TranscriptionEngine         │  │   │
│                      │  │  (SpeechAnalyzer +          │  │   │
│                      │  │   SpeechTranscriber)        │  │   │
│                      │  └─────────────────────────────┘  │   │
│                      │  ┌─────────────────────────────┐  │   │
│                      │  │ AudioPipeline               │  │   │
│                      │  │  (AVAudioEngine)            │  │   │
│                      │  └─────────────────────────────┘  │   │
│                      │  ┌─────────────────────────────┐  │   │
│                      │  │ Analyzer                    │  │   │
│                      │  │  (WPM + monologue)          │  │   │
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

**Implementation (locked Session 016 — M2.1 complete):**
- `AudioObjectAddPropertyListenerBlock` (block API, not the C function-pointer API) on `kAudioDevicePropertyDeviceIsRunningSomewhere` of the default input device, plus `kAudioHardwarePropertyDefaultInputDevice` on `kAudioObjectSystemObject` for default-device changes. Modern element constant `kAudioObjectPropertyElementMain` (macOS 12+).
- **`CoreAudioDeviceProvider` protocol injection (Convention 6, mirrors `PermissionStatusProvider`).** `SystemCoreAudioDeviceProvider` is a `nonisolated` `Sendable` struct that wraps the HAL APIs; `FakeCoreAudioDeviceProvider` is a `@unchecked Sendable` class that drives synchronous tests via `simulateIsRunningChange()` / `simulateDefaultDeviceChange()`. Listener handles cross the protocol as opaque `AnyObject?` tokens so the production impl can keep its block + queue pair encapsulated in a `ListenerToken` reference type without leaking the implementation choice.
- `MicMonitor` itself is a `@MainActor final class` (Convention 2). Listener-block closures are defined inside the provider's `nonisolated` methods so they cannot inherit MainActor isolation — Spike #4's `_dispatch_assert_queue_fail` runtime-crash analog does not occur. The closures hop to MainActor via `Task { @MainActor in }` to invoke the delegate.
- **Asymmetric `start()`, silent `stop()`.** `start()` synchronously emits `micActivated()` if the default device is already running at start time (handles app-launched-during-Zoom). Emits nothing if inactive — there is no "current state" delegate callback by design. `stop()` does not emit a final `micDeactivated()` (caller chose to stop). Same-value HAL notifications are deduplicated via `lastKnownRunningState`. Both `start()` and `stop()` are idempotent.
- `deinit` removes any remaining listeners directly via the provider's `nonisolated` methods. Listener-token storage uses `nonisolated(unsafe)` so `deinit` (which runs in any isolation) can read and clear the tokens.
- **Log-and-continue on listener-removal failure.** When a default-device change races a device destruction (Zoom aggregate-device case observed in M2.1 smoke gate — see below), `AudioObjectRemovePropertyListenerBlock` returns `OSStatus 560947818` / `kAudioHardwareBadObjectError`. The production provider logs the error and continues; state remains consistent because the new device's listener is attached before the old detach is attempted.

**Inputs:** none (subscribes to system events).
**Outputs:** `MicMonitorDelegate` callbacks (`@MainActor`): `micActivated()`, `micDeactivated()`.

**M3.1 inheritance note (Zoom audio-stack churn composition).** Smoke-gate scenario S3.2 (Session 016) confirmed Zoom can both flip the default input device AND destroy the previous default device, mid-session, in any order. M2.1's `MicMonitor` survives this via log-and-continue at the HAL level. M3.1 `AudioPipeline` faces the same churn at the engine level (`AVAudioEngineConfigurationChange` per Spike #4 plus device-vanish per M2.1) and must compose both recoveries. Plan M3.1 to handle: (a) engine config change → re-prepare and re-tap with `format: nil`; (b) underlying device disappears → log-and-continue on cleanup, attach to whatever is now default.

---

### 2. `SessionCoordinator`
**Job:** Orchestrate the full lifecycle of a coaching session.

**Skeleton (locked Session 017 — M2.3 complete):**
- `@MainActor final class SessionCoordinator: ObservableObject, MicMonitorDelegate`. Conforms to `MicMonitorDelegate` (M2.1 contract); receives mic events directly.
- **Hybrid consumer interface (locked).** `@Published private(set) var state: SessionState` for SwiftUI binding (M2.5 `FloatingPanel` consumes this directly via `@ObservedObject` / `@EnvironmentObject` — no adapter needed). Plus `func onSessionEnded(_ handler: @escaping @MainActor (EndedSession) -> Void)` for one-shot consumers (M2.7 `SessionStore` registers a single handler at app startup). Rejected alternatives: `@Published`-only forces M2.7 to detect end-of-session via `removeDuplicates().pairwise()` Combine acrobatics; delegate-only forces the widget to mirror state externally. Hybrid serves both consumers natively.
- **State types:** `enum SessionState: Equatable { case idle; case active(SessionContext) }`. `struct SessionContext: Equatable { let id: UUID; let startedAt: Date }`. `struct EndedSession: Equatable { let id: UUID; let startedAt: Date; let endedAt: Date }`. `SessionContext` represents an active session and is intentionally minimal — Phase 3+ modules (`LanguageDetector`, `Analyzer`) will add fields when wired. `EndedSession` is the value delivered to `onSessionEnded` handlers; carries `endedAt` which the active-session type does not.
- **Pause-mid-session — option (a), immediate termination (locked).** When `coachingEnabled` transitions to `false` while a session is active, `SessionCoordinator` ends the session immediately (transitions state to `.idle`, delivers `EndedSession` to handlers, logs `Coaching disabled mid-session — ending active session`). When `coachingEnabled` transitions to `true`, no immediate action — the next `micActivated()` starts a session as normal. Rationale: the menu copy is "Pause Coaching", not "Pause After This Session"; FM3's "controls do what they say" demands immediate effect. Smoke-gate verified end-to-end Session 017.
- **Combine subscription to `SettingsStore.$coachingEnabled`** (`.dropFirst().sink { [weak self] in ... }`). Justified deviation from the project's general "prefer async/await over Combine" preference: `SettingsStore` is already an `ObservableObject` with `@Published` properties; `.sink` is the idiomatic one-liner for observing them and avoids wrapping in `AsyncStream` for no benefit. Documented per Session 017's sub-agent note 8.
- **Ownership and lifecycle.** `AppDelegate` owns `SessionCoordinator` (Convention 7 — accessed via `AppDelegate.current?.sessionCoordinator`). `SessionCoordinator` owns `MicMonitor` strongly; `MicMonitor` holds a `weak` reference back via `MicMonitorDelegate`. `applicationDidFinishLaunching` calls `sessionCoordinator.start()`. `applicationWillTerminate` calls `sessionCoordinator.stop()` (sub-agent catch in commit `180c0b2`, smoke-gate verified at Cmd+Q). `start()` and `stop()` are idempotent (mirror M2.1 shape).
- **Same-MainActor-turn delivery.** `endCurrentSession()` builds the `EndedSession`, transitions state to `.idle`, and delivers to all registered handlers synchronously — no extra `Task { @MainActor in }` hop. Tests rely on this contract; rapid-toggle scenarios depend on it for deterministic event ordering.
- **Defensive duplicate-activation guard.** `micActivated()` while already in `.active` is a no-op at the coordinator level (in addition to `MicMonitor`'s own deduplication). Sub-agent caught the missing test in Session 017; added in commit `180c0b2`.

**Full lifecycle (target — additional modules wire in over Phase 3 and Phase 4):**
1. `MicMonitor` reports activation → M2.1 ✅, M2.3 ✅. `FloatingPanel` shows immediately on mic-active with "Listening…" placeholder → M2.5
2. Start `AudioPipeline` and `LanguageDetector` → M3.1, M3.4
3. Once language is detected, start `TranscriptionEngine` with that locale → M3.5 / M3.5a / M3.5b
4. Wire `TranscriptionEngine` and `AudioPipeline` outputs into `Analyzer` → Phase 4
5. Wire `Analyzer` outputs into the floating widget's view model → M2.5 (skeleton wiring), Phase 4 (data wiring)
6. When first WPM sample is available → widget replaces "Listening…" placeholder with metrics → M5.1 / M5.2
7. On `MicMonitor` deactivation:
   - Stop pipeline and engine
   - Persist session via `SessionStore` → M2.7
   - `FloatingPanel` starts a 5s hide timer; on timer fire, fade-out → M2.5

**Inputs:** `MicMonitor` events. `SettingsStore.coachingEnabled` (gate + pause-mid-session signal).
**Outputs:** `@Published var state: SessionState` (for SwiftUI consumers, primarily M2.5 widget); `onSessionEnded(_ handler)` callbacks (for one-shot consumers, primarily M2.7 persistence).

---

### 3. `AudioPipeline`
**Job:** Capture mic audio and provide raw buffers to `TranscriptionEngine`.

**Implementation:**
- `AVAudioEngine` with `inputNode` tap
- **Voice Processing IO disabled** (`isVoiceProcessingEnabled = false`) — set before `prepare()`/`start()`. Validated stable across all 10 Spike #4 scenarios; macOS never overrode it.
- **Tap installed with `format: nil`** — lets the system provide whatever format the device negotiates. Required because Safari Meet changes input channel count from 1→3 mid-session (Spike #4); a hardcoded format would crash on that transition.
- **Subscribe to `AVAudioEngineConfigurationChange` notifications.** When fired (browser-based Meet joining mid-session is the known trigger), the engine has stopped — re-fetch the input format, reinstall the tap with `format: nil`, and call `engine.start()` again. Native conferencing apps (Zoom, FaceTime) do not trigger this; only browser-based audio stacks do, and they only trigger it in the harness-first ordering. Recovery is a routine Apple pattern, not an exception case.
- Tap callback delivers buffers to `TranscriptionEngine` (forwarded to whichever backend serves the active locale).

**Swift 6 concurrency requirement (Spike #4 finding):**
The audio tap callback runs on Core Audio's `RealtimeMessenger.mServiceQueue`. If the closure is defined in a `@MainActor`-isolated context (e.g., inside `@main struct` body or `main.swift` top level), Swift 6's runtime checks crash with `_dispatch_assert_queue_fail` because the closure inherits main-actor isolation. Define tap closures in a separate non-main-actor source file. `AVAudioEngine`/`AVAudioInputNode` are non-Sendable; when captured in such closures, annotate with `nonisolated(unsafe)`. The compiler does NOT warn — this only surfaces at runtime.

**Outputs:** Audio buffers (for `TranscriptionEngine`).

**Design notes:**
- *No standalone VAD module* (locked Session 004): the previous design fed `isSpeaking` events from energy-based VAD into the WPM calculator. Replaced by deriving speaking activity from `SpeechAnalyzer` token arrival timestamps directly (see `SpeakingActivityTracker` in the `Analyzer` module). Reasons: `SpeechAnalyzer` already does ML-based speech/non-speech classification internally; energy VAD requires noise-floor calibration that fails when mic AGC adjusts during silence (FM3 violation); removing one module reduces CPU and bug surface.
- *No RMS / loudness path* (locked Session 013): Spike #9 invalidated the RMS-based shouting detection algorithm. Shouting detection deferred to v2. `AudioPipeline` is purely a buffer transport.

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
- Uses `AssetInventory.assetInstallationRequest(supporting:)` to download the locale's model (after user confirms in Settings)
- Streams `AnalyzerInput` via `AsyncStream`
- This is essentially "Apple does it for free" — minimal CPU/memory cost (validated in Spike #7 Phase A)

**Backend B — `ParakeetTranscriberBackend` (fallback for locales Apple doesn't cover):**
- Wraps NVIDIA's `parakeet-tdt-0.6b-v3` multilingual model (Core ML conversion by FluidInference, distributed via FluidAudio Swift SDK — selected and validated in Spike #10)
- Used for any locale NOT in `SpeechTranscriber.supportedLocales` but in Parakeet's supported list (notably `ru_RU` for v1; 25 European languages total)
- Model file size on disk: ~1.2 GB (FP16, ANE-optimized). INT8 alternative exists but forces CPU-only execution and was rejected (Spike #10 — ANE offload preserves CPU/GPU headroom for Zoom)
- Downloaded after user confirms in Settings via FluidAudio's Hugging Face fetch, with Settings showing download progress. M3.6 may relocate this to a self-hosted CDN before launch — TBD.
- Cold-start (validated Spike #10): three tiers — first-ever download ~53s on broadband (one-time); recompile after cache eviction ~16s; warm subsequent runs 0.4s
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
- The two backends never run simultaneously in v1 (ruled out by Spike #7 power budget; v1.x can revisit if needed)

**Outputs:** Stream of `(token, startTime, endTime, isFinal)` records — identical schema regardless of backend; downstream `SpeakingActivityTracker` and `Analyzer` are unaware of which backend produced them.

**Caveats:**
- Word-level vs phrase-level timestamps: `SpeechAnalyzer` produces word-level. Parakeet's Core ML port (FluidAudio) was validated word-level in Spike #10 Phase D — `ASRResult.tokenTimings` provides per-token `startTime`/`endTime` after BPE subword tokens are merged. The proportional-estimation fallback designed in Session 006 is not needed and is dropped from `ParakeetTranscriberBackend`'s scope.
- First use of any locale triggers a model download — gated by user confirmation in Settings.
- Apple's `AssetInventory.status(forModules:)` returns `.unsupported` for locales the platform actually doesn't support, even if `supportedLocale(equivalentTo:)` returns the locale. The routing layer must check `supportedLocales` (the list), not `supportedLocale(equivalentTo:)` (the misleading helper). Spike #6 / Session 006 found this the hard way.

---

### 5. `LanguageDetector` (locked Session 010, Spike #2)
**Job:** Decide which of the user's declared locales to initialize `TranscriptionEngine` with for the current session.

**Inputs:**
- `declaredLocales: [Locale]` from `Settings` (1 or 2 entries — set in Settings, editable anytime)
- For Strategy 1 & 2: partial transcript from `TranscriptionEngine` (first ~5s)
- For Strategy 3: raw audio buffers from `AudioPipeline` (first ~3s)

**Behavior by N (count of declared languages):**

**N=1 (most common case):**
- No detection runs. `LanguageDetector` returns the single declared locale immediately.
- `TranscriptionEngine` routes to the locale's backend. No swap ever happens — only one language is in scope.
- This path is correct by construction; no spike validation needed for N=1.

**N=2 (bilingual users) — script-aware hybrid:**
- Binary classifier between exactly the two declared locales. Detection strategy selected based on the Unicode script properties of the two languages. Three strategies, each empirically validated in Spike #2 at 100% accuracy:

**Strategy selection (one-time, when languages are set):**
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
- Widget stays hidden (mic active but no speech transcribed yet)
- Buffer first 3s of audio
- Run `openai_whisper-tiny` language detection via WhisperKit Core ML, constrained to `{locale1, locale2}`
- Commit to detected locale → start `TranscriptionEngine`
- Validated: 100% accuracy on EN+JA at both 3s and 5s (16/16 evaluations). Cost: 75.5 MB model (downloaded on first CJK-language use); ~600ms inference + ~3s audio buffering.
- The "two transcribers in parallel" approach (Option A) remains **disqualified** by power budget (FM4).

**What each user pays (decided when languages are set, not runtime):**

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
- Downloaded on first use of a CJK language, consistent with Parakeet model download flow
- Detection is pair-constrained in production: logits suppressed for all languages outside the declared pair

**Architecture Y interaction (Session 006, refined Session 008, concrete Session 010):**
- `LanguageDetector` outputs a `Locale`, not a backend choice. `TranscriptionEngine` decides routing per the locale → backend rule.
- A swap (Strategy 1 or 2 only) may cross the backend boundary if the two declared locales are served by different backends (e.g., English via Apple, Russian via Parakeet). `TranscriptionEngine` handles the actual backend swap; `LanguageDetector` just emits the new locale.
- Both backends are pre-known when languages are set (the user's two declared locales determine which backends ever get loaded). Models for both are downloaded after user confirmation in Settings.
- Strategy 3 (Whisper) runs before transcription starts, so no backend swap occurs — the locale is committed before `TranscriptionEngine` initializes.

**Outputs:** A `Locale` to use for the session. For Strategies 1 & 2, the initial locale may be revised after ~5s (emitted as a locale-change event to `SessionCoordinator`). For Strategy 3, the locale is final.

---

### 6. `Analyzer`
**Job:** Take token stream → produce metrics for widget and session record.

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

#### `MonologueDetector` (v1 feature — design pending Spike #11 outcome)
- Tracks continuous-speech duration using `SpeakingActivityTracker.isCurrentlySpeaking` as the source of truth
- Pauses ≤2.5s do not break the streak; pauses >2.5s reset it
- Emits warning levels at 60s (soft), 90s (warning), 150s (urgent)
- Spike #11 (parked) validates the source-signal robustness across mics and environments before implementation. M4.5 implements the detector; M5.6 implements the widget indicator. v1.x scope per `04_BACKLOG.md`.

#### `EffectiveSpeakingDuration`
- Accumulates `SpeakingActivityTracker.speakingDuration` over the entire session for the `effectiveSpeakingDuration` field in `Session`

#### ~~`FillerDetector`, `RepeatedPhraseDetector`~~ (deferred to v2.0 — Session 018)

Deferred alongside the v2.0 dashboard. Algorithm sketches preserved here in case v2.0 reopens the design discussion: `FillerDetector` was to be loaded with a seed dictionary per active language, tokenize finalized speech segments only (not partials, to avoid double-counting), lowercase + punctuation-strip, and match single-word and multi-word fillers. `RepeatedPhraseDetector` was a sliding 4-word window over finalized tokens detecting 2–4 word phrase repetition within ~5 seconds. Both run off the same finalized-token stream as `WPMCalculator` and have no dependency on RMS, so v2.0 implementation is straightforward — the cost is a `MigrationPlanV2` schema addition for `fillerCounts` and `repeatedPhrases`, plus a per-language Settings editor for the dictionary.

**Outputs (v1):** Updates to widget view model (rate-limited to every 3s for the WPM display, immediate for monologue level escalations) and final `Session` aggregate at session end.

---

### 7. `SessionStore`
**Job:** Persist session metrics.

**Implementation (locked Phase 1, M1.5):**
- SwiftData under macOS 26
- `@ModelActor` boundary — `SessionStore` runs on its own actor executor, separate from MainActor
- Single-store file resolved via `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)`. Inside the sandbox this is `~/Library/Containers/com.antonglance.TalkCoach/Data/Library/Application Support/TalkCoach/sessions.store`
- Schema as defined in `02_PRODUCT_SPEC.md`, expressed as `enum SchemaV1: VersionedSchema` with `versionIdentifier = Schema.Version(1, 0, 0)`. Migrations attach via `enum SessionMigrationPlan: SchemaMigrationPlan`

**Public API (Sendable record types, NOT @Model objects):**
```
@ModelActor actor SessionStore {
  init(modelContainer: ModelContainer)
  func save(_ record: SessionRecord) throws
  func fetchAll() throws -> [SessionRecord]
  func fetchByDateRange(from: Date, to: Date) throws -> [SessionRecord]
  func delete(id: PersistentIdentifier) throws
}
```

**Why records, not @Model objects:** SwiftData `@Model` types are non-`Sendable` and cannot cross actor isolation boundaries under Swift 6 strict concurrency. The `nonisolated struct Sendable` record types — `SessionRecord`, `WPMSampleRecord`, and (v1.x) `MonologueEventRecord` — are the boundary surface. `@Model` instances are constructed inside the actor from records on `save()` and converted back to records before crossing out on `fetch...()`. Production callers (M2.7 session persistence at session end, future v2 StatsWindow consumers) work with value-type records, never `@Model` directly.

Note (Session 018): the v1 schema does NOT include `FillerCountRecord` or `RepeatedPhraseRecord`. Filler tracking is deferred to v2.0; those record types and their corresponding fields on `SessionRecord` are added in `MigrationPlanV2` when v2.0 reopens that work.

**Privacy guard:** `testNoTranscriptFieldOnSession` and `testNoTranscriptFieldOnAnyRecordType` use `Mirror` to scan both the `@Model` class and all four record types for property names matching the forbidden set (`text`, `transcript`, `transcription`, `utterance`, `content`). Both green; any future field addition matching the set fails the build.

**Migration plan:** v1 schema is locked. `SessionMigrationPlan.stages` is empty. Future versions add a `SchemaV2` enum and a `MigrationStage` entry.

---

### 8. `FloatingPanel`
**Job:** The translucent, draggable, always-on-top widget.

**Implementation (locked Session 019 — M2.5 complete; extended Session 020 — M2.6 complete):**

The skeleton ships at M2.5: NSPanel infrastructure, SwiftUI host, lifecycle wired to `SessionCoordinator.$state`, the persistent-visibility state machine, the dismissal flow, the dynamic placeholder content (mm:ss timer + "Listening…" caption), default top-right 16pt-inset position. M2.6 adds per-display position memory, last-used-display preference, and the drag-save trigger. Real WPM display, color interpolation, hover saturation, drag-to-move with snap, and accessibility polish defer to M5.x.

- **`CoachingPanel`** (`final class CoachingPanel: NSPanel`) with locked init: `styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView]`, `backing: .buffered`, `defer: false`, `level = .floating`, `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`, `isMovableByWindowBackground = true`, `backgroundColor = .clear`, `hasShadow = false`, `isOpaque = false` (additive over the original §8 spec — required alongside `.clear` background and `hasShadow = false` for SwiftUI material translucency to render without AppKit drawing an opaque base), `canBecomeKey` and `canBecomeMain` overridden to return `false`. Compile-time locked — no public setter, no test parameterization.
- **SwiftUI content via `NSHostingView` (not `NSHostingController`).** The panel-as-container pattern: the custom `NSPanel` subclass owns the hosting view directly as its `contentView`. `NSHostingController` is reserved for cases where the controller IS the window's content controller (e.g. M1.3's Settings window). 144 × 144 pt size, corner radius 32 pt on the SwiftUI content (the panel itself is borderless).
- **Material:** `.regularMaterial` placeholder for M2.5, marked `// REMOVE-IN-M5.7` for the real Liquid Glass treatment in M5.7.
- **`FloatingPanelController`** (`@MainActor final class`) owns the panel lifecycle, the view model, and the visibility state machine. Reachable via `AppDelegate.current?.floatingPanelController`. Started in `applicationDidFinishLaunching` after `sessionCoordinator.start()`; stopped in `applicationWillTerminate` before `sessionCoordinator.stop()`. `start()` / `stop()` idempotent (Convention from M2.1 / M2.3).
- **Visibility state machine — 4 states.** `enum PanelVisibilityState: { hidden, visible, fadingOut, dismissed }`. Transitions: `hidden → visible` on `.idle → .active` (gated by `panelState != .dismissed`); `visible → fadingOut` on `.active → .idle` (5s timer scheduled); `fadingOut → hidden` on timer fire; `fadingOut → visible` on `.idle → .active` returning before timer fire (timer canceled); `visible → dismissed` on user confirm in dismiss alert; `dismissed → hidden` on `.active → .idle` (dismissal scope cleared at session end). All other transitions are no-ops. **Pause-mid-session uses the same `.active → .idle → fadingOut` path as mic-off** — `SessionCoordinator` produces `.idle` regardless of cause; the panel treats both identically.
- **Combine `.sink` subscription on `SessionCoordinator.$state`** with `[weak self]` capture, mirroring M2.3's justified deviation from the project's general async/await preference (`@Published` is already there; `.sink` is the idiomatic one-liner; wrapping in `AsyncStream` adds complexity for no benefit). `state` subscription stored as `private var stateSubscription: AnyCancellable?`, niled in `stop()` to break the strong reference path.
- **`AlertPresenter` protocol injection (Convention 6).** Production `SystemAlertPresenter` is a `nonisolated` `Sendable` struct that constructs an `NSAlert` with the spec text "Are you sure you are not going to speak during this session?" + Yes/No buttons and returns `runModal() == .alertFirstButtonReturn`. Test `FakeAlertPresenter` is `@unchecked Sendable` with a stubbed `Bool` result and call-count recording. Synchronous `-> Bool` return because `NSAlert.runModal()` blocks the runloop until the user clicks; async would add complexity for no benefit.
- **`HideScheduler` protocol injection (Convention 6).** Production `DispatchHideScheduler` uses `DispatchQueue.main.asyncAfter(deadline:execute:)` with `DispatchWorkItem`. `Task.sleep` was rejected — cooperative cancellation can fire the action even after `cancel()` if the task hasn't reached the suspension point. `DispatchWorkItem.cancel()` is synchronous and guaranteed: if canceled before execution, the block never runs. Tokens are erased to a `HideSchedulerToken` opaque type and stored in a `@MainActor` `TokenStorage` keyed by `ObjectIdentifier`. **Token cleanup on natural fire** — when the work item runs, the callback removes the entry from storage before invoking the action; the cancel path also removes. Without this, `TokenStorage.items` would leak entries over multi-day uptime sessions (sub-agent catch in commit `add8d78`).
- **Dismissal flow.** Always-visible × button on the placeholder widget for the skeleton (`// REMOVE-IN-M5.7` marker → hover-only in M5.7). Click → `requestDismiss()` → `alertPresenter.presentDismissConfirmation()`. On confirm → `panelState = .dismissed`, panel hidden immediately. On cancel → no state change. Dismissal scope clears in `handleSessionIdle()` when the session ends — re-activating the mic shows the panel again.
- **Per-display position memory (locked Session 020 — M2.6 complete).** Three concerns compose orthogonally: target-screen selection, position lookup, off-screen clamp. **Target-screen selection** uses a fallback chain: (1) if `settingsStore.lastUsedDisplay()` returns a non-nil name AND that name matches a screen in `screenProvider.allScreens()`, use that screen; (2) else fall back to `screenProvider.mainScreen() ?? screenProvider.allScreens().first`. The hardcoded synthetic-frame fallback (1440×900 NSRect) only triggers if no screens exist at all. **Position lookup** consults `settingsStore.position(for: targetScreen.localizedName)`. If a saved position exists, it's converted from screen-relative to absolute coords (`targetScreen.frame.origin + saved`); else the default top-right 16pt-inset is computed. **Off-screen clamp** constrains the panel rect to fit within `targetScreen.visibleFrame` (clamp-and-don't-save: the original saved value is never overwritten by clamping; the user's intent on a 4K display is preserved when temporarily on a smaller display).
- **Screen-relative coordinate storage.** Saved positions are stored as `(panel.origin - screen.frame.origin)`, not in absolute global coords. This preserves user intent across multi-monitor rearrangement: if the user moves the external display from left to right in System Settings → Displays, global coords shift but the screen-relative offset stays correct, so the widget appears at the same relative position on the same named screen.
- **Drag-save trigger (locked Session 020 — M2.6 fix in commit `6351a25`).** `NSWindow.didMoveNotification` observer registered with `object: <CoachingPanel>` and `queue: .main`. The handler is filtered by an `isProgrammaticMove: Bool` flag on `FloatingPanelController` set to `true` around every programmatic `setFrame(_:display:)` call (currently only `showPanel()`). Multiple fires during a single drag are coalesced via `HideScheduler.schedule(delay: 0.3)` — each fire cancels the prior debounce token and schedules a new one; on settle, `handlePanelDragEnd(panelFrame:)` is invoked with the panel's final frame. The earlier M2.6 design used a `CoachingPanel.mouseDown(with:)` override comparing frame origins around `super.mouseDown`; this was wrong because `super.mouseDown` returns immediately under modern AppKit (the drag is async-handed-off to the window server), so the comparison saw no change. The notification-based approach sidesteps the synchronous-vs-async question entirely by observing the actual window-server-driven frame events. Synchronous main-thread delivery of `NotificationCenter.post` posted on the main thread is the load-bearing assumption that makes the `isProgrammaticMove` flag reliable; this is documented Apple behavior and the worst-case failure mode if it ever changed (a redundant write of the already-stored position) is bounded and harmless.
- **Last-used-display preference (locked Session 020 — M2.6 fix in commit `3fe2a48`).** `SettingsStore.widgetLastUsedDisplay: String?` UserDefaults-backed `@Published` property with the M1.4 live-sync wiring. Written in `handlePanelDragEnd(panelFrame:)` immediately after the position write, both on the same MainActor turn. Read in `frameForShow()` ahead of `mainScreen()` per the target-screen selection chain above. Solves the multi-display UX bug where `NSScreen.main` (which tracks "screen of the focused window," not "screen the widget was last on") would put the widget on the user's currently-focused display rather than where they last placed it. Fallback path on disconnected display does NOT clear the orphaned entry — reconnecting the display restores the user's intent without further action.
- **Screen identification on drag-end: overlaps-the-most.** `screenWithMostOverlap(for:in:)` computes intersection-area between the panel's final frame and each screen's frame, picks the largest. Robust under partial overlap; matches the user's intuition of "which screen is this widget on." The `panel.screen` AppKit property was rejected because it updates asynchronously after a move — reading it inside the drag handler would give the source screen, not the destination.
- **`ScreenProvider` protocol injection (Convention 6).** `Sources/Widget/ScreenProvider.swift` defines a `ScreenDescription: Equatable, Sendable` value type carrying `localizedName`, `visibleFrame`, `frame` (NSScreen itself isn't Sendable). Production `SystemScreenProvider` reads from `NSScreen.main` and `NSScreen.screens` on each call. Test `FakeScreenProvider` (`@unchecked Sendable` class) provides configurable `stubbedMainScreen` and `stubbedAllScreens` for multi-monitor and disconnected-display test scenarios without actual hardware.
- **`os.Logger` category.** New `static let floatingPanel = Logger(subsystem: subsystem, category: "floatingPanel")` in `Logger+Subsystem.swift`. Lifecycle, state-machine transitions, and scheduler schedule/fire/cancel events log at `.info`. The pre-existing `widget` category is reserved for future view-model and SwiftUI-view logging in M5.x.

**Files (Sources/Widget/):** `CoachingPanel.swift`, `FloatingPanelController.swift`, `WidgetViewModel.swift`, `PlaceholderWidgetView.swift`, `AlertPresenter.swift`, `HideScheduler.swift`, `ScreenProvider.swift` (M2.6). Tests in `Tests/UnitTests/Widget/FloatingPanelControllerTests.swift` (17 tests, M2.5), `FloatingPanelPositionTests.swift` (13 tests, M2.6 original), `FloatingPanelDragTriggerTests.swift` (4 tests, M2.6 save-trigger fix), `FloatingPanelLastUsedDisplayTests.swift` (7 tests, M2.6 last-used-display fix). The `Sources/Widget/` directory was the established Phase 1 layout per `CLAUDE.md`; the M2.5 prompt's `Sources/UI/` reference was an architect-side writeup error caught by the agent in plan review.

**View model (v1):** `WidgetViewModel` (`@MainActor` `ObservableObject`). M2.5 ships a Phase 2 skeleton surface — `sessionStartedAt: Date?` (drives the timer) and `isSessionActive: Bool` (gates content visibility). M5.1 expands to the full v1 surface: `currentWPM: Double?`, `averageWPM: Double?`, `paceZone: PaceZone (tooSlow/ideal/tooFast)`, `monologueLevel: MonologueLevel (none/soft/warning/urgent)` — the `monologueLevel` field wires in v1.x when M4.5/M5.6 land. Filler-related fields (`topFillers: [FillerEntry]`) are removed from v1 per the Session 018 deferral; they return in v2.0's view model when filler tracking is reintroduced. The skeleton-vs-final split was decided in M2.5 to avoid coupling this module to M5.1's view-model design (e.g. whether `paceZone` should be optional or have a `.listening` case).

**Panel visibility (locked Session 013, reaffirmed Session 018):**
- **Show** when mic is active. Widget appears as soon as `MicMonitor` reports activation, regardless of whether speech has been detected yet.
- When mic is active but no speech yet (or no speech for an extended pause), the widget shows a low-attention "Listening…" placeholder. Metrics show no values rather than zeroed values.
- **Hide** 5 seconds after mic deactivates, with fade-out.
- The user can manually dismiss the widget via an on-widget close affordance. Dismissal triggers a confirmation prompt: "Are you sure you are not going to speak during this session?" with Yes/No. Dismissal is scoped to the current session only; widget re-appears on the next mic activation.
- Show/hide animated: 0.35s easeInOut fade + 4pt y-offset (clamped to instant when Reduce Motion is on).

**Visual rules (per `docs/design/01-design-spec.md`, failure-mode-driven):**
- Color transitions interpolate over 0.45s (FM1 — no step transitions)
- State ink colors per the brand state palette: slate-blue for too slow, sage-green for ideal, warm-coral for too fast (see `docs/design/02-brand-guidelines.html`)
- No flash, no pulse on metric changes (state transitions, monologue level escalation)
- Full accessibility support: Reduce Transparency fallback, Reduce Motion clamp, Increase Contrast adjustments
- Hover state: alpha 0.42→0.62, border 0.55→0.78, scale 1.025, translateY -3pt — the only intentional attention-grab in the widget surface (locked Session 018: more saturated on hover, intentionally inviting interaction)

---

### 9. `MenuBarUI`
**Job:** Status item, quick controls, settings access.

**Implementation (locked Phase 1, M1.2 + M1.3 + M1.6):**
- `MenuBarExtra` (SwiftUI) with `systemImage: "waveform.badge.mic"` label
- App is `LSUIElement = true`; no Dock icon
- Items in fixed order:
  - **About TalkCoach** — calls `NSApplication.shared.activate(); NSApplication.shared.orderFrontStandardAboutPanel(nil)`. The explicit `activate()` is required for `LSUIElement` apps so the panel comes to the foreground.
  - **Pause Coaching** / **Resume Coaching** — toggle bound to `@AppStorage("coachingEnabled")`. When paused, `SessionCoordinator` ignores `MicMonitor` events and the widget stays hidden. The `coachingEnabled` UserDefaults key is shared with `SettingsStore.coachingEnabled`; live-sync via `UserDefaults.didChangeNotification` keeps both in sync regardless of which writer fired.
  - **Settings…** — calls `AppDelegate.current?.openSettings()` (see Settings window section below for AppKit ownership rationale)
  - **Quit TalkCoach** — `NSApplication.shared.terminate(nil)` with `keyboardShortcut("q", modifiers: .command)`

**`AppDelegate.current` accessor (locked Phase 1, M1.6):**
```
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var current: AppDelegate?

    let permissionManager = PermissionManager()
    let settingsStore = SettingsStore()
    private(set) var settingsWindow: NSWindow?

    override init() {
        super.init()
        AppDelegate.current = self
    }
    // ... openSettings, applicationDidFinishLaunching, etc.
}
```

The naive `static var current: AppDelegate? { NSApp.delegate as? AppDelegate }` does NOT work when `@NSApplicationDelegateAdaptor` is used: SwiftUI registers its own `SwiftUI.AppDelegate` proxy class as `NSApp.delegate`, and the cast to `TalkCoach.AppDelegate` fails silently. The reliable pattern is to capture `self` at `init` time. Locked by `testAppDelegateCurrentIsSetAfterInit` in `MenuBarTests.swift`.

---

### 10. `Settings`
**Job:** UserDefaults-backed preferences + Settings window UI.

**Implementation (locked Phase 1, M1.3 + M1.4):**
- `SettingsStore` is a `@MainActor final class` conforming to `ObservableObject` with `@Published` properties for each preference
- Initializer takes `userDefaults: UserDefaults = .standard` for production / test isolation
- All UserDefaults access goes through a private `Keys` enum (no string literals at call sites)
- Live-sync: `SettingsStore` registers an observer on `UserDefaults.didChangeNotification` (with `queue: .main`, observer token stored as `nonisolated(unsafe) private var observer: (any NSObjectProtocol)?`, removed in `deinit`). When an external writer like `@AppStorage("coachingEnabled")` in `MenuBarContent` updates the underlying defaults, `SettingsStore`'s `@Published` properties refresh on the next runloop tick. An `isSyncing` guard prevents feedback loops between programmatic writes and notification-triggered reads.

**Keys (seven for v1, after Session 020 last-used-display addition):**
- `declaredLocales` ([String], 1–2 entries, locale identifiers like "en_US", "ru_RU"). Set via Settings (auto-opened on first launch); editable anytime. Default: `[]`. On first launch, if the system locale is in `LocaleRegistry.allLocales`, the `AppDelegate` silently commits it to `declaredLocales` and sets `hasCompletedSetup = true` — the user can edit afterward but isn't trapped in a no-op picker loop if they dismiss Settings.
- `wpmTargetMin`, `wpmTargetMax` (Int, defaults 130, 170)
- `coachingEnabled` (Bool, default true) — drives Pause/Resume in menu bar. Key string `"coachingEnabled"` is shared with `MenuBarContent`'s `@AppStorage`.
- `hasCompletedSetup` (Bool, default false; set to true after first valid declared locale, either silent-committed at first launch or user-toggled)
- `widgetPositionByDisplay` ([String: CGPoint], default `[:]`) — encoded via JSON to `Data` for UserDefaults round-trip (CGPoint is not natively plist-storable inside a dictionary). Populated by M2.6 on every drag-end via screen-relative coords keyed by `NSScreen.localizedName`. Typed accessors: `position(for screenName: String) -> CGPoint?` and `setPosition(_:for:)`. Corrupt UserDefaults data decodes to `[:]` with a `Logger.settings` warning (no crash).
- `widgetLastUsedDisplay` (String?, default nil) — populated by M2.6 alongside every `widgetPositionByDisplay` write; consulted by `FloatingPanelController.frameForShow()` ahead of `NSScreen.main` to pick the target screen. Stored as plain `String?` (natively plist-storable; no JSON encoding needed). Typed accessors: `lastUsedDisplay() -> String?` and `setLastUsedDisplay(_:)`. Orphaned entries (display disconnected after being recorded) are NOT auto-cleared — reconnecting the display restores the user's intent.

Note (Session 018): `fillerDict` is removed from v1 keys. v2.0 adds it back when filler tracking returns; the existing M1.4 implementation registered the key but no v1 module reads or writes it after the deferral.

**Settings window (locked Phase 1, M1.3):**
- AppKit `NSWindow` containing an `NSHostingController(rootView: SettingsView().environmentObject(settingsStore))`. The window is owned by `AppDelegate` and reachable via `AppDelegate.current?.openSettings()`. Creates lazily on first `openSettings()`; subsequent calls reuse the same window via `makeKeyAndOrderFront(nil)`.
- **Why AppKit, not SwiftUI `Window` scene:** SwiftUI `Window(id:)` + `openWindow` is unreliable in `LSUIElement` apps where `MenuBarExtra` is the only scene. Window scenes don't reliably register and `openWindow` silently fails to present. AppKit `NSWindow` + `NSHostingController` is the reliable escape hatch and is the project's standard pattern for any future windows beyond `MenuBarExtra`.
- Window size: 520×600pt, `styleMask: [.titled, .closable, .resizable]`, `isReleasedWhenClosed = false`, `isRestorable = false` to prevent macOS state restoration from re-presenting the window after first-launch dismissal.
- First-launch auto-open: in `applicationDidFinishLaunching`, if `hasCompletedSetup == false`, the AppDelegate calls `DispatchQueue.main.async { self.openSettings() }`. The async dispatch lets `applicationDidFinishLaunching` finish before window presentation, avoiding ordering issues with the SwiftUI scene graph.

**Settings window sections:**
- **Languages** — `LocaleRegistry.allLocales` rendered as a list with checkbox toggles. 50 locales (27 Apple-supported + 23 Parakeet-only). Each row shows display name, identifier, and backend label `(Apple, ~150 MB)` or `(Parakeet, ~1.2 GB)`. Max-2 enforcement via disabled state on unselected rows when `selection.count >= 2`. System locale silent-commit on first launch (see `declaredLocales` above).
- **Speaking Pace** — placeholder in v1; M6.2 adds the WPM band slider.
- ~~**Filler Words**~~ — section removed in Session 018 with the filler-tracking deferral. Returns in v2.0.

---

## Data flow (single session)

```
User joins Zoom call
     │
     ▼
MicMonitor: kAudioDevicePropertyDeviceIsRunningSomewhere → true
     │
     ▼
SessionCoordinator: coachingEnabled check → start session
     │
     ├──► FloatingPanel: shown on mic-active (persistent), "Listening…" placeholder until first token
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
     │         │         start streaming
     │         │         │
     │         │         ▼
     │         │    Token stream with timestamps
     │         │    (word-level)
     │         │         │
     │         │         ▼
     │         │    SpeakingActivityTracker: derives speaking duration
     │
     ▼
Analyzer: consumes tokens + speaking duration
     │
     ├──► WPMCalculator → wpmShort, wpmAvg
     ├──► MonologueDetector → monologueLevel (none/soft/warning/urgent) — v1.x
     │
     ▼
WidgetViewModel updates (every 3s for WPM, immediate for monologue level escalations)
     │
     ▼
FloatingPanel: renders updated metrics (replaces "Listening…" placeholder on first WPM)
     │
     ⋮  (continues until mic deactivates)
     │
     ▼
MicMonitor: kAudioDevicePropertyDeviceIsRunningSomewhere → false
     │
     ▼
SessionCoordinator: state → .idle → finalize Session (FloatingPanel starts 5s hide timer)
     │
     ▼
SessionStore: persist Session via SwiftData
```

---

## Threading model

- `MicMonitor` callback fires on a Core Audio thread → marshal to main actor
- `AudioPipeline` tap fires on a real-time audio thread → never block, dispatch heavy work to a `DispatchQueue` for `Analyzer`
- `SpeechAnalyzer` uses Swift concurrency (`AsyncStream`) → consume on a background `Task`
- `ParakeetTranscriberBackend` runs Core ML inference on a dedicated background `Task`. Compute units = `.cpuAndNeuralEngine` by default (Spike #7 confirmed Apple SpeechAnalyzer runs entirely on E-Cluster efficiency cores — no contention with Parakeet's ANE usage).
- All UI updates on `@MainActor`
- SwiftData writes on a background `ModelActor`

---

## Permissions / entitlements

```xml
<!-- Info.plist -->
<key>NSMicrophoneUsageDescription</key>
<string>Locto analyzes your speaking pace during meetings, fully on-device.</string>

<key>NSSpeechRecognitionUsageDescription</key>
<string>Locto uses on-device speech recognition to compute your speaking pace. No audio leaves your Mac.</string>

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
  1. Downloading the Parakeet Core ML model when the user confirms in Settings for a Parakeet-routed locale (e.g., Russian). Self-hosted CDN, single file fetch, no analytics.
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

## Design reference

The `docs/design/` directory is the visual source of truth for the widget and brand surfaces (Session 018). It contains:

- `docs/design/01-design-spec.md` — behavior, IA, motion, accessibility, and edge-case treatments. Implementation-facing companion to the brand guidelines HTML.
- `docs/design/02-brand-guidelines.html` — visual identity (colors, type, components in isolation). Open in any browser.
- `docs/design/README.md` — precedence rules and what's superseded.

**Precedence (locked Session 018):**
- `02_PRODUCT_SPEC.md` wins on **content scope** (what features ship in v1).
- `03_ARCHITECTURE.md` (this file) wins on **technical architecture** (modules, data flow, framework choices).
- `docs/design/01-design-spec.md` and `docs/design/02-brand-guidelines.html` win on **visual and brand specifics** (palette ink colors, type ramp, motion timings, voice/tone for user-facing copy).

**What the docs/design package does NOT cover, and our locked decisions instead:**
- Widget size: 144×144pt (locked Session 014, preserved Session 018) — NOT the 320pt size the Locto reference package suggests.
- Widget material: Liquid Glass with hover saturation shift (locked Session 014, preserved Session 018) — NOT solid pastel gradients.
- Persistent visibility + "Listening…" placeholder + dismissal flow (locked Session 013, preserved Session 018) — NOT show-on-first-token / hide-on-mic-off.
- Monologue indicator (v1.x feature locked Session 013) — extension to the brand component set, not in the Locto reference package.

**What was superseded in Session 018:**
- The earlier `design/` directory at the project root is superseded by `docs/design/`. Any prior reference SwiftUI implementations there are superseded by the Locto-derived design tokens (palette ink colors, Inter type stack, motion principles, voice rules) plus the locked widget shell decisions above. Production code uses tokens from `docs/design/02-brand-guidelines.html` adapted to Liquid Glass tinting, not solid backgrounds.

The design package is authoritative for **visuals and voice only**. Anything it implies about content scope (e.g., the Locto reference includes filler-stroke components) is overridden by `02_PRODUCT_SPEC.md`. Anything it implies about technical architecture (e.g., the Locto reference recommends GRDB for persistence) is overridden by this architecture doc.

---

## Open architecture questions (deferred to spikes)

| Question | Resolved by |
|---|---|
| Which auto-detect mechanism for N=2 declared-locale binary classification? | Spike #2 ✅ passed Session 010 (script-aware hybrid: NLLanguageRecognizer + word-count + Whisper-tiny) |
| Mic coexistence with Zoom voice processing? | Spike #4 ✅ passed Session 008 (browser Meet has recoverable config-change caveat) |
| WPM accuracy vs ground truth? | Spike #6 (English ✅ passed Session 005; Russian ✅ passed Session 007) |
| Architecture Y power envelope (Apple + Parakeet)? | Spike #7 ✅ conditional pass Session 012 (Apple baseline: mean 4.18% CPU under 18× overload, ~2% estimated production; Parakeet characterized in S10 Phase E) |
| Token-arrival robustness across mics/environments? | Spike #8 ✅ passed Session 011 |
| Adaptive RMS noise-floor for shouting? | Spike #9 ❌ invalidated Session 013 (feature deferred to v2) |
| Parakeet feasibility on macOS for Russian? | Spike #10 ✅ passed Session 006–007 |

All architecture-blocking spikes are resolved. Remaining open spikes (S1 blocklist app-ID → v2, S11 MonologueDetector VAD → v1.x) are deferred with their respective features and do not gate v1 implementation.
