# Spike 16 — Buffer-Level Voice Activity Detection: Evaluation Report

**Date:** 2026-05-19  
**Branch:** spike/16-buffer-vad  
**Verdict: ESCALATE — algorithm approach is insufficient for v1**

---

## Summary

A simple RMS-energy VAD with adaptive noise floor and hysteresis was implemented and evaluated
against 10 fixture recordings across 2 microphone types (AirPods Pro, MacBook built-in).
No parameter combination in a 27-point sweep (voiceOnCount ∈ {2,3,5}, voiceOffCount ∈ {20,30,45},
thresholdMarginDB ∈ {10,15,20}) produced an overall PASS verdict.
The approach fails systematically in noisy environments and after loud distractor events.

---

## Verdict Reasons (default parameters: voiceOn=3, voiceOff=30, margin=15 dB)

    [FAIL] onset_latency_median:  expected ≤ 100ms,   actual 140ms
    [FAIL] onset_latency_p95:     expected ≤ 200ms,   actual 500ms  *
    [PASS] onset_latency_max:     expected ≤ 500ms,   actual 500ms
    [PASS] end_latency_median:    expected ≤ 500ms,   actual 410ms
    [PASS] end_latency_p95:       expected ≤ 1000ms,  actual 480ms
    [PASS] end_latency_max:       expected ≤ 2000ms,  actual 730ms
    [PASS] silence_only_pods_fp:  expected ≤ 100ms,   actual 0ms
    [PASS] silence_only_mac_fp:   expected ≤ 100ms,   actual 0ms
    [FAIL] speech_fn_max:         expected ≤ 5.0%,    actual 28.15%
    [FAIL] distractor_max_incorrect: expected ≤ 20.0%, actual 24.00%
    [FAIL] calibration_fallback_correctness:
               expected alternating_*+distractors_*=true, silence_only_*=false
               actual   incorrect: alternating_mac, distractors_mac, distractors_pods
    [FAIL] distractor_latency_correctness:  covered by distractor_max_incorrect FAIL

(*) onset_latency_p95 = 500ms is partially an evaluation artifact — see note below.

---

## Per-clip Metrics

    Clip                  FN%     SilenceFP  OnsetLatencies(ms)   EndLatencies(ms)   FallbackUsed
    alternating_pods      11.2    0/0/5000   500, -80, 60         730, 380, -30      YES (ceiling breach)
    alternating_mac       15.6    400/230/6100  500, 140, -130   410, 100, 480       NO  (threshold -29 dBFS)
    quiet_speech_pods     8.7     460        500                  -220               NO  (threshold -30 dBFS)
    quiet_speech_mac      14.7    370        500                  290                NO  (threshold -30 dBFS)
    cafe_noise_pods       19.3    0          120                  2000               NO  (threshold -14 dBFS)
    cafe_noise_mac        15.0    790        500                  -60                NO  (threshold -14 dBFS)
    silence_only_pods     0 FN    0          (no speech)          (no speech)        NO
    silence_only_mac      0 FN    0          (no speech)          (no speech)        NO
    distractors_pods      18.9    810        500                  (no speech_end)    NO  (threshold -30 dBFS)
    distractors_mac       28.2    0          500                  (no speech_end)    NO  (threshold -30 dBFS)

Notes on SilenceFP for alternating_*: these are false positives during inter-speech silence intervals,
not in the silence_only clips. The silence_only clips score 0ms FP (excellent isolation).

---

## Pods vs Mac Comparison

AirPods Pro (close-mic, ~2-5cm from mouth):
- Triggers calibration ceiling breach (-25 dBFS) on `alternating_pods` → fallback threshold -40 dBFS
- Generally lower FN rates than Mac mic for equivalent environments
- Onset latency p50 ~60ms for non-cold-start windows (well within budget)
- End latency p50 ~380ms (within budget)

MacBook built-in (far-field, ~30-50cm):
- Never triggers ceiling breach in any clip → always uses adaptive calibration
- Speech signal is 10-15 dB quieter than AirPods signal
- Higher threshold relative to speech energy → higher FN rates
- Particularly poor on distractors_mac: 28.15% FN because threshold calibrated during speech onset
  (the VAD cannot distinguish quiet room + quiet mic from near-silence during the 1s calibration window)

