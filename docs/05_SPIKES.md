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

**Status:** ✅ conditional pass (Session 012, Apple baseline only) · **Priority:** P0 · **Estimate:** 6h (4h actual for Apple baseline)

### Validated outcomes (Apple SpeechAnalyzer baseline, Session 012)
- **Mean CPU (loaded, 45 min continuous podcast):** 4.18% — under 5% FM4 threshold. Production estimate ~2% (test load 18× heavier than real meeting).
- **CPU delivery pattern:** Extremely bursty — 79% of 10s samples read 0.00%, punctuated by spikes up to 126.58% (multi-core). P95 of 60s rolling windows is 11.91%. This is SpeechAnalyzer's batch-processing model, not a bug.
- **RSS:** 38 MB peak (well under 150 MB). Growth rate 16.2 MB/hr — projects to 49 MB at 3 hours. Monitor in sessions >1 hour.
- **Energy impact:** ~150 mW marginal CPU power (loaded vs isolated). Workload runs entirely on E-Cluster (efficiency cores). "Low" Energy Impact.
- **Thermal:** Nominal (state 0) throughout full 60 minutes.
- **Mic coexistence:** Zero AVAudioEngine config changes across 60 minutes including Zoom join/leave.
- **Phase 4 analyzers:** Safe to build. They process token events, not audio — negligible CPU (~0.01%).
- **Conditions:** (1) Verify with a real 30-min Zoom meeting during Phase 5 integration testing. (2) Monitor RSS in sessions >1 hour. (3) Do not add SoundAnalysis VAD.
- **Parakeet path:** Not re-measured in this spike — already characterized in Spike #10 Phase E (RTF 0.011, 133 MB RSS, ANE-offloaded).
- Full report at `PowerSpike/REPORT.md`.

### Original spike specification (preserved for reference)

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

**Status:** ⚠️ passed with caveats (Phase 1, Session 008) · 📋 Phase 2 tightening planned (Session 022). Full Phase 1 report at `MicCoexistSpike/REPORT.md`.

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

### Phase 2 — Strict-concurrency tap pattern tightening (Session 022)

**Status:** ✅ passed (Session 022). All 5 scenarios PASS, all 8 ACs met, sub-agent review clean. Full report at `MicTapTightenSpike/REPORT.md`.

#### Validated outcomes (Session 022)

