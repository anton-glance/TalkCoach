## WPM Spike Recordings

Record the following clips AFTER verifying the harness builds and the algorithm tests pass with synthetic data.

No calibration is required. The harness derives speaking duration from `SpeechAnalyzer` token timestamps directly.

### What to record

6 audio clips, each approximately 60 seconds:

| Filename | Language | Pace | Target WPM | Pause? | Notes |
|---|---|---|---|---|---|
| en_normal.caf | en-US | normal | ~140 | Yes, 4s | Spontaneous conversational pace |
| en_fast.caf | en-US | fast | ~180 | No | Rushing, slightly uncomfortable |
| en_slow.caf | en-US | slow | ~100 | No | Deliberate, presentation-style |
| ru_normal.caf | ru-RU | normal | ~120 | Yes, 4s | Spontaneous Russian conversation |
| ru_fast.caf | ru-RU | fast | ~160 | No | Rushing in Russian |
| ru_slow.caf | ru-RU | slow | ~90 | No | Deliberate Russian speech |

### Recording guidelines

- Use your Mac's built-in mic or your usual meeting mic
- Quiet room, no background music
- **Prefer spontaneous speech** (describe a topic from memory, tell a story, explain a concept) over reading aloud. Spontaneous speech is what the app will see in real Zoom calls. Reading aloud runs 10-15% faster than natural speech and would skew calibration.
- Reading is acceptable only for fast/slow clips where precise pace control matters.
- The 4-second deliberate pause goes in **en_normal** and **ru_normal only**. Fast/slow clips should be continuous speech for clean rate measurement.
- Record as .caf (Core Audio Format) or .wav

### How to record

QuickTime Player > File > New Audio Recording > Record for ~60s > Save as .caf

### Ground truth JSON

For each clip, create a sidecar .json file with the same base name. Count words manually from a transcript.

**Important:** `groundTruthWPM` must be calculated against **speaking duration** (excluding the deliberate pause), not wall-clock `durationSeconds`. Otherwise you'd compare wall-clock ground truth against token-derived harness WPM, which is apples-to-oranges.

- For clips **without** a pause: `groundTruthWPM = totalWords / (durationSeconds / 60)`
- For clips **with** a 4-second pause: `groundTruthWPM = totalWords / ((durationSeconds - 4) / 60)`

Example (en_normal.json — clip with 4s pause):

    {
        "clipName": "en_normal",
        "language": "en-US",
        "paceLabel": "normal",
        "groundTruthWPM": 149,
        "durationSeconds": 60,
        "totalWords": 139
    }

Note: 139 words / ((60 - 4) / 60) = 139 / 0.933 = ~149 WPM.
`durationSeconds` is still the full wall-clock duration (used for other calculations).
`groundTruthWPM` is the pause-adjusted speaking-rate WPM.

Example (en_fast.json — continuous clip, no pause):

    {
        "clipName": "en_fast",
        "language": "en-US",
        "paceLabel": "fast",
        "groundTruthWPM": 180,
        "durationSeconds": 60,
        "totalWords": 180
    }

### How to count ground truth WPM

1. Record the clip
2. Play it back and transcribe manually (or use macOS dictation as a starting point, then correct)
3. Count whitespace-separated words in the transcript
4. For clips with a pause: WPM = totalWords / ((durationSeconds - pauseSeconds) / 60)
5. For clips without a pause: WPM = totalWords / (durationSeconds / 60)

### Running the harness

    cd WPMSpike
    swift run WPMSpikeCLI recordings/en_normal.caf

Output is CSV to stdout. Redirect to a file for analysis:

    swift run WPMSpikeCLI recordings/en_normal.caf > results/en_normal.csv

To adjust the token silence timeout (default 1.5s):

    swift run WPMSpikeCLI recordings/en_normal.caf --token-silence-timeout 2.0

### Processing all clips at once

After recording and creating JSON sidecars for all 6 clips, run:

    ./recordings/process_all.sh

This produces `results/combined.csv` with one header row followed by all data rows from all clips. Paste this file back to the architect for analysis.

To use a custom token silence timeout:

    TOKEN_SILENCE_TIMEOUT=2.0 ./recordings/process_all.sh

### What to look for in results

- error_pct < 8% on normal-pace clips (Spike #6 pass criterion)
- WPM direction matches pace label (fast > normal > slow)
- Check different (window_s, alpha) combos to find the best fit
- The 4-second pause in normal clips should NOT crash WPM (verify peak_wpm stays reasonable)

### After all clips are processed

Compile results into a summary table. The best (window_s, alpha) combination becomes the production default in the Analyzer module.
