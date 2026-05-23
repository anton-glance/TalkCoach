// parakeet-bridge — C ABI wrapper around parakeet-rs for Swift FFI.
//
// C ABI contract (mirrored in CParakeetBridge.h):
//   PkEngine *pk_engine_create(const char *model_dir_utf8)  — null on failure
//   void      pk_engine_destroy(PkEngine *engine)           — no-op on null
//   PkResult *pk_transcribe(PkEngine *, const float *, usize) — null on null engine
//   void      pk_free_result(PkResult *)                    — no-op on null
//
// PkResult ownership: pk_transcribe heap-allocates the struct, tokens array, and text
// buffer separately. pk_free_result frees all three. Swift must call pk_free_result
// exactly once per non-null result; the ParakeetBackend actor's serial executor
// ensures this.
//
// Threading: ParakeetTDT::transcribe_samples takes &mut self. The engine is wrapped
// in a Mutex so the C pointer is Sync. Swift calls only from the ParakeetBackend actor
// serial executor so lock contention never occurs in practice.

use std::ffi::{CStr, CString};
use std::os::raw::c_char;
use std::sync::Mutex;

use parakeet_rs::{ParakeetTDT, TimestampMode, Transcriber};

// ── Public C types ────────────────────────────────────────────────────────────

#[repr(C)]
pub struct PkToken {
    pub start: f32,
    pub end: f32,
}

#[repr(C)]
pub struct PkResult {
    pub word_count: u32,
    /// Heap-allocated array of word_count PkToken values; freed by pk_free_result.
    pub tokens: *mut PkToken,
    /// Null-terminated UTF-8 transcript; freed by pk_free_result.
    pub text: *mut c_char,
}

// SAFETY: PkResult is only ever created and consumed from Swift via the C ABI.
// Swift uses it single-threaded (actor serial executor), so Send is safe here.
unsafe impl Send for PkResult {}

// ── Engine handle ─────────────────────────────────────────────────────────────

/// Opaque engine handle exposed to Swift as `PkEngine *`.
pub struct PkEngine {
    model: Mutex<ParakeetTDT>,
}

// ── Exported C functions ──────────────────────────────────────────────────────

/// Load the Parakeet TDT model from `model_dir_utf8`.
/// Returns a heap-allocated PkEngine on success, null on any failure.
/// Caller owns the returned pointer; free with pk_engine_destroy.
#[no_mangle]
pub extern "C" fn pk_engine_create(model_dir_utf8: *const c_char) -> *mut PkEngine {
    if model_dir_utf8.is_null() {
        return std::ptr::null_mut();
    }
    let dir = match unsafe { CStr::from_ptr(model_dir_utf8) }.to_str() {
        Ok(s) => std::path::Path::new(s).to_path_buf(),
        Err(_) => return std::ptr::null_mut(),
    };
    match ParakeetTDT::from_pretrained(&dir, None) {
        Ok(m) => Box::into_raw(Box::new(PkEngine { model: Mutex::new(m) })),
        Err(_) => std::ptr::null_mut(),
    }
}

/// Destroy a PkEngine created by pk_engine_create. No-op on null.
#[no_mangle]
pub extern "C" fn pk_engine_destroy(engine: *mut PkEngine) {
    if !engine.is_null() {
        // SAFETY: pointer was created by pk_engine_create via Box::into_raw.
        unsafe { drop(Box::from_raw(engine)) };
    }
}

/// Run transcription on `num_samples` f32 samples at 16 kHz mono.
/// Returns a heap-allocated PkResult; caller must free via pk_free_result.
/// Returns null if engine is null or inference fails.
#[no_mangle]
pub extern "C" fn pk_transcribe(
    engine: *mut PkEngine,
    samples: *const f32,
    num_samples: usize,
) -> *mut PkResult {
    if engine.is_null() || samples.is_null() {
        return std::ptr::null_mut();
    }
    // SAFETY: engine is valid (created by pk_engine_create, not yet destroyed).
    let eng = unsafe { &*engine };
    let audio: Vec<f32> = unsafe {
        std::slice::from_raw_parts(samples, num_samples).to_vec()
    };

    let mut model = match eng.model.lock() {
        Ok(g) => g,
        Err(_) => return std::ptr::null_mut(),
    };

    // channels = 1u16 (mono), sample rate = 16_000. Spike #18 confirmed this signature.
    let result = match model.transcribe_samples(audio, 16_000u32, 1u16, Some(TimestampMode::Words)) {
        Ok(r) => r,
        Err(_) => return std::ptr::null_mut(),
    };

    let word_count = result.tokens.len() as u32;

    // Allocate tokens array.
    let mut tokens_vec: Vec<PkToken> = result
        .tokens
        .iter()
        .map(|t| PkToken { start: t.start, end: t.end })
        .collect();
    tokens_vec.shrink_to_fit();
    let tokens_ptr = tokens_vec.as_mut_ptr();
    std::mem::forget(tokens_vec);

    // Allocate transcript string.
    let text_ptr = match CString::new(result.text.trim()) {
        Ok(cs) => cs.into_raw(),
        Err(_) => match CString::new("") {
            Ok(cs) => cs.into_raw(),
            Err(_) => std::ptr::null_mut(),
        },
    };

    Box::into_raw(Box::new(PkResult {
        word_count,
        tokens: tokens_ptr,
        text: text_ptr,
    }))
}

// ── Silero VAD v5 stub ────────────────────────────────────────────────────────
//
// Stub implementations return null / 0.0 until the green-phase implementation
// replaces them. Swift callers check for null from sl_engine_create and either
// XCTSkip (tests) or log an error (production) when the model is absent.

pub struct SlEngine {
    _private: (),
}

#[no_mangle]
pub extern "C" fn sl_engine_create(
    _model_path_utf8: *const c_char,
) -> *mut SlEngine {
    std::ptr::null_mut()
}

#[no_mangle]
pub extern "C" fn sl_engine_destroy(_engine: *mut SlEngine) {}

#[no_mangle]
pub extern "C" fn sl_process_frame(
    _engine: *mut SlEngine,
    _samples: *const f32,
    _num_samples: usize,
) -> f32 {
    0.0
}

#[no_mangle]
pub extern "C" fn sl_engine_reset(_engine: *mut SlEngine) {}

// ── Parakeet free ─────────────────────────────────────────────────────────────

/// Free a PkResult previously returned by pk_transcribe. No-op on null.
#[no_mangle]
pub extern "C" fn pk_free_result(result: *mut PkResult) {
    if result.is_null() {
        return;
    }
    // SAFETY: result was created by pk_transcribe via Box::into_raw.
    let r = unsafe { Box::from_raw(result) };
    // Free the tokens array (allocated via Vec::into_raw_parts pattern).
    if !r.tokens.is_null() {
        unsafe {
            let _ = Vec::from_raw_parts(r.tokens, r.word_count as usize, r.word_count as usize);
        }
    }
    // Free the text string (allocated by CString::into_raw).
    if !r.text.is_null() {
        unsafe { drop(CString::from_raw(r.text)) };
    }
}
