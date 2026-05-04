# Project Journal — Speech Coach

> Append-only log of every working session. Never edit past entries destructively. New entries go at the **top**.

---

## Session 012 — 2026-05-04 — Spike #7 closed CONDITIONAL PASS, Apple SpeechAnalyzer Power Baseline Validated

**Format:** Claude Code agent execution (Spike #7 Phases A–C), sub-agent reviewed.

### What happened
Ran Spike #7 (Apple SpeechAnalyzer power baseline) end-to-end. Built a `PowerSpike/` harness (SPM package, reusing frozen copies of `WPMCalculator`, `SpeakingActivityTracker`, `EMASmoother` from WPMSpike) that runs `AVAudioEngine` + `SpeechAnalyzer` on live mic input, measures CPU%, RSS, and thermal state every 10 seconds, and writes CSV.

**Phase A (harness + smoke test):** Built PowerSpikeCLI with CLI flags (`--isolated-duration`, `--total-duration`, `--sample-interval`, `--output`). Key technical challenge: bridging live mic audio to `SpeechAnalyzer`, which requires `AsyncStream<AnalyzerInput>` with format conversion (48kHz→16kHz via `bestAvailableAudioFormat`). Created BufferRelay pattern for thread-safe buffer handoff. 60s smoke test confirmed harness works: CPU 2.75% on one sample, RSS stable at 23.8 MB.

**Phase B (full 60-minute run):** User ran the harness: 15 min isolated (quiet room, no speech) + 45 min loaded (Zoom solo meeting + iPhone playing conversational podcast next to Mac mic). Podcast drove 45.4 words/sec (including volatile result revisions) — approximately 18× heavier than real-meeting production load.

**Phase C (analysis + report):** Analyzed CSV (360 data rows) and powermetrics output (395 samples). Key finding: SpeechAnalyzer's processing is extremely bursty — 79% of 10s samples read 0.00% CPU, with spikes up to 126.58% (multi-core). The P95 metric from the original spike spec is unsuitable for this workload pattern. Mean CPU (4.18% loaded) is under the 5% FM4 threshold; production estimate is ~2%.

Sub-agent review caught four issues in REPORT.md: off-by-one sample count (90 not 89), silent headroom formula change (mean vs P95 — now explicitly documented with justification), RSS slope ambiguity (loaded-phase vs full-run — both now reported), and a minor word count delta (122,116 not 122,115). All fixed.

### Key findings
- Apple `SpeechAnalyzer` runs entirely on E-Cluster (efficiency cores) — P-Cluster at 0% active residency
- Mean CPU 4.18% under 18× overload; estimated ~2% in production
- RSS 38 MB peak, growing at 16.2 MB/hr (loaded) — projects to 54 MB at 3 hours
- Energy impact ~150 mW marginal — "Low" classification
- Zero AVAudioEngine config changes across 60 minutes including Zoom join/leave
- Thermal state nominal throughout

### Technical findings for production
- `SpeechAnalyzer` requires `AsyncStream<AnalyzerInput>`, not direct AVAudioEngine integration. Must query `bestAvailableAudioFormat(compatibleWith:considering:)` and convert via `AVAudioConverter` if source format differs.
- BufferRelay pattern (deep-copy in tap, drain from separate Task) is the correct architecture for feeding live audio to `SpeechAnalyzer`
- `AnalyzerInput(buffer:)` wraps `AVAudioPCMBuffer` for the async stream
- `analyzer.prepareToAnalyze(in:)` + `analyzer.start(inputSequence:)` for autonomous analysis

### What changed in the docs
- `05_SPIKES.md` — Spike #7 marked ✅ conditional pass with validated outcomes section
- `03_ARCHITECTURE.md` — Open questions table: S7 marked closed, S8 marked closed; Parakeet compute unit note updated (no contention with Apple path); summary paragraph updated
- `04_BACKLOG.md` — S7 marked ✅ conditional pass (4h actual), Phase 0 remaining reduced to ~5h
- `01_PROJECT_JOURNAL.md` — this entry

### Ups
- Mean CPU is comfortably under FM4's 5% threshold even under 18× overload. Production headroom is ~3%.
- Harness worked on first live run after the format-conversion fix. The `bestAvailableAudioFormat` + `AVAudioConverter` pattern is clean and reusable for production `AppleTranscriberBackend`.
- Zero config changes — confirms Spike #4's finding that native Zoom does not trigger `AVAudioEngineConfigurationChange`.
- Sub-agent review caught real issues (headroom formula, sample count) that improved report accuracy.
- 4h actual = 4h estimated. On budget.

### Downs
- Initial attempt crashed (SIGTRAP) because `SpeechAnalyzer` silently requires 16kHz input, not the mic's native 48kHz. No compile-time warning. Fixed by discovering `bestAvailableAudioFormat` via Apple docs.
- The bursty CPU pattern means the original headroom formula (5.0 - P95) is meaningless for this workload. The spike spec's "sustained <5%" criterion was poorly matched to SpeechAnalyzer's batch-processing model. Had to redefine headroom in terms of mean rather than P95, with explicit justification.
- RSS growth at 16.2 MB/hr (loaded) needs monitoring — not a leak concern yet, but could become one in very long sessions (6+ hours).

### Next session
- Phase 1 (Foundation) can begin — no remaining P0/P1 spikes gate it
- Remaining P2 spikes: S9 (adaptive RMS noise-floor), S1 (identifying activating app)
- PowerSpike code in `PowerSpike/` — throwaway harness, not production code

---

## Session 011 — 2026-05-03 — Spike #8 closed PASS, Token-Arrival Robustness Validated

**Format:** Claude Code agent execution (Spike #8 Phases A–C), sub-agent reviewed.

### What happened
Ran Spike #8 end-to-end. Built `TokenStabilitySpike/` harness (SPM package, reusing frozen copies of `WPMCalculator`, `SpeakingActivityTracker`, `EMASmoother` from WPMSpike) to test whether `SpeechAnalyzer` token timestamps are stable across mics (MacBook built-in vs AirPods Pro 2) and environments (quiet room vs café ambience).

**Phase A (harness):** Created CLI that processes one `.caf` file with locked production constants (window=6, alpha=0.3, tokenSilenceTimeout=1.5), outputs one CSV row. Validated by processing WPMSpike's `en_normal.caf` — bit-for-bit match with Spike #6 result at identical parameters.

**Phase B (recordings + evaluation):** User recorded 4 clips of a fresh 96-word English script in 4 conditions. Same noise source (YouTube café ambience) for both noisy clips, recorded back-to-back. All 4 processed successfully with zero failures.

**Phase C (analysis):** Three direct token-stability measures all pass:
- Word count: identical (99) across all 4 conditions
- Speaking duration: CV 2.93% (threshold <10%)
- Inter-onset interval: 355–384ms (CV 2.9%); silence gaps 4–6ms avg — tokens effectively contiguous

WPM raw CV (7.84%) exceeds the 5% threshold, but root cause analysis shows this is not token-arrival instability — it's speaker pace variance (3.35% CV from natural re-reading variation) plus an EMA warmup artifact in one clip (`airpods_quiet`: 3.0s pre-speech delay → EMA accumulates zeros). Pace-normalized CV excluding the outlier: 1.99%.

### Key finding
Approach D (token-arrival-based speaking duration) is fully validated. `SpeechAnalyzer`'s ML-based VAD produces stable token timestamps regardless of input device or ambient noise. No need for Approach C (`SoundAnalysis` VAD) as secondary signal.

### Production note
`WPMCalculator` should begin sampling after the first token arrives, not from t=0. The `airpods_quiet` outlier demonstrated that pre-speech silence causes an EMA warmup artifact that depresses the sliding-window average. Production code handles this naturally — widget shows "Listening..." until first token, then starts WPM computation.

### Ups
- Perfect word count stability (all 99, 0% spread) — strongest possible evidence that `SpeechAnalyzer` recognition is environment-agnostic
- Harness validated with bit-for-bit S6 match before running any new clips
- 3h actual = 3h estimated. Clean execution.

### Downs
- `airpods_quiet` WPM outlier initially looked alarming (9.2% error) before root cause analysis traced it to pre-speech delay, not a mic problem
- Natural speaker pace variance (~3.35%) conflates with mic/environment effects when using raw WPM CV. Need pace normalization to separate the two.

### Next session
- S7 (Power & CPU profiling) is next P1 spike. Phase 0 remaining: ~9h.
- Phase 1 (Foundation) can begin any time — no remaining spikes gate it.

---

## Session 010 — 2026-05-03 — Spike #2 closed PASS, Language Auto-Detect Validated as Script-Aware Hybrid

**Format:** Claude Code agent execution (Spike #2 Phases A–D), fully verified, sub-agent reviewed.

### What happened
Ran Spike #2 end-to-end across two conversation sessions. Built a `LangDetectSpike/` harness (SPM package, CLI with `preflight`, `evaluate-b`, `evaluate-c`, `analyze-wordcount` subcommands) to test two detection approaches across three representative language pairs (EN+RU, EN+JA, EN+ES) using 16 real audio clips (4 per language, sourced from YouTube by user).

**Phase A (preflight):** Validated test corpus, confirmed Apple `SpeechTranscriber` locale support (en, ja, es — not ru), confirmed `NLLanguageRecognizer` sanity, checked Parakeet model cache.

**Phase B (Option B — transcribe-then-detect):** 48 evaluations total. Two signals emerged:
- `NLLanguageRecognizer` on transcribed text: 100% for same-script pairs (EN+ES), 0% for cross-script wrong-guess transcripts (EN+RU). The wrong-locale transcriber produces garbled text that the text classifier cannot parse.
- Word-count on wrong-guess transcript: 100% for EN+RU (threshold 13 words), 62.5% for EN+ES. Cross-script transcription produces dramatically fewer words; same-script does not.
- Character-count tested post-hoc: identical accuracy to word-count, no additional value.
- Russian evaluations initially blocked by Apple `SpeechTranscriber` not supporting `ru_RU`. Resolved by routing Russian through Parakeet (FluidAudio) — the same backend Architecture Y uses in production.

**Phase C (Option C — Whisper-tiny audio LID):** 48 evaluations. Used WhisperKit's `openai_whisper-tiny` Core ML model (75.5 MB).
- EN+JA: **100% at both 3s and 5s windows** — the load-bearing gate (≥90% required).
- EN+RU: 100% at both windows (informational — already covered by word-count).
- EN+ES: 75% at 3s, 100% at 5s. Two Spanish clips misclassified as Portuguese and Arabic at 3s. Detection was unconstrained across 99 languages — no pair restriction applied. Informational only — EN+ES handled by NLLanguageRecognizer.

**Phase D (this entry):** Wrote canonical REPORT.md, investigated compute units (ANE confirmed by default configuration), analyzed the unconstrained detection finding, updated four docs.

### The empirically-confirmed Risk A prediction
The spike's Risk A from the original plan was: "What if Option B's NLLanguageRecognizer fails on cross-script pairs because the wrong-locale transcript is garbled?" This is exactly what happened — and it's exactly why the spike ran both options. The word-count signal catches what NLLanguageRecognizer misses (cross-script), and NLLanguageRecognizer catches what word-count misses (same-script). Neither alone is sufficient. The hybrid is stronger than either.

### The surprise EN+ES finding
NLLanguageRecognizer achieved 100% accuracy on EN+ES — a pair many text classifiers struggle with due to shared vocabulary. This was not expected at this confidence level. It means the production path for same-script pairs (the most common user scenario) needs zero additional models and zero detection latency beyond the ~5s transcription window.

### Compute unit finding
WhisperKit's `ModelComputeOptions` defaults to `.cpuAndNeuralEngine` for audio encoder and text decoder on macOS 14+ (our target is macOS 26). This matches Parakeet's compute unit configuration. Apple does not expose a runtime API to verify actual hardware dispatch, but the Core ML configuration explicitly requests ANE. Spike #7's power profiling should use Instruments to measure actual hardware utilization.

### Unconstrained detection finding
WhisperKit's `detectLangauge` method runs argmax over all 99 language tokens — no pair-based filtering. The API only returns the single argmax token, discarding the full probability distribution. Pair-constrained detection would require modifying WhisperKit's `LanguageLogitsFilter` (~20 lines). For production M3.4, this is a straightforward enhancement. Not retested because the unconstrained failure only affects same-script pairs (EN+ES), which are handled by NLLanguageRecognizer, not Whisper.

### Script-aware hybrid recommendation (locked)
```
User declares 2 languages at onboarding
  → dominantScript(locale1) vs dominantScript(locale2)
    → same script?        → Strategy 1: NLLanguageRecognizer (0 MB, ~5s background)
    → one is CJK?         → Strategy 3: Whisper-tiny LID (75.5 MB, ~3s blocking)
    → otherwise (Cyrillic) → Strategy 2: Word-count threshold (0 MB, ~5s background)
```

### What changed in the docs
- `05_SPIKES.md` — Spike #2 marked ✅ passed with validated outcomes above original spec
- `03_ARCHITECTURE.md` — `LanguageDetector` section rewritten: placeholder "Spike #2 will pick" replaced with concrete three-strategy design, strategy selection logic, per-user cost table, Whisper-tiny model details, architecture interaction notes
- `04_BACKLOG.md` — S2 marked ✅ passed (6h actual), Phase 0 remaining reduced to ~12h, M3.4 description updated to reflect three-strategy router (estimate confirmed at 4–6h)
- `01_PROJECT_JOURNAL.md` — this entry

### Where we left off
- Phase 0 has 4 open spikes: S8 (token-arrival robustness, next P1), S7 (power profiling), S9 (shouting detection), S1 (activating app ID)
- Spike #2 code in `LangDetectSpike/` — throwaway harness, not production code
- Working tree has uncommitted LangDetectSpike additions (WhisperKit dependency, evaluate-c implementation, REPORT.md, run_option_c.sh). Ready for commit.
- Spike #7 note: should now include Whisper-tiny's ~600ms inference in its power budget for CJK-language users (adds to the language-detection phase, not to sustained transcription)

### Ups
- Both options (B and C) exceeded their accuracy gates. EN+JA at 100% on both windows was decisive — no ambiguity about whether the Whisper-tiny model is adequate.
- The hybrid recommendation emerged naturally from the data — each signal has a complementary strength. This is a cleaner architecture than either option alone would have been.
- Parakeet integration for Russian evaluations (Phase B blocker) was resolved quickly by reusing the FluidAudio API pattern from the ParakeetSpike.
- NLLanguageRecognizer's 100% on EN+ES was a positive surprise — eliminates model cost for the most common pair type.
- 6h actual vs 5h estimated. Slight overrun due to the Parakeet routing addition and WhisperKit model search, both of which were not in the original scope but were necessary.

### Downs
- The original spike plan assumed Apple `SpeechTranscriber` supports Russian. It doesn't — same finding as Session 006 / Spike #10, but re-encountered here. We needed Parakeet as a transcription backend for the Russian evaluations, adding ~1h of unplanned integration work. This was already known from the architecture but wasn't reflected in the spike's method section.
- WhisperKit has a typo in its public API: `detectLangauge` (swapped a/u). This will need to be tracked if the API is ever fixed in a future WhisperKit version.
- The EN+ES 3s misclassifications (Spanish→Portuguese, Spanish→Arabic) could not be retested with pair restriction because WhisperKit's API doesn't support it. The finding is documented but the fix is deferred to production implementation.

### Next session
- S8 (token-arrival robustness across mics/environments) is next P1
- After S8, S7 (power profiling) can run — it now has all the compute-unit information from S2 and S10
- Commit LangDetectSpike harness code
- Once all Phase 0 spikes close, write Phase 0 summary and begin Phase 1

---

## Session 009 — 2026-05-02 — Language model simplified to N≤2 declared at onboarding; Spike #2 rescoped

**Format:** Architecture decision triggered by user observation about real-user multilingual frequency.

### What happened
While prepping the Spike #2 prompt, the user (Anton) raised an onboarding question that reframed the entire language-detection design: *"I'm thinking about an onboarding question: which languages do you speak and want to improve. Allow to select 3 max, expecting most of the users select 1 and some 2. Hardly believe multilingual audience for this app."*

That observation flips Spike #2's premise. The original design assumed runtime auto-detection across the v1 supported languages with no user input — a 3-way classifier (EN/RU/ES) at minimum, potentially harder if v1 added languages later. The user's read of the audience says: most users will declare 1 language, some will declare 2, almost none will declare 3+.

After working through implications, the user simplified further: **v1 supports max 2 declared languages, picked at first-launch onboarding from the union of Apple's 27 + Parakeet's 25 supported locales (~50 distinct languages).**

### Decision: declared-languages model (locked Session 009)

**At onboarding (M1.7, new module):**
- Single screen, one question: "Which 1–2 languages do you speak in meetings?"
- Combined alphabetized list of ~50 locales (Apple ∪ Parakeet supported sets). Backend choice (Apple vs Parakeet) is invisible to the user — app decides routing internally.
- System locale pre-checked as default. User must affirmatively pick at least one. Max 2 selectable.
- Editable from Settings later.
- Sets `declaredLocales: [Locale]` (1 or 2 entries) and `hasCompletedOnboarding: Bool` in `Settings`/`UserDefaults`.

**At runtime (`LanguageDetector` module, simplified):**
- N=1: no detection. Return `declaredLocales[0]` immediately. Most users — most sessions — never run any auto-detect machinery.
- N=2: binary classifier between exactly the two declared locales. Never has to consider any other language in the world. Spike #2 picks the mechanism (Option B vs C).
- The "two transcribers in parallel" approach (Option A) remains disqualified by FM4.

### Why this is materially cleaner
- A 2-way classifier is meaningfully more accurate than a 3-way or N-way one. Smaller candidate set, fewer wrong calls.
- Backend routing is fully precomputed at onboarding. A user who picks only English never downloads Parakeet, never sees a Russian-related anything. The 1.2 GB Parakeet download becomes opt-in.
- "Unsupported language at runtime" disappears as a concept — onboarding gates it. If the user can't pick a language, they can't speak it to the app.
- Language-specific assets (filler dictionary, WPM target, locale model) are seeded only for declared languages.
- Spike #2 simplifies — fewer pairs to test, smaller harness, narrower acceptance criteria.

### Why this works within FM3 (no setup)
The product spec previously locked "no dedicated onboarding screen, ≤2 first-launch user actions." This decision technically adds an onboarding screen but the user-action count stays at 2: (1) language picker (one screen, one question), (2) mic permission grant (system dialog at first session start). The product spec's FM3 wording is updated to "Minimal setup" instead of "No setup" — that's a more accurate framing of where v1 actually lands.

### Scope impact

**Added:**
- New module **M1.7** in Phase 1: onboarding language picker (3h)
- New `Settings` keys: `declaredLocales: [Locale]`, `hasCompletedOnboarding: Bool`. Filler dict keys move to `fillerDict[<localeIdentifier>]` instead of fixed `fillerDictEN/RU/ES`.

**Reduced:**
- **M3.4** `LanguageDetector` estimate: 6–10h → 4–6h. Binary classifier is materially smaller than the N-way version, and N=1 case is a no-op.

**Revised:**
- **Spike #2** rewritten in `05_SPIKES.md` to test the binary classifier across three representative language pairs: EN+RU, EN+JA, EN+ES. Test corpus sourced from YouTube (public monologue/news clips, ~10s each, 4 per language). Pass criteria tightened: ≥90% on EN+RU and EN+JA, ≥85% on EN+ES (the more similar pair). Estimate revised 6h → 5h.
- **`02_PRODUCT_SPEC.md`** Languages and Language Handling sections rewritten to reflect onboarding picker and ~50 locale union. Filler dictionary scope generalized.
- **`03_ARCHITECTURE.md`** `LanguageDetector` section rewritten: explicit N=1 trivial path + N=2 binary classifier behavior. Settings keys updated. Open questions table reflects narrower Spike #2 scope.
- **`04_BACKLOG.md`** Phase 1 totals 11h → 14h (+M1.7). Phase 3 totals 40–48h → 38–44h (M3.4 reduced). Project total roughly net zero.

### Where we left off
- All four affected docs (02, 03, 04, 05) updated and ready for replacement in repo
- No agent prompt for Spike #2 has been generated yet — that's the immediate next session task
- No production code committed this session beyond previous commits
- Session 008's Spike #4 commit (`a31231d`) and prior commits remain the head of main; this session adds doc updates only

### Ups
- User caught an over-engineering instinct in my Spike #2 framing. I had been designing for "auto-detect any language anywhere," which was the wrong product premise for an audience that's mostly monolingual or bilingual.
- The simpler model genuinely is simpler at every layer: spec, architecture, spike, module, runtime cost. Rare to find a simplification that wins on all axes.
- Confirmed via the conversation that the architecture's `TranscriptionEngine` routing layer (locked Session 006) survives this change unmodified — it just gets fewer locales to route in practice. Good signal that the underlying abstraction is sound.

### Downs
- This is the second time in the project's planning that an "obvious" requirement (here: real-time auto-detection) turned out to be over-scoped relative to actual audience behavior. The first was Session 001's hotkey-vs-auto-detect oscillation. Lesson: when designing a feature for a hypothetical user, double-check the hypothesis against the *actual* user (Anton) before locking it in.
- Slight re-scope cost on `02_PRODUCT_SPEC.md` and `03_ARCHITECTURE.md`. Not a huge edit, but it's the third "small" architecture-doc rewrite this week. Each one is justified, but each one also hurts confidence in the locked-ness of "locked" decisions.

### Lesson for future planning
**Before a spike defines its test corpus, the architect must verify the spike's runtime scope matches the real product scope, not an inflated worst-case scope.** Spike #2 was originally scoped for "auto-detect any of v1's 3 languages, plus future flexibility" — but the runtime never needed to do that, because the user pre-declares which languages matter. The corpus was sized for a problem the product doesn't actually solve. Add to `00_COLLABORATION_INSTRUCTIONS.md` next session: when reviewing a spike's plan, explicitly ask "what does the runtime *actually* see in production, not in theory."

### Next session
- Generate revised Spike #2 prompt for Claude Code with the N=2 binary-classifier scope
- User sources YouTube clips for the EN+RU, EN+JA, EN+ES test corpus
- Agent runs Spike #2 phases A through D, reports outcome
- After Spike #2 closes, S8 (token-arrival robustness) is the next P1

---

## Session 008 — 2026-05-02 — Spike #4 closed PASS WITH CAVEATS, Mic Coexistence Validated

**Format:** Claude Code agent execution (Spike #4 all scenarios), user-assisted real-device testing.

### What happened
Built a throwaway `MicCoexistSpike/` CLI harness that runs `AVAudioEngine` with `isVoiceProcessingEnabled = false`, installs an input tap, and logs per-second buffer counts. Ran 10 scenarios across Zoom, Google Meet (Chrome + Safari), and FaceTime using an iPhone self-loop (iPhone joined same call, mic muted, speaker on).

Headline: native conferencing apps (Zoom, FaceTime) coexist perfectly in all patterns. Browser-based conferencing (Chrome Meet, Safari Meet) works when already active, but triggers `AVAudioEngineConfigurationChange` when joining after our engine — stopping the engine. This is recoverable by restarting the engine, a well-documented Apple pattern.

### Validated numbers (final)
- **VPIO:** `false` at every checkpoint in all 10 scenarios. macOS never overrode it.
- **Native app coexistence (Zoom, FaceTime):** 0 gaps, 0 config changes in C/D/E/G patterns. Mean ~47,900 fps on 48kHz input.
- **Browser coexistence (Chrome Meet, Safari Meet):**
  - App-first pattern (C): 0 gaps, 0 config changes. Perfect.
  - Harness-first pattern (D): 1 config change → engine stopped → 30+ gaps. Recoverable.
- **Safari channel count change:** Safari Meet changes input from 1→3 channels. Using `format: nil` handles this transparently.
- **Conferencing audio quality:** User confirmed zero degradation in all 10 scenarios.

### What changed in the docs
- `05_SPIKES.md` — Spike #4 marked ⚠️ passed with caveats. Validated outcomes section added above original spec.
- `01_PROJECT_JOURNAL.md` — this entry.

### Swift 6 strict concurrency findings
The harness exposed two Swift 6 runtime issues relevant to production `AudioPipeline`:

1. **`@main struct` / `main.swift` top-level closures inherit `@MainActor` isolation.** The audio tap callback runs on CoreAudio's `RealtimeMessenger.mServiceQueue`. When the closure is defined in a main-actor context, Swift 6's runtime checks crash with `EXC_BREAKPOINT` / `_dispatch_assert_queue_fail`. Fix: define tap closures in a separate source file outside the main-actor context.

2. **`AVAudioEngine` / `AVAudioInputNode` are non-Sendable.** When captured in closures from `main.swift` (main-actor-isolated scope), they need `nonisolated(unsafe)` annotation.

These are directly relevant to how `AudioPipeline` structures its tap installation and should be documented in the architecture.

### Production requirements surfaced
`AudioPipeline` must:
1. Observe `AVAudioEngineConfigurationChange` and restart engine + reinstall tap on receipt.
2. Use `format: nil` for tap installation (never hardcode channel count or sample rate).
3. Set `isVoiceProcessingEnabled = false` before any tap installation.
4. Ensure audio tap closures do not inherit `@MainActor` isolation.

### Where we left off
- Phase 0 has 4 open spikes: S2 (language auto-detect), S8 (token robustness), S7 (power profiling), S9 (shouting detection), S1 (activating app ID).
- Spike #4's config-change recovery is not a blocker — it's a routine `AudioPipeline` implementation detail for M2.1.
- Working tree has uncommitted `MicCoexistSpike/` harness code. Ready for commit.

### Ups
- All native conferencing apps (the primary use case — Zoom calls) coexist with zero issues. The VPIO=false strategy is validated.
- Browser Meet failures are recoverable, not fatal. The config-change pattern is standard Apple audio handling.
- User confirmed audio quality was unaffected in every single scenario. Our engine is invisible to conferencing apps.
- Swift 6 concurrency findings caught now save debugging time during production AudioPipeline implementation.
- 3h actual vs 3h estimated. On budget.

### Downs
- Spent ~45 minutes debugging a Swift 6 runtime crash (`EXC_BREAKPOINT` in `_dispatch_assert_queue_fail`) before identifying that `@main struct` closures inherit main-actor isolation. The crash report was the key — the compiler gave no warning. This is a subtle Swift 6 gotcha that would have hit production code too.
- Browser Meet coexistence requires engine restart logic. Not hard, but it's additional code in `AudioPipeline` that wouldn't exist if all apps used CoreAudio directly.

### Next session
- Commit MicCoexistSpike harness
- Proceed to next P0 spike (S7 power profiling, or S2/S8 depending on priority review)
- Update `03_ARCHITECTURE.md` with config-change recovery requirement and Swift 6 isolation note
- Update `04_BACKLOG.md` with actual hours

---

## Session 007 — 2026-05-02 — Spike #10 closed PASS, Architecture Y validated

**Format:** Claude Code agent execution (Spike #10 Phases A–F + clean-vs-noisy A/B addendum), fully verified, sub-agent reviewed.

### What happened
Spike #10 ran end-to-end across the day. The agent acquired FluidInference's pre-converted `parakeet-tdt-0.6b-v3` Core ML model via FluidAudio Swift SDK (saved ~20h of custom Core ML inference work). Built a small `ParakeetSpike/` harness (sibling to `WPMSpike/`), validated all six pass criteria from the original spec on the three Russian clips from Spike #6, then executed an additional clean-vs-noisy A/B with two new clips the user recorded.

Headline: every gate passed comfortably except one marginal — `ru_fast` Russian WER at 26.8% vs 25% gate. Investigation in the addendum confirmed café noise is **not** the cause; the 26.8% is a fast-pace Parakeet limitation. Clean-vs-noisy A/B at ~110 WPM showed identical 9.4% WER in both conditions.

### Validated numbers (final)
- **Real-time factor:** 0.011 mean, 0.032 worst → ~90× real-time. Budget gate was 0.5.
- **Peak working memory:** 133 MB. Budget gate was 800 MB. Architecture's earlier estimate was conservative by 6×.
- **Cold-start (3 tiers):** ~53s first-ever model download (one-time, M3.6 toast); ~16s recompile after cache eviction; 0.4s warm subsequent runs.
- **Russian WER:** 9.4% clean speech / 9.4% café-noisy speech at ~110 WPM; 11.6% on `ru_normal` (156 WPM); 10.8% on `ru_slow` (102 WPM); 26.8% on `ru_fast` (205 WPM, marginal).
- **Filler recognition:** 70% / 90% across the two A/B clips (sample-size-noise dominates the spread; both above 70% gate).
- **Word-level timestamps:** confirmed. `ASRResult.tokenTimings` provides per-token `startTime`/`endTime` after BPE subword merging via `TokenMerger`.
- **WPM accuracy:** 1.6% / 0.7% error vs ground truth on the two A/B clips. Spike #6 gate was <8%.
- **Sustained-run stability:** 185 iterations, RSS flat, no leaks.

### What changed in the docs
- `03_ARCHITECTURE.md` — `ParakeetTranscriberBackend` section rewritten with validated numbers replacing the conservative pre-spike estimates. Phrase-level fallback caveat removed (word-level confirmed). Open-questions table marks Spike #10 closed.
- `05_SPIKES.md` — Spike #10 marked ✅ passed with full validated outcomes and open follow-ups (none blocking). Spike #6 marked ✅ passed with locked production constants. Original spike specifications preserved below the validated outcomes for archaeology.
- `04_BACKLOG.md` — Phase 0 table reordered. Closed spikes (S6, S10) noted with actual hours. Remaining work: S4 next P0 (3h), then S2/S8/S7/S9/S1. Phase 0 remaining ~21h (down from 35–39h).
- `01_PROJECT_JOURNAL.md` — this entry.

### The clean-vs-noisy A/B (Session 007 addendum)
User recorded two ~165s Russian clips back-to-back, identical 298-word script:
- `ru_clean.caf` — quiet home environment
- `ru_noisy.caf` — café environment (matches the original Spike #6 recording conditions)

Pace was slow-normal at ~110 WPM in both. Agent ran them through Phase C of the spike harness and produced a delta table.

Result: WER identical at 9.4%. WPM error 1.6% / 0.7%. RTF essentially identical. Filler-rate gap (70% / 90%) is sample-size noise — 10 instances per clip, missing one filler shifts the rate by 10 points.

The big takeaway: the fast-Russian quality cliff at 26.8% WER is a *pace* issue, not an environment issue. Café noise is fine. Russian-in-meetings should work for normal-paced speakers regardless of where they're working.

### Caveat documented in REPORT.md addendum
The clean-vs-noisy A/B was at ~110 WPM only. Russian-at-fast-pace under noise is untested. If real users report degraded fast Russian in noisy conditions during early v1 use, re-test with a fast-pace café clip. Logged as a v1.x follow-up, not a v1 blocker.

### Architecture corrections from validated numbers
The architecture doc's original estimates were:
- Cold-start <30s — actual is two numbers: 53s first-ever, 16s recompile. The 30s gate was wrong; M3.6's "Preparing Russian model…" toast must handle ~1 minute on first download.
- <800 MB memory — actual is 133 MB. Budget gate stays at 800 MB (defense-in-depth) but the realistic number is ~6× under.
- 600 MB INT8 / 1.2 GB FP16 — INT8 was rejected. FP16 chosen because INT8 forces CPU-only Core ML execution, losing ANE offload, which is more expensive overall despite the smaller file. Architecture doc updated.

### Where we left off
- Phase 0 still has 5 open spikes: S4 (Zoom mic coexistence) is next P0, then S2 / S8 / S7 / S9 / S1.
- User explicitly chose Path A: complete all Phase 0 spikes before any Phase 1 production code, on the basis that the design (UI/UX) work can run in parallel and Phase 1 implementation deserves a clean session start with no spike risk hanging over it.
- No production code committed this session beyond the spike harness in `ParakeetSpike/`.
- Working tree clean except for `WPMSpike/recordings/m4a/` (user's source Voice Memos exports). Adding to `.gitignore` next session — minor cleanup, not blocking.

### Ups
- Pre-converted Core ML model existed publicly. Saved a major chunk of work that I would have estimated 20+ agent hours.
- Word-level timestamps confirmed. The Session 004 `SpeakingActivityTracker` design is preserved without compromise. No fallback logic to write, no degraded-Russian-WPM path to maintain.
- Clean-vs-noisy A/B was the user's idea, and it's the most useful experiment we've run. It surfaced that the "noise problem" we thought we had was actually a "fast-pace problem." Different mitigation entirely.
- Agent flagged the filler-rate delta as sample-size noise without me prompting. Right call.
- 10h actual vs 8–12h estimate. Estimate was correct.

### Downs
- The original Spike #10 acceptance criterion of "<30s cold-start" was wrong. Should have been "<30s for warm/recompile cold-start; first-ever download is a one-time UX consideration covered by M3.6 toast." When I write spike pass criteria with hard numbers, I need to think about whether the number applies to all instances of the metric or only specific ones.
- We learned that fast-pace Russian (~205 WPM) has noticeably worse WER than normal-pace. The product implication: a user who genuinely speaks Russian at 205 WPM will get a degraded experience compared to a 110 WPM speaker. That's a real product consideration but not a spike failure — Russian filler counting and WPM math both still work.
- I asked about Phase 0 vs Phase 1 twice before getting an answer. Could have been one sharper ask.

### Lesson for future spikes
Whenever a spike measures a "cold-start" or any latency that has a one-time vs steady-state distinction, the acceptance criterion must be split into both. Otherwise the spike's pass/fail blurs together two different user experiences (first-ever vs every-day) that have different mitigations.

### Next session
- Generate Spike #4 prompt (Zoom mic coexistence) for Claude Code
- After Spike #4 closes, S2 / S8 / S7 / S9 / S1 in priority order
- Once all Phase 0 spikes close, write a Phase 0 summary entry covering all validated decisions, lock-in numbers, and the Phase 1 starting state. That's the entry the new session reads to begin Phase 1 implementation cleanly.

---

## Session 006 — 2026-05-02 — Architecture Pivot Y: Apple + Parakeet, Russian via Core ML

**Format:** Architecture decision triggered by Spike #6 incidentally discovering Russian is not on macOS 26.4.1's `SpeechTranscriber.supportedLocales`.

### What happened
Began the session running Spike #6 (WPM ground truth). English: 3 clips processed cleanly across all (window, alpha) combinations. Russian: failed with `SFSpeechErrorDomain Code=1 "transcription.ru asset unavailable"`.

After ruling out network, VPN, signing, disk space, the agent's diagnostic discovered the actual cause: `SpeechTranscriber.supportedLocales` on macOS 26.4.1 contains 27 locales, none of them Russian. `AssetInventory.status` returns `.unsupported` for `ru_RU`. The `supportedLocale(equivalentTo: Locale("ru"))` API misleadingly returns `ru_RU` even though it's not in the supported set — the locale is "reservation-only" with no model deliverable.

### Root cause vs assumption
Session 001 chose `SpeechAnalyzer` over legacy `SFSpeechRecognizer` because the user had real-world Russian failures on iOS with the legacy framework. We assumed `SpeechAnalyzer` had Russian. It does not on macOS 26.4.1. We have less Russian coverage than we started with.

This is exactly the failure that Phase 0 spikes are meant to catch — but Spike #3 was scheduled too late (after #6, #7, #4, #2). It should have been Phase 0 step 1 alongside checking `SpeechTranscriber.supportedLocales` for the explicit set of v1 languages. Lesson: when the architecture depends on a specific platform locale being supported, verify the *list* of supported locales before any other spike.

### Decision: Architecture Y
Apple `SpeechAnalyzer` for the 27 locales it actually supports (English, Spanish, French, German, etc.), NVIDIA Parakeet via Core ML for Russian. The user has prior production experience running Parakeet in real time on iOS in a translation app — strong signal it's feasible.

Considered and rejected:
- **Path A — drop Russian from v1:** user is bilingual EN/RU; Russian meetings are weekly; would gut the product's value for them
- **Path X — Parakeet for everything:** wastes Apple's free, OS-integrated path for English; bloats the install with a 600 MB model that adds nothing for English-only users; FM4 (no performance impact) likely violated for English sessions
- **Path C — wait for Apple to add Russian:** indefinite, blocks v1

### Scope impact

**Added:**
- New **Spike #10** — Parakeet feasibility on macOS 26 / Apple Silicon (8–12h). Validates: working Core ML port exists, real-time factor <0.5, Russian WER acceptable, **word-level timestamps** (load-bearing assumption for `SpeakingActivityTracker` from Session 004), cold-start <30s.
- New **`ParakeetTranscriberBackend`** module (M3.5b, 8–12h).
- New routing layer **`TranscriptionEngine`** (replaces `SpeechEngine`; M3.5, 4h).
- Network entitlement flips to `network.client = true` — required for Parakeet model download from CDN. Documented network policy in architecture doc: download only, no telemetry, no transcripts, audio never leaves the device.

**Revised:**
- **Spike #7** scope expanded — now validates Architecture Y power envelope specifically. Two-phase: Apple path baseline (Phase A), Parakeet path under load (Phase B), backend-switching cost (Phase C). Estimate 4h → 6h.
- **Spike #3** marked superseded by Spike #10 in `05_SPIKES.md` rather than left pending. Phantom tasks in the backlog cause confusion later.
- **`02_PRODUCT_SPEC.md`** Languages section rewritten: explicit Apple-vs-Parakeet split per locale; Russian first-use download is ~600 MB one-time with toast (vs ~150 MB for Apple locales).
- **`03_ARCHITECTURE.md`** `SpeechEngine` renamed `TranscriptionEngine` with two backends (`AppleTranscriberBackend`, `ParakeetTranscriberBackend`) and a routing layer. Network entitlement changed. Threading model adds Parakeet inference Task. Data-flow diagram updated to show routing.
- **`04_BACKLOG.md`** Phase 0 totals: 29h → 35–39h. Phase 3 totals: 28–32h → 40–48h. Project total: 169–173h → 192–204h.

### Critical assumption to validate (Spike #10 Phase D)
Session 004's `SpeakingActivityTracker` requires word-level timestamps. If Parakeet's Core ML port emits only phrase-level timestamps (one range per ~5-word phrase), the WPM math degrades for Russian — speaking-duration intersections become coarse, `tokenSilenceTimeout` gap-bridging is meaningless. Spike #10 explicitly tests this with intra-phrase pauses and quotes the result. Fallback plan: proportional estimation within phrases (N words over T seconds → each word `T/N` duration centered in the phrase). Documented in `TranscriptionEngine` caveats.

### Where we left off
- Session 005 closed Spike #6 English: ✅ provisional production constants — window=6, alpha=0.3, tokenSilenceTimeout=1.5 — pending Russian re-validation
- Russian WPM data not yet collected — blocked on Spike #10
- Recommended next session: generate Spike #10 prompt, agent investigates Parakeet Core ML, reports back. After Spike #10 passes, re-run WPM harness with Russian routed through Parakeet to close Spike #6 RU leg.

### Ups
- User caught the platform-locale gap before Phase 1 started — i.e., before any production code was committed. Cost so far: a few hours of misdirected harness runs. Cost if discovered after M3.5 was implemented: a major refactor.
- User had real-world prior experience with Parakeet (mobile, translation app). Anchored the architectural decision instead of speculation.
- Architecture Y is cleaner than alternatives despite adding a backend. The interface (`TranscriptionEngine` emits unified `(token, startTime, endTime, isFinal)` tuples regardless of backend) keeps downstream code unchanged. `SpeakingActivityTracker`, `WPMCalculator`, `FillerDetector` etc. don't care which backend produced the tokens.

### Downs
- Phase 0 spikes were not ordered to surface platform availability first. Spike #3 should have been "verify Apple supports each v1 locale" as a P0 prerequisite instead of "verify quality" as a P0 followup. Lesson: the *availability* check is upstream of the *quality* check; sequence matters.
- The Session 001 framework decision (`SpeechAnalyzer` over `SFSpeechRecognizer`) was made on the strength of "verified to support `ru_RU`" — that verification was based on `supportedLocale(equivalentTo:)` returning a non-nil value, which we now know is misleading. We need a hard rule: when validating platform availability, check the explicit list (`supportedLocales`), never the lookup helper (`supportedLocale(equivalentTo:)`).
- ~22–31h added to v1 effort. Real cost. The product is much stronger for it (Russian works), but the calendar slips by 2–3 weeks at 20h/week pace.
- Network entitlement flipping from `false` to `true` is real — every privacy-conscious user reading the app's entitlements will notice. Mitigation: tight network policy, documented; UI never presents network-related options; consider adding a "network used only for first-run model downloads" disclosure in settings.

### Lesson for the prompt template (carryover from Session 004)
Session 004 added: "Before generating an agent prompt for any module that depends on a sensor, signal source, or environmental input, the architect must explicitly answer: 'How does this work when the user changes [environment / device / context]?'"

Session 006 adds: **Before locking any architectural decision that depends on a platform capability (a specific framework, locale, codec, API), the architect must verify the capability is actually present on the target OS version, by checking the explicit enumeration (e.g., `supportedLocales`, `availableEncoders`, etc.) — not the convenience lookup that may misleadingly succeed.** Add to `00_COLLABORATION_INSTRUCTIONS.md` next session.

### Files updated this session
- `02_PRODUCT_SPEC.md` — Languages at launch section rewritten for Architecture Y
- `03_ARCHITECTURE.md` — `SpeechEngine` → `TranscriptionEngine` with two backends; entitlements; threading; data-flow diagram; open questions table
- `04_BACKLOG.md` — Phase 0 spike list, Phase 3 module table, summary totals, recommended order
- `05_SPIKES.md` — Spike #3 marked superseded; Spike #7 revised for Architecture Y; Spike #10 added
- `01_PROJECT_JOURNAL.md` — this entry

### Next session
- Generate Spike #10 (Parakeet feasibility) prompt for Claude Code
- Agent runs Phase 1 inventory (does a Core ML port exist? how do we get one?), then implementation, then validation
- After Spike #10 closes ✅ or ❌, replan from there

---

## Session 005 — 2026-05-02 — Spike #6 harness rewritten to Approach D

**Format:** Claude Code agent execution, fully verified.

### What was done
Rewrote WPMSpike Swift Package to match the Session 004 architecture pivot. Energy-based VAD removed entirely; speaking duration now derived from `SpeechAnalyzer` token-arrival timestamps via a new `SpeakingActivityTracker` type.

### Commits
- `b88a274` — refactor: remove energy VAD and calibration step
- `ebb85cd` — test: add SpeakingActivityTracker tests (red phase)
- `8bf9c27` — test: adapt WPMCalculator tests to token-derived speaking duration
- `d025c45` — implementation (all green)

### Files removed
- `Sources/WPMSpikeCLI/SimpleEnergyVAD.swift`
- `Sources/WPMSpikeCLI/NoiseFloorMeasurer.swift`
- `VADEvent` struct from `Models.swift`
- `--measure-noise-floor` and `--vad-threshold` CLI flags
- "Step 0 — Calibrate VAD threshold" section of `recordings/README.md`
- `<vad-threshold>` argument from `recordings/process_all.sh`
- `updateSessionAccumulators()`, `totalWords` accumulator, and stored `totalSpeakingDuration` from `WPMCalculator` (single source of truth now lives in the tracker)

### Files added
- `Sources/WPMCalculatorLib/SpeakingActivityTracker.swift` — `speakingDuration(in:)` via clip-then-merge with `tokenSilenceTimeout` gap-bridging; `isCurrentlySpeaking(asOf:)` via `[startTime, endTime + tokenSilenceTimeout]` containment check
- `Tests/WPMCalculatorTests/SpeakingActivityTrackerTests.swift` — 6 tests covering empty tokens, full containment, partial containment with clipping, gap-bridging at different timeouts, and `isCurrentlySpeaking` recent/old cases
- `TimeRange` struct in `Models.swift`

### CLI / CSV changes
- New flag: `--token-silence-timeout <seconds>` (default 1.5)
- New CSV columns: `token_silence_timeout_s` (column 9, between alpha and recognized columns), `total_speaking_duration_s` (column 14, appended at end)
- `process_all.sh` now takes no positional arguments; `TOKEN_SILENCE_TIMEOUT` env var optional

### Test count
14 total: 5 `WPMCalculatorTests` + 3 `EMASmoothingTests` + 6 `SpeakingActivityTrackerTests`. All green on `d025c45`.

### Test 1 expected value derivation
The Risk 1 mitigation from the planning round: instead of widening tolerance, recomputed `evenlySpacedWords_yieldsExpectedWPM`'s expected WPM under token-derived speaking duration. 60 words over 30s, 0.5s spacing, 0.4s token duration (0.1s gaps, all bridged < 1.5s timeout). Window 8s at t=25 → tokens 34–49 in window (16 words), speaking duration 17.0 → 24.9 = 7.9s. Raw WPM = 16/7.9 × 60 = 121.5. Tolerance kept at ±1%.

### Sub-agent verdict
Read `03_ARCHITECTURE.md` `SpeakingActivityTracker` section + the implementation file fresh. Reported no discrepancies. Specifically validated: clip-then-merge order (prevents cross-window gap-bridging), `isCurrentlySpeaking` semantics (timestamp inside `[startTime, endTime + timeout]`), edge cases (empty tokens, window before/after all tokens, single-token clip), Sendable conformance, default timeout value.

### Where we left off
- Spike #6 harness ready for real recordings
- No audio recorded yet — that's the next step
- After recording: run harness, sweep `(window, alpha, tokenSilenceTimeout)`, tabulate error %, lock production constants
- Spike #6 still in 🔬 in-progress status (harness done, validation against ground truth not started)

### Ups
- Agent executed cleanly. No mid-flight scope creep. Reported deviations honestly (none in this case).
- The "test count by suite" plan-time inventory caught a miscount in the prompt's acceptance criterion — the criterion said "8 original tests" but the actual count is 5 + 3. The agent reported the truth instead of fudging to match the prompt. Good signal.
- Sub-agent review caught nothing because the implementation matched the spec, not because the sub-agent was lazy — its report named specific properties it verified.
- TDD discipline held: failing tests committed before implementation; implementation didn't touch test files.

### Downs
- The acceptance criterion said "all original 8 tests" when the actual count was 5 + 3. Lesson for future prompts: when the prompt's acceptance criterion contains a count, sample size, or other hard number, require Phase 1 inventory to verify the number before approval. The Spike #6 redo prompt did this for "current test count" — and the agent caught it. Make this a permanent rule.

### Next session
- User records 6 audio clips per revised Spike #6 method
- User runs harness, generates CSV outputs across the parameter sweep
- Claude analyzes CSV, decides whether pass criteria are met, locks production constants

---

## Session 004 — 2026-05-02 — Architecture Pivot: Token-Arrival Speaking Duration (Approach D + A)

**Format:** Architecture decision triggered by user concern during Spike #6 recording prep.

### Trigger
User raised the question while preparing to record the `silence.caf` calibration clip for Spike #6: *"I'm afraid the mic will re-adjust sensitivity if there is no voice input and it will capture background noise. It's important to mention that I can be on different environments and use different headphones. how the app will adapt to that?"*

This exposed a real architecture gap, not a recording-day problem. The original design used energy-based VAD with a fixed dBFS threshold — broken for two reasons the user correctly identified:

1. **Mic AGC during silence:** macOS Core Audio + most consumer mics apply automatic gain control. When no voice input, the mic *increases* sensitivity, recording an *amplified* noise floor that doesn't match the floor during actual speech. A `silence.caf` calibration would tell us threshold = -30 dBFS, but during real speech the floor is -50 dBFS. VAD using -30 would classify quiet speech as silence, breaking WPM math.
2. **Multi-environment / multi-mic usage:** user works in coffee shops, home, hotels, with built-in mic, AirPods, USB headsets. A one-time calibration is wrong for every environment after the first. Violates FM3 (no setup).

### Decision
Combined **Approach D + Approach A**:

- **Approach D — derive speaking duration from `SpeechAnalyzer` token-arrival timestamps.** No audio energy involved. `SpeechAnalyzer` already does ML-based speech/non-speech classification internally; piggyback on it instead of reinventing energy VAD. New module: `SpeakingActivityTracker`.
- **Approach A — adaptive noise-floor for the only remaining audio-energy feature: `ShoutingDetector`.** Maintain a rolling 5s buffer of RMS samples; current noise floor = 10th percentile; shouting threshold = floor + 25 dB. Recomputed every 100ms. Works in any environment without calibration.

### Why this is better
- Removes the entire energy-VAD module. One less thing to build, debug, and tune.
- Removes the calibration step from Spike #6 and from production setup. FM3 satisfied.
- WPM math now uses Apple's robust ML-based speech detection instead of a hand-rolled energy threshold.
- ShoutingDetector becomes environment-adaptive in ~30 lines of additional code.
- Enables a clean Spike #8 to validate cross-environment robustness.

### What changed in docs

#### `03_ARCHITECTURE.md`
- `AudioPipeline` no longer fans out to a VAD module. Just buffers (to SpeechEngine) + RMS samples (to ShoutingDetector).
- New `SpeakingActivityTracker` sub-component in `Analyzer`: consumes token stream, provides `speakingDuration(in:)` and `isCurrentlySpeaking(asOf:)`.
- `ShoutingDetector` rewritten with adaptive noise-floor logic.
- Removed standalone `SpeakingDurationTracker` — its job is now done by `SpeakingActivityTracker` accumulator (`EffectiveSpeakingDuration`).
- Data flow diagram updated: token stream → SpeakingActivityTracker; RMS → ShoutingDetector (no VAD branch).

#### `05_SPIKES.md`
- Spike #6 method revised: no `silence.caf` calibration step, no `--measure-noise-floor` CLI flag, speaking duration derived from token interval lengths. Pass criteria add: "no environment-specific calibration required."
- New Spike #8: cross-environment/cross-mic robustness test. Records same script on built-in/AirPods × quiet/noisy. Validates that Approach D produces consistent WPM (<5% variance).
- New Spike #9: adaptive noise-floor validation for ShoutingDetector. Records normal/shouting in quiet/noisy. Validates that adaptive threshold catches real shouting without false positives in noisy environments.
- Spike #5 (acoustic non-words) stays deferred to v1.x.

#### `04_BACKLOG.md`
- Phase 0 spikes total: 24h → 29h (added S8 + S9, 5h).
- Phase 3 M3.2: was "VAD on audio buffers (3h)" → "SpeakingActivityTracker derive speaking duration from token timestamps (2h)". Net: 1h saved, simpler module.
- Phase 4 M4.5: `ShoutingDetector` 2h → 3h (added adaptive noise-floor logic).
- Phase 4 M4.6: `SpeakingDurationTracker` (1h) → `EffectiveSpeakingDuration: accumulate from SpeakingActivityTracker` (1h). Same effort, different source.

#### Spike #6 harness code
The agent will need to update the Spike #6 harness to match the new architecture:
- Remove `SimpleEnergyVAD.swift`
- Remove `--measure-noise-floor` CLI flag and `NoiseFloorMeasurer.swift`
- Remove `silence.caf` calibration step from `recordings/README.md`
- Replace `[VADEvent]` input to `WPMCalculator` with token-derived speaking-duration computation
- Tests become simpler: instead of constructing both `[TimestampedWord]` AND `[VADEvent]`, tests construct only `[TimestampedWord]` (with their start/end times encoding speaking activity directly)

This is a meaningful rewrite of `WPMCalculator.swift` and ~half the tests. Estimated 2-3h agent work.

### Why this is the right time to do this
- Recording any data with the current spike would test the wrong VAD model. Wasted effort, plus tuned constants would be wrong.
- The agent already wrote clean code; rewriting now (before user has invested 90 min in recording) is much cheaper than after.
- Sets up Spike #8 cleanly — once Approach D harness exists, validating it across mics is a 1-hour exercise.

### Where we left off
- Spike #6 harness exists but uses the old (energy VAD) architecture. Will be rewritten in next session.
- No recordings have been made yet. Good — recording with the new architecture will be simpler (no `silence.caf` step, fewer JSON fields).
- All planning docs updated to reflect Approach D + A.
- Next session: Claude generates a "Spike #6 redo" prompt for Claude Code to rewrite the harness. Then user records.

### Ups
- User caught a real architecture gap before spending hours on recordings. Excellent product instinct — "how does this work in different environments" is exactly the question to ask, and we should have asked it during Session 001.
- The fix is simpler than the original design, not more complex. Removed a module instead of adding one.
- Adaptive techniques (token-derived VAD, percentile-based noise floor) are robust by construction; the architecture no longer has a calibration concept anywhere.

### Downs
- Original architecture had a blind spot we didn't catch until recording day. The Session 001 docs glossed VAD as "simple energy-based or `SoundAnalysis`" without forcing the choice. Lesson: every "or" in an architecture spec is a deferred decision that needs to be resolved before the dependent spike runs, not during.
- 5h added to Phase 0 (S8 + S9). But since 1h was saved on M3.2 and the alternative was finding the problem in production, this is a rounding error.
- Some agent work to throw away (the `SimpleEnergyVAD.swift`, the `--measure-noise-floor` flag, parts of the README). Lesson re-stated: architecture decisions should be locked before agent code, not adjusted after.

### Lesson for the prompt template
Session 002 added "verification-first prompts." Session 004 suggests another rule: **Before generating an agent prompt for any module that depends on a sensor, signal source, or environmental input, the architect must explicitly answer: 'How does this work when the user changes [environment / device / context]?' If the answer is unclear, run a spike to resolve it before the dependent module's prompt.**

Will add to `00_COLLABORATION_INSTRUCTIONS.md` in next session.

---

## Session 003 — 2026-05-01 — Project Identifier Renamed to TalkCoach

**Format:** Naming decision during environment setup, no code written.

### What changed
- GitHub repo: `talk_coach`
- Local folder: `/Users/antonglance/coding/talk_coach`
- Xcode product / target / scheme / bundle base / app class: **`TalkCoach`** (was `SpeechCoach` in earlier docs)

### What did NOT change
- The user-facing product name "Speech Coach" (with space) — that's the marketing name and remains
- Anything in product spec, architecture decisions, or backlog content beyond identifier strings

### Why
User chose `talk_coach` for the repo name and `TalkCoach` for Xcode product to align identifiers with the GitHub URL. Updated all 14 technical references across 5 docs (collaboration instructions, architecture, backlog, CLAUDE.md, example prompt). Search confirms zero remaining `SpeechCoach` references.

### Where we left off
- Phase A of Xcode setup complete: Xcode 26.4.1, macOS 26.4.1, SwiftLint 0.63.2, Apple Silicon, dev account presumed signed in
- Empty GitHub repo created, awaiting Phase B (folder structure + git init + docs in place)
- Next: Phase B walk-through customized for actual paths

---

## Session 002 — 2026-05-01 — Collaboration Instructions Revised + CLAUDE.md Added

**Format:** Best-practices research, no code written.

**Goal:** Make every Claude Code prompt produce shippable, fully-verified output without requiring user testing of mediocre intermediate results.

### What changed

#### Researched current Claude Code best practices (April–May 2026)
Web searched for current guidance from Anthropic docs, community guides, and verified-author writeups (DataCamp, dbreunig.com, builder.io, claudefa.st, official `code.claude.com/docs`). Key findings:

1. **Verification is the single highest-leverage practice.** Per official Claude Code docs: *"Claude performs dramatically better when it can verify its own work. Without clear success criteria, it might produce something that looks right but actually doesn't work."* This directly addresses the user's stated goal of removing the need to test mediocre results.

2. **TDD is the strongest pattern for agentic coding.** Tests written first, committed as a checkpoint, then implementation that's not allowed to modify the tests. Closes the "agent modifies tests to make them pass" failure mode.

3. **Plan mode + "don't implement yet" guard phrase.** Without the explicit "don't implement yet" instruction, Claude Code skips revision and starts coding immediately.

4. **CLAUDE.md is per-project, gets loaded every session, must be lean.** Long CLAUDE.md files cause Claude to ignore half of them. Reference richer docs by `@path` syntax.

5. **Hooks are deterministic, CLAUDE.md is advisory.** For things that must happen every time (lint, format, tests), hooks > CLAUDE.md instructions.

6. **Writer-reviewer sub-agent pattern catches ~92% of errors before production** for high-risk modules.

7. **Two-strike rule:** if correcting the same issue twice doesn't fix it, polluted context is the problem; clean session + refined prompt fixes 89% of the time.

#### Rewrote `00_COLLABORATION_INSTRUCTIONS.md`
- Added the 5 non-negotiables every prompt must include (verification, TDD, no-modify-tests, iterate-until-green, self-review)
- Replaced the simple prompt template with a **3-phase template**: Plan (read-only, no code) → Implement (with TDD) → Self-review (mandatory checklist)
- Added explicit "Always do / Never do" rules for prompt construction
- Documented when to use sub-agents (high-risk modules) vs standard prompts
- Documented the two-strike rule and the "no state C — looks done, please test it" principle
- Added unambiguous "shippable from each prompt" definition: A) demonstrably done, B) demonstrably blocked. No middle state.

#### Created `CLAUDE.md` (new file)
Lives in repo root. Read at every Claude Code session start. Contents:
- What the project is + pointers to richer docs
- The four failure modes (FM1–FM4) restated as hard requirements
- "Always do" / "Never do" lists tuned to this project's specific traps:
  - Never enable Voice Processing IO (Spike #4 outcome)
  - Never use legacy `SFSpeechRecognizer` (use `SpeechAnalyzer`)
  - Never write transcripts to disk
  - Never use the network (sandbox entitlement is `network.client = false`)
- Project layout (file tree)
- Tech stack
- Verification commands the agent should run
- Apple documentation references the agent should consult per module
- When to use sub-agents
- "When you're stuck" protocol — try 3 approaches, then stop and report

### Why this matters
The user's concern was: *"the produced result of each prompt must be potentially shippable product fully tested and validated on test cases."* The previous prompt template was clearer than nothing but didn't enforce verification — it relied on the agent to "do the right thing." The revised template makes verification mandatory and provides the agent with the structure to self-correct.

This is also the difference between using Claude Code at ~33% success rate (unguided) and ~80%+ success rate (with structured planning + TDD + verification loops + sub-agent review).

### Decisions
- Adopted: Plan / Implement / Self-review three-phase prompt template
- Adopted: TDD as default (tests first, committed, frozen)
- Adopted: Writer-reviewer sub-agent pattern for high-risk modules (`Audio/`, `Speech/`, `Analyzer/`, `Core/`)
- Adopted: Per-module verification command (`xcodebuild test`) that agent runs in a loop
- Added: `CLAUDE.md` in repo root as the per-project context file

### Where we left off
- All planning docs finalized including verification-first prompt template
- Ready to begin actual work — recommendation remains: start with Spike #6 (WPM ground truth)
- Next session: Claude generates the first real prompt for Spike #6 using the new template; user runs it in Xcode

### Ups
- Best practices research was specific and recent — we're using current (April–May 2026) guidance, not 2024-era patterns
- The user's stated requirement ("remove need to test mediocre result") maps cleanly to the verification-first principle from official docs

### Downs
- The new prompt template is significantly longer than the previous one; risk: prompts become bureaucratic and slow to write. Mitigation: keep `CLAUDE.md` lean so the prompt itself can reference rather than repeat context.
- Hooks (deterministic enforcement) are mentioned but not yet set up. The user should configure `.claude/settings.json` with PostToolUse hooks for `xcodebuild` after edits, once the project exists. Add to backlog.

---

## Session 001 — 2026-05-01 — Planning & Architecture Lock

**Format:** Architect interview with user, no code written.

**Goal:** Establish full v1 scope, architecture, backlog, and spike list.

### What was decided

#### Product scope (v1)
- macOS menu bar app, no Dock icon (`LSUIElement = true`)
- Translucent floating widget appears automatically when ANY app activates the mic, with a per-app blocklist
- Counts only the user's mic input (not remote Zoom participants)
- WPM display: short rolling window (5–8s, EMA smoothed) + session average
- Filler-word counts (seeded dictionary, editable per language)
- Repeated phrase detection (n-grams)
- Volume / shouting detection (real-time icon)
- Auto-detect language per session — three options to be evaluated in spike
- Session metrics saved locally only; no transcripts persisted
- Two charts in expanded stats window: WPM trend, filler frequency trend per language
- No iCloud sync, no cloud anything
- Languages at launch: English, Russian, Spanish

#### Failure modes (the "if this is wrong, the app is dead to me" criteria)
1. **Destructive UI** — anything that pulls eyes when nothing actionable changed = failure. No flashing, no jitter, smooth color transitions, fixed visual layout.
2. **Unreliable data** — if the user feels fast and the widget says "good pace," trust is broken. WPM must match felt experience.
3. **No setup** — first-launch must be ≤2 actions; defaults must work out of the box.
4. **No performance impact** — invisible CPU/battery cost during 1hr Zoom calls; mic never drops out of other apps.

#### What was parked (NOT in v1)
- Acoustic non-word detection ("hmm", "ahh") — deferred to v1.x
- Auto-learn fillers / smart dictionary — deferred to v1.x (needs session data first)
- Pitch monotony — deferred to v1.x or v2 (research task disguised as a feature)
- Long pauses as a tracked metric — explicitly dropped (but VAD runs internally for accurate WPM)
- Speaker diarization (your-voice-only in mixed mic environments) — v2
- iCloud sync — never (or v3 if multi-device demand emerges)
- Cloud LLM analysis — v2+, optional
- Live transcript display on widget — explicitly dropped (lag would break trust)

#### Locked technical decisions
- **Framework:** `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26+), NOT legacy `SFSpeechRecognizer`. Russian and Spanish are first-class supported in `SpeechTranscriber.supportedLocales`.
- **Mic detection:** Core Audio `kAudioDevicePropertyDeviceIsRunningSomewhere` listener — fires when any process on the system pulls audio from the input device.
- **Mic coexistence:** Disable Voice Processing IO in `AVAudioEngine` setup so we don't fight Zoom's echo cancellation; reading raw input alongside Zoom is supported by macOS HAL.
- **WPM math:** Short EMA-smoothed rolling window (5–8s), with internal VAD excluding silence from the denominator. Session average computed separately.
- **Storage:** SwiftData (macOS 14+), local only. Schema saves metrics only, no transcripts.
- **Widget:** `NSPanel` with `.nonactivatingPanel` + `.hudWindow` style mask, hosted SwiftUI view, `.canJoinAllSpaces` collection behavior. Liquid Glass material on macOS 26.
- **Language auto-detect:** TBD in Spike #2 — disqualified the "two transcribers in parallel" option due to power budget. Will be Option B (best-guess + swap) or Option C (small audio language-ID model).

### Decisions reversed during the session
- **First proposal:** Hotkey-activated v1, auto-detect deferred. **Reversed to:** Auto-detect mandatory in v1, after user pushed back that "extra steps = forgotten = missed data = bad UX."
- **First proposal:** Use `SFSpeechRecognizer`. **Reversed to:** `SpeechAnalyzer` after user reported real-world Russian failure on iOS (verified via search — `SFSpeechRecognizer` Russian on-device quality is poor; `SpeechAnalyzer` is the modern replacement with proper Russian support).
- **First proposal:** 15–20s rolling window for WPM. **Reversed to:** 5–8s EMA-smoothed window, after user named "unreliable data" as a failure mode (long window = lag = mismatch with felt experience).
- **First proposal:** Capture activating app name in session metadata for future use. **Reversed to:** Don't capture, fully anonymous sessions. (Blocklist still works at runtime without persisting.)
- **First proposal:** Standard onboarding flow with permissions, language model picker, target WPM picker. **Reversed to:** No dedicated onboarding. Permissions inline at point-of-use. Defaults pre-baked. English model bundled or silent-downloaded; RU/ES download silently on first detected use.

### Tensions worth remembering
- **"No app capture" vs "blocklist"** — blocklist needs to know which app activated the mic at runtime. Resolved cleanly: read-and-decide at activation time, never persist. But Spike #1 still needs to confirm we *can* identify the app.
- **"Don't track pauses" vs "internal VAD for accurate metrics"** — user said no pause tracking; FM2 (unreliable data) forced VAD back in for the math. Resolved: VAD runs internally, no UI surface, no pause stats, only used to make WPM trustworthy and `effectiveSpeakingDuration` accurate.
- **"Auto-detect language" vs "no setup" vs "no performance impact"** — pure auto-detect every session was user's preference; can't run two transcribers in parallel due to power budget. Pushed to Spike #2 with constraint that the chosen method must be cheap.
- **"Public release" vs "1–2 week sprint" vs "macOS new to user"** — flagged as unrealistic. User reframed: drop calendar timeline, plan by modules with effort estimates, decide pace later.

### Spike list (final, ordered by failure-mode risk)
1. **Spike #6** — WPM ground truth on real EN/RU recordings (FM2 risk)
2. **Spike #7** — Power & CPU profiling during 1hr session (FM3 risk)
3. **Spike #3** — Russian transcription quality on `SpeechAnalyzer` (architecture risk)
4. **Spike #4** — Coexistence with Zoom voice processing (FM3 risk)
5. **Spike #2** — Language auto-detect mechanism (architecture, constrained by Spike #7)
6. **Spike #1** — Identifying activating app for blocklist (deferred until needed by module)

Detailed spec for each spike: see `05_SPIKES.md`.

### Ups
- User has clear instincts and pushed back on weak proposals (correctly). Good signal-to-noise.
- Failure modes were specific and actionable — they directly drove three architectural changes (EMA window, no parallel transcribers, no onboarding).
- Scope discipline held — multiple "while we're at it" features successfully parked to v1.x.

### Downs
- Initial architecture proposal underestimated the auto-detect requirement and over-recommended hotkey activation. User correction was right.
- Initial framework recommendation (`SFSpeechRecognizer`) would have wasted a week of work; user's iOS experience caught it before any code was written.
- Timeline reality check (1–2 weeks insufficient for stated public-release ambition + macOS new + un-de-risked spikes) was uncomfortable but necessary.

### Open questions for next session
- Distribution path (App Store vs direct vs both) is "decide later" — affects Spike #1 priority and notarization workflow
- WPM target band defaults — currently set to 130–170, no language differentiation; may need per-language defaults after Spike #6 reveals natural Russian/English speech rate differences
- Liquid Glass material on macOS 26 — examples and best practices still emerging; first widget implementation will likely need iteration

### Where we left off
- Planning session complete
- All v1 scope, architecture, schema, and failure modes locked
- Next session should start with **the spikes** (#6, #7, #3, #4 in priority order) before any production code
- User will receive: this journal, the product spec, the architecture doc, the backlog, the spike doc, and the collaboration instructions

---