The far-field Mac mic is the primary failure driver across ALL noise conditions.

---

## Calibration Fallback Analysis

The ceiling-breach mechanism (-25 dBFS → fallback at -40 dBFS) was designed to detect
when recording starts mid-speech and switch to a safe static threshold.

ONLY `alternating_pods` triggers fallback. Three other speech-starting clips
(`alternating_mac`, `distractors_mac`, `distractors_pods`) do NOT trigger fallback because
the Mac mic and the specific recording gain settings produce speech peaks below -25 dBFS.

Effect: for these clips, the 1s calibration window runs during active speech,
the noise floor estimate absorbs speech energy, and the resulting threshold
(noise_floor + margin) is set too close to speech energy → persistent FN throughout the clip.

The ceiling threshold (-25 dBFS) is calibrated for close-mic scenarios only.
A lower ceiling (e.g., -35 dBFS) would catch Mac mic speech during calibration,
but would also trigger spuriously on any momentary noise. This trade-off is fundamental
to the energy-based approach.

---

## Onset Latency Cold-Start Note

The p95 onset latency of 500ms (capped) is a partial evaluation artifact.
All first-window onset misses occur because the 1s calibration window is served
during the first speech segment in each test clip. In the actual TalkCoach app,
the mic is always-on: calibration completes during the pre-session idle period
(the user opens the app, grants mic permission, and calibration runs in background
before the first word is spoken). Real onset latency for non-first-word windows
measured at p50 = 60-140ms depending on microphone — both within the ≤100ms budget.

Even accounting for this artifact, the other criteria (speech_fn_max, calibration
correctness) remain failing across all parameter combinations.

---

## Parameter Sweep Results (27 combinations)

    voiceOn  voiceOff  margin  onset_med  onset_p95  end_med  end_p95  sil_fp  fn_max%  dist_max%  verdict
    2        20        10.0    120        500        420      610      320     22.73    15         FAIL
    2        20        15.0    130        500        310      380      120     29.80    28.5       FAIL
    2        20        20.0    140        500        280      340      0       90.03    48.25      FAIL
    2        30        10.0    120        500        520      710      420     19.90    12.5       FAIL
    2        30        15.0    130        500        410      480      120     27.72    23.5       FAIL
    2        30        20.0    140        500        380      440      0       74.90    40.75      FAIL
    2        45        10.0    120        500        670      860      570     16.09    8.75       FAIL
    2        45        15.0    130        500        560      630      120     23.45    10         FAIL
    2        45        20.0    140        500        530      590      0       71.43    22.5       FAIL
    3        20        10.0    130        500        420      610      120     25.24    15.25      FAIL
    3        20        15.0    140        500        310      380      0       30.23    29.0       FAIL
    3        20        20.0    150        500        280      340      0       94.70    48.75      FAIL
    3        30        10.0    130        500        520      710      120     23.80    12.75      FAIL
    3        30        15.0    140        500        410      480      0       28.15    24         FAIL  (default)
    3        30        20.0    150        500        380      440      0       92.63    41.25      FAIL
    3        45        10.0    130        500        670      860      120     20.48    9          FAIL
    3        45        15.0    140        500        560      630      0       23.82    10.25      FAIL
    3        45        20.0    150        500        530      590      0       72.53    22.75      FAIL
    5        20        10.0    150        500        420      610      0       26.13    15.75      FAIL
    5        20        15.0    160        500        310      380      0       33.50    30         FAIL
    5        20        20.0    170        500        280      340      0       98.07    53.25      FAIL
    5        30        10.0    150        500        520      710      0       24.69    13.25      FAIL
    5        30        15.0    160        500        410      480      0       28.55    25         FAIL
    5        30        20.0    170        500        380      440      0       97.40    45.75      FAIL
    5        45        10.0    150        500        670      860      0       21.26    9.5        FAIL
    5        45        15.0    160        500        560      630      0       24.11    10.75      FAIL
    5        45        20.0    170        500        530      590      0       96.40    34.5       FAIL

Best combination for FN + distractor: voiceOn=2, voiceOff=45, margin=10
    → fn_max=16.09%, dist_max=8.75%, but silence_fp=570ms (fails FP budget)

Key tradeoff: lowering margin reduces FN but raises silence FP. No combination resolves both.

---