- **Canonical strict-concurrency pattern locked.** A top-level `nonisolated func makeTapBlock(continuation:)` returning `@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void`, capturing only an `AsyncStream<CapturedAudioBuffer>.Continuation` (Sendable). The `nonisolated` keyword is **load-bearing** under production's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — without it the function is implicitly `@MainActor` and the tap closure inherits the `_dispatch_assert_queue_fail` crash from Phase 1. In SPM (no default-isolation setting), `nonisolated` is redundant but should be kept for consistency with the production form. M3.1 copies the production form.
- **Hand-off mechanism: `AsyncStream` continuation with `.bufferingNewest(64)`.** `continuation.yield(_:)` is `@Sendable`, thread-safe, non-blocking — safe to call from CoreAudio's render thread. Consumer pulls via `for await`. Three rejected alternatives documented (per-buffer `Task.detached` allocates on the audio thread + unbounded actor mailbox; `nonisolated(unsafe)` ring buffer fights the concurrency model; dispatch serial queue is pre-Swift-concurrency).
- **Backpressure policy: `.bufferingNewest(64)`.** ~5.5s of audio at 48kHz; bounded memory; oldest dropped silently when consumer falls behind. Drain count exactly matched policy capacity in S5 (64 elements), confirming the policy held. Three rejected alternatives documented (`.bufferingOldest` keeps stale data — wrong for real-time audio; `.unbounded` carries OOM risk; bounded queue with blocking yield would block the render thread).
- **`AVAudioEngineConfigurationChange` recovery cycle.** Observe → stop engine → remove tap → re-set `setVoiceProcessingEnabled(false)` → reinstall tap with `format: nil` → prepare → start → resume buffer flow. Same `AsyncStream` continuation reused across recovery so the consumer's `for await` loop is uninterrupted. Recovery latency 196.9ms in S4 (well within 500ms budget). VPIO state confirmed `false` after recovery.
- **`CapturedAudioBuffer` carries PCM samples, not just metadata.** Per the architect's plan-approval addition: the tap closure copies sample data out of `AVAudioPCMBuffer.floatChannelData` before yielding. Validated under strict concurrency (S2), TSAN (S3), and at sustained rate (S1: 2,976,000 samples copied over 60s, no continuity gaps). M3.1 inherits the validated copy step, not the validation work.
- **Strict-concurrency + TSAN clean.** S2: 0 errors / 0 warnings under Swift 6 + `-warnings-as-errors`. S3: 0 TSAN warnings over 60s, 618 buffers received. No `_dispatch_assert_queue_fail` in any scenario.
- **Total spike effort:** ~1.5h estimated, ~3h actual including S4 trigger-debugging round (Chrome Meet did not reproduce Phase 1's config-change behavior; input-device switch trigger validated the recovery code path instead).

#### Caveats and findings for M3.1

1. **Chrome Meet trigger non-reproducibility from Phase 1.** Two 90s S4 runs with engine-first ordering and Chrome joining a Meet produced zero `AVAudioEngineConfigurationChange` events (~952 and ~958 buffers respectively). Spike #4 Phase 1 (Session 008) recorded this trigger as reliable. Possible causes: Chrome version drift, harness-vs-Phase-1-harness setup difference, or macOS behavior change. The recovery code path was validated via input-device switch (MacBook mic ↔ AirPods), which exercises the same notification + recovery cycle. M3.1's smoke gate should include both trigger sources to surface this discrepancy in production conditions.
2. **Recovery latency measured only on event #2 in S4, not event #1.** Either #1's latency was measured but not logged, or the measurement logic activates only on subsequent events after the first. M3.1's plan must specify recovery measurement on **every** config-change event, not just rapid-fire successors. (Documented in `MicTapTightenSpike/REPORT.md` "S4 recovery-latency measurement: per-event analysis.")
3. **S5 expected-callback math overestimated.** Report calculated 703 expected callbacks at "48kHz / 4096 frames" but actual frame size delivered by `format: nil` on this hardware is ~4792 (~99.8ms per callback, ~10.0/sec). True expected ≈ 601 over 60s. The `bufferingNewest(64)` policy demonstrably held (drain = 64), so AC6 is met regardless. M3.1 must derive frame size dynamically from the active format, never hardcode 4096.
4. **Sub-agent MEDIUM finding (harness-only).** `S4Tracker` in `MicTapTightenSpike/main.swift` is `@unchecked Sendable` with mutable state and no synchronization. Benign data race in the harness; does not affect the production pattern M3.1 copies. Not fixed (harness-scope).

#### Original Phase 2 specification (preserved for reference)

##### Question
What's the canonical Swift 6 strict-concurrency pattern for an `AVAudioEngine` input-tap closure that hands buffers to a non-main consuming actor, plus the recovery cycle for `AVAudioEngineConfigurationChange`, such that the pattern compiles clean under `-strict-concurrency=complete`, runs without `_dispatch_assert_queue_fail`, and survives a Chrome/Safari Meet config-change without buffer-flow loss?

#### Why it matters
M3.1 (`AudioPipeline`) is the next module after this spike. Spike #4 Phase 1 (Session 008) identified two findings that block confident M3.1 implementation but did not lock the implementation pattern:

1. **Swift 6 finding.** Audio tap closures must NOT inherit `@MainActor` isolation — strict concurrency crashes at runtime (`_dispatch_assert_queue_fail`) if the tap closure is defined in a main-actor context. The fix direction is "define tap callbacks in a separate non-main-actor source file" but the canonical pattern that hands buffers to a non-main consuming actor was not exercised end-to-end under strict mode.

2. **Recovery requirement.** Production must observe `AVAudioEngineConfigurationChange`, restart engine, reinstall tap, use `format: nil` (never hardcode channel count). The end-to-end recovery cycle was not exercised in Phase 1 — only the no-recovery-needed scenarios.

If M3.1 is the validation site for these patterns, a single smoke-gate fix round costs +2–3h; one fix round per finding = +4–6h. A focused 1.5h tightening here pays for itself even if it heads off only one fix round, and protects M3.1's plan content from being driven by unverified assumptions.

#### Method
1. Build a tiny harness `MicTapTightenSpike/` (mirror `MicCoexistSpike/` structure):
   - Swift Package executable, `-strict-concurrency=complete -warnings-as-errors`
   - One `AudioTapBridge.swift` source file containing the canonical pattern (the production-shape artifact this spike validates)
   - One `main.swift` runner that builds the bridge, runs the scenarios, prints structured outcomes
   - One `REPORT.md` filled in at the end
2. Implement the canonical pattern as the bridge:
   - Owns an `AVAudioEngine` instance
   - Configures `setVoiceProcessingEnabled(false)` per Phase 1 finding
   - Installs a tap on the input node with `format: nil`
   - The tap closure is defined outside any `@MainActor` context
   - Hands each buffer to a consuming actor via a single, documented mechanism (the spike's job is to pick and validate one of: `AsyncStream` continuation, actor-task spawning, `nonisolated(unsafe)` ring buffer with explicit barrier, etc. — agent picks primary + fallback in Phase 1 plan)
   - Observes `AVAudioEngineConfigurationChange` and runs a recovery cycle: stop → reinstall tap → re-set VPIO=false → restart → resume buffer flow
3. Run scenarios:
   - **S1 — Baseline (60s):** start engine, verify buffer flow at the consuming actor (count, monotonic timestamps).
   - **S2 — Strict-concurrency compile gate:** must compile clean under `-strict-concurrency=complete -warnings-as-errors`.
   - **S3 — Thread Sanitizer (60s):** S1 under TSAN; zero warnings.
   - **S4 — Config-change recovery:** start engine, then user manually opens Chrome and joins a Google Meet (any meeting; self-join test room fine). Confirm `AVAudioEngineConfigurationChange` fires, recovery runs, buffer flow resumes within 500ms, no crash.
   - **S5 — Backpressure stress (60s):** consuming actor's buffer handler artificially delayed by 50ms per buffer. Documented backpressure policy holds without unbounded memory growth.
4. Document findings in `REPORT.md` with the canonical pattern code excerpt + decision rationale + scenario outcomes + a "how M3.1 copies this" subsection.

#### Pass criteria
- S2 compiles clean under `-strict-concurrency=complete -warnings-as-errors`.
- S3 runs 60s under TSAN with zero warnings.
- S4 confirms recovery: config-change event observed, buffer flow resumes within 500ms, no crash.
- S5 confirms documented backpressure policy holds (no unbounded memory growth, no crash).
- `REPORT.md` documents the canonical pattern, the backpressure policy choice with rationale, the hand-off mechanism choice with rationale, and any caveats M3.1 needs to inherit.

#### Fail mode → action
- **S2 fails (compile errors under strict concurrency):** the chosen hand-off mechanism is incompatible with strict mode. Try the fallback. Re-run.
- **S3 fails (TSAN warning):** data race between tap closure and actor consumer. The `nonisolated` boundary alone isn't sufficient — the buffer hand-off has a real race. Investigate `nonisolated(unsafe)` semantics or queue-based hand-off.
- **S4 fails (recovery doesn't run, or buffer flow doesn't resume):** Phase 1's `AVAudioEngineConfigurationChange` finding is incomplete. Investigate observer attachment timing, engine state after stop, format retention across reinstall.
- **S5 fails (memory unbounded):** backpressure policy is broken. Pick a stricter policy (drop oldest, drop newest, bounded queue) and re-validate.
- **All pass:** copy the canonical pattern code excerpt into a Phase 2 validated-outcomes block (architect adds at session close). M3.1 is unblocked.

#### Outputs
- `MicTapTightenSpike/Sources/AudioTapBridge.swift` — canonical pattern (production-shape; M3.1 copies and adapts).
- `MicTapTightenSpike/Sources/main.swift` — harness runner.
- `MicTapTightenSpike/REPORT.md` — scenario outcomes + canonical pattern excerpt + locked policy decisions + "how M3.1 copies this" subsection.
- Phase 2 validated-outcomes block added to this Spike #4 entry by the architect at session close.

#### Out of scope
- No production code modifications outside `MicTapTightenSpike/`. M3.1 is the next module *after* this spike.
- No CPU / RSS measurement — Spike #7's scope.
- No broader browser Meet coexistence testing — Phase 1 covered that.
- No audio formats other than what `format: nil` delivers from the system default mic.

---

## Spike #2 — Language auto-detect mechanism (N=2 binary classifier)

**Status:** ✅ passed (Session 010) · **Production mechanism locked:** script-aware hybrid — NLLanguageRecognizer for same-script, word-count threshold for Latin↔Cyrillic, Whisper-tiny audio LID for Latin↔CJK

### Validated outcomes (Spike closed Session 010)
- **Recommendation: script-aware hybrid of three signals.** No single signal covers all pair types. The detection strategy is selected at onboarding based on the Unicode script properties of the user's two declared languages.
- **Same-script pairs (EN+ES):** `NLLanguageRecognizer` on ~5s of transcribed text. 100% accuracy across all 16 evaluations (8 wrong-guess + 8 correct-guess). Zero model cost.
- **Latin↔Cyrillic pairs (EN+RU):** Word-count threshold (t=13) on the wrong-guess transcript. 100% accuracy across 16 evaluations. Wrong-locale Russian transcription produces 0–6 words vs 14–42 for correct-locale. Zero model cost. (Parakeet used as transcription backend for Russian since Apple `SpeechTranscriber` doesn't support `ru_RU`.)
- **Latin↔CJK pairs (EN+JA):** Whisper-tiny audio LID (WhisperKit, `openai_whisper-tiny`). 100% accuracy at both 3s and 5s windows across 16 evaluations. Model cost: 75.5 MB (one-time download for CJK users only).
- **EN+ES at 3s with Whisper-tiny (informational):** 75% accuracy — 2/8 Spanish clips misclassified as Portuguese and Arabic. Detection was unconstrained across 99 languages (no pair restriction). Irrelevant for production: EN+ES is handled by NLLanguageRecognizer, not Whisper.
- **Whisper-tiny compute units:** Audio encoder and text decoder configured as `.cpuAndNeuralEngine` (ANE requested) on macOS 14+. Spike #7 will measure actual hardware utilization via Instruments.
- **Whisper-tiny inference:** ~600ms mean, consistent across 3s and 5s windows (fixed-size encoder pass). One-time model load adds ~7s on first invocation.
- **Character-count signal (tested post-hoc):** Identical accuracy to word-count signal for all pairs. No additional discriminative value. Dropped.
- **Model selection:** Whisper-tiny chosen over SpeechBrain voxlingua107-ecapa (Core ML conversion fails on Emphasis layers), Meta MMS-LID (no public Core ML conversion, 300MB+), and FluidAudio/Parakeet (no LID API).
- **Total spike effort:** ~6h actual vs 5h estimated.

### Open follow-ups (NOT blockers)
- Untested same-script pairs: EN+FR, EN+DE, EN+PT, EN+IT. NLLanguageRecognizer expected to work (100% on EN+ES), but unvalidated.
- Untested CJK pairs: EN+KO, EN+ZH. Whisper-tiny supports both; EN+JA at 100% is a strong signal, but unvalidated.
- Pair-constrained Whisper detection: currently unconstrained over 99 languages. Adding `allowedLanguages` filter to `LanguageLogitsFilter` would improve edge-case robustness. Low priority — script-aware routing avoids the scenario where unconstrained detection fails.
- Mid-session language re-detection: v1 detects once at session start. v1.x could periodically re-evaluate with hysteresis.
- Whisper-tiny model distribution: download on first CJK-language use (consistent with Parakeet pattern) vs bundle in app. Recommendation: download on first use.

---

### Original spike specification (preserved for reference)

### Scope (locked Session 008)

The product makes a fundamentally simpler choice than the original Spike #2 envisioned: users declare 1 or 2 languages at first-launch onboarding, from the union of Apple's 27 + Parakeet's 25 supported locales (~50 distinct languages). N=1 needs no detection at all (return the single declared locale). Only N=2 requires a runtime detector, and it only ever has to pick between two specific pre-declared locales — never against the full set of world languages.

This narrows the spike to: **does our chosen mechanism reliably pick the correct one of two arbitrary declared locales, on short clips, across language pairs that vary in similarity?**

### Question
Which approach for the N=2 binary classifier:
- **(B)** Best-guess (last-used or `declaredLocales[0]`) → transcribe → use `NLLanguageRecognizer` on partials after ~5s → swap if detected language ≠ initialized language
- **(C)** Small audio language-ID model → identify locale on first ~3s of audio → commit to a backend before transcription begins

(Option A — two transcribers in parallel — is **disqualified** by power budget, FM4.)

### Why it matters
The user-facing behavior of `LanguageDetector` differs materially between the two:
- Option B: instant transcription start; first ~5 seconds of words may be discarded if language guess was wrong (cost: words missed at session start)
- Option C: ~3-second "Listening…" delay before any transcription; once committed, no swap (cost: latency at session start)

The wrong choice degrades FM2 (unreliable data) at the start of every session. We need empirical data on which is less bad.

### Method

**Test corpus:** YouTube clips, ~10 seconds each, ~4 per language. Single speaker, monologue/news/interview content, no music, no overlapping voices. The user (Anton) sources from YouTube, downloads audio via `yt-dlp` or similar, converts to `.caf` for the harness.

Three representative pairs covering different similarity regimes:
- **EN + RU** (Latin + Cyrillic, very different acoustic and tokenization profile) — primary use case, easiest acoustic distinction
- **EN + JA** (Latin + non-Latin, different from EN+RU because Japanese phonology is also very different from English) — stress test
- **EN + ES** (both Latin alphabet, both Apple-routed, more similar acoustic profile) — the harder case; if this works, the easier pairs work too

For each pair, the harness presents a clip from one of the two languages and the detector must say which. 4 clips × 2 languages × 3 pairs = 24 clip evaluations total. Source 4 clips per language, so 16 raw clips needed (4 EN × 1 + 4 RU + 4 JA + 4 ES, with EN reused across the three pairs).

**Option B test:**
1. For each clip: initialize the transcriber with the *opposite* language from what the clip actually contains (worst-case wrong-guess to stress the swap logic)
2. After 5 seconds of partials, run `NLLanguageRecognizer` on the accumulated text
3. Record: did the detector identify the correct language? How many words were emitted in the wrong-language interpretation before the swap (count from the partial transcript)?
4. Measure: detection accuracy %, mean wrong-language words emitted, time from clip start to detection decision

**Option C test:**
1. Find a Core ML language-ID model. First check: does a small public LID model exist (e.g., from Hugging Face) covering at least the 50 candidate locales? Whisper-tiny LID head, or alternative.
2. For each clip: run the LID model on the first 3 seconds, get a locale identifier or score vector restricted to the two declared locales
3. Record: did the model identify the correct one? What was the model's confidence?
4. Measure: detection accuracy %, model size in MB, CPU/inference time per clip

### Pass criteria

For the option chosen for production:
- ≥90% accuracy on the EN+RU pair (the bilingual case the architecture was designed around)
- ≥90% accuracy on the EN+JA pair (the stress test)
- ≥85% accuracy on the EN+ES pair (acceptable given more similar acoustic profile)
- Time-to-decision: Option B ≤5s after session start; Option C ≤3s (the "Listening…" window) before session starts
- Option C model must be ≤200 MB on disk; CPU cost validated against Spike #7's residual budget after the Apple/Parakeet stacks

### Fail mode → action
- **Both options below 85% on the harder pairs (EN+ES):** declare auto-detect unsuitable for some pairs; ship with a UI-level manual override prompt for those pairs at session start. Document.
- **Option C model unavailable, large, or below 90% on EN+RU:** Option B is the path. Accept the ~5s start-of-session penalty.
- **Option B's wrong-guess interval emits too many wrong-language words:** consider using `declaredLocales[0]` as best-guess (the user's primary) instead of `last-used`, on the assumption that primary language is more common per session.
- **Both options fail across all pairs:** ship with manual language switcher in menu bar only, defer auto-detect to v1.x. The product still works; user has to flip a menu bar control when they start a different-language session.

### Outputs
- Selected mechanism (B or C) with measured numbers per pair
- Implementation sketch for `LanguageDetector` M3.4 module (a few hundred lines max)
- The chosen mechanism's tuned parameters: detection-window length (Option B) or first-N-seconds (Option C), confidence threshold, hysteresis if any

### Out of scope
- N=1 case (no detection needed, return declaredLocales[0])
- N>2 case (forbidden by product spec; user can pick max 2)
- Mid-session re-detection (Option B's swap *is* mid-session re-evaluation; Option C does not support mid-session swap by construction)
- Detection across all 50 candidate locales (the spike only validates the binary case actual users encounter)

---

## Spike #1 — Identifying activating app for blocklist

**Status:** ⏸ deferred to v2 (Session 014 — blocklist feature deferred) · **Original priority:** P2 · **Estimate:** 3h

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

**Status:** ✅ passed (Session 011) · **Priority:** P1 (run after S6 passes) · **Estimate:** 3h (3h actual)

### Validated outcomes (Spike closed Session 011)

- **Word count:** Identical (99) across all 4 conditions (MacBook quiet, MacBook noisy, AirPods Pro 2 quiet, AirPods Pro 2 noisy). 0% spread. `SpeechAnalyzer` consistently recognizes 99 words from a 96-word script regardless of mic or environment.
- **Speaking duration:** CV = 2.93% across conditions (35.3–38.2s). Well under the 10% threshold.
- **Inter-onset interval (IOI):** 355–384 ms mean (CV 2.9%) across conditions. Silence gaps between tokens average 4–6 ms — tokens are effectively contiguous regardless of input device.
- **WPM (raw CV):** 7.84% — exceeds the 5% threshold, but driven by speaker pace variance (3.35% CV) and a pre-speech delay artifact in one clip (`airpods_quiet` first token at 3.0s vs 1.1–1.6s for others). Pace-normalized CV excluding outlier: 1.99%.
- **Decision:** Approach D (token-arrival) validated. No need for Approach C (`SoundAnalysis` VAD) as secondary signal.
- **Production note:** `WPMCalculator` should begin sampling after the first token arrives, not from t=0, to avoid EMA warmup artifact on pre-speech silence.

Full report at `TokenStabilitySpike/REPORT.md`.

### Original spike specification (preserved for reference)

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

**Status:** ❌ closed Session 013 — algorithm invalidated, feature deferred to v2 · **Estimate vs actual:** 2h estimate, ~3h actual

### Original question
Does the adaptive noise-floor approach (rolling 5s buffer, 10th percentile = noise floor, threshold = floor + 25 dB) reliably detect shouting across environments without false positives?

### Verdict
**No.** The algorithm cannot perform the task. Two failure modes, both fundamental, neither tunable:

1. **In quiet rooms with natural speech, every sentence-after-pause looks like a shout.** The 10th percentile of a 5-second buffer dominated by speech-with-pauses calibrates to *the silences between sentences* (e.g. -62 dBFS), not to room ambience (e.g. -38 dBFS). Normal speech at -32 dBFS is then 30 dB above floor — over the +25 dB threshold. Validated on `quiet_normal.caf`: 3 false positives at architecture defaults.

2. **In noisy rooms, genuine raised-voice cannot clear the threshold.** The Lombard effect causes speakers to raise their voice 10-15 dB automatically in noise — that's automatic, non-aggressive vocal compensation, not shouting. In a noisy room the floor IS the noise (no silent gaps), so it sits at e.g. -33 dBFS. Genuine shouting peaks at e.g. -10 dBFS — 23 dB above floor, below threshold. Validated on `noisy_shout.caf`: 0 events detected at architecture defaults despite a clear deliberate shout in the recording.

The cleaner the room, the more silences in speech, the lower the floor, the easier to false-trigger. The noisier the room, the harder to true-trigger. Inverse of what's wanted.

### Root cause
RMS dBFS is the wrong signal for shouting. The algorithm is a *loudness detector* — and loudness alone cannot distinguish:
- Genuine shouting (aggressive, intentional, destructive)
- Lombard compensation (automatic, non-aggressive, environment-appropriate)
- Emphasis (passionate but not aggressive)
- Plosives, laughs, clearings of throat (transient energy, not voice)

No combination of percentile / threshold / sustain / buffer length resolves this — the input signal does not carry the information needed.

### Implementation status
The `ShoutingSpike/` harness is correct and well-engineered. Tests pass 12/12, sub-agent independent review passed 7/7, byte-identical re-runs verified. The implementation faithfully realizes the architecture's algorithm. The *algorithm* is what's wrong, not the code. Harness is preserved in the repo for v2 reference.

### Tuning attempts (all failed)
- Architecture defaults (p10, +25 dB): 2/5 gates pass — false positives on `quiet_normal` and `transition`, missed shout on `noisy_shout`.
- Targeted variants from this spike's "Fail mode → action" list (p25 +20 dB, p25 +20 dB / b8, etc.): best variant achieves 4/5 gates by hiding the quiet-room false positives behind a higher percentile, but `noisy_shout` still misses because the Lombard problem is structural.
- No combination passes all five gates because the two failure modes pull in opposite directions: tighter threshold → more false negatives in noise; looser threshold → more false positives in quiet.

### Decision (Session 013)
Shouting detection removed from v1 entirely. Deferred to v2 with explicit framing: "intelligent voice analysis."

Removed from v1:
- `02_PRODUCT_SPEC.md`: shouting metric, widget icon, `shoutingEvents` from Session schema, "Volume/shouting events" feature
- `03_ARCHITECTURE.md`: `ShoutingDetector` sub-component, RMS path on `AudioPipeline`, `isShouting` on `WidgetViewModel`
- `04_BACKLOG.md`: M3.3 (RMS calculation), M4.5 (ShoutingDetector), M5.6 (Shouting indicator icon)
- v1 effort estimate dropped by ~4h.

### What v2 needs to revisit
A real shouting detector likely needs a multi-signal model. Candidates worth exploring in a future spike:
- **Pitch / fundamental frequency (F0):** shouted speech raises F0 substantially (~20-50%); Lombard compensation raises it slightly (~5-10%). The gradient discriminates.
- **Spectral tilt:** shouted speech has more high-frequency energy (raspier, more "edge"). Measurable via spectral centroid or rolloff.
- **Onset rate-of-change:** shouting is sudden (1-2s ramp); Lombard adaptation is gradual (5-10s ramp). A signal that captures derivative-of-loudness, not absolute loudness.
- **Small ML model:** an on-device classifier trained on labeled shout/non-shout audio. The SpeechAnalyzer audio buffers we're already capturing are a viable input.

A v2 spike should record a much larger and more diverse clip set (noisy office, café, quiet bedroom, post-Lombard adapted speech, emphatic-but-not-shouting examples, laughs, plosives) before committing to any approach.

### Artifacts
- `ShoutingSpike/` — full harness, tests, recordings, results, REPORT.md (note: REPORT.md as committed by the agent overstates the result; this entry is the authoritative verdict)
- Recordings (`quiet_normal.caf`, `quiet_shout.caf`, `noisy_normal.caf`, `noisy_shout.caf`, `transition.caf`) and time-series CSVs are kept for v2 reference

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

## Spike #11 — `MonologueDetector` VAD source validation

**Status:** ⏸ deferred to v1.x (Session 014 — MonologueDetector feature deferred) · **Original priority:** P1 · **Estimate:** 3h · **Added:** Session 013

### Question
Is `SpeakingActivityTracker`'s token-arrival-derived speaking signal a sufficient VAD source for `MonologueDetector`, or do we need to add a parallel frame-level VAD (Silero) running on `AudioPipeline` buffers?

### Why it matters
`MonologueDetector` is a v1 feature (Session 013 product decision). Its state machine is straightforward but its accuracy is bounded by the granularity and timing-fidelity of its `isSpeech` input. `SpeakingActivityTracker` is already wired and free; Silero adds a Core ML model + module + buffer fan-out. We want to use the existing signal if it's adequate, and only add Silero if the existing signal materially under-counts or mis-times monologues.

The 60s/90s/150s thresholds tolerate ~1-2s of timing slop in start-of-monologue detection (<3% error at 60s threshold). The risks are:
1. `SpeakingActivityTracker` reports speaking with a 1.5s `tokenSilenceTimeout`. A 2.5s grace window minus 1.5s timeout = effective 1s grace from the user's perspective — too tight; may fragment monologues that have natural 2s breath pauses.
2. Backchannels ("mm-hmm" while listening) may produce tokens that start a monologue clock that takes 1.5s to clear. Spurious 1.5s "monologues" don't reach the 60s threshold but could thrash the IDLE/SPEAKING state.
3. `SpeechAnalyzer` may suppress short utterances entirely (no token = no speaking signal), in which case backchannels are correctly invisible. We don't know which.

### Method
1. Record 3 conversation clips (~3-5 min each) with the user as one speaker:
   - **Clip A — Q&A:** user answers questions in 30-60s chunks. No long monologues. ~6-10 turn-takings. Goal: validate that turn-yields cleanly transition PAUSED → IDLE.
   - **Clip B — Long answer + backchannels:** user delivers one ~2-min answer with the other speaker injecting "mm-hmm" / "right" backchannels every ~20s. Goal: validate that backchannels do not fragment the user's monologue or spuriously start one.
   - **Clip C — Mixed:** ~5 min of varied conversational rhythm — short answers, one ~90s answer, two ~45s answers, several brief exchanges. Goal: validate detection of the 90s answer as a monologue without false positives elsewhere.
   For each clip, the user manually annotates "ground truth" monologue events with start time + duration via stopwatch (audio review post-hoc is fine).
2. Build a small harness `MonologueSpike/` (mirror `ShoutingSpike/` structure):
   - Read audio file.
   - Run two parallel pipelines: (a) feed audio buffers through a stub `SpeakingActivityTracker` reproducing the production logic (token arrival via `SpeechAnalyzer` for English clips, 1.5s timeout); (b) feed the same buffers through Silero VAD (Core ML, ~1MB).
   - Both pipelines emit `[(speakingStart, speakingEnd)]` interval lists.
   - Run `MonologueDetector`'s state machine over each interval list; emit `[MonologueEvent]` per pipeline.
   - Compare both outputs to the ground-truth annotations.
3. Per clip, compute:
   - **Recall:** fraction of ground-truth monologues correctly detected (start time within ±3s, duration within ±5s).
   - **Precision:** fraction of detected monologues that are real (vs spurious).
   - **Backchannel false positives:** count of "monologue starts" emitted during the other speaker's backchannels in Clip B.

### Pass criteria
- `SpeakingActivityTracker` pipeline alone hits ≥90% recall and ≥90% precision across all three clips.
- Zero backchannel false positives in Clip B (or all such false positives clear before reaching the 60s threshold, so they're invisible to the user).
- Detected monologue start times match ground truth within ±3s; durations within ±5s.

If `SpeakingActivityTracker` passes, M4.5a (Silero parallel path) is dropped from the backlog — production uses `SpeakingActivityTracker` only.

### Fail mode → action
- **Recall too low (< 90%):** the 1.5s `tokenSilenceTimeout` is fragmenting monologues at natural breath pauses. Try increasing the `MonologueDetector` grace window from 2.5s to 3.5s (within `MonologueDetector` itself, not changing `SpeakingActivityTracker`). Re-run. If still failing, M4.5a needs to ship with Silero as the source.
- **Precision too low (false positives):** likely backchannels or environmental noise getting transcribed. Check whether tightening `SpeakingActivityTracker`'s minimum-tokens-to-count-as-speech helps. If `SpeechAnalyzer` is mis-attributing backchannels to the user (single-mic limitation), this is solvable only with mic-side improvements (beamforming) or speaker diarization — both v2 territory; M4.5a Silero would not help. Document and accept the limitation.
- **Silero outperforms substantially:** ship M4.5a with Silero as the production VAD source for `MonologueDetector` only. `SpeakingActivityTracker` continues to feed `WPMCalculator` and `EffectiveSpeakingDuration` (which need different things from a VAD signal).

### Outputs
- Per-clip CSV: ground-truth monologues vs `SpeakingActivityTracker` detections vs Silero detections.
- Decision: `SpeakingActivityTracker` alone, or M4.5a Silero parallel path required.
- If M4.5a is required: documented integration design (where the Silero buffer fan-out attaches in `AudioPipeline`, how the `MonologueDetector` chooses its source).
- Updated `MonologueDetector` parameter values (grace window, smoothing — if any tuning was needed during validation).

### Out of scope
- Actual ML model conversion or training. Silero ships pre-converted; we use it as-is.
- Multi-speaker / diarization. v1 `MonologueDetector` is mic-only; conversation-aware (resetting clock when other party speaks) is v2.
- Power profiling of the Silero parallel path. If we add it (M4.5a), do a mini-spike or fold into M7.8 (final perf pass). At ~1MB and ANE-resident, it's expected to be near-zero overhead.

---

## Spike #12 — Trail-off / vocal-cliff detector validation

**Status:** ⏸ parked for v2 · **Estimate:** 2h · **Added:** Session 013

### Question
Does the "6 dB drop in recent RMS AND SPEAKING→PAUSED transition within 300ms" rule reliably detect deliberate trail-offs without false-positiving on normal sentence ends, across at least 2 voice samples, without per-user tuning?

### Why it matters (v2)
Trail-off detection is a v2 feature (parked in `02_PRODUCT_SPEC.md` non-goals). Captured here so v2 doesn't re-derive the algorithm.

### Algorithm
- Maintain rolling RMS over 200ms windows (recompute every 100ms).
- Maintain 5-min adaptive baseline RMS (silence excluded). Personal calibration; works regardless of mic/room.
- While in `SPEAKING`, compare recent RMS (last 200ms) against prior RMS (avg over the prior 1.5s).
- Fire trail-off event when: (a) recent dropped ≥6 dB below prior, AND (b) `SPEAKING → PAUSED` fires within next 300ms.
- Rate-limit to one event per 10s.

The conjunction in (a) AND (b) is what makes this defensible vs S9: it's not "loud = trail-off." It's "rapid volume drop *that ends in silence*." Mid-sentence dips stay SPEAKING and never fire.

### Method (when v2 begins)
1. Record 5-10 short clips per user, mixed:
   - Half deliberate trail-offs (sentences ending with the user's voice fading out).
   - Half normal sentence ends (stopping cleanly without volume drop).
   - At least 2 voice samples (architect + one other) to validate cross-user generalization.
2. Build `TrailOffSpike/` harness mirroring `ShoutingSpike/`. Reuse `RMSExtractor` from `ShoutingSpike/` if still in repo.
3. Run the algorithm with default thresholds. Compute precision and recall.

### Pass criteria
- Recall ≥80% on deliberate trail-offs.
- Precision ≥95% on normal sentence ends (false positives on normal speech are FM1 violations).
- Same threshold (6 dB) works for both voice samples without per-user tuning. If different users need different thresholds, the feature has the same FM3 problem as S9 → re-evaluate or ship without trail-off in v2 too.

### Fail mode → action
- Threshold doesn't generalize across users: try widening the comparison window (200ms / 1.5s → 300ms / 2.0s) before declaring failure. The trade-off is responsiveness vs stability.
- False positives on emphatic-but-not-trail-off sentence ends: tighten the 300ms post-event check to 200ms (forces silence to come *immediately* after the volume drop).
- Validation requires more than 2 voice samples to be confident: scope the spike up before running.

### Out of scope
- Adding RMS calculation to v2 `AudioPipeline`. That's a v2 architecture decision dependent on this spike outcome.
- v2 widget treatment of the trail-off cue (the 500ms edge flash is the proposed UX; visual design is a v2 product decision).

---

## Spike #5 — Acoustic non-word detection ("hmm", "ahh")
**Status:** ⏸ deferred to v1.x

Not in v1. Run when v1.x scoping begins.

### App Store reviewability of mic auto-detection
**Status:** ⏸ deferred to distribution decision

Only matters if you go App Store. Run a TestFlight submission as the validation when distribution path is chosen.

---

## Spike #13 — External-mic-detection signal (replaces inactivity-timeout as session-end trigger)

**Status:** ❓ Open, blocks M3.7 close. **Opened Session 028 (2026-05-12).**
**Owner:** Architect designs probes; agent executes each probe sequentially; architect audits results after each.
**Budget:** 4–6h total wall-clock across all three probes. Gated: each probe is ~1–2h; stop at the first SUCCESS.
**Prereq:** None. M3.7.2 inactivity-timer code is in place as interim fallback — does not need to be reverted before this spike runs.

### Why this spike exists

The product UX (locked Session 028 Chief of Product call) requires the widget to be visible whenever macOS shows the orange-dot mic indicator and to fade out when the indicator goes off. This means session lifecycle is bounded by **"is anything on this Mac recording the microphone"** — NOT by speech activity in incoming audio.

M3.7.2 shipped an inactivity-timer-based deactivation (30s without tokens → end session) as an interim, but this breaks a critical v1 use case: an hour-long Zoom call where the user speaks for 10–15 minutes when it's their turn. The session would end at 0:30 of listening, miss the actual pitch entirely, or fragment one pitch into 5–10 micro-sessions.

Session 028 empirically established that one specific HAL API path doesn't work for external-mic detection from inside our sandboxed app (`kAudioProcessPropertyIsRunningInput` direct-reads return false for external recording processes; QuickTime never appears in our process-object list). That established a culture of empirical validation, but it did NOT exhaustively prove that external-mic state is undetectable. We jumped to inactivity-timeout without testing three other candidate signals.

This spike tests those three signals, in order from "cleanest if it works" to "biggest rewrite if it works." First success wins.

### Hard requirements (any probe that passes must satisfy ALL of these)

1. **Detects external recording.** When QuickTime (or Zoom, or any external app) starts recording, signal goes to "external active." When that app stops recording, signal goes to "external inactive." Detected within 1s of state change.

2. **Survives our own active capture.** Our `AudioPipeline.start()` is running throughout the session (we need the audio for transcription). The signal must distinguish "external app is recording" from "we are recording." Specifically: signal goes false when ONLY we are recording, true when ANYONE ELSE (with or without us) is recording.

3. **Survives mid-session default-device change (AirPods scenario).** User starts Zoom on built-in mic, mid-call connects AirPods, system default input device changes. Zoom may or may not follow the system default (varies by app). Our signal observation must NOT see this as "external stopped recording" — the user is still in the same call, the session must stay alive. The chosen probe API must either (a) be device-agnostic in semantics, or (b) be re-attachable to the new default device within ~100ms so the observer continuity isn't lost.

4. **Observable from a sandboxed app.** No new entitlements, no TCC dialogs, no Mach-lookup global-name exceptions beyond what TalkCoach already has. If a probe requires new entitlements, that's a fail.

5. **Works with `AVAudioEngine`-based AudioPipeline as currently implemented, OR the rewrite cost is bounded and acceptable.** Probe A: zero AudioPipeline changes. Probe B and C: AudioPipeline rewrite required; budget impact accepted only if Probe A fails.

### Probes

Each probe is a self-contained Swift package in `Spike/Spike13_ExternalMicDetection/<probe-letter>/`. Each builds as a CLI executable that runs for ~60s, logs observations to stdout, and exits. Manual test choreography (start/stop QuickTime, switch AirPods) noted per probe.

#### Probe A — `AVCaptureDevice.isInUseByAnotherApplication` (KVO-observable)

**Hypothesis:** `AVCaptureDevice` exposes a documented, KVO-observable Boolean property that reports whether ANOTHER application is using the device. If this property reflects reality from our sandbox, and if KVO notifications fire reliably across state changes, this is the cleanest possible signal.

**Why first:** zero changes to existing AudioPipeline. Pure additive observer in MicMonitor or a new component. If it works, integration is ~2h.

**Method:**

1. Get the default audio capture device: `AVCaptureDevice.default(for: .audio)`.
2. KVO-observe its `isInUseByAnotherApplication` property.
3. Manually:
    - t=0: probe starts. Log initial value.
    - t=5s: open QuickTime, start New Audio Recording. Log observed KVO callbacks.
    - t=15s: stop QuickTime recording (keep app open). Log.
    - t=20s: start QuickTime recording again. Log.
    - t=30s: connect AirPods (switch default input device). Log. Verify probe observer correctly re-attaches to the new default device (or that the property is somehow device-agnostic).
    - t=45s: stop QuickTime. Log.
    - t=60s: exit.
4. Run probe twice with our `AVAudioEngine.inputNode` actively capturing in a parallel thread (simulating M3.7's wiring). Confirm the property reads false when only we are capturing.

**Pass criteria:**

- Property is observable from sandbox (no permission errors, no crashes).
- Property correctly reflects "external app recording" with our pipeline ALSO active.
- KVO callbacks fire within 1s of state change.
- AirPods mid-switch is handled (either property is device-agnostic, or re-attaching to the new default device picks up the existing call's state correctly within 100ms).
- No false positives from our own activity.

**Fail modes:**

- KVO callbacks never fire even though documented as observable → fail; finding 5 in the project's Apple-framework runtime-trap inventory.
- Property returns nonsense values (always true, always false, returns the OPPOSITE of reality) → fail.
- AirPods switch ends the observation chain and we can't re-attach without losing state → fail unless workaround documented.
- Requires entitlement we don't have → fail.

**Effort budget:** 1h probe + 1h integration if pass. Total Probe A path: 2h.

#### Probe B — Core Audio process tap (`AudioHardwareCreateProcessTap`, macOS 14.2+)

**Hypothesis:** Apple introduced process taps in macOS 14.2 specifically for "monitor another process's audio without becoming a primary reader." If we capture our audio via a tap rather than a direct HAL reader, we don't trip `kAudioDevicePropertyDeviceIsRunningSomewhere`, and M2.1's original listener architecture works as designed.

**Why second:** medium rewrite cost (~4–6h to swap AudioPipeline's underlying mechanism). Tests the cleanest theoretical solution to the composition bug.

**Method:**

1. Create a process tap on our own process: `AudioHardwareCreateProcessTap(...)`.
2. Create an aggregate device with the tap as a sub-device.
3. Run `AVAudioEngine` against the aggregate device instead of the default input.
4. Observe `kAudioDevicePropertyDeviceIsRunningSomewhere` on the ORIGINAL default input device.
5. Manually:
    - t=0: probe starts. Log initial state of `IsRunningSomewhere` (should be false if no external app recording).
    - t=5s: start our aggregate-device-based capture. Log `IsRunningSomewhere` — does it stay false? (Goal: yes.)
    - t=10s: open QuickTime, start recording on default device. Log `IsRunningSomewhere` — should fire true.
    - t=20s: stop QuickTime. Log `IsRunningSomewhere` — should fire false (CRITICAL: this is the signal M3.7's bug killed).
    - t=30s: connect AirPods. Log behavior. Verify our capture continues; verify we re-attach `IsRunningSomewhere` observer to AirPods.
    - t=45s: stop our capture. Log.
    - t=60s: exit.

**Pass criteria:**

- Process tap successfully captures audio (we get buffers).
- `IsRunningSomewhere` stays false while ONLY we are capturing (the load-bearing assumption).
- `IsRunningSomewhere` correctly fires true→false when external apps start/stop, even with our tap-based capture active.
- AirPods mid-switch handled cleanly.

**Fail modes:**

- Process tap unavailable on macOS version (we're 14.2+, should be available — but verify).
- Tap-based capture still trips `IsRunningSomewhere` (apparently Apple counts taps as readers too) → fail; same composition bug returns.
- Audio quality from tap is degraded (sample rate mismatch, format issues, dropped buffers) → fail.
- AirPods switch breaks the aggregate device → fail unless workaround documented.

**Effort budget:** 1h probe + 4–6h AudioPipeline rewrite if pass. Total Probe B path: 5–7h.

#### Probe C — `AVCaptureSession`-based audio capture

**Hypothesis:** `AVCaptureSession` uses a different audio plumbing than `AVAudioEngine.inputNode`. The mechanism is higher-level and may not register as a primary HAL reader, leaving `IsRunningSomewhere` clean.

**Why third:** unknown rewrite cost (probably 4–6h, but `AVCaptureSession` is a different paradigm and may not give us the same buffer-tap surface M3.5's TranscriptionEngine expects). Tested last because Probe A and B are cleaner if they work.

**Method:**

1. Create `AVCaptureSession`, add audio input from default device.
2. Add `AVCaptureAudioDataOutput` with a sample buffer delegate.
3. Start the session, observe buffers arriving in delegate callbacks.
4. Observe `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device.
5. Same manual choreography as Probe B (t=0 start, t=5s our capture, t=10s QuickTime, t=20s QuickTime stop, t=30s AirPods, t=45s our stop, t=60s exit).

**Pass criteria:**

- `AVCaptureSession` captures audio buffers cleanly.
- `IsRunningSomewhere` stays false while only we are capturing.
- `IsRunningSomewhere` correctly fires true→false when externals start/stop.
- AirPods mid-switch handled.
- Buffer format is compatible with M3.5's `AudioBufferProvider` protocol (or convertible without significant added latency).

**Fail modes:**

- `AVCaptureSession` audio output trips `IsRunningSomewhere` same as `AVAudioEngine` → fail.
- Buffer format incompatible with TranscriptionEngine's expected input → fail (or accept 1-2h conversion shim cost).
- AirPods switch behavior different/worse than current → fail.

**Effort budget:** 1h probe + 4–6h AudioPipeline rewrite if pass + possibly 1–2h format conversion shim. Total Probe C path: 6–9h.

### Decision tree after probe runs

- **Probe A passes:** integrate `AVCaptureDevice.isInUseByAnotherApplication` observer as the deactivation signal. M3.7.2 inactivity-timer stays in code as defense-in-depth fallback (cancel-on-true-signal-deactivation; fire if no signal ever arrives). 2h integration → M3.7 closes with correct UX.

- **Probe A fails, Probe B passes:** rewrite AudioPipeline to use process-tap-via-aggregate-device. Restore original M2.1 listener semantics. M3.7.2 inactivity-timer kept as defense-in-depth. 5–7h work → M3.7 closes with correct UX.

- **Probe A and B fail, Probe C passes:** rewrite AudioPipeline to use AVCaptureSession. Same integration shape as Probe B but with different underlying mechanism. 6–9h work → M3.7 closes with correct UX.

- **All three probes fail:** the deactivation signal is genuinely unavailable from a sandboxed macOS app. Accept inactivity-timeout as v1 mechanism, document UX limitation explicitly in product spec, ship v1 with the known constraint. Re-investigate in v1.x with a fifth probe direction (e.g., private TCC framework signals, distributed notifications from Sound preferences, etc.) or accept the limitation permanently. M3.7 closes with documented-limitation tag rather than full-correct tag.

### Procedural notes

- **Each probe runs as a STANDALONE Swift package**, not as test code or production code. Compiled with `swift build`, run from terminal. Stdout logs are the evidence. This matches Spike #4's pattern (`MicTapTightenSpike/Sources/MicTapTightenSpike/AudioTapBridge.swift`).
- **Probes run sequentially with architect audit between each.** Don't pre-run Probe B while A is still being evaluated. Each probe's outcome may change the spec for the next.
- **Sub-agent review of probe results is mandatory.** Probes report observational evidence; sub-agent confirms the evidence supports the pass/fail conclusion before architect locks the decision.
- **AirPods test requires physical hardware.** Probe runs that can't reach the AirPods switch step report partial-pass with explicit gap noted. Architect decides whether to proceed to next probe or hold for hardware availability.
- **AVAudioEngine concurrent capture in Probe A** can be simulated by running M3.7's actual app in parallel terminal (open Xcode, Cmd+R, separately run the probe binary in terminal). This isn't ideal isolation but it's the cheapest way to test "external HAL reader present" without writing extra harness code.

### What this spike does NOT do

- Does not implement the chosen signal in production. That's a separate ~2–7h follow-up depending on which probe passes.
- Does not investigate `kAudioHardwarePropertyProcessIsAudible` or other obscure HAL properties beyond the three named probes. If all three fail, future investigation is open-ended and v1 ships with the inactivity-timer documented limitation.
- Does not address the rare case of external apps that record audio without triggering the system mic indicator (e.g., audio interception via virtual audio devices like BlackHole). That's a separate v1.x consideration.

### Outputs

- `Spike/Spike13_ExternalMicDetection/probe-a/main.swift` (Probe A code)
- `Spike/Spike13_ExternalMicDetection/probe-b/main.swift` (Probe B code, only if needed)
- `Spike/Spike13_ExternalMicDetection/probe-c/main.swift` (Probe C code, only if needed)
- Stdout logs from each probe, captured to `/tmp/spike13-probe-{a,b,c}.txt`
- One architect-level decision artifact in this spec under "Outcome" section (TBD after probes run)

### Outcome

**Spike #13 — CLOSED Session 030, 2026-05-13. All three formal probes (A, B, C) plus Probe D cascade FAILED. Architect pivots to disconnect-probe-reconnect algorithm; Spike #13.5 measures the algorithm parameter.**

The full sequence of probes across Sessions 029 + 030, every one of which produced locked Apple-framework runtime-discovery findings:

**Probe A — FAILED (Session 029, 2026-05-13).**

Executed as standalone Swift package at `Spike/Spike13_ExternalMicDetection/probe-a/` on branches `spike/13-probe-a` (KVO-only, commit `279152f`) and `spike/13-probe-a-prime` (KVO + 1Hz polling alongside, commit `4ada2c7`). Six manual choreography runs total across the two binaries.

- **Run-1** (Voice Memos recording twice on built-in mic, no AirPods, Locto not running): 0 KVO state-change callbacks, 0 polled-read transitions across 62 reads spanning all four record/stop events.
- **Run-2** (Locto launched in parallel, no Voice Memos, no AirPods): 0 KVO state-change callbacks, 0 polled-read transitions. NOTE: this run did NOT empirically test HR2 (signal goes false when only we are recording) — Locto-on-launch does NOT arm the mic. Run-2 was effectively a second idle baseline. Moot in the failure case because the property is inert in all conditions.
- **Run-3** (AirPods device switch + Voice Memos recording on AirPods): 0 KVO state-change callbacks, 0 polled-read transitions. Default-device-change listener (`kAudioHardwarePropertyDefaultInputDevice`) DID fire correctly both switches with sub-100ms latency, and KVO observer re-attached cleanly to the new device — these mechanisms are sound and reusable in any future probe.

The polling extension (Probe A-prime) disambiguated the two interpretations of Probe A's failure: it is NOT "KVO infrastructure is inert for this property while the property is live"; it is **"the property itself does not update at runtime from a sandboxed app context."** 186 polled reads across the three Probe A-prime runs combined, none transitioning off `false`, on both built-in mic AND AirPods, regardless of who was actively recording.

**Fifth Apple-framework runtime-discovery finding locked (tighter wording than this spec's fail-mode prediction at line 824):** `AVCaptureDevice.isInUseByAnotherApplication` is inert at runtime from a sandboxed app context — the underlying property does not reflect "another application is using this device," not merely that KVO event delivery is broken. The whole `AVCaptureDevice` surface for external-mic detection is closed for TalkCoach v1 and will not be re-investigated absent a major OS-level behavior change.

**Probe B — FAILED (Session 030, 2026-05-13).**

Aggregate device wrapping the physical mic as a sub-device, AVAudioEngine reading the aggregate's input stream. Standalone Swift package at `Spike/Spike13_ExternalMicDetection/probe-b/` on branch `spike/13-probe-b` (commit `f52a7cc`) and additive-only extension on `spike/13-probe-b-prime`. Agent's Phase 1 plan correctly flagged that `CATapDescription` is for process OUTPUT audio only and the original spec's process-tap-on-our-own-process approach would deliver silence; pivoted to aggregate-device-only architecture as the feasible interpretation.

Probe B alone: `AVAudioEngine.start()` on an aggregate device fires `AVAudioEngineConfigurationChange` immediately at startup, and Probe B's `configChangeObserver` logged the DROP but had no restart logic, so the tap never entered steady state (`Tap total buffers: 0` in summary). The hypothesis was unanswered because no buffers ever flowed.

Probe B-prime (additive-only startup-restart observer): registered a NEW one-shot observer AFTER the existing `configChangeObserver` (FIFO delivery: existing logs DROP, new fires restart), self-deregisters after first fire, executes `stop → removeTap → installTap → start`. Boot smoke produced clean steady-state evidence: `RESTART[1] outcome=success` at t=2.18s, `TAP[1] FIRST_BUFFER` at t=2.29s, 628 buffers over 62.71s at 10 buf/s. **Critical diagnostic: at t=2.19s, exactly 0.01s after restart success, `IRS[2] LISTENER t=2.19 old=false new=true`. IRS stayed true through the remaining 62 seconds of steady-state capture. Zero subsequent listener events, zero polled transitions across 62 reads.**

**Sixth Apple-framework runtime-discovery finding locked:** aggregate device wrapping a physical input as a sub-device, with AVAudioEngine reading the aggregate's input stream, trips `kAudioDevicePropertyDeviceIsRunningSomewhere` on the physical sub-device exactly as if AVAudioEngine read the physical device directly. The aggregate abstraction is NOT HAL-invisible from IsRunningSomewhere's accounting view.

**Probe C — FAILED (Session 030, 2026-05-13).**

AVCaptureSession via CMIO (CoreMedia I/O) framework. Standalone Swift package at `Spike/Spike13_ExternalMicDetection/probe-c/` on branch `spike/13-probe-c` (commit `52ba826`) and additive-only extension on `spike/13-probe-c-prime` (two commits `4908310` and `33498b2`). Agent's Phase 1.1 finding: AVCaptureSession on macOS uses CMIO as its capture abstraction, but CMIO ultimately calls into CoreAudio HAL; whether CMIO→HAL registers as a primary HAL reader is empirically unknown without runtime measurement.

Probe C alone: `Cap total buffers: 0` across two runs, blocked by TCC and then by a second issue. NO-SKIPPING triggered — no verdict locked on incomplete data.

Probe C-prime first commit (`4908310`) added `IRS_BEFORE_START` pre-session baseline, `TCC_AUTH status=authorized` confirmation logging, and two new summary lines. First post-amendment run still showed zero buffers despite TCC=authorized. Agent diagnosed root cause: `AVCaptureAudioDataOutput.sampleBufferDelegate` is declared `weak` in Apple's API. The local-let `BufferDelegate` inside `configureSession` was ARC-deallocated as soon as the function returned, so the session was delivering buffers to a nil weak delegate. Probe C-prime second commit on the same branch (`33498b2`) added two more `+` lines: file-scope `var captureDelegate: BufferDelegate?` and `captureDelegate = delegate` inside `configureSession`. **Post-fix boot smoke produced the clean diagnostic pair:** `IRS_BEFORE_START value=false` at t=1.24s, `SESSION STARTED` at t=2.65s, `IRS_AFTER_START value=true` at t=2.66s, `CAP[1] FIRST_BUFFER` at t=2.69s, 5627 buffers over 62.76s at 89.7 buf/s. **`startRunning()` caused the IRS transition false→true; active capture sustained IRS=true for the full 60 seconds with zero subsequent listener events and zero polled transitions.**

**Seventh Apple-framework runtime-discovery finding locked:** AVCaptureSession via CMIO trips IRS on the physical mic during active capture. No abstraction layer change (AUHAL vs CMIO) bypasses the underlying HAL accounting.

**Probe D — FAILED / INCONCLUSIVE-DISQUALIFIED (Session 030, 2026-05-13).**

Cascading multi-candidate probe at `Spike/Spike13_ExternalMicDetection/probe-d/` on branch `spike/13-probe-d`. Three sequential cascade phases in one binary:

- **Candidate 1 — ScreenCaptureKit.** Agent's Phase 1.1 corrected the original prompt: `capturesAudio = true` with output type `.audio` is a SYSTEM AUDIO OUTPUT tap (captures what plays through speakers, doesn't touch input mic). The load-bearing test is macOS 15's `SCStreamConfiguration.captureMicrophone = true` + `microphoneCaptureDeviceID` + output type `.microphone`. Sub-test A (system-output tap, control) and Sub-test B (mic-tap, hypothesis test) implemented.
  - Sub-test B IRS verdict: **INCONCLUSIVE / DISQUALIFIED.** First run TCC-blocked with verbatim macOS dialog text "The user declined TCCs for application, window, display capture" — Terminal did not have Screen Recording TCC granted. The 5-second completion-deadline mechanism (architect-prescribed) prevented the probe from hanging on the dialog. Second run had two STOP-triggering structural problems: HAL-reference-capture (Candidate 2's apparatus) was running concurrently with SCK sub-tests, so SCK IRS readings were CONFOUNDED — IRS=true could come from HAL-ref alone; and the synchronous Bash tool prevented architect participation in CHOREO_PROMPT real-time actions. NO-SKIPPING applied; no verdict locked.
  - **Eighth Apple-framework runtime-discovery finding locked:** `SCStreamConfiguration.captureMicrophone = true` on macOS 15+ requires Screen Recording TCC even when capturing ONLY microphone audio with no display content captured. This is an architectural disqualifier for SCK mic-tap as TalkCoach v1's external-detection mechanism independent of IRS behavior — Screen Recording is a permission users associate with surveillance, not microphone capture, and the UX cost exceeds the UX benefit for v1 even if Sub-test B were to pass IRS.
- **Candidate 2 — HAL property scan.** Six candidate selectors (`IsRunningSomewhere`, `IsRunning` (without Somewhere), `HogMode`, `ControlList`, `ClockDomain`, `ProcessorOverload`) plus two extras (`Latency`, `SafetyOffset`) read at three observation points (NO_CAPTURE, OUR_CAPTURE, EXTERNAL_CAPTURE) via the comparison table. **Inconclusive in the executed run — architect was unable to act on CHOREO_PROMPT due to Bash-tool sync invocation, so all three observation points collapsed to identical readings. The probe-design issue blocks the comparison table's value.** Not re-run because the architectural pivot (algorithm path) made the search unnecessary.
- **Candidate 3 — CMIO Extensions.** Agent's Phase 1.3 finding: `CMIOExtension*` API is provider-side only. `connectClient:` / `disconnectClient:` are callbacks for the PROVIDER receiving connections; no "monitor", "observe", or "subscribe" symbols exist client-side. Legacy `CMIOHardware.h` is a DAL-level C API for device control with no monitoring surface. **Ninth Apple-framework runtime-discovery finding locked:** `CMIOExtension*` provides no client-side observation API; the framework is intended for implementing virtual camera/device providers, not for client-side monitoring of other providers' streams.

**Architectural pivot at Probe D STOP:** instead of fixing Probe D's cascade ordering and re-running, architect surfaced to product owner that every standard Apple capture API trips IRS, SCK's mic-tap is disqualified by Screen Recording permission cost regardless of empirical IRS outcome, and CMIO Extensions provides no client-side observation API. Anton (product owner) proposed the **disconnect-probe-reconnect algorithm**: when inactivity timer fires, save session to SwiftData, tear down AudioPipeline, wait briefly for HAL state to settle, read IRS in our absence (now an unambiguous "anyone else?" question), then either finalize the session or rebuild AudioPipeline and resume capture. Algorithm sidesteps every locked Spike #13 finding by changing the problem framing. No new APIs, no new permissions, no new framework dependencies, all composing primitives shipped in M2.1 / M2.7 / M3.7.2. Only empirical unknown was the HAL stop-settling time — measured by Spike #13.5.

### Summary of locked findings (six total)

The six Apple-framework runtime-discovery findings established across Sessions 029 + 030 for the external-mic-detection problem domain:

1. (Session 026/027, finding #4 in project sequence) `kAudioProcessPropertyIsRunningInput` listeners silently never fire from sandbox; direct reads asymmetric across the process boundary; HAL filters external processes from our `kAudioHardwarePropertyProcessObjectList` enumeration view.
2. (Session 029, finding #5) `AVCaptureDevice.isInUseByAnotherApplication` property is inert at runtime from sandbox — the property value itself does not update when external apps record on the device, not merely that KVO event delivery is broken.
3. (Session 030, finding #6) Aggregate device wrapping the physical mic as a sub-device, with AVAudioEngine reading the aggregate's input stream, trips IRS on the physical sub-device exactly as if AVAudioEngine read the device directly. The aggregate abstraction is NOT HAL-invisible from IsRunningSomewhere's accounting view.
4. (Session 030, finding #7) AVCaptureSession on macOS uses CMIO (CoreMedia I/O) framework as its capture abstraction, and the CMIO→HAL path trips IRS on the physical mic during active capture. No abstraction layer change (AUHAL vs CMIO) bypasses the HAL accounting.
5. (Session 030, finding #8) `SCStreamConfiguration.captureMicrophone = true` on macOS 15+ requires Screen Recording TCC even when capturing ONLY microphone audio with no display content. Architectural disqualifier for SCK as v1 mechanism regardless of empirical IRS behavior.
6. (Session 030, finding #9) `CMIOExtension*` provides no client-side observation surface. The framework is intended for implementing virtual camera/device providers; client-side monitoring of other providers' streams is not supported by the API.

### Architectural conclusion

**No standard Apple API distinguishes "our capture" from "external capture" at the HAL level when our capture is active.** Every capture path that registers as a HAL reader trips `kAudioDevicePropertyDeviceIsRunningSomewhere` on the underlying physical device. The HAL does not expose per-client visibility at the read-accessible property level. Six probes' worth of empirical evidence support this conclusion across three different framework surfaces (AVAudioEngine direct, AVAudioEngine via aggregate, AVCaptureSession via CMIO) plus a fourth surface disqualified by entitlement cost (ScreenCaptureKit mic-tap).

The disconnect-probe-reconnect algorithm bypasses the distinguishability problem by removing Locto from the set of HAL readers during the probe step. The IRS property read in our absence is unambiguous: "anyone else?" — and if no one else, we finalize cleanly; if someone else, we rebuild AudioPipeline and resume capture into the same session record.

### Re-usable patterns proven across the spike's probes

- The default-device-change listener (`kAudioHardwarePropertyDefaultInputDevice` on `kAudioObjectSystemObject`) DOES fire correctly within ~100ms of switch. AirPods scenario mechanism is solid; M3.7.3 reuses this pattern for HR3 (AirPods) coverage.
- The 1Hz `Timer.scheduledTimer` polling pattern on top-level `RunLoop.main` is drift-free across 60s windows.
- The additive-only probe-extension pattern (new branch off prior probe's tagged commit; every diff hunk is `+` lines between unchanged context lines; sub-agent code review verifies via `grep '^-' | grep -v '^---' | wc -l` returns 0) operated across four uses in one session at scale.
- The weak-property gotcha defense: any Apple framework delegate property declared `weak` (`AVCaptureAudioDataOutput.sampleBufferDelegate`, `SCStream.delegate`, etc.) MUST have its delegate retained by a file-scope strong reference. Probe C-prime's fix is the canonical example.
- The hypothesis-direction-explicit pattern: every probe prompt involving a viability/falsification decision states the direction in the prompt body, the Phase 3 self-review marker block, AND the Sub-agent 2 brief.
- The NO-SKIPPING rule (Session 030 lock): if data is incomplete or ambiguous, STOP and report rather than locking a verdict on bad data. Six probes in this spike applied the rule across four substantive STOP-and-report cycles.

### Decision tree status

- **Probe A:** ❌ Failed Session 029
- **Probe B:** ❌ Failed Session 030
- **Probe C:** ❌ Failed Session 030
- **Probe D (cascade):** ❌ Failed Session 030 (Candidate 1 disqualified by TCC, Candidate 2 inconclusive due to Bash-tool sync limitation, Candidate 3 API_MISMATCH_DEAD)
- **Decision tree line 906 ("Accept inactivity-timeout as v1 mechanism, document UX limitation"):** SUPERSEDED by the NO-SKIPPING rule and the disconnect-probe-reconnect algorithm. Spike #13 closes with a working architectural path, not a documented limitation.

**Spike status: CLOSED.** M3.7.3 implements the disconnect-probe-reconnect algorithm in Session 031. M3.7.2 inactivity threshold migrates to user settings as part of M3.7.3.

---

## Spike #13.5 — HAL stop-settling time measurement (Session 030, single-session)

**Goal:** measure the time delta between `AudioPipeline.stop()` returning and `kAudioDevicePropertyDeviceIsRunningSomewhere` transitioning to false on the physical mic. This delta is the M3.7.3 algorithm's "wait-after-teardown-before-IRS-read" parameter.

**Why this matters:** the disconnect-probe-reconnect algorithm tears down Locto's capture, waits for HAL state to settle, then reads IRS in our absence. If the settling time is ~10ms, the wait is imperceptible. If the settling time is ~2 seconds, the algorithm has a user-perceptible audio gap cost during every probe cycle and the algorithm parameters need to be tuned accordingly. Probe B-prime had given us start-side settling (~0.01s); the stop side was unmeasured.

**Method:** standalone Swift package at `Spike/Spike13_5_HALStopSettling/probe/` on branch `spike/13.5-hal-stop-settling`. Single-mechanism measurement probe — not a hypothesis pass/fail probe. Ten capture-then-stop cycles with plain `AVAudioEngine` against the default input (matching M3.7 production AudioPipeline mechanism exactly).

Each cycle:
1. Build AVAudioEngine, install input-node tap with empty closure, prepare.
2. `engine.start()`. Wait 2 seconds (HAL state firmly establishes IRS=true).
3. Capture `cycleStopRequestedAt = DispatchTime.now().uptimeNanoseconds`.
4. `engine.inputNode.removeTap(onBus: 0)`. `engine.stop()`.
5. Capture `cycleStopReturnedAt = DispatchTime.now().uptimeNanoseconds`.
6. Wait up to 1s for IRS listener (on dedicated background queue, NOT main) to fire `true → false`.
7. In parallel: 50ms backup polling timer reads IRS property directly as belt-and-suspenders measurement.
8. Compute settling deltas in nanoseconds. Rest 1s. Next cycle.

The dedicated background queue for the IRS listener is load-bearing — `DispatchTime.now().uptimeNanoseconds` is captured as the very FIRST line in the listener callback before any dispatch to main, eliminating main-queue-drain latency from the measurement.

**Outcome (Session 030):**

All 10 cycles settled via listener within the 1-second wait window. Zero missed settles. Zero NO-SKIPPING trigger. Zero IRS carry-over between cycles (1-second rest is sufficient). Zero unexpected `AVAudioEngineConfigurationChange` notifications during cycles. All 10 backup-poll entries showed "—" (listener fired and cancelled the backup timer before any 50ms poll tick caught the transition), confirming listener latency is consistently sub-50ms across the run.

**Distribution (ns from `engine.stop()` return to listener fire):**

- cycle 1: ~41 ms
- cycle 2: ~38 ms (min)
- cycles 3–10: 39–45 ms
- **Min: 38.331 ms**
- **Max: 44.854 ms**
- **Mean: 41.451 ms**
- **P95 (= max for n=10): 44.854 ms**

Distribution is tight and deterministic — 6.5 ms spread across 10 cycles, no outliers, no bimodal split.

**Production parameter locked: ~100ms wait after `AudioPipeline.stop()` returns before reading IRS.** Derivation: measured max 45ms + safety margin for cross-hardware variance, system load, AirPods vs built-in mic, and possible OS-version variation = round up to 100ms. The total disconnect-probe-reconnect cycle cost is estimated at 500–800ms (stop + wait 100ms + IRS read + AudioPipeline.start() + engine warmup), at the edge of user-perceivable but acceptable for an event that fires at most once per inactivity-threshold window.

**Outputs:**

- `Spike/Spike13_5_HALStopSettling/probe/Sources/probe/main.swift` (probe code)
- `/tmp/spike13.5-bootsmoke.txt` (boot smoke output with AGGREGATE block)
- This spec section as the locked measurement artifact for M3.7.3

**Status:** CLOSED. Measurement landed. M3.7.3 uses the parameter.

---

## Spike status summary (Session 030)

All architecture-blocking spikes from earlier project phases are resolved. Seven spikes completed (S2, S4, S6, S7, S8, S9, S10), one superseded (S3). Two spikes deferred with their features: S1 (blocklist → v2), S11 (MonologueDetector → v1.x). S12 remains parked for v2 (trail-off detector). S5 deferred to v1.x.

**Spike #13 (external-mic-detection signal) — CLOSED Session 030.** All four formal probe paths (A, B, C, D) FAILED across nine total executions including additive-only extensions. Six locked Apple-framework runtime-discovery findings establish that no standard Apple API distinguishes our capture from external capture at the HAL level when our capture is active. Architect pivoted to disconnect-probe-reconnect algorithm proposed by product owner; algorithm sidesteps the distinguishability problem by temporarily removing Locto from the set of HAL readers during the probe step. **Spike #13.5 (HAL stop-settling time measurement)** measured the algorithm parameter empirically: max 45 ms with tight distribution, production parameter 100ms with safety margin. M3.7.3 implements the algorithm Session 031.

Phase 1 module work is fully unblocked. Phase 3 token pipeline is functional pending M3.7.3 implementation.
