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

use ndarray::{Array1, Array3};
use ort::value::TensorRef;
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

// ── Silero VAD v5 ─────────────────────────────────────────────────────────────
//
// C ABI contract (mirrored in CParakeetBridge.h):
//   SlEngine *sl_engine_create(const char *model_path_utf8)  — null on failure
//   void      sl_engine_destroy(SlEngine *engine)            — no-op on null
//   float     sl_process_frame(SlEngine *, const float *, usize) — 0.0 on null engine
//   void      sl_engine_reset(SlEngine *)                    — no-op on null
//
// Silero VAD v5 ONNX API (verified against snakers4/silero-vad utils_vad.py):
//   Inputs:  "input"  [1, 576]  f32  — context(64) prepended to new_samples(512)
//            "state"  [2,1,128] f32  — GRU hidden state, zero-initialized per session
//            "sr"     [1]       i64  — sample rate, always 16000
//   Outputs: index 0 → voice probability (f32 scalar)
//            index 1 → updated "state" [2,1,128]
//
// ORT two-models note: ort and ndarray are also pulled in transitively by
// parakeet-rs. Explicit deps in Cargo.toml pin exact versions to avoid
// duplicate symbols in the staticlib. cargo will unify to a single instance.

const SL_SAMPLE_RATE: u32 = 16_000;
const SL_FRAME_SAMPLES: usize = 512;
const SL_CONTEXT_SAMPLES: usize = 64;
const SL_INPUT_SAMPLES: usize = SL_FRAME_SAMPLES + SL_CONTEXT_SAMPLES; // 576
const SL_STATE_ELEMENTS: usize = 2 * 1 * 128; // 256

struct SileroInner {
    session: ort::session::Session,
    /// GRU hidden state flattened [2, 1, 128].
    state: Vec<f32>,
    /// Last 64 samples from the previous frame (context buffer).
    context: Vec<f32>,
}

impl SileroInner {
    fn new(model_path: &std::path::Path) -> Option<Self> {
        let session = ort::session::Session::builder().ok()?
            .commit_from_file(model_path).ok()?;
        Some(Self {
            session,
            state: vec![0.0f32; SL_STATE_ELEMENTS],
            context: vec![0.0f32; SL_CONTEXT_SAMPLES],
        })
    }

    /// Process one 512-sample frame. Returns voice probability in [0, 1], or 0.0 on error.
    fn process(&mut self, new_samples: &[f32]) -> f32 {
        if new_samples.len() != SL_FRAME_SAMPLES {
            return 0.0;
        }

        // Build input: [context(64) || new_samples(512)] = 576 total
        let mut input_data = Vec::with_capacity(SL_INPUT_SAMPLES);
        input_data.extend_from_slice(&self.context);
        input_data.extend_from_slice(new_samples);

        let input_arr = match Array1::from_vec(input_data)
            .into_shape_with_order((1, SL_INPUT_SAMPLES))
        {
            Ok(a) => a,
            Err(_) => return 0.0,
        };
        let state_arr = match Array3::from_shape_vec([2, 1, 128], self.state.clone()) {
            Ok(a) => a,
            Err(_) => return 0.0,
        };
        let sr_arr = Array1::from_vec(vec![SL_SAMPLE_RATE as i64]);

        let input_ref = match TensorRef::<f32>::from_array_view(input_arr.view()) {
            Ok(r) => r,
            Err(_) => return 0.0,
        };
        let state_ref = match TensorRef::<f32>::from_array_view(state_arr.view()) {
            Ok(r) => r,
            Err(_) => return 0.0,
        };
        let sr_ref = match TensorRef::<i64>::from_array_view(sr_arr.view()) {
            Ok(r) => r,
            Err(_) => return 0.0,
        };

        let outputs = match self.session.run(ort::inputs![
            "input" => input_ref,
            "state" => state_ref,
            "sr"    => sr_ref,
        ]) {
            Ok(o) => o,
            Err(_) => return 0.0,
        };

        // Extract probability (output 0)
        let prob = outputs[0]
            .try_extract_array::<f32>()
            .ok()
            .and_then(|a| a.iter().next().copied())
            .unwrap_or(0.0);

        // Persist updated GRU state (output 1)
        if let Ok(new_state) = outputs[1].try_extract_array::<f32>() {
            self.state = new_state.iter().cloned().collect();
        }

        // Advance context: keep last 64 samples of the frame just processed
        self.context
            .copy_from_slice(&new_samples[SL_FRAME_SAMPLES - SL_CONTEXT_SAMPLES..]);

        prob
    }

    fn reset(&mut self) {
        self.state = vec![0.0f32; SL_STATE_ELEMENTS];
        self.context = vec![0.0f32; SL_CONTEXT_SAMPLES];
    }
}

/// Opaque Silero VAD engine handle exposed to Swift as `SlEngine *`.
pub struct SlEngine {
    inner: Mutex<SileroInner>,
}

#[no_mangle]
pub extern "C" fn sl_engine_create(model_path_utf8: *const c_char) -> *mut SlEngine {
    if model_path_utf8.is_null() {
        return std::ptr::null_mut();
    }
    let path = match unsafe { CStr::from_ptr(model_path_utf8) }.to_str() {
        Ok(s) => std::path::Path::new(s).to_path_buf(),
        Err(_) => return std::ptr::null_mut(),
    };
    match SileroInner::new(&path) {
        Some(inner) => Box::into_raw(Box::new(SlEngine { inner: Mutex::new(inner) })),
        None => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub extern "C" fn sl_engine_destroy(engine: *mut SlEngine) {
    if !engine.is_null() {
        // SAFETY: pointer was created by sl_engine_create via Box::into_raw.
        unsafe { drop(Box::from_raw(engine)) };
    }
}

#[no_mangle]
pub extern "C" fn sl_process_frame(
    engine: *mut SlEngine,
    samples: *const f32,
    num_samples: usize,
) -> f32 {
    if engine.is_null() || samples.is_null() {
        return 0.0;
    }
    // SAFETY: engine is valid (created by sl_engine_create, not yet destroyed).
    let eng = unsafe { &*engine };
    let frame: &[f32] = unsafe { std::slice::from_raw_parts(samples, num_samples) };
    let mut inner = match eng.inner.lock() {
        Ok(g) => g,
        Err(_) => return 0.0,
    };
    inner.process(frame)
}

#[no_mangle]
pub extern "C" fn sl_engine_reset(engine: *mut SlEngine) {
    if engine.is_null() {
        return;
    }
    // SAFETY: pointer was created by sl_engine_create, not yet destroyed.
    let eng = unsafe { &*engine };
    if let Ok(mut inner) = eng.inner.lock() {
        inner.reset();
    }
}

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
