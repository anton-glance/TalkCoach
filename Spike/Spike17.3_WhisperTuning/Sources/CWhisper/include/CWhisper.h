#pragma once
#include <stdbool.h>
#include <stddef.h>

// ----- Opaque handles -----
typedef void CWhisperContext;
typedef void CWhisperVadContext;

// ----- Segment callback -----
typedef void (*CWhisperSegmentCallback)(
    CWhisperContext * ctx,
    int               n_new,
    void            * user_data
);

// ----- Whisper context lifecycle -----
CWhisperContext * cwhisper_init(const char * model_path, bool use_gpu);
void              cwhisper_free(CWhisperContext * ctx);
const char *      cwhisper_system_info(void);

// ----- Inference -----
int  cwhisper_full(
    CWhisperContext          * ctx,
    const float              * samples,
    int                        n_samples,
    int                        n_threads,
    const char               * language,
    bool                       no_timestamps,
    CWhisperSegmentCallback    callback,
    void                     * user_data
);

// ----- Segment accessors (call after cwhisper_full) -----
int          cwhisper_n_segments     (CWhisperContext * ctx);
const char * cwhisper_segment_text   (CWhisperContext * ctx, int i_segment);
int          cwhisper_n_tokens       (CWhisperContext * ctx, int i_segment);
float        cwhisper_token_prob     (CWhisperContext * ctx, int i_segment, int i_token);

// ----- Silero VAD context lifecycle -----
CWhisperVadContext * cwhisper_vad_init(const char * model_path, int n_threads);
void                 cwhisper_vad_free(CWhisperVadContext * ctx);

// ----- VAD inference -----
// Default threshold (0.5): returns true if speech detected in the given PCM window.
bool cwhisper_vad_detect_speech(
    CWhisperVadContext * ctx,
    const float        * samples,
    int                  n_samples
);

// Threshold-aware VAD: uses whisper_vad_segments_from_samples with the given threshold.
// Returns true if any speech segment is detected above the threshold.
bool cwhisper_vad_detect_speech_threshold(
    CWhisperVadContext * ctx,
    const float        * samples,
    int                  n_samples,
    float                threshold
);
