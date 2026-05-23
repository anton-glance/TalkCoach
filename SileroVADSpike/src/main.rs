// Spike #19 — Silero VAD v5 far-field validation
//
// OQ-1 resolved (v5 ONNX API, verified against snakers4/silero-vad utils_vad.py):
//   Inputs:  "input"  [1, 576]  f32  — context(64) prepended to new_samples(512)
//            "state"  [2,1,128] f32  — GRU hidden state, zero-initialized per session
//            "sr"     [1]       i64  — sample rate, always 16000
//   Outputs: index 0 → voice probability (f32 scalar-ish)
//            index 1 → updated "state" [2,1,128]
//
// Context management: the caller keeps the last 64 samples from the PREVIOUS frame
// and prepends them to the current 512-sample frame before passing to the model.
// This is external state — NOT an ONNX input tensor of its own.
//
// OQ-5 resolved: state is initialized to zeros at session start; we never reset
// during a session (matches Python reference). Context buffer likewise stays zero
// at the very first frame.

use anyhow::{bail, Context, Result};
use clap::Parser;
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use ndarray::{Array1, Array3};
use ort::value::TensorRef;
use rubato::{Resampler, SincFixedIn, SincInterpolationParameters, SincInterpolationType, WindowFunction};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

// ═══════════════════════════════════════════════════════════════════════════════
// CONSTANTS
// ═══════════════════════════════════════════════════════════════════════════════

const SAMPLE_RATE: u32 = 16_000;
const FRAME_SAMPLES: usize = 512; // 32 ms at 16 kHz
const CONTEXT_SAMPLES: usize = 64; // 4 ms context prepended per v5 spec
const INPUT_SAMPLES: usize = FRAME_SAMPLES + CONTEXT_SAMPLES; // 576 total
const STATE_SHAPE: [i64; 3] = [2, 1, 128];
const STATE_ELEMENTS: usize = 2 * 1 * 128; // 256 f32 values

// ═══════════════════════════════════════════════════════════════════════════════
// CLI
// ═══════════════════════════════════════════════════════════════════════════════

#[derive(Parser, Debug)]
#[command(name = "silero-vad-spike", about = "Spike #19: Silero VAD v5 far-field validation")]
struct Args {
    /// Gate to run: 0=load-check, 1=WAV latency (floor), 2=WAV false-positive,
    ///              3=WAV false-negative, 4=live-mic real-time (REQUIRED for latency)
    #[arg(long)]
    gate: u8,

    /// Absolute path to silero_vad.onnx (v5 model from snakers4/silero-vad)
    #[arg(long)]
    model_path: PathBuf,

    /// WAV file path (required for gates 1, 2, 3) — must be 16 kHz mono
    #[arg(long)]
    wav_path: Option<PathBuf>,

    /// Gate 2/3 scenario label printed in the report (e.g. hvac, keyboard, room_rest,
    ///   fn_normal, fn_soft, fn_breathe)
    #[arg(long, default_value = "unknown")]
    scenario: String,

    /// Gate 3: wall-clock second where annotated speech STARTS in the WAV
    #[arg(long, default_value_t = 0.0)]
    speech_start_s: f64,

    /// Gate 3: wall-clock second where annotated speech ENDS in the WAV
    #[arg(long, default_value_t = 999.0)]
    speech_end_s: f64,

    /// Detection threshold — evaluated at 0.3, 0.4, 0.5 in all gate reports;
    /// this value is used for binary voice/silence decisions in gate 4 output
    #[arg(long, default_value_t = 0.5)]
    threshold: f64,

    /// Gate 4: capture duration in seconds
    #[arg(long, default_value_t = 30)]
    duration_s: u64,
}

// ═══════════════════════════════════════════════════════════════════════════════
// SILERO SESSION
// ═══════════════════════════════════════════════════════════════════════════════

struct SileroVad {
    session: ort::session::Session,
    /// GRU hidden state, flattened row-major [2, 1, 128].
    state: Vec<f32>,
    /// Last 64 samples from the previous frame (context buffer).
    context: Vec<f32>,
}

impl SileroVad {
    fn new(model_path: &Path) -> Result<Self> {
        let session = ort::session::Session::builder()
            .context("Failed to build ORT session builder")?
            .commit_from_file(model_path)
            .with_context(|| format!("Failed to load model from {:?}", model_path))?;
        Ok(Self {
            session,
            state: vec![0.0f32; STATE_ELEMENTS],
            context: vec![0.0f32; CONTEXT_SAMPLES],
        })
    }

