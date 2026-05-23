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
