## WPM Spike Recordings

Record the following clips AFTER verifying the harness builds and the algorithm tests pass with synthetic data.

### What to record

6 audio clips, each approximately 60 seconds:

| Filename | Language | Pace | Target WPM | Notes |
|---|---|---|---|---|
| en_normal.caf | en-US | normal | ~140 | Natural conversational pace |
| en_fast.caf | en-US | fast | ~180 | Rushing, slightly uncomfortable |
| en_slow.caf | en-US | slow | ~100 | Deliberate, presentation-style |
| ru_normal.caf | ru-RU | normal | ~120 | Natural Russian conversation |
| ru_fast.caf | ru-RU | fast | ~160 | Rushing in Russian |
| ru_slow.caf | ru-RU | slow | ~90 | Deliberate Russian speech |

### Recording guidelines

- Use your Mac's built-in mic or your usual meeting mic
- Quiet room, no background music
- Speak naturally (read a passage or talk about a topic)
- Include one deliberate 4-second pause in the middle of each clip
- Record as .caf (Core Audio Format) or .wav

### How to record

QuickTime Player > File > New Audio Recording > Record for ~60s > Save as .caf

Or use the command line:

    afrecord -f caff -d LEF32@44100 -c 1 -l 60 en_normal.caf

### Ground truth JSON

For each clip, create a sidecar .json file with the same base name. Count words manually from a transcript.

Example (en_normal.json):

    {
        "clipName": "en_normal",
        "language": "en-US",
        "paceLabel": "normal",
        "groundTruthWPM": 142,
        "durationSeconds": 60,
        "totalWords": 142
    }

### How to count ground truth WPM

1. Record the clip
2. Play it back and transcribe manually (or use macOS dictation as a starting point, then correct)
3. Count whitespace-separated words in the transcript
4. WPM = totalWords / (durationSeconds / 60)

### Running the harness

    cd WPMSpike
    swift run WPMSpikeCLI recordings/en_normal.caf

Output is CSV to stdout. Redirect to a file for analysis:

    swift run WPMSpikeCLI recordings/en_normal.caf > results/en_normal.csv

### What to look for in results

- error_pct < 8% on normal-pace clips (Spike #6 pass criterion)
- WPM direction matches pace label (fast > normal > slow)
- Check different (window_s, alpha) combos to find the best fit
- The 4-second pause should NOT crash WPM (verify peak_wpm stays reasonable)

### After all clips are processed

Compile results into a summary table. The best (window_s, alpha) combination becomes the production default in the Analyzer module.
