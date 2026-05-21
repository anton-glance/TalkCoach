// WhisperBridge.c — thin C wrappers around the whisper.cpp C API.
// Compiled by SPM as part of the CWhisper target, with cSettings that provide
// -I paths to whisper.cpp/include and whisper.cpp/ggml/include.
// The public CWhisper.h header exposes only simple C types (no ggml structs),
// so Swift can import CWhisper without needing any whisper/ggml include paths.

#include "whisper.h"
#include "CWhisper.h"
#include <stdlib.h>
#include <stdio.h>

// Segment callback bridge state passed as user_data to whisper_full.
typedef struct {
    CWhisperSegmentCallback callback;
    void                  * user_data;
} BridgeCallbackCtx;

static void whisper_segment_bridge(
    struct whisper_context * ctx,
    struct whisper_state   * state,
    int                      n_new,
    void                   * user_data
) {
    (void)state;
    BridgeCallbackCtx * bctx = (BridgeCallbackCtx *)user_data;
    if (bctx && bctx->callback) {
        bctx->callback((CWhisperContext *)ctx, n_new, bctx->user_data);
    }
}

// ----- Whisper context lifecycle -----

CWhisperContext * cwhisper_init(const char * model_path, bool use_gpu) {
    struct whisper_context_params params = whisper_context_default_params();
    params.use_gpu    = use_gpu;
    params.flash_attn = false;
    return (CWhisperContext *)whisper_init_from_file_with_params(model_path, params);
}

void cwhisper_free(CWhisperContext * ctx) {
    whisper_free((struct whisper_context *)ctx);
}

const char * cwhisper_system_info(void) {
    return whisper_print_system_info();
}

// ----- Inference -----

int cwhisper_full(
    CWhisperContext          * ctx,
    const float              * samples,
    int                        n_samples,
    int                        n_threads,
    const char               * language,
    bool                       no_timestamps,
    CWhisperSegmentCallback    callback,
    void                     * user_data
) {
    BridgeCallbackCtx bctx = { callback, user_data };
    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.language             = language;
    params.translate            = false;
    params.no_timestamps        = no_timestamps;
    params.print_special        = false;
    params.print_realtime       = false;
    params.print_progress       = false;
    params.print_timestamps     = false;
    params.n_threads            = n_threads;
    params.new_segment_callback           = whisper_segment_bridge;
    params.new_segment_callback_user_data = &bctx;
    return whisper_full((struct whisper_context *)ctx, params, samples, n_samples);
}

// ----- Segment accessors -----

int cwhisper_n_segments(CWhisperContext * ctx) {
    return whisper_full_n_segments((struct whisper_context *)ctx);
}

const char * cwhisper_segment_text(CWhisperContext * ctx, int i_segment) {
    return whisper_full_get_segment_text((struct whisper_context *)ctx, i_segment);
}

int cwhisper_n_tokens(CWhisperContext * ctx, int i_segment) {
    return whisper_full_n_tokens((struct whisper_context *)ctx, i_segment);
}

float cwhisper_token_prob(CWhisperContext * ctx, int i_segment, int i_token) {
    return whisper_full_get_token_p((struct whisper_context *)ctx, i_segment, i_token);
}

// ----- Silero VAD lifecycle -----

CWhisperVadContext * cwhisper_vad_init(const char * model_path, int n_threads) {
    struct whisper_vad_context_params params = whisper_vad_default_context_params();
    params.n_threads = n_threads;
    params.use_gpu   = false;  // Metal not applicable for Silero VAD in whisper.cpp v1.8.4
    return (CWhisperVadContext *)whisper_vad_init_from_file_with_params(model_path, params);
}

void cwhisper_vad_free(CWhisperVadContext * ctx) {
    whisper_vad_free((struct whisper_vad_context *)ctx);
}

// ----- VAD inference -----

bool cwhisper_vad_detect_speech(
    CWhisperVadContext * ctx,
    const float        * samples,
    int                  n_samples
) {
    return whisper_vad_detect_speech(
        (struct whisper_vad_context *)ctx,
        samples,
        n_samples
    );
}