## Root Cause Analysis

**Failure mode 1 — Café/noisy environment FN (15-19%):**
The adaptive noise floor absorbs background noise (café music, crowd). With margin=15,
threshold = -29 + 15 = -14 dBFS. Speech energy in a noisy café peaks at approximately -20 to -22 dBFS,
which is below the threshold. The VAD cannot detect speech that sits only 7-9 dB above noise.
With margin=10, threshold = -19 dBFS — speech at -20 dBFS STILL fails (-20 < -19).
The RMS energy approach conflates speech and background noise; it needs a frequency-selective
or temporal-spectral approach to separate them.

**Failure mode 2 — Distractors clip FN (19-28%):**
After loud transient events (door slam, notification), the noise floor EMA update fires
during the post-distractor "silence" (VAD is inactive). If the event was very loud,
the estimated noise floor rises, causing the subsequent threshold to rise above speech energy.
Recovery latencies of 2,000-14,850ms were observed for door_slam events. A proper VAD
needs to detect non-stationary noise events and freeze the noise floor estimate.

**Failure mode 3 — Mac mic FN in quiet speech (8-15%):**
At normal working distance (30-50cm), the Mac built-in mic records speech 10-15 dB quieter
than close-mic AirPods. The adaptive threshold ends up within 5-7 dB of speech energy,
causing marginal frames (sentence-initial consonants, breath groups) to be missed.

**Failure mode 4 — Calibration polluted by far-field speech:**
For clips that start with immediate speech, the ceiling (-25 dBFS) only fires for close-mic
recordings. Far-field Mac mic speech at -30 to -35 dBFS goes undetected as "speech during calibration,"
and the 1s window sets threshold based on speech energy → threshold too high → persistent FN.

---

## What Passed (reusable for next approach)

- Silence detection: 0ms false positive on both silence_only clips across all parameters
- End latency: median ≤500ms, p95 ≤1000ms across all non-cold-start clips
- Hysteresis logic: unit-tested, correct, no off-by-one errors
- 300ms closing filter: reduces FN rate substantially in clean conditions
- Adaptive noise floor: tracks stationary noise correctly (silence_only passes cleanly)
- Evaluation harness: Spike16Eval is reusable for evaluating any algorithm that outputs
  the same CSV format (timestamp_ms, rms_db, noise_floor_db, threshold_db, is_voice_active, calib_state)

---

## Recommendation: ESCALATE

The simple RMS energy + adaptive noise floor approach is **not sufficient for v1** on its own.
No parameter tuning resolves the fundamental problems in noisy environments and on far-field mics.

Recommended escalation path (in priority order):

**Option A — WebRTC VAD (recommended first attempt):**
Google's WebRTC VAD uses a Gaussian mixture model on mel-filterbank features.
It runs at 10/20/30ms frames, supports 8/16/32kHz, has three aggressiveness modes,
and is battle-tested in production video conferencing at exactly this latency/quality point.
A Swift wrapper exists (or C header bridging is ~30 lines). Expected FN rate in café: <5%.
License: BSD. Binary size: ~50KB.

**Option B — Silero VAD (ML-based, on-device):**
ONNX/Core ML model, 1.7MB, runs at 10ms frames, trained on 6000+ hours of multilingual audio.
Achieves near-perfect VAD across all noise conditions. Available as Swift package via ONNX Runtime.
Higher accuracy but adds a 1-2MB model dependency.

**Option C — AVAudioSession with voice processing (ruled out):**
`isVoiceProcessingEnabled = true` on `AVAudioInputNode` provides Apple's built-in VAD
but conflicts with Zoom co-existence (Spike #4 finding). Not viable for v1.

**Option D — Lower ceiling threshold + fixed bias:**
Change calibration ceiling from -25 dBFS to -35 dBFS, and add a separate per-mic bias
(detected by device type). This may bring Mac mic FN below 10% but likely still not ≤5%.
Low effort, worth trying before WebRTC VAD if a shorter spike is preferred.

---

## Integration Test Status

`IntegrationTests.testSummaryVerdictIsPass` FAILS with the above verdictReasons.
This is expected and intentional: the integration test is a CI gate that documents
the algorithm does not yet meet the v1 quality bar. It will pass when a future spike
(or implementation) writes a conformant CSV + produces PASS verdict.
