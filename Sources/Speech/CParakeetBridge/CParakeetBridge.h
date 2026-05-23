#pragma once
#include <stdint.h>
#include <stddef.h>

/// Single word-level timestamp from Parakeet.
typedef struct {
    float start;
    float end;
} PkToken;

/// Transcription result heap-allocated by pk_transcribe.
/// Must be freed by exactly one call to pk_free_result.
typedef struct {
    uint32_t word_count;
    PkToken *tokens;   ///< heap-allocated array of word_count elements
    char    *text;     ///< null-terminated UTF-8 transcript
} PkResult;

/// Opaque engine handle; created by pk_engine_create.
typedef struct PkEngine PkEngine;

/// Load the Parakeet TDT model from model_dir_utf8.
/// Returns null on failure. Caller owns the result; free with pk_engine_destroy.
PkEngine *pk_engine_create(const char *model_dir_utf8);

/// Destroy an engine created by pk_engine_create. No-op on null.
void pk_engine_destroy(PkEngine *engine);

/// Transcribe num_samples f32 samples at 16 kHz mono.
/// Returns a heap-allocated PkResult; caller must free via pk_free_result.
/// Returns null if engine is null or inference fails.
PkResult *pk_transcribe(PkEngine *engine, const float *samples, size_t num_samples);

/// Free a PkResult returned by pk_transcribe. No-op on null.
void pk_free_result(PkResult *result);

// ── Silero VAD v5 bridge ────────────────────────────────────────────────────

/// Opaque Silero VAD engine handle; created by sl_engine_create.
typedef struct SlEngine SlEngine;

/// Load the Silero VAD v5 ONNX model from model_path_utf8 (full path to .onnx file).
/// Returns null on failure (model absent, ORT init error). Caller owns the result;
/// free with sl_engine_destroy.
SlEngine *sl_engine_create(const char *model_path_utf8);

/// Destroy a SlEngine created by sl_engine_create. No-op on null.
void sl_engine_destroy(SlEngine *engine);

/// Run Silero VAD inference on exactly 512 f32 samples at 16 kHz mono.
/// Returns speech probability in [0, 1]. Returns 0.0 if engine is null.
/// Maintains GRU hidden state across calls; call sl_engine_reset to clear state.
float sl_process_frame(SlEngine *engine, const float *samples, size_t num_samples);

/// Reset the GRU hidden state to zeros. Call between independent audio segments.
void sl_engine_reset(SlEngine *engine);
