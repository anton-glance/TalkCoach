# Whisper Models

These binary model files are required to build TalkCoach but are NOT committed to git.
After cloning or pulling the repo, download both files and place them in this directory
before building.

## Required files

### ggml-small.bin — whisper-small multilingual (~487 MB)

    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin

Expected: ~487 MB on disk. This is the whisper-small multilingual model in ggml format.

### ggml-silero-v5.1.2.bin — Silero VAD v5.1.2 (~0.88 MB)

    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-silero-v5.1.2.bin

Expected: ~0.88 MB on disk.

## Verifying your download

After downloading, the Xcode "Copy Whisper Models" build phase will copy both files
into `TalkCoach.app/Contents/Resources/Models/` at build time.

If either file is absent, the build fails with:

    error: whisper model 'ggml-small.bin' not found at <SRCROOT>/Vendor/models/ggml-small.bin.
    error: Download it from the URL above and place it in Vendor/models/ before building.
