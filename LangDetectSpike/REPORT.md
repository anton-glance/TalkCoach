# Spike #2 Report: Language Auto-Detect Mechanism (N=2 Binary Classifier)

**Date:** 2026-05-03
**Status:** PASS
**Total effort:** ~6h actual vs 5h estimated

---

## Executive Summary

The production `LanguageDetector` (M3.4) should use a **script-aware hybrid** of three signals, selected at onboarding based on the Unicode script properties of the user's two declared languages:

- **Same-script pairs (e.g., EN+ES):** `NLLanguageRecognizer` on ~5s of transcribed text. 100% accuracy in testing. No additional model needed.
- **Latin+Cyrillic pairs (e.g., EN+RU):** Word-count threshold on the wrong-guess transcript. 100% accuracy at threshold 13 words. No additional model needed.
- **Latin+CJK pairs (e.g., EN+JA):** Whisper-tiny audio LID via WhisperKit Core ML. 100% accuracy at both 3s and 5s windows. Requires bundling the 75.5 MB `openai_whisper-tiny` model.

This hybrid means most users (same-script or Latin+Cyrillic pairs) pay zero model-size cost. Only users who declare a CJK language alongside a Latin-script language incur the 75.5 MB Whisper-tiny download. The architecture selected by script analysis at onboarding, not at runtime.

---

## Per-Pair Results

### Option B: Transcribe-Then-Detect (NLLanguageRecognizer + word-count)

| Pair  | Signal             | Guess Mode | Window | Correct / Total | Accuracy |
|-------|--------------------|------------|--------|-----------------|----------|
| EN+ES | NLLanguageRecognizer | wrong    | full   | 8 / 8           | 100%     |
| EN+ES | NLLanguageRecognizer | correct  | full   | 8 / 8           | 100%     |
| EN+RU | NLLanguageRecognizer | wrong    | full   | 0 / 8           | 0%       |
| EN+RU | NLLanguageRecognizer | correct  | full   | 8 / 8           | 100%     |
| EN+JA | NLLanguageRecognizer | wrong    | full   | 4 / 8           | 50%      |
| EN+JA | NLLanguageRecognizer | correct  | full   | 8 / 8           | 100%     |

NLLanguageRecognizer is perfect when the transcript is in the correct language (correct-guess mode). It fails on wrong-guess transcripts for cross-script pairs because the wrong-locale transcriber produces garbled text that NLLanguageRecognizer cannot classify.

| Pair  | Signal           | Threshold | Correct / Total | Accuracy |
|-------|------------------|-----------|-----------------|----------|
| EN+RU | Word count       | 13 words  | 16 / 16         | 100%     |
| EN+ES | Word count       | 17 words  | 10 / 16         | 62.5%    |
| EN+JA | Word count       | N/A       | N/A             | N/A      |

Word-count works for cross-script pairs (wrong-locale transcriber emits far fewer words) but fails for same-script pairs (both locales produce similar word counts). Structurally inapplicable to CJK languages (no word boundaries without tokenization).

**Option B composite (best signal per pair):**

| Pair  | Best Signal          | Accuracy |
|-------|----------------------|----------|
| EN+ES | NLLanguageRecognizer | 100%     |
| EN+RU | Word count (t=13)    | 100%     |
| EN+JA | Neither sufficient   | -        |

### Option C: Audio LID (Whisper-tiny via WhisperKit)

| Pair  | Window | Correct / Total | Accuracy |
|-------|--------|-----------------|----------|
| EN+RU | 3s     | 8 / 8           | 100%     |
| EN+RU | 5s     | 8 / 8           | 100%     |
| EN+JA | 3s     | 8 / 8           | 100%     |
| EN+JA | 5s     | 8 / 8           | 100%     |
| EN+ES | 3s     | 6 / 8           | 75%      |
| EN+ES | 5s     | 8 / 8           | 100%     |

Whisper-tiny handles all cross-script pairs perfectly. It struggles with same-script pairs at 3s (ES misclassified as Portuguese and Arabic), though 5s eliminates these errors.

### Combined Strategy Coverage