    /// Process one 512-sample frame. Returns voice probability in [0, 1].
    ///
    /// The caller must pass exactly FRAME_SAMPLES (512) new samples at 16 kHz mono.
    /// Context management is internal: the previous 64 samples are prepended
    /// automatically before each inference call, matching the v5 Python reference.
    fn process(&mut self, new_samples: &[f32]) -> Result<f32> {
        assert_eq!(new_samples.len(), FRAME_SAMPLES, "frame must be exactly 512 samples");

        // Build input: [context(64) || new_samples(512)] = 576 total
        let mut input_data = Vec::with_capacity(INPUT_SAMPLES);
        input_data.extend_from_slice(&self.context);
        input_data.extend_from_slice(new_samples);

        // ORT input tensors
        let input_arr = Array1::from_vec(input_data)
            .into_shape_with_order((1, INPUT_SAMPLES))
            .context("reshape input")?;
        let state_arr = Array3::from_shape_vec(
            [STATE_SHAPE[0] as usize, STATE_SHAPE[1] as usize, STATE_SHAPE[2] as usize],
            self.state.clone(),
        )
        .context("reshape state")?;
        let sr_arr = Array1::from_vec(vec![SAMPLE_RATE as i64]);

        let input_ref = TensorRef::<f32>::from_array_view(input_arr.view())
            .context("create input TensorRef")?;
        let state_ref = TensorRef::<f32>::from_array_view(state_arr.view())
            .context("create state TensorRef")?;
        let sr_ref = TensorRef::<i64>::from_array_view(sr_arr.view())
            .context("create sr TensorRef")?;

        let outputs = self
            .session
            .run(ort::inputs![
                "input" => input_ref,
                "state" => state_ref,
                "sr"    => sr_ref,
            ])
            .context("ort session run")?;

        // Extract probability (output 0)
        let prob_arr = outputs[0].try_extract_array::<f32>().context("extract prob")?;
        let prob = prob_arr.iter().next().copied().unwrap_or(0.0);

        // Extract updated state (output 1) and persist it
        let new_state_arr = outputs[1].try_extract_array::<f32>().context("extract state")?;
        self.state = new_state_arr.iter().cloned().collect();

        // Advance context: keep last 64 samples of the frame we just processed
        self.context
            .copy_from_slice(&new_samples[FRAME_SAMPLES - CONTEXT_SAMPLES..]);

        Ok(prob)
    }

