# Test Corpus for Spike #2

## Requirements per clip

- Duration: 10-15 seconds of continuous speech
- Content: single speaker, monologue/news/interview (one voice only)
- No music, no overlapping voices, no long silences
- Clean-ish audio (studio or indoor recording, not street noise)

## Sourcing workflow

1. Find a YouTube clip matching the requirements
2. Download and convert:

        yt-dlp -x --audio-format wav -o "%(id)s.wav" "<YouTube-URL>"
        afconvert -f caff -d LEI16 "%(id)s.wav" "en_01.caf"

3. Name files by language and index: `en_01.caf` through `en_04.caf`, etc.
4. Copy `manifest.example.json` to `manifest.json` and update descriptions

## File inventory

    4 x English (en_01..en_04) — reused across all three pairs
    4 x Russian (ru_01..ru_04)
    4 x Japanese (ja_01..ja_04)
    4 x Spanish (es_01..es_04)
    = 16 clips total