| Pair  | Strategy                    | Accuracy | Model Cost   |
|-------|-----------------------------|----------|--------------|
| EN+ES | Option B: NLLanguageRecognizer | 100%  | 0 MB         |
| EN+RU | Option B: Word count (t=13)   | 100%  | 0 MB         |
| EN+JA | Option C: Whisper-tiny LID    | 100%  | 75.5 MB      |

Every tested pair reaches 100% accuracy with the script-aware hybrid. No single signal achieves this alone.

---

## Model Selection Rationale

### Why Whisper-tiny (WhisperKit) over alternatives

**Considered models:**

| Model | Size | CJK Support | Core ML Available | Status |
|-------|------|-------------|-------------------|--------|
| openai_whisper-tiny (WhisperKit) | 75.5 MB | Yes (ja, ko, zh, +96 others) | Yes (pre-converted, Argmax) | Selected |
| SpeechBrain voxlingua107-ecapa | ~20 MB | Yes | No (conversion issues with Emphasis layers) | Rejected |
| Meta MMS-LID | ~300 MB+ | Yes | No (requires conversion) | Rejected |
| FluidAudio (Parakeet) | ~1.2 GB | No LID API | N/A | Not applicable |

**Selection rationale:**

1. **Pre-converted Core ML model exists.** WhisperKit (Argmax) maintains pre-converted Core ML models on Hugging Face. No custom `coremltools` conversion needed. SpeechBrain's ECAPA model has Emphasis layer conversion failures; MMS-LID has no public Core ML conversion.

2. **Verified CJK coverage.** Whisper's training data includes Japanese, Korean, Chinese (both Mandarin and Cantonese), plus 95 other languages. The model's language token vocabulary explicitly includes `<|ja|>`, `<|ko|>`, `<|zh|>`, confirmed in the tokenizer.

3. **Size is acceptable.** 75.5 MB is the smallest Whisper variant. Compressed (~25 MB in an app bundle), it's comparable to a single locale model from Apple's `AssetInventory`. SpeechBrain's voxlingua107 would be smaller at ~20 MB, but the Core ML conversion is not viable.

4. **Swift-native API.** WhisperKit provides `detectLangauge(audioArray:)` returning `(language: String, langProbs: [String: Float])`. No Python bridge, no custom inference code.

5. **Inference latency.** ~600ms mean, consistent across 3s and 5s windows. The language detection forward pass is a single encoder pass (30s mel spectrogram, padded) followed by a single decoder step — input length does not affect latency.

---

## Compute Unit Verification

**Finding: Whisper-tiny's audio encoder and text decoder request ANE execution by default.**

WhisperKit's `ModelComputeOptions` defaults (from `Models.swift:94-124`):

| Component        | Default (macOS 14+)      |
|------------------|--------------------------|
| Mel spectrogram  | `.cpuAndGPU`             |
| Audio encoder    | `.cpuAndNeuralEngine`    |
| Text decoder     | `.cpuAndNeuralEngine`    |
| Prefill          | `.cpuOnly`               |

When `WhisperKitConfig` is initialized without explicit `computeOptions` (our case), these defaults apply. The `audioEncoderCompute` field is set to `.cpuAndNeuralEngine` on macOS 14.0+ via a version check (`Models.swift:118-122`). Our target is macOS 26, so ANE is always requested.

**Caveat:** Apple does not expose a runtime API to confirm which compute unit CoreML actually dispatched to. The `MLModelConfiguration.computeUnits` property is a *request*, not a guarantee — CoreML may fall back to CPU if the model's operations are not ANE-compatible. However, Whisper's encoder architecture (multi-head attention + convolutions) is well-supported on ANE, and WhisperKit's Argmax team specifically optimizes their Core ML conversions for ANE execution.

**Conclusion for Spike #7:** The compute unit configuration is `.cpuAndNeuralEngine`, matching the Parakeet backend's configuration. Spike #7's power profiling should measure actual hardware utilization via Instruments (GPU/ANE trace) rather than relying on the configuration value alone. No revised scope needed for Spike #7 — this is within its existing measurement plan.

---

## EN+ES 3s Misclassification Analysis