    fn reset(&mut self) {
        self.state = vec![0.0f32; STATE_ELEMENTS];
        self.context = vec![0.0f32; CONTEXT_SAMPLES];
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// WAV LOADING
// ═══════════════════════════════════════════════════════════════════════════════

fn load_wav_16k(path: &Path) -> Result<Vec<f32>> {
    let mut reader = hound::WavReader::open(path)
        .with_context(|| format!("Cannot open WAV: {:?}", path))?;
    let spec = reader.spec();
    if spec.sample_rate != SAMPLE_RATE {
        bail!(
            "WAV must be 16 kHz, got {} Hz. Resample with:\n  ffmpeg -i {:?} -ar 16000 -ac 1 out.wav",
            spec.sample_rate,
            path
        );
    }
    if spec.channels != 1 {
        bail!("WAV must be mono (1 channel), got {}", spec.channels);
    }
    let samples: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Float => reader
            .samples::<f32>()
            .collect::<hound::Result<Vec<_>>>()
            .context("read f32 samples")?,
        hound::SampleFormat::Int => reader
            .samples::<i16>()
            .collect::<hound::Result<Vec<_>>>()
            .context("read i16 samples")?
            .into_iter()
            .map(|s| s as f32 / 32768.0)
            .collect(),
    };
    Ok(samples)
}

/// Run all FRAME_SAMPLES-sized frames through the model.
/// Returns a vec of per-frame probabilities.
fn run_frames(vad: &mut SileroVad, samples: &[f32]) -> Result<Vec<f32>> {
    let n_frames = samples.len() / FRAME_SAMPLES;
    let mut probs = Vec::with_capacity(n_frames);
    for i in 0..n_frames {
        let frame = &samples[i * FRAME_SAMPLES..(i + 1) * FRAME_SAMPLES];
        probs.push(vad.process(frame)?);
    }
    Ok(probs)
}

// ═══════════════════════════════════════════════════════════════════════════════
// GATE 0 — MODEL LOAD + SINGLE FRAME SMOKE TEST
// ═══════════════════════════════════════════════════════════════════════════════

fn gate0(args: &Args) -> Result<()> {
    println!("=== GATE 0: model load + single silent frame ===");
    let mut vad = SileroVad::new(&args.model_path)?;
    println!("  model loaded from {:?}", args.model_path);

    let silent = vec![0.0f32; FRAME_SAMPLES];
    let prob = vad.process(&silent)?;
    println!("  silent frame → prob={:.4}", prob);
    println!("  state elements: {} (expect 256)", vad.state.len());
    println!("  context elements: {} (expect 64)", vad.context.len());

    // Verify output is a valid probability
    if !(0.0..=1.0).contains(&prob) {
        bail!("probability out of [0,1] range: {}", prob);
    }
    if vad.state.len() != STATE_ELEMENTS {
        bail!("state size mismatch: got {}, want {}", vad.state.len(), STATE_ELEMENTS);
    }

    // Run a second frame to confirm state update path works
    let prob2 = vad.process(&silent)?;
    println!("  second silent frame → prob={:.4}", prob2);
    println!("GATE 0 PASS");
    Ok(())
}

// ═══════════════════════════════════════════════════════════════════════════════
// GATE 1 — WAV ALGORITHMIC LATENCY (LOWER BOUND — NOT REAL-WORLD)
// ═══════════════════════════════════════════════════════════════════════════════
//
// Protocol: WAV must be a clap-start recording.
//   - 1 s silence
//   - 1 sharp clap (loud transient)
//   - 0.5 s gap
//   - Speech begins
//   - 5–10 s speech
//   - Silence for offset measurement
//
// The harness auto-detects the clap as the frame with peak absolute amplitude.
// Speech-start is estimated as clap_frame + 16 frames (0.5 s).

fn gate1(args: &Args) -> Result<()> {
    println!("=== GATE 1: WAV algorithmic latency (lower bound — real-world will be higher) ===");
    let wav_path = args.wav_path.as_ref().context("--wav-path required for gate 1")?;
    let samples = load_wav_16k(wav_path)?;
    println!("  loaded {} samples ({:.1} s)", samples.len(), samples.len() as f64 / SAMPLE_RATE as f64);

    let mut vad = SileroVad::new(&args.model_path)?;
    let n_frames = samples.len() / FRAME_SAMPLES;

    // Find clap: frame with highest peak absolute amplitude
    let mut clap_frame = 0usize;
    let mut clap_peak = 0.0f32;
    for i in 0..n_frames {
        let frame = &samples[i * FRAME_SAMPLES..(i + 1) * FRAME_SAMPLES];
        let peak = frame.iter().map(|s| s.abs()).fold(0.0f32, f32::max);
        if peak > clap_peak {
            clap_peak = peak;
            clap_frame = i;
        }
    }
    let clap_ms = clap_frame as f64 * 32.0;
    println!("  clap detected: frame {} ({:.0} ms, peak={:.3})", clap_frame, clap_ms, clap_peak);

    // Estimated speech-start frame = clap + ~16 frames (0.5 s gap)
    let speech_start_frame = (clap_frame + 16).min(n_frames.saturating_sub(1));
    println!(
        "  speech start estimated: frame {} ({:.0} ms)",
        speech_start_frame,
        speech_start_frame as f64 * 32.0
    );

    // Reset VAD and run all frames, noting the first frame where prob > threshold after speech_start
    for threshold in [0.3f64, 0.4, 0.5] {
        vad.reset();
        let probs = run_frames(&mut vad, &samples)?;

        // Onset: first frame at or after speech_start where prob > threshold
        let onset_frame = probs
            .iter()
            .enumerate()
            .skip(speech_start_frame)
            .find(|(_, &p)| p as f64 > threshold)
            .map(|(i, _)| i);

        let onset_latency_ms = onset_frame.map(|f| (f - speech_start_frame) as f64 * 32.0);

        // Offset: find end of speech window (first sustained run of low-prob after peak activity)
        // Heuristic: first frame >= speech_start+10 frames where prob < threshold for 5+ consecutive frames
        let silence_start_frame = {
            let mut result = None;
            let mut run = 0usize;
            for i in (speech_start_frame + 10)..probs.len() {
                if (probs[i] as f64) < threshold {
                    run += 1;
                    if run >= 5 {
                        result = Some(i - 4);
                        break;
                    }
                } else {
                    run = 0;
                }
            }
            result
        };

        let offset_frame = {
            // From silence_start, find first frame stably false for 5+ consecutive frames
            silence_start_frame.and_then(|start| {
                let mut run = 0usize;
                let mut result = None;
                for i in start..probs.len() {
                    if (probs[i] as f64) < threshold {
                        run += 1;
                        if run >= 5 && result.is_none() {
                            result = Some(i - 4);
                        }
                    } else {
                        run = 0;
                        result = None;
                    }
                }
                result
            })
        };

        let offset_from_silence = silence_start_frame
            .zip(offset_frame)
            .map(|(ss, of)| (of - ss) as f64 * 32.0);

        println!(
            "  threshold={:.1}: onset={}, offset_lag={}",
            threshold,
            onset_latency_ms
                .map(|ms| format!("{:.0} ms", ms))
                .unwrap_or_else(|| "NOT DETECTED".into()),
            offset_from_silence
                .map(|ms| format!("{:.0} ms", ms))
                .unwrap_or_else(|| "N/A".into()),
        );
    }

    println!();
    println!("  *** ALGORITHMIC FLOOR — onset latency on real-world mic will be higher ***");
    println!("  *** because frame-fill time (32 ms minimum) is NOT included here.      ***");
    println!("  *** Gate 4 (live mic) is the authoritative latency measurement.        ***");
    println!("GATE 1 COMPLETE");
    Ok(())
}

// ═══════════════════════════════════════════════════════════════════════════════
// GATE 2 — WAV FALSE POSITIVE RATE (silence scenarios)
// ═══════════════════════════════════════════════════════════════════════════════
//
// Scenarios (pass via --scenario): room_rest, keyboard, hvac
// Report: total frames, frames above threshold at 0.3/0.4/0.5, FP rate per threshold

fn gate2(args: &Args) -> Result<()> {
    println!("=== GATE 2: WAV false-positive rate — scenario: {} ===", args.scenario);
    let wav_path = args.wav_path.as_ref().context("--wav-path required for gate 2")?;
    let samples = load_wav_16k(wav_path)?;
    let n_frames = samples.len() / FRAME_SAMPLES;
    println!(
        "  loaded {} frames ({:.1} s) from {:?}",
        n_frames,
        n_frames as f64 * 32.0 / 1000.0,
        wav_path
    );

    for threshold in [0.3f64, 0.4, 0.5] {
        let mut vad = SileroVad::new(&args.model_path)?;
        let probs = run_frames(&mut vad, &samples)?;
        let fp_frames = probs.iter().filter(|&&p| (p as f64) > threshold).count();
        let fp_pct = fp_frames as f64 / n_frames as f64 * 100.0;

        let verdict = match args.scenario.as_str() {
            "hvac" | "room_rest" => {
                if fp_pct <= 5.0 { "PASS" } else { "FAIL" }
            }
            "keyboard" => {
                if fp_pct <= 10.0 { "PASS" } else { "FAIL" }
            }
            _ => {
                if fp_pct <= 5.0 { "PASS (generic)" } else { "FAIL (generic)" }
            }
        };

        println!(
            "  threshold={:.1}: {}/{} frames above threshold → FP={:.1}%  {}",
            threshold, fp_frames, n_frames, fp_pct, verdict
        );
    }
    println!("GATE 2 COMPLETE");
    Ok(())
}

// ═══════════════════════════════════════════════════════════════════════════════
// GATE 3 — WAV FALSE NEGATIVE / DETECTION RATE (speech scenarios)
// ═══════════════════════════════════════════════════════════════════════════════
//
// Scenarios: fn_normal, fn_soft, fn_breathe
// Requires --speech-start-s and --speech-end-s to annotate the speech window.
//
// Reports (per revision 2):
//   - Frame detection rate % within the annotated window
//   - Longest consecutive false-gap WITHIN the speech window (ms)
//     — if this gap > 2000 ms the pipeline would pause mid-sentence (FAIL)

fn gate3(args: &Args) -> Result<()> {
    println!("=== GATE 3: WAV false-negative / detection rate — scenario: {} ===", args.scenario);
    let wav_path = args.wav_path.as_ref().context("--wav-path required for gate 3")?;
    let samples = load_wav_16k(wav_path)?;
    let n_frames = samples.len() / FRAME_SAMPLES;
    println!(
        "  loaded {} frames ({:.1} s)",
        n_frames,
        n_frames as f64 * 32.0 / 1000.0
    );

    let speech_start_frame = (args.speech_start_s * SAMPLE_RATE as f64 / FRAME_SAMPLES as f64) as usize;
    let speech_end_frame = ((args.speech_end_s * SAMPLE_RATE as f64 / FRAME_SAMPLES as f64) as usize)
        .min(n_frames);
    let speech_frames = speech_end_frame.saturating_sub(speech_start_frame);

    if speech_frames == 0 {
        bail!("Speech window is empty — check --speech-start-s / --speech-end-s");
    }

    println!(
        "  speech window: frames {}–{} ({:.1}–{:.1} s, {} frames)",
        speech_start_frame,
        speech_end_frame,
        args.speech_start_s,
        args.speech_end_s,
        speech_frames
    );

    for threshold in [0.3f64, 0.4, 0.5] {
        let mut vad = SileroVad::new(&args.model_path)?;
        let probs = run_frames(&mut vad, &samples)?;

        let window = &probs[speech_start_frame..speech_end_frame];

        let detected_frames = window.iter().filter(|&&p| (p as f64) > threshold).count();
        let detection_pct = detected_frames as f64 / speech_frames as f64 * 100.0;

        // Longest consecutive false-gap within the window
        let mut longest_false_gap_frames = 0usize;
        let mut current_false_run = 0usize;
        for &p in window {
            if (p as f64) <= threshold {
                current_false_run += 1;
                longest_false_gap_frames = longest_false_gap_frames.max(current_false_run);
            } else {
                current_false_run = 0;
            }
        }
        let longest_false_gap_ms = longest_false_gap_frames as f64 * 32.0;

        // Revision 2 pass/fail: the disqualifier is mid-sentence gap > 2000 ms
        // (production grace window), not the raw frame detection rate.
        let gap_verdict = if longest_false_gap_ms > 2000.0 {
            "FAIL — gap > 2 s grace window, pipeline would pause mid-sentence"
        } else if longest_false_gap_ms > 1000.0 {
            "WARN — gap > 1 s, close to grace boundary"
        } else {
            "PASS — gap within grace window"
        };

        let rate_verdict = match args.scenario.as_str() {
            "fn_normal" => if detection_pct >= 90.0 { "PASS" } else { "FAIL" },
            "fn_soft"   => if detection_pct >= 75.0 { "PASS" } else { "FAIL" },
            "fn_breathe" => if detection_pct >= 75.0 { "PASS" } else { "FAIL" },
            _ => if detection_pct >= 75.0 { "PASS" } else { "FAIL" },
        };

        println!(
            "  threshold={:.1}: detected={}/{} ({:.1}%)  {}  | longest_gap={:.0} ms  {}",
            threshold, detected_frames, speech_frames, detection_pct, rate_verdict,
            longest_false_gap_ms, gap_verdict
        );
    }

    println!("GATE 3 COMPLETE");
    Ok(())
}

// ═══════════════════════════════════════════════════════════════════════════════
// GATE 4 — LIVE MIC REAL-TIME (REQUIRED for latency judgment)
// ═══════════════════════════════════════════════════════════════════════════════
//
// Captures from the system default input device at its native rate via cpal.
// MacBook Air built-in mic does not support 16 kHz directly through cpal;
// we capture at the device's native rate (typically 44100 or 48000 Hz) and
// resample to 16 kHz using rubato's SincFixedIn resampler before feeding Silero.
//
// Output: per-frame log (timestamp, probability, VOICE/SILENCE), followed by
// a summary of observed onset/offset transitions.
//
// Onset latency measurement protocol:
//   1. Run gate 4 with --duration-s 30.
//   2. Sit at normal working distance from the MacBook built-in mic.
//   3. Wait for the "CAPTURING — speak now" prompt.
//   4. Snap or clap once, then begin speaking immediately after.
//   5. After the run, scan the log for the first VOICE frame after the clap
//      transient (identifiable as a brief high-prob spike). Count the frames
//      between the clap frame and the first sustained VOICE run.
//   6. Multiply by 32 ms/frame = onset latency (includes frame-fill time).
//   7. To measure offset: stop speaking abruptly, find the first SILENCE entry
//      in the transition log and measure to the frame when you stopped.
//
// NOTE: Gate 4 includes frame-fill latency (32 ms floor at 16 kHz after
// resampling) and resampler delay, which Gates 1–3 (WAV files) do not.
// This is the authoritative real-world latency measurement.

fn gate4(args: &Args) -> Result<()> {
    println!("=== GATE 4: live-mic real-time (REQUIRED for latency judgment) ===");
    println!("  duration: {} s  threshold (for VOICE/SILENCE label): {:.1}",
             args.duration_s, args.threshold);

    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .context("No default input device found")?;
    println!("  device: {}", device.name().unwrap_or_else(|_| "unknown".into()));

    // Use the device's native default config — MacBook Air mic does not accept
    // arbitrary sample rates through cpal; CoreAudio does not auto-convert here.
    let supported = device
        .default_input_config()
        .context("Cannot query default input config")?;
    let native_rate = supported.sample_rate().0;
    let native_channels = supported.channels() as usize;
    println!("  native rate: {} Hz, channels: {}", native_rate, native_channels);
    println!("  resampling {} Hz → 16000 Hz via rubato SincFixedIn", native_rate);

    let stream_config = cpal::StreamConfig {
        channels: native_channels as u16,
        sample_rate: cpal::SampleRate(native_rate),
        buffer_size: cpal::BufferSize::Default,
    };

    // rubato SincFixedIn resampler: native_rate → 16000 Hz, mono
    let ratio = SAMPLE_RATE as f64 / native_rate as f64;
    let sinc_params = SincInterpolationParameters {
        sinc_len: 64,
        f_cutoff: 0.90,
        interpolation: SincInterpolationType::Linear,
        oversampling_factor: 128,
        window: WindowFunction::BlackmanHarris2,
    };
    // chunk_size: number of INPUT samples to consume per resampler call
    // Target: produce FRAME_SAMPLES (512) output samples each call.
    let chunk_size_in = (FRAME_SAMPLES as f64 / ratio).ceil() as usize;
    let resampler: Arc<Mutex<SincFixedIn<f32>>> = Arc::new(Mutex::new(
        SincFixedIn::<f32>::new(ratio, 2.0, sinc_params, chunk_size_in, 1)
            .context("Failed to create rubato resampler")?,
    ));

    // Shared raw sample buffer (multichannel interleaved, native rate)
    let raw_buf: Arc<Mutex<Vec<f32>>> = Arc::new(Mutex::new(Vec::new()));
    let raw_for_cb = Arc::clone(&raw_buf);

    let stream = device
        .build_input_stream(
            &stream_config,
            move |data: &[f32], _: &cpal::InputCallbackInfo| {
                if let Ok(mut buf) = raw_for_cb.lock() {
                    buf.extend_from_slice(data);
                }
            },
            |err| eprintln!("cpal input error: {}", err),
            None,
        )
        .context("Failed to build input stream — ensure mic permission is granted")?;

    stream.play().context("Failed to start input stream")?;

    println!();
    println!("  CAPTURING — sit at normal working distance from the built-in mic.");
    println!("  Snap or clap once to mark onset, then begin speaking normally.");
    println!("  Watch the probability column. Clap appears as a brief spike, then");
    println!("  count frames from your speech start to the first VOICE label.");
    println!("  Press Ctrl+C or wait for the duration to end.");
    println!();
    println!("  {:>10}  {:>8}  {}", "time_ms", "prob", "signal");
    println!("  {}", "-".repeat(30));

    let start = Instant::now();
    let mut vad = SileroVad::new(&args.model_path)?;
    // mono_pending holds 16 kHz mono samples ready for Silero frame processing
    let mut mono_16k_pending: Vec<f32> = Vec::new();
    // native_pending holds raw multichannel native-rate samples before downmix/resample
    let mut native_pending: Vec<f32> = Vec::new();

    let mut frame_count = 0usize;
    let mut prev_voice = false;
    let mut onset_log: Vec<(f64, f64)> = Vec::new();
    let mut offset_log: Vec<(f64, f64)> = Vec::new();

    let deadline = Duration::from_secs(args.duration_s);

    loop {
        if start.elapsed() >= deadline {
            break;
        }

        // Drain raw samples from cpal callback
        {
            let mut buf = raw_buf.lock().unwrap();
            native_pending.extend_from_slice(&buf);
            buf.clear();
        }

        // Downmix to mono: take first channel of every frame
        // native_pending is interleaved: [ch0, ch1, ..., ch0, ch1, ...]
        while native_pending.len() >= native_channels * chunk_size_in {
            let block: Vec<f32> = native_pending.drain(..native_channels * chunk_size_in).collect();
            // downmix: average all channels
            let mono_in: Vec<f32> = block
                .chunks_exact(native_channels)
                .map(|frame| frame.iter().sum::<f32>() / native_channels as f32)
                .collect();

            // Resample mono_in (chunk_size_in samples at native_rate) → ~512 samples at 16 kHz
            let resampled = {
                let mut rs = resampler.lock().unwrap();
                rs.process(&[mono_in], None).context("resampler failed")?
            };
            // resampled is Vec<Vec<f32>> with 1 channel
            mono_16k_pending.extend_from_slice(&resampled[0]);
        }

        // Process complete 512-sample Silero frames
        while mono_16k_pending.len() >= FRAME_SAMPLES {
            let frame: Vec<f32> = mono_16k_pending.drain(..FRAME_SAMPLES).collect();
            let prob = vad.process(&frame)?;
            let time_ms = frame_count as f64 * 32.0;
            let voice = (prob as f64) > args.threshold;
            let signal = if voice { "VOICE  " } else { "SILENCE" };
            println!("  {:>10.0}  {:>8.4}  {}", time_ms, prob, signal);

            if voice && !prev_voice {
                onset_log.push((time_ms, prob as f64));
            }
            if !voice && prev_voice {
                offset_log.push((time_ms, prob as f64));
            }
            prev_voice = voice;
            frame_count += 1;
        }

        std::thread::sleep(Duration::from_millis(10));
    }

    drop(stream);

    println!();
    println!("=== GATE 4 SUMMARY ===");
    println!("  total frames: {}  ({:.1} s)", frame_count, frame_count as f64 * 32.0 / 1000.0);
    println!("  voice onset transitions (SILENCE→VOICE): {}", onset_log.len());
    for (t, p) in &onset_log {
        println!("    onset at t={:.0} ms (prob={:.4})", t, p);
    }
    println!("  voice offset transitions (VOICE→SILENCE): {}", offset_log.len());
    for (t, p) in &offset_log {
        println!("    offset at t={:.0} ms (prob={:.4})", t, p);
    }

    if onset_log.is_empty() {
        println!("  WARNING: no onset detected — check mic permission, volume, or threshold");
    }

    println!();
    println!("  Latency interpretation:");
    println!("    - Clap transient appears as a brief high-prob spike in the log");
    println!("    - Count frames from first speech frame to first VOICE label × 32 ms = onset lag");
    println!("    - Offset lag = first SILENCE transition time − when you stopped speaking");
    println!("    - Pass bar: onset ≤ 100 ms, offset stable within 2000 ms grace window");

    println!("GATE 4 COMPLETE");
    Ok(())
}

// ═══════════════════════════════════════════════════════════════════════════════
// MAIN
// ═══════════════════════════════════════════════════════════════════════════════

fn main() -> Result<()> {
    let args = Args::parse();

    // OQ-3 resolved: standalone binary, single ORT instance via download-binaries.
    // No parakeet-rs dep → no ORT version conflict.
    if !args.model_path.exists() {
        bail!(
            "Model not found at {:?}\n\
             Download the Silero VAD v5 ONNX model:\n\
             wget -P SileroVADSpike/models/ \\\n\
               'https://huggingface.co/onnx-community/silero-vad/resolve/main/onnx/silero_vad.onnx'",
            args.model_path
        );
    }

    match args.gate {
        0 => gate0(&args),
        1 => gate1(&args),
        2 => gate2(&args),
        3 => gate3(&args),
        4 => gate4(&args),
        g => bail!("Unknown gate {}. Valid: 0, 1, 2, 3, 4", g),
    }
}
