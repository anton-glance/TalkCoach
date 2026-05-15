# Spike 14 — SpeechAnalyzer Warm-State Survival Across AVAudioEngine Teardown

## What was measured

Can the same `AsyncStream<AnalyzerInput>.Continuation` fed into `SpeechAnalyzer.start(inputSequence:)` survive an `AVAudioEngine.stop()` + fresh-engine-instantiation + tap-reinstall cycle and continue emitting tokens — without triggering the 5-7s acoustic-model cold-start that normally follows a full transcription stack rebuild?

**API under test:** `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26), which is the exact API used by `Sources/Speech/AppleTranscriberBackend.swift`.

**Key invariant preserved across phases:** `inputContinuation.finish()` is NOT called between phases. The `SpeechAnalyzer.start(inputSequence:)` task stays alive, blocked waiting for the next `AnalyzerInput`. When the fresh engine's tap fires, it yields to the same continuation — in theory resuming analysis without a gap.

## Hypothesis

The `SpeechAnalyzer` + `SpeechTranscriber` pair's internal warm acoustic state is decoupled from the `AVAudioEngine` lifecycle. As long as the `AsyncStream<AnalyzerInput>` input sequence is not finished, analysis continues across an engine stop/rebuild cycle with no warm-up delay on first new token.

## How to run

    cd Spike/Spike14_AnalyzerWarmSurvival
    swift run

Requires macOS 26, mic permission (Terminal.app must have mic access in System Settings > Privacy > Microphone).

**The test is interactive — you must speak during both phases:**

1. Phase 1 (`=== PHASE 1 START ===`): speak continuously for 30 seconds. Look for token output. Note when tokens first appear.
2. At second 30 the binary prints `=== PHASE 2 START ===`, stops engine1, waits 200ms, starts engine2.
3. Immediately after `[engine2 started ...]`: say "phase two test sentence one two three" clearly.
4. Observe: does that sentence appear in tokens? Is the latency < 1 second or 5-7 seconds?
5. Binary prints `SPIKE 14 RESULT:` with automatic classification.

## Automated run result (ambient audio only — no deliberate speech)

Run completed 2026-05-15 on macOS 26 (Darwin 25.4), Apple Silicon.

    === SPIKE 14: SpeechAnalyzer warm-state survival across AVAudioEngine teardown ===
    API: SpeechAnalyzer + SpeechTranscriber (macOS 26)
    Test: same inputContinuation kept alive across engine stop/rebuild

    Requesting microphone access...
    Microphone access granted.

    Hardware input format: 48000.0Hz 1ch
    Analyzer target format: 16000.0Hz 1ch
    Sample-rate conversion enabled: 48000.0 → 16000.0
    SpeechAnalyzer started.

    === PHASE 1 START === (wallMs=1015)
    Speak now — running 30 seconds...
    [+12.67s] p1 "." final=false
    [+16.59s] p1 "Okay. Okay." final=true

    === PHASE 2 START — engine teardown + rebuild === (wallMs=32917)
    [engine1 stopped | inputContinuation NOT finished | same reference active]
    [HAL settling — waiting 200ms]
    [engine2 started | new tap feeding SAME inputContinuation]
    Speak now — running 30 seconds...

    === PHASE 3: FINISHING === (wallMs=65389)
    [result stream ended]

    SPIKE 14 RESULT:
    Phase 1: first token at +12.67s, total tokens: 2
    Phase 2 (after engine rebuild): first new token at never, total tokens: 0
    Phase 3: tokens continued = NO, warm-up gap on rebuild = N/A
    HYPOTHESIS: REJECTED

## Interpretation of ambient run

**This run is inconclusive.** Phase 1 received ambient microphone audio (likely a nearby voice or mechanical sound) and produced tokens — confirming `SpeechAnalyzer` was running correctly. Phase 2 produced zero tokens, but this is ambiguous:

- **Scenario A (Hypothesis REJECTED):** The `SpeechAnalyzer` resets its internal acoustic state after a buffer-flow gap. Even with the same `inputContinuation`, the 200ms silence during engine rebuild causes the analyzer to cold-start. Phase 2 would then only produce tokens after a 5-7s warm-up — and since no speech occurred, zero tokens is expected.

- **Scenario B (Hypothesis SUPPORTED):** The `SpeechAnalyzer` correctly resumed from the same continuation. Phase 2 produced no tokens simply because there was no audio event to transcribe (the ambient audio that triggered phase 1 tokens was a brief, unrepeated sound).

**To distinguish A from B, a manual run with deliberate speech in both phases is required.** See instructions above.

## What the result means for M3.7.3

**If SUPPORTED:** The M3.7.3 probe-resume cycle can keep the `SpeechAnalyzer`/`SpeechTranscriber` stack alive across each 15s probe, feeding the existing `inputContinuation` from the fresh engine's tap. No cold-start cost per probe. Clean fix.

**If PARTIAL (tokens resume but with 3-7s delay):** The analyzer internally ties acoustic state to buffer continuity. The gap during engine teardown + HAL settling causes a partial reset. M3.7.3 fix-round #4 must either shorten the gap (< 50ms tap-to-tap) or accept the warm-up cost and pre-fill the pipeline with a few seconds of silence buffers.

**If REJECTED (no tokens in phase 2 after real speech):** The `SpeechAnalyzer`/`SpeechTranscriber` lifecycle is tightly coupled to the input sequence stream. Finishing or pausing the stream terminates the analysis session internally. M3.7.3 must pursue speculative pre-warm: start a parallel fresh transcription stack while the probe runs, discarding whichever stack loses.

## Structural findings (confirmed by automated run)

- `SpeechAnalyzer` builds and starts cleanly on macOS 26 (no crashes).
- Engine teardown + rebuild completes in ~200ms HAL settling time.
- `inputContinuation.finish()` → `transcriber.results` async sequence terminates cleanly (confirmed by `[result stream ended]` appearing exactly when expected in phase 3).
- Format: hardware delivers 48kHz/1ch; `bestAvailableAudioFormat` targets 16kHz/1ch; `AVAudioConverter` bridges the gap without errors.