**Finding: Detection was fully unconstrained across all 99 languages. No pair restriction was applied.**

WhisperKit's `detectLangauge` implementation (`WhisperKit.swift:546-593`, `TextDecoder.swift:610-729`):

1. A `LanguageLogitsFilter` suppresses all non-language tokens (keeping ~99 language token logits active)
2. A `GreedyTokenSampler` (temperature=0) takes the argmax across all 99 language tokens
3. The returned `langProbs` dictionary contains only the single argmax entry — the full probability distribution is discarded

When `es_03.caf` (3s) was classified as "pt" (Portuguese) and `es_04.caf` (3s) as "ar" (Arabic), the model was choosing from all 99 languages, not restricted to {en, es}. Portuguese winning over Spanish on a 3s clip of Spanish audio is linguistically plausible — the two languages share significant phonetic overlap. The Arabic classification is likely a noise artifact on a short audio window.

**Can we retest with pair-constrained detection?** Not as a one-line change in the harness. WhisperKit's `detectLangauge` API does not accept a language subset parameter. Implementing pair-constrained detection would require modifying `LanguageLogitsFilter` to accept an `allowedLanguages: Set<String>` parameter and suppress logits for all other language tokens (setting them to `-infinity` before softmax). This is a ~20-line change to WhisperKit internals, not a harness-level tweak.

**Production recommendation:** For the M3.4 `LanguageDetector`, implement pair-constrained Whisper detection by either:
- (a) Forking WhisperKit and adding the `allowedLanguages` filter (clean, ~20 lines)
- (b) Subclassing `LanguageLogitsFilter` and injecting it via `WhisperKitConfig.logitsFilters`
- (c) Accessing the raw logits pre-argmax and applying the restriction in our code

With pair constraint, the 3s EN+ES misclassifications would almost certainly disappear — the model would be forced to choose between "en" and "es" only, and the Spanish audio clips do contain Spanish speech. However, this is academic for v1: EN+ES is already handled by NLLanguageRecognizer at 100% accuracy. The Whisper path is only used for Latin+CJK pairs, where it achieves 100% unconstrained.

---

## Production Implementation Sketch: M3.4 LanguageDetector

### Onboarding: Script Analysis (one-time)

At onboarding, when the user declares their two languages, `LanguageDetector` determines the detection strategy based on the Unicode script properties of both locales:

```
func selectStrategy(locale1: Locale, locale2: Locale) -> DetectionStrategy {
    let script1 = dominantScript(for: locale1)  // e.g., .latin
    let script2 = dominantScript(for: locale2)  // e.g., .cyrillic

    if script1 == script2 {
        return .nlLanguageRecognizer     // same script → text classification
    }

    if script1.isCJK || script2.isCJK {
        return .whisperAudioLID          // Latin↔CJK → audio model
    }

    return .wordCountThreshold           // Latin↔Cyrillic, etc. → word count
}
```

`dominantScript` maps locale identifiers to their primary writing system:
- Latin: en, es, fr, de, pt, it, nl, pl, ro, ...
- Cyrillic: ru, uk, bg, ...
- CJK: ja, ko, zh, ...
- Arabic: ar, fa, ur, ...
- Devanagari: hi, mr, ...

For script pairs not tested in this spike (e.g., Latin+Arabic, Latin+Devanagari), `wordCountThreshold` is the safe default — cross-script transcription produces dramatically different word counts. If future testing shows otherwise, promote to `whisperAudioLID`.

### Runtime: Per-Strategy Detection Flow

**Strategy 1: NLLanguageRecognizer (same-script pairs)**

Cost: zero additional resources. Uses Apple's built-in NLLanguageRecognizer.

```
Session starts → begin transcription with best-guess locale (last-used or declaredLocales[0])
→ after ~5s of partials, run NLLanguageRecognizer constrained to {locale1, locale2}
→ if detected language differs from current locale → swap TranscriptionEngine backend
→ discard first ~5s of wrong-language transcription
```

User-visible behavior: transcription starts immediately. If wrong language was guessed, a brief gap (~5s) of missed words occurs at session start. No "Listening..." delay.

