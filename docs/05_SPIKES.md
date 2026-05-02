# Spikes — Speech Coach v1

> Each spike is a small piece of throwaway code (or sometimes a recording + spreadsheet) whose only purpose is to answer a yes/no architectural question. Production code does NOT depend on the spike code — when the spike is done, the answer goes into the journal and the spike code is deleted.
>
> Run **P0 spikes first**. If any P0 spike fails, re-plan rather than push through.

---

## Status legend
`📋 planned` · `🔬 running` · `✅ passed` · `❌ failed` · `⚠️ passed with caveats` · `⏸ deferred`

---

## Spike #6 — WPM ground truth on real EN/RU recordings

**Status:** 🔬 in progress (revised Session 004) · **Priority:** P0 · **Estimate:** 4h

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

## Spike #7 — Power & CPU profiling during 1hr session

**Status:** 📋 planned · **Priority:** P0 · **Estimate:** 4h

### Question
Will running `SpeechAnalyzer` + `AVAudioEngine` + VAD + RMS continuously for 1 hour stay under our resource budget on Apple Silicon, on battery?

### Why it matters
FM4 (no performance impact) is a uninstall-trigger. If a 1hr Zoom call drains battery 20% more with this app running, the user kills it.

### Budget
- <5% sustained CPU on M-series during active session
- <150MB RSS memory
- No measurable mic dropouts in Zoom (manual A/B test)
- Battery drain delta <2% per hour vs control (Zoom alone)

### Method
1. Build a minimal harness: `AVAudioEngine` with input tap → `SpeechAnalyzer` (English) → discard tokens. Add VAD + RMS computation.
2. Run a 1hr loop playing English audio (or speaking) into the mic.
3. Measure with Xcode's Instruments:
   - **Time Profiler** — CPU usage breakdown
   - **Allocations / Leaks** — memory growth
   - **Energy Log** — power impact rating
4. Run Zoom alongside for the second half of the test. Compare both readings.
5. Run a control: Zoom alone, no harness, for 1hr. Diff.

### Pass criteria
- Sustained CPU within budget
- No memory growth over time (stable RSS after warmup)
- Energy Impact rating "low" or better in Activity Monitor
- Zoom audio quality unchanged in A/B test

### Fail mode → action
- **CPU too high:** investigate `SpeechAnalyzer` reporting options (do we need both `.volatileResults` and full results? what's the cost of `.audioTimeRange`?), VAD frequency
- **Memory grows:** likely leak in token accumulation or audio buffer retention — fix at the source
- **Zoom degrades:** Voice Processing IO conflict — verify our `isVoiceProcessingEnabled = false` is actually taking effect; may need different audio session configuration

### Outputs
- Energy Impact baseline numbers
- Confirmed (or revised) settings for `SpeechAnalyzer` reporting/attribute options
- Decision input for Spike #2 (how much budget remains for language detection)

---

## Spike #3 — Russian transcription quality on `SpeechAnalyzer`

**Status:** 📋 planned · **Priority:** P0 · **Estimate:** 4h

### Question
Is `SpeechAnalyzer`'s Russian recognition good enough for our use case (counting words, detecting fillers)?

### Why it matters
The user's prior iOS experience showed `SFSpeechRecognizer` Russian was unusable. We've moved to `SpeechAnalyzer` (which is verified to support `ru_RU`) but quality has not been independently confirmed for our specific use case. If Russian quality is poor, the whole multilingual story collapses.

### Method
1. Record (or source) ~10 minutes of real meeting-style Russian audio:
   - Clear speaker, no background noise → ~3 min
   - Realistic conditions (some background, normal speaker) → ~5 min
   - Two speakers in the same room (your worst case) → ~2 min
2. Transcribe via `SpeechAnalyzer` with `SpeechTranscriber(locale: ru_RU)`, `.audioTimeRange`, `.volatileResults`
3. Manually transcribe ground truth
4. Compute WER (Word Error Rate) per clip
5. Specifically check: are the Russian filler words ("ну", "это", "как бы", "типа", "короче") being recognized correctly when spoken? (Filler counting is the most demanding test — fillers are short and often softly spoken.)

### Pass criteria
- WER <15% on clean speech
- WER <25% on realistic speech
- Russian fillers in our seed dictionary are recognized at least 70% of the time when spoken clearly
- Word boundaries (timestamps) are reasonable (no 5-word chunks merged into single tokens)

### Fail mode → action
- **WER too high overall:** is `requiresOnDeviceRecognition` falling back to a worse model? Can we get a better model? Is the `ru_RU` model actually downloaded (`AssetInventory.installedLocales`)?
- **Russian fillers specifically missed:** these are very short — try `addsPunctuation = true` (sometimes that improves segmentation), check if they're being elided as non-words
- **Total fail (worse than iOS):** consider Whisper.cpp via Core ML as fallback for Russian only — significant scope expansion. Alternative: ship without Russian in v1, add later. Discuss with user.

### Outputs
- WER measurements per clip type
- Confirmed model behavior on `ru_RU`
- Filler-word recognition rates per Russian filler in seed dictionary
- Go/no-go decision on Russian in v1

---

## Spike #4 — Mic coexistence with Zoom voice processing

**Status:** 📋 planned · **Priority:** P0 · **Estimate:** 3h

### Question
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
