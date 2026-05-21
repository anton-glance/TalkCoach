#pragma once
#include <stdbool.h>
#include <stddef.h>

// ----- Opaque handles -----
// whisper_context and whisper_vad_context are opaque C++ types.
// We expose them to Swift as void* behind typedef aliases.
typedef void CWhisperContext;
typedef void CWhisperVadContext;

// ----- Segment callback -----
// Fired synchronously during whisper_full() for each newly decoded segment.
// n_new: number of new segments in this batch (always ≥1).
// user_data: caller-supplied context pointer.
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
// Returns 0 on success.
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
// Returns true if speech detected in the given PCM window.
bool cwhisper_vad_detect_speech(
    CWhisperVadContext * ctx,
    const float        * samples,
    int                  n_samples
);