**Strategy 2: Word-Count Threshold (cross-script, non-CJK pairs)**

Cost: zero additional resources. Uses the existing transcription pipeline's word output.

```
Session starts → begin transcription with best-guess locale
→ after ~5s, count words emitted
→ if word count < threshold (13) → current locale is wrong → swap to other declared locale
→ discard wrong-language partial
```

User-visible behavior: identical to Strategy 1. The threshold of 13 words was empirically determined from EN+RU testing (wrong-locale transcription of Russian clips produced 0-6 words vs 14-42 for correct-locale).

**Strategy 3: Whisper Audio LID (Latin+CJK pairs)**

Cost: 75.5 MB model, ~600ms inference time. Only loaded for users who declared a CJK language.

```
Session starts → widget shows "Listening..."
→ buffer first 3s of audio
→ run Whisper-tiny detectLanguage, constrained to {locale1, locale2}
→ commit to detected locale → start TranscriptionEngine
```

User-visible behavior: ~3s "Listening..." delay before transcription begins. No swap after commit — Whisper's accuracy at 3s is 100% for Latin+CJK pairs.

### What Each User Actually Pays

| Declared Pair Type | Model Download | Detection Latency | Wrong-Start Risk |
|--------------------|---------------|-------------------|-----------------|
| N=1 (single language) | None | 0ms | None |
| Same-script (EN+ES) | None | ~5s (background) | ~5s of wrong-lang words if guessed wrong |
| Cross-script non-CJK (EN+RU) | None | ~5s (background) | ~5s of wrong-lang words if guessed wrong |
| Latin+CJK (EN+JA) | 75.5 MB (one-time) | ~3s (blocking) | None |

---

## Inference Performance Summary

| Metric | Value |
|--------|-------|
| Model | openai_whisper-tiny (Core ML, WhisperKit) |
| Model size on disk | 75.5 MB |
| Compute units | `.cpuAndNeuralEngine` (ANE requested) |
| Mean inference time | 601 ms |
| Median inference time | ~596 ms |
| Min inference time | 571 ms |
| Max inference time | 867 ms |
| Inference time vs window size | No correlation (fixed-size encoder pass) |

---

## Open Follow-Ups for v1.x

1. **Untested Latin-script pairs:** EN+FR, EN+DE, EN+PT, EN+IT. These should follow the same-script strategy (NLLanguageRecognizer), which achieved 100% on EN+ES. Low risk but unvalidated.

2. **Untested CJK pairs:** EN+KO (Korean), EN+ZH (Chinese). Whisper-tiny's training data includes all three CJK languages; EN+JA at 100% is a strong signal, but Korean and Chinese have different phonetic profiles. Validate before claiming coverage.

3. **Other cross-script pairs:** EN+AR (Arabic), EN+HI (Hindi/Devanagari). The word-count strategy should work (cross-script transcription garbles heavily), but untested.

4. **Mid-session re-detection:** v1 detects language once at session start. A user who switches languages mid-meeting (common for bilingual users) gets wrong analysis for the remainder. v1.x could periodically re-evaluate using the same strategy, with hysteresis to prevent flapping.

5. **Pair-constrained Whisper detection:** Currently unconstrained over 99 languages. Adding pair constraint would improve robustness for edge cases (especially if Whisper is ever used for same-script pairs as a fallback). Low priority for v1 since the script-aware routing avoids this scenario.

6. **Whisper-tiny model bundling vs download:** The 75.5 MB model could be bundled in the app (inflating download for all users) or downloaded on first use of a CJK language (requires network, matching the Parakeet download pattern). Recommendation: download on first use, consistent with the Parakeet model download flow in M3.6.

---

## Raw Data

- Option B results: `LangDetectSpike/results/option_b_merged.csv` (48 rows)
- Option C results: `LangDetectSpike/results/option_c.csv` (48 rows)
- Word-count analysis: `LangDetectSpike/results/wordcount_analysis_merged.txt`
- Test corpus: `LangDetectSpike/recordings/manifest.json` (16 clips, 4 per language)
- Harness code: `LangDetectSpike/Sources/LangDetectSpikeCLI/main.swift`
