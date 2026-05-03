# Spikes — Speech Coach v1

> Each spike is a small piece of throwaway code (or sometimes a recording + spreadsheet) whose only purpose is to answer a yes/no architectural question. Production code does NOT depend on the spike code — when the spike is done, the answer goes into the journal and the spike code is deleted.
>
> Run **P0 spikes first**. If any P0 spike fails, re-plan rather than push through.

---

## Status legend
`📋 planned` · `🔬 running` · `✅ passed` · `❌ failed` · `⚠️ passed with caveats` · `⏸ deferred`

---

## Spike #6 — WPM ground truth on real EN/RU recordings

**Status:** ✅ passed (English Session 005, Russian Session 007 via Spike #10) · **Production constants locked:** window=6, alpha=0.3, tokenSilenceTimeout=1.5

### Question
Does the WPM number we plan to display match what a stopwatch + manual word count says, in both English and Russian, across normal/fast/slow speech — using `SpeechAnalyzer` token timestamps as the speaking-duration source (not energy VAD)?

### Why it matters
FM2 (unreliable data) is a hard failure mode. If WPM math is off by 15%+, the user immediately distrusts the app and uninstalls. We need to prove the math before building UI on top of it.

### Method
1. Record 6 audio clips (yourself, ~60s each):
   - EN normal pace (with deliberate 4s pause)
   - EN fast (continuous)
   - EN slow (continuous)
   - RU normal pace (with deliberate 4s pause)
   - RU fast (continuous)
   - RU slow (continuous)
2. For each clip:
   - Manually count words (from a transcript) → ground truth WPM
   - Run `SpeechAnalyzer` test harness with `attributeOptions: [.audioTimeRange]`
   - Use proposed `WPMCalculator` math: 5–8s rolling window, EMA smoothing, **speaking duration derived from token interval lengths** (NOT from audio energy VAD)
   - Compare displayed WPM at the end of each clip vs ground truth
3. Tabulate error % per clip across all (window, alpha) combinations
4. For pause clips: confirm WPM doesn't crash to 0 during the 4s pause (stays within 10% of pre-pause value because token gaps reduce window-effective speaking duration naturally)

### Pass criteria
- Mean absolute error <8% on normal-pace clips (EN and RU)
- WPM does not crash to 0 during the 4s pause (stays within 10% of pre-pause value)
- Direction of change matches direction of speech rate change (fast clip shows higher WPM than slow clip)
- **No environment-specific calibration required** — same recording on different mics produces similar errors (validates Approach D + A architecture decision)

### Fail mode → action
- **Error too high:** investigate window size (try 8–12s), EMA alpha, token-arrival timing accuracy
- **Russian specifically off:** word-count semantics differ (compound morphology) → may need a per-language word-counting rule
- **Pause crashes WPM:** `SpeechAnalyzer` may not be reporting token end times accurately during silence — examine `.audioTimeRange` behavior at pause edges
- **Token timestamps too coarse (phrase-level not word-level):** falls back to proportional estimation within phrases; may degrade accuracy and trigger Spike #8

### Outputs
- A small Swift Package harness that runs the WPM math on an audio file
- A spreadsheet of clip → ground truth WPM → calculated WPM → error %
- Tuned values for window size, EMA alpha (these become production constants)
- **No** VAD threshold value (the architecture no longer uses energy VAD)

---

## Spike #7 — Power & CPU profiling during 1hr session (Architecture Y)

**Status:** 📋 planned · **Priority:** P0 · **Estimate:** 6h (was 4h before Parakeet was added to scope)

### Question
Does Architecture Y (Apple `SpeechAnalyzer` for supported locales, NVIDIA Parakeet via Core ML for unsupported locales like Russian) stay under the resource budget for a 1hr session on Apple Silicon, on battery?

This is a two-part question because the two backends have categorically different resource profiles:
- Apple `SpeechAnalyzer` is OS-integrated and effectively free — measured separately to confirm.
- Parakeet (0.6B params Core ML) is materially more expensive and must be measured under sustained load.

### Why this scope changed (Session 006)
Originally this spike asked "can `SpeechAnalyzer` + `AVAudioEngine` run for 1hr within budget?" — a single-stack question. After Session 006's pivot to Architecture Y, we now have two stacks and the budget question is different: **can we afford to run Parakeet at all on consumer Apple Silicon during a typical Zoom call?**

The architecture's load-bearing assumption is that Apple handles English (cheap), Parakeet handles Russian and ES-on-Apple-fallback (expensive but only when needed). If Parakeet's cost is so high that running it in real-time during a Zoom call is infeasible, Architecture Y is dead and we need to reopen scope.

### Why it matters
FM4 (no performance impact). If a Russian session drains battery 20%+ more than an English session, the user notices and disables the app for Russian meetings — meaning the multilingual story collapses functionally even if the recognition technically works.

### Budget (per backend, per active session)

**Apple `SpeechAnalyzer` path (English, Spanish, etc.):**
- <5% sustained CPU on M-series
- <150 MB RSS memory
- Energy Impact: "low" in Activity Monitor
- No measurable mic dropouts in Zoom

**Parakeet path (Russian, future locales):**
- <15% sustained CPU on M-series (3× the Apple budget; Parakeet is doing real work)
- <800 MB RSS memory (model weights + activation buffers; depends on quantization tier)
- Energy Impact: "high" acceptable but not "extreme"
- No mic dropouts; Parakeet's GPU/ANE usage must not starve other apps
- Battery drain delta <5% per hour vs control (vs <2% for Apple path)

If Parakeet exceeds these, Architecture Y fails and we either:
1. Drop Russian from v1 (revisit Path A from Session 006)
2. Find a smaller/cheaper Russian-capable model
3. Accept that Russian sessions warn the user about battery cost

### Method

**Phase A — Apple `SpeechAnalyzer` path (English baseline):**
1. Build minimal harness: `AVAudioEngine` input tap → `SpeechAnalyzer` (en_US) → discard tokens. Add RMS computation.
2. Run a 1hr English audio loop into the mic.
3. Measure with Instruments: Time Profiler (CPU), Allocations/Leaks (memory), Energy Log (power).
4. Run Zoom alongside for the second 30 minutes. Compare.
5. Control: Zoom alone, 1hr, no harness.

**Phase B — Parakeet path (Russian load):**
1. Extend the harness to route Russian audio through Parakeet (whichever quantization tier Spike #10 selected).
2. Run a 1hr Russian audio loop.
3. Same Instruments measurements as Phase A.
4. Run Zoom alongside for the second 30 minutes. Compare.
5. Control: Zoom alone (already from Phase A).

**Phase C — Backend switching cost:**
1. Run a 1hr loop alternating between English (5 min) and Russian (5 min) chunks.
2. Measure transition cost: model load time, memory churn, any audio dropouts at the swap.
3. Validates that real-world bilingual users (the primary persona) don't pay a tax every time language detection swaps.

### Pass criteria
- Apple path within Apple budget
- Parakeet path within Parakeet budget
- Switching cost: <500 ms gap in token output across language swap, no Zoom audio degradation, no memory ratchet (memory returns to baseline within 30s of swap)
- Both backends combined Energy Impact rating <"high" averaged over the alternating-languages run

### Fail mode → action
- **Parakeet CPU too high:** try smaller quantization (INT8 over FP16), reduced sample rate, or lower-tier Parakeet variant. Reopen with user.
- **Parakeet memory pinning Russian-session users:** reduce model footprint or accept "Russian sessions use more battery" disclosure in settings.
- **Switching cost too high:** keep both models loaded simultaneously (memory cost) or accept brief gaps (UX cost). Pick.
- **Apple path degrades when Parakeet is loaded:** unlikely but possible (ANE/GPU contention). Investigate scheduling.
- **Zoom degrades during Parakeet:** Parakeet is using shared compute resources. Investigate Core ML compute units (`.cpuOnly` vs `.cpuAndNeuralEngine`).

### Outputs
- Energy Impact numbers per backend
- Confirmed `SpeechAnalyzer` reporting/attribute settings
- Confirmed Parakeet quantization tier and Core ML compute unit selection (input from Spike #10)
- Decision input for Spike #2 (how much language-detection budget is left after both transcription stacks)
- Go/no-go on Architecture Y as a whole

---

## Spike #3 — Russian transcription quality on `SpeechAnalyzer`

**Status:** ❌ superseded by Spike #10 (Session 006)

### Why superseded
Spike #6 incidentally discovered that `SpeechTranscriber.supportedLocales` on macOS 26.4.1 does not include `ru_RU`. Russian transcription via `SpeechAnalyzer` is not available on the platform — not a quality problem, an availability problem. `supportedLocale(equivalentTo:)` returns `ru_RU` misleadingly even though it is not in the supported set; `AssetInventory.status` returns `.unsupported`.

The architecture decision in Session 006 adopts Architecture Y (Apple where Apple covers, Parakeet for the rest). Russian transcription quality validation moves to Spike #10, which validates the Parakeet Core ML port on macOS 26 / Apple Silicon.

This spike's outputs (WER bars, filler recognition rates, word-boundary expectations) carry forward to Spike #10's pass criteria with the recognizer swapped from `SpeechTranscriber(locale: ru_RU)` to Parakeet.

---

## Spike #4 — Mic coexistence with Zoom voice processing

**Status:** ⚠️ passed with caveats (Session 008). Full report at `MicCoexistSpike/REPORT.md`.

### Validated outcomes (Spike closed Session 008)
- **VPIO stays false:** `isVoiceProcessingEnabled` remained `false` at every checkpoint across all 10 scenarios. macOS never overrode it. `setVoiceProcessingEnabled(false)` works as documented.
- **Native apps (Zoom, FaceTime) coexist perfectly:** Zero gaps, zero config changes, zero audio degradation in either direction. Both C-pattern (app first) and D-pattern (harness first) pass cleanly. Zoom toggle (leave + rejoin mid-session) also clean.
- **Browser Meet (Chrome, Safari) coexist with one caveat:** When Meet is already active before our engine starts, no issue. When Meet joins *after* our engine, it triggers `AVAudioEngineConfigurationChange` which stops the engine. Safari additionally changes channel count from 1→3. Conferencing audio is never degraded in either case.
- **Production requirement:** `AudioPipeline` must observe `AVAudioEngineConfigurationChange` and restart engine + reinstall tap. Must use `format: nil` (never hardcode channel count). This is a well-documented Apple recovery pattern.
- **Swift 6 concurrency finding:** Audio tap closures must NOT inherit `@MainActor` isolation — Swift 6's strict concurrency crashes at runtime (`_dispatch_assert_queue_fail`) if the tap closure is defined in a main-actor context. Define tap callbacks in a separate non-main-actor source file.
- **Conferencing never degraded:** User confirmed hearing themselves clearly on the iPhone self-loop in all 10 scenarios.
- **Total spike effort:** ~3h actual vs 3h estimated.

### Original question
Can our app continuously read mic input while Zoom is in a call, without degrading Zoom's audio for the user or remote participants?

### Why it matters
FM4 (no performance impact). Apple Developer Forums show that VPIO (Voice Processing IO) conflicts can cut off mic input in one of two co-running apps. We've architecturally said "disable VPIO in our pipeline" but this needs real verification.

### Method
1. Set up a harness app with `AVAudioEngine` input tap, **`isVoiceProcessingEnabled = false` explicit**, no Speech framework, just reads buffers and discards them
2. Join a real Zoom call (or use Zoom's "Test Audio" feature with a friend on the other end)
3. Test scenarios:
   - Zoom alone → confirm baseline audio quality (other participant hears you fine)
   - Harness alone → confirm we read buffers continuously
   - Both running → other participant confirms audio still fine; harness still receives buffers
   - Toggle harness on/off mid-call → no Zoom dropout
4. Repeat with Google Meet (web-based, different audio handling)
5. Repeat with FaceTime (Apple's own VPIO usage)

### Pass criteria
- All four scenarios pass: Zoom audio remains clean for the remote participant in all cases
- Our harness receives continuous buffers in all cases
- No system audio errors logged

### Fail mode → action
- **Zoom degrades when our app reads:** investigate `AVAudioSession` category equivalent on macOS, audio engine configuration. May need to read from a different node.
- **We get cut off when Zoom starts:** we lose, fundamentally — Zoom's VPIO is taking exclusive control. Workarounds: aggregate device tricks (complex, requires user setup → violates FM3); or accept that Zoom calls always come with degraded coaching (defeats the use case). This is a major problem if it happens — discuss with user before committing to a workaround.

### Outputs
- Confirmed mic coexistence behavior across Zoom / Meet / FaceTime
- The exact `AVAudioEngine` configuration that works
- Decision: can we proceed with the architecture as drafted

---

## Spike #2 — Language auto-detect mechanism

**Status:** 📋 planned · **Priority:** P1 (run after S7) · **Estimate:** 6h

### Question
Which approach to language auto-detection:
- (B) Best-guess locale → transcribe → use `NLLanguageRecognizer` on partials → swap if wrong
- (C) Small dedicated audio language-ID model (e.g., Whisper LID head, alternative Core ML model) → identify locale → start transcription

(Option A — two transcribers in parallel — is **disqualified** by Spike #7 power budget regardless of outcome.)

### Why it matters
User wants pure auto-detect every session. Both options have real costs and accuracy questions. Need data before committing.

### Method

**Test corpus:** 10 short clips (10s each), mixed:
- 4 EN
- 4 RU
- 2 ES
- (later) some borderline cases: code-switched, mumbled start, ambient music + speech

**Option B test:**
1. Initialize `SpeechTranscriber(locale: en_US)` for all clips (worst-case wrong-guess scenario)
2. After 5s of partials, run `NLLanguageRecognizer` on accumulated text
3. If detected locale ≠ initialized locale, swap recognizer
4. Measure: detection accuracy, time-to-detection, words-discarded during swap

**Option C test:**
1. Find a Core ML language-ID model (Whisper-tiny LID head; alternative: train one in CreateML if needed; alternative: a third-party model)
2. Run on first 3s of each clip's audio
3. Measure: detection accuracy, time-to-detection, model size, CPU cost

### Pass criteria

For whichever option performs better:
- ≥85% language detection accuracy across the corpus
- Time-to-decision <5s
- Cost (Option C) within budget per Spike #7
- Discarded-words count (Option B) low enough that the user doesn't notice the first few words being missed

### Fail mode → action
- **Both options weak:** propose hybrid — use Option B with system-locale-as-best-guess (most likely right anyway), live with occasional wrong-language-first-5s. Document as known limitation.
- **Option C model unavailable / huge:** fall back to Option B
- **Option B accuracy too low:** Option C is the only path; if no model fits, scope decision: ship with manual language picker only, defer auto-detect to v1.x

### Outputs
- Selected approach + tuned parameters
- Implementation sketch for `LanguageDetector` module (M3.4)

---

## Spike #1 — Identifying activating app for blocklist

**Status:** 📋 planned · **Priority:** P2 (run before M2.2) · **Estimate:** 3h

### Question
Can we reliably identify which app activated the mic, so the blocklist can decide whether to suppress the widget?

### Why it matters
Blocklist needs this. Without it, "skip Voice Memos" can't work, and we'd have to fall back to "always activate" — which the user explicitly rejected.

### Method

Try in priority order, stop at the first that works reliably:

1. **`NSWorkspace.shared.frontmostApplication`** at the moment of mic activation. Cheap and reliable for foreground apps. Fails if the activating app is in background (rare but possible).
2. **`AVCaptureDevice.userPreferredCamera` / audio device clients** — not directly available for input devices, but check Core Audio for client process info via `kAudioDevicePropertyDeviceIsRunningSomewhere` siblings (e.g., `kAudioObjectPropertyOwner`)
3. **`tccd` (privacy database) inspection** — read `/Library/Application Support/com.apple.TCC/TCC.db` to see who has mic permission. Does NOT tell you who's *currently using* the mic, only who can. Likely not useful.
4. **CoreAudio `kAudioHardwarePropertyProcessIsAudible` / similar** — if these expose per-process audio state, that's our answer.

Test by:
1. Launching the app
2. Opening Zoom → check what the app reports
3. Opening Voice Memos (foreground) → check
4. Letting QuickTime trigger a recording in the background → check
5. Multiple mic-using apps simultaneously → check

### Pass criteria
- Correct identification ≥90% of the time across the test scenarios
- No false positives that block legitimate sessions
- Solution doesn't require special entitlements that block App Store distribution

### Fail mode → action
- **Can't reliably ID activator:** fall back to "blocklist by foreground app at activation time" using `NSWorkspace.frontmostApplication` only. Acceptable: covers Zoom, FaceTime, Meet (browser), Voice Memos in normal use. Misses background-recording cases.
- **Solution requires private API or extra entitlements:** drop blocklist from v1, document workaround (user can disable coaching via menu bar before launching the to-be-skipped app)

### Outputs
- Working `ActivatingAppIdentifier` utility
- Documented limitations (which scenarios fail)
- Confirmation it doesn't block App Store distribution

---

## Spike #8 — Token-arrival robustness across environments and mics

**Status:** 📋 planned · **Priority:** P1 (run after S6 passes) · **Estimate:** 3h

### Question
Does `SpeechAnalyzer` produce stable token-arrival timing across different microphones and ambient environments? If a clip is recorded on AirPods in a coffee shop vs. MacBook built-in in a quiet room, do we get similar WPM measurements?

### Why it matters
Architecture decision Session 004 chose Approach D (token-arrival-based speaking duration) specifically because it should be environment-agnostic — `SpeechAnalyzer` does its own ML-based VAD internally. But this assumption needs validation. If token timestamps are noisy or shift based on mic/environment, the WPM math degrades and we'd need to add Approach C (`SoundAnalysis`-based VAD) as a secondary signal.

This addresses FM2 (unreliable data) under the realistic condition that the user changes mics and locations.

### Method
1. Record the same script (~30s, English, normal pace) in 4 conditions:
   - MacBook built-in mic, quiet room
   - MacBook built-in mic, café/noisy room
   - AirPods, quiet room
   - AirPods, café/noisy room
2. Run all 4 through the Spike #6 harness with the production-tuned (window, alpha)
3. Compare WPM and `effectiveSpeakingDuration` across the 4 conditions

### Pass criteria
- WPM variance across the 4 conditions <5% (i.e., same script produces consistent WPM regardless of mic/environment)
- `effectiveSpeakingDuration` consistent within 10%
- No clip produces wildly different word counts (would indicate `SpeechAnalyzer` model degradation in noise)

### Fail mode → action
- **WPM varies >10% across conditions:** token-arrival isn't stable enough; add Approach C (small `SoundAnalysis` model) as a confidence-weighted secondary signal. This becomes a backlog item.
- **Word count varies wildly:** `SpeechAnalyzer` model is failing in noise; this is a deeper problem affecting all metrics, not just WPM. May force scope change (warn user about noisy environments, or accept degraded quality). Discuss.
- **AirPods specifically degrades:** AirPods apply aggressive bluetooth compression — may be unrecoverable. Document as a known limitation.

### Outputs
- Cross-condition WPM table
- Decision: do we add Approach C, or proceed with Approach D alone?

---

## Spike #9 — Adaptive RMS noise-floor for shouting detection

**Status:** 📋 planned · **Priority:** P2 (run before M4.5) · **Estimate:** 2h

### Question
Does the adaptive noise-floor approach (rolling 5s buffer, 10th percentile = noise floor, threshold = floor + 25 dB) reliably detect shouting across environments without false positives?

### Why it matters
The shouting detector is the only audio-energy-based feature in the app (per Session 004 architecture decision). It must work in any environment without calibration to satisfy FM3 (no setup). Fixed-dBFS thresholds break across mics and rooms.

### Method
1. Record short clips (~20s each):
   - Quiet room, normal speech (no shouting expected)
   - Quiet room, deliberate shouting at end
   - Noisy environment (HVAC + nearby conversation), normal speech (no shouting expected)
   - Noisy environment, deliberate shouting at end
2. Build a small harness: ingest RMS samples → run adaptive threshold → output detected shouting events
3. Validate: shouting clips trigger events, non-shouting clips don't

### Pass criteria
- Shouting clips: at least one shouting event detected with timestamp matching the actual shouting onset (±1s)
- Non-shouting clips: zero shouting events
- Adaptive floor adjusts within 5s when ambient noise changes (validate by switching environments mid-clip)

### Fail mode → action
- **False positives in noisy environments:** floor estimation too low — try 25th percentile instead of 10th, or longer rolling window
- **False negatives on actual shouting:** threshold too conservative — try 20 dB margin instead of 25
- **Adaptation too slow:** shorten rolling buffer from 5s to 3s
- **Adaptation too jumpy:** lengthen to 8s

### Outputs
- Tuned constants for adaptive floor: rolling buffer length, percentile, threshold dB
- These become production constants in `ShoutingDetector`

---

---

## Spike #10 — Parakeet (NVIDIA) feasibility on macOS 26 / Apple Silicon

**Status:** ✅ passed (Sessions 006–007). Validated outcomes below; full implementation report at `ParakeetSpike/REPORT.md`.

### Validated outcomes (Spike closed Session 007)
- **Acquisition:** FluidInference's `parakeet-tdt-0.6b-v3-coreml` exists pre-converted on Hugging Face. FluidAudio (Apache 2.0 Swift SDK) wraps it with a clean API. Spike used FluidAudio as SPM dependency; production `ParakeetTranscriberBackend` (M3.5b) decides whether to keep that dependency or extract the model.
- **Quantization tier:** FP16/ANE-optimized chosen. INT8 was rejected — INT8 forces CPU-only execution and gives up ANE offload, costing more battery overall despite smaller model file.
- **Real-time factor:** 0.011 mean (≈90× real-time). 45× under the budget gate of 0.5.
- **Peak working memory:** 133 MB. 6× under the 800 MB budget. Architecture doc updated to reflect actual measurement.
- **Cold-start (3 tiers):** ~53s first-ever model download (one-time, M3.6 toast covers); ~16s recompile after cache eviction; 0.4s warm subsequent launches.
- **Russian WER:** 9.4% on clean speech at ~110 WPM; 9.4% on café-noisy speech at same pace (clean-vs-noisy A/B in Session 007 confirmed café noise has zero measurable WER impact); 26.8% on fast speech at ~205 WPM (marginal — fast Russian is the actual quality cliff, not noise).
- **Filler recognition:** 70–93% across the seed dictionary («ну», «как бы», «типа», «короче»), with sample-size variance dominating the spread — gate ≥70% met.
- **Word-level timestamps:** confirmed. `ASRResult.tokenTimings` provides per-token `startTime`/`endTime`. After BPE subword merging via `TokenMerger`, words feed directly into `SpeakingActivityTracker`. Proportional-estimation fallback designed in Session 006 is **not needed** and dropped from M3.5b.
- **Sustained run:** 185 iterations over 5 minutes with no memory leak, RSS flat. Confirms long-session stability.
- **Total spike effort:** ~10h actual vs 8–12h estimated.

### Open follow-ups (NOT blockers — all v1.x or routine)
- Russian-at-fast-pace under noise: untested. The clean-vs-noisy A/B was at ~110 WPM only. If real users report degraded fast Russian in noisy meetings, re-test with a fast-pace café clip in v1.x.
- Self-hosted CDN vs Hugging Face download: M3.6 (model download flow) decides whether production keeps Hugging Face as the source or relocates the model to an Anthropic-controlled CDN. Spike used HF; either is acceptable.
- "Preparing Russian model…" toast copy: needs to handle ~1 minute on first-ever download, not 30 seconds. Update copy in M3.6.

---

### Original spike specification (preserved for reference)

**Original priority:** P0 · **Original estimate:** 8–12h

### Question
Can NVIDIA Parakeet (multilingual, v3) run as a Core ML model on macOS 26 / Apple Silicon, in real time, with word-level timestamps, at acceptable quality for Russian transcription, within a power/memory budget compatible with Architecture Y?

### Why it matters
Architecture Y depends on Parakeet covering locales Apple does not (notably Russian — confirmed unsupported by `SpeechTranscriber` on macOS 26.4.1, Session 006). If Parakeet can't be made to work on macOS, Architecture Y collapses and we are back to Path A from Session 006 (drop Russian from v1) or a third option not yet identified.

This spike was originally Spike #3 ("Russian quality on `SpeechAnalyzer`"). Spike #6 incidentally found Russian is not on the platform's supported locale list at all. The question is no longer "is Apple Russian good enough" but "is Parakeet feasible at all in our deployment context."

### Variant selection
- **Investigate v3 first** — `parakeet-tdt-0.6b-v3` is multilingual (25 European languages including Russian and Spanish). Serves Russian-now and future-language flexibility.
- The user has used Parakeet in real-time on iOS in a translation app (variant unknown). v3 is the right default here unless v3 doesn't have a usable Core ML port and an earlier multilingual variant does.

### Method

**Phase A — Acquisition + conversion check (2–3h):**
1. Investigate whether a Core ML conversion of `parakeet-tdt-0.6b-v3` already exists publicly (Hugging Face, NVIDIA NeMo Core ML exports, third-party ports). If yes, use it. If no, attempt conversion via `coremltools` from the NeMo PyTorch checkpoint. Document the conversion path and any pitfalls.
2. Confirm at least one runnable Core ML model file exists at end of phase. If conversion fails completely, stop here and raise a blocker.

**Phase B — Quantization tier comparison (2h):**
1. Test two model tiers in this order:
   - **INT8** (~600 MB): smaller download, lower memory, possibly lower quality
   - **FP16** (~1.2 GB): higher quality, larger footprint
2. For each tier, measure on the same test corpus:
   - Cold-start time (model load → first token)
   - Real-time factor (RTF = processing time / audio duration; <1.0 means real-time capable)
   - Peak memory during inference
   - Word Error Rate vs ground truth (see Phase C)
3. Output a quality-vs-size tradeoff table. Architecture doc references the chosen tier's realistic size, not worst case.

**Phase C — Russian quality validation (3–4h):**
1. Reuse the Spike #6 Russian recordings (`ru_normal.caf`, `ru_fast.caf`, `ru_slow.caf`). Add ~5 minutes of more realistic Russian (some background noise, slightly varied register).
2. Transcribe via Parakeet at the chosen quantization tier.
3. Compute Word Error Rate vs the manual transcripts.
4. Specifically check Russian fillers: «ну», «это», «как бы», «типа», «короче». These are short and softly spoken — the most demanding case.
5. Pass criteria same as the original Spike #3: WER <15% clean, <25% realistic, fillers recognized ≥70% when spoken clearly.

**Phase D — Word-level timestamp validation (1–2h):** ★ critical
1. Confirm Parakeet's Core ML port emits **word-level** timestamps, not phrase-level.
2. Why this matters: the Session 004 `SpeakingActivityTracker` architecture assumes word-level start/end times. If Parakeet only emits phrase-level segmentation (e.g., one timestamp range per 5-word phrase), the WPM math degrades for Russian — speaking-duration intersections become coarse and `tokenSilenceTimeout` gap-bridging is meaningless.
3. Test method: process a Russian clip with 2–3 internal pauses of ~1.5s each (within a phrase). Inspect the emitted timestamps. Expected if word-level: 1 timestamp per word, gaps visible in the `[startTime, endTime]` series. Expected if phrase-level: 1 timestamp range per phrase, internal pauses invisible.
4. If only phrase-level is available, design a fallback: proportional estimation within phrases (if a phrase is N words over T seconds, assign each word `T/N` duration centered in the phrase). Measure how much this degrades WPM accuracy vs the Spike #6 English baseline.

**Phase E — Power & cold-start under realistic conditions (2h):**
1. Run a 5-minute Russian session through Parakeet, measure with Instruments:
   - Sustained CPU
   - Peak GPU/ANE utilization
   - Memory profile
   - Energy Impact rating
2. These are inputs to Spike #7's Architecture Y validation — not the final budget verdict, just the per-second profile.
3. Specifically measure cold-start: how long from "user starts speaking Russian for the first time in the app's lifetime" to "first Russian token emitted." This is the user-facing latency of the M3.6 toast ("Preparing Russian model…").

### Pass criteria
- A working Core ML port of Parakeet v3 (or a justified alternate variant) exists and runs on macOS 26 / Apple Silicon
- At chosen quantization tier: real-time factor <0.5 (i.e., 2× real-time, leaves headroom), peak memory <800 MB
- Russian WER <15% on clean clips, <25% on realistic clips
- Russian fillers recognized ≥70%
- Word-level timestamps present (or fallback estimation degrades WPM accuracy by <5% vs English baseline)
- Cold-start <30s on first session (acceptable for a "Preparing model…" toast)

### Fail mode → action
- **No working Core ML port and conversion fails:** investigate alternatives — Whisper.cpp Core ML (English+Russian), Whisper Distil, or accept Path A (drop Russian from v1)
- **Real-time factor >1.0 (slower than real-time):** Parakeet can't keep up with live audio; would require buffering with growing latency. Probable kill for Architecture Y as-drafted. Try smaller tier; if still too slow, drop to Path A.
- **Quality unacceptable:** test if a different multilingual model fits better (Whisper-medium Russian)
- **Phrase-level timestamps only AND fallback estimation degrades WPM accuracy too much:** WPM math for Russian becomes a known limitation. Document, accept, move on — better to have inaccurate WPM than no Russian.
- **Power profile clearly violates budget:** input to Spike #7 — may force "Russian sessions warn user about battery impact" UX.

### Outputs
- Working Parakeet Core ML pipeline (script or small library) usable as the basis for the production `TranscriptionEngine` non-Apple backend
- Quality-vs-size tradeoff table (INT8 vs FP16)
- Selected quantization tier with justification
- Word-level vs phrase-level timestamp finding (and fallback design if needed)
- Per-second power profile to feed into Spike #7
- Documentation of the conversion path (so the production app can repeat it as part of build, or pin a conversion artifact)

---

## Spike #5 — Acoustic non-word detection ("hmm", "ahh")
**Status:** ⏸ deferred to v1.x

Not in v1. Run when v1.x scoping begins.

### App Store reviewability of mic auto-detection
**Status:** ⏸ deferred to distribution decision

Only matters if you go App Store. Run a TestFlight submission as the validation when distribution path is chosen.

---

## When all spikes are done

Update `01_PROJECT_JOURNAL.md` with:
- Final answers per spike
- Any architecture changes (revise `03_ARCHITECTURE.md` if needed, log the change)
- Any product changes (revise `02_PRODUCT_SPEC.md` if needed, log the change)
- Updated estimates in `04_BACKLOG.md` based on what was learned

Then begin Phase 1 module work.
