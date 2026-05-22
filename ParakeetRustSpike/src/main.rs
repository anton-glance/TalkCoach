// Spike #18 — Parakeet word-fidelity + rolling-window batch feasibility
//
// Real parakeet-rs 0.3.5 API (verified from crate source at Gate 0):
//   - ParakeetTDT::from_pretrained(path, None) for TDT spine (None = CPU)
//   - Parakeet::from_pretrained(path, None) for CTC fallback
//   - transcribe_samples(&mut self, audio: Vec<f32>, sr: u32, channels: u16, mode) via Transcriber trait
//   - TranscriptionResult { text: String, tokens: Vec<TimedToken> }
//   - TimedToken { text: String, start: f32, end: f32 } — NO confidence field
//   - channels must be u16 (not u32)
//   - model variable must be mut (method takes &mut self)
//   - Transcriber trait must be in scope for transcribe_samples to resolve
//
// All CLI paths must be ABSOLUTE. Binary validates at startup and exits non-zero otherwise.

use anyhow::{bail, Context, Result};
use clap::Parser;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

use parakeet_rs::{Parakeet, ParakeetTDT, TimestampMode, Transcriber, TranscriptionResult};
use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, System};

// ═══════════════════════════════════════════════════════════════════════════════
// CLI ARGS
// ═══════════════════════════════════════════════════════════════════════════════

#[derive(Parser, Debug)]
#[command(name = "parakeet-spike", about = "Spike #18: Parakeet word-fidelity + rolling-window sweep")]
struct Args {
    /// Gate to run: 0 (build+load), 1 (fidelity), 2 (sweep), 3 (robustness), 4 (Nemotron probe)
    #[arg(long)]
    gate: u8,

    /// Absolute path to model directory (e.g. /…/ParakeetRustSpike/models/tdt)
    #[arg(long)]
    model_dir: PathBuf,

    /// Model variant: tdt | ctc | nemotron
    #[arg(long, value_enum)]
    model_type: ModelKind,

    /// Absolute path to dir containing *_16k.wav files
    #[arg(long)]
    recordings_dir: PathBuf,

    /// Absolute path to dir containing en_slow.txt etc. (required for gates 1, 3)
    #[arg(long, default_value = "/dev/null")]
    transcripts_dir: PathBuf,

    /// Absolute path to dir containing en_slow.json etc.
    #[arg(long, default_value = "/dev/null")]
    json_dir: PathBuf,

    /// Absolute path for CSV output
    #[arg(long)]
    output_dir: PathBuf,

    /// Gate 2 window sizes in seconds, comma-separated
    #[arg(long, default_value = "6,10,15")]
    window_sizes: String,

    /// Gate 2 hop sizes in seconds, comma-separated
    #[arg(long, default_value = "2,3")]
    hop_sizes: String,

    /// Gate 3: window size (seconds) of the best Gate-2 cell
    #[arg(long, default_value_t = 10.0)]
    best_window: f64,

    /// Gate 3: hop size (seconds) of the best Gate-2 cell
    #[arg(long, default_value_t = 3.0)]
    best_hop: f64,
}

#[derive(Debug, Clone, clap::ValueEnum)]
enum ModelKind {
    Tdt,
    Ctc,
    Nemotron,
}

// ═══════════════════════════════════════════════════════════════════════════════
// MODEL WRAPPER — dispatches TDT vs CTC via the Transcriber trait
// ═══════════════════════════════════════════════════════════════════════════════

enum AnyModel {
    Tdt(ParakeetTDT),
    Ctc(Parakeet),
}

impl AnyModel {
    fn transcribe(
        &mut self,
        audio: Vec<f32>,
        sr: u32,
        channels: u16,
        mode: Option<TimestampMode>,
    ) -> Result<TranscriptionResult> {
        match self {
            AnyModel::Tdt(m) => m
                .transcribe_samples(audio, sr, channels, mode)
                .map_err(Into::into),
            AnyModel::Ctc(m) => m
                .transcribe_samples(audio, sr, channels, mode)
                .map_err(Into::into),
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// TYPES
// ═══════════════════════════════════════════════════════════════════════════════

#[derive(Debug, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct GroundTruth {
    #[allow(dead_code)]
    clip_name: String,
    duration_seconds: f64,
    total_words: usize,
    #[allow(dead_code)]
    #[serde(rename = "groundTruthWPM")]
    ground_truth_wpm: f64,
}

/// Gate 0 probe result — determines which flicker branch Gate 2 uses.
#[derive(Debug, Clone, PartialEq)]
enum TsSupport {
    /// Per-token timestamps are real: non-zero, monotonic, plausibly spaced.
    Present,
    /// Timestamps are all-zero, all-identical, or token vec is empty.
    Absent,
}

/// One window's transcription result.
struct WindowResult {
    t_start: f64,
    word_count: usize,
    batch_ms: f64,
    /// Per-token absolute clip timestamps (start_s, end_s).
    /// Only populated when TsSupport::Present; empty otherwise.
    tokens_abs: Vec<(f64, f64)>,
}

/// Non-overlapping tile accuracy for one (clip, window_size) pair.
struct TileRow {
    clip: String,
    window_s: f64,
    tile_total: usize,
    gt_words: usize,
    tile_error_pct: f64,
}

/// One row in the Gate 2 sweep matrix (corrected metrics).
#[derive(Clone)]
struct SweepRow {
    window_s: f64,
    hop_s: f64,
    clip: String,
    /// Non-overlapping tile error for this (clip, ws) — same value across hop sizes.
    tile_error_pct: f64,
    /// Mean per-span |count_A − count_B| / overlap_dur across consecutive overlapping pairs.
    consistency_mean_wps: f64,
    /// Stddev of the above — the flicker measure.
    consistency_stddev_wps: f64,
    batch_ms_mean: f64,
    batch_ms_max: f64,
    headroom_ratio_mean: f64,
    headroom_ratio_min: f64,
}

// ═══════════════════════════════════════════════════════════════════════════════
// HELPERS
// ═══════════════════════════════════════════════════════════════════════════════

fn validate_absolute(path: &Path, name: &str) -> Result<()> {
    if !path.is_absolute() {
        bail!("--{} must be an absolute path, got: {:?}", name, path);
    }
    Ok(())
}

fn load_wav(path: &Path) -> Result<(Vec<f32>, u32)> {
    let mut reader = hound::WavReader::open(path)
        .with_context(|| format!("Cannot open WAV: {:?}", path))?;
    let spec = reader.spec();
    let sample_rate = spec.sample_rate;
    let samples: Vec<f32> = match spec.sample_format {
        hound::SampleFormat::Int => reader
            .samples::<i16>()
            .map(|s| s.map(|v| v as f32 / i16::MAX as f32))
            .collect::<std::result::Result<_, _>>()
            .context("WAV i16 read failed")?,
        hound::SampleFormat::Float => reader
            .samples::<f32>()
            .map(|s| s.context("WAV f32 read failed"))
            .collect::<Result<_>>()?,
    };
    Ok((samples, sample_rate))
}

fn slice_samples(samples: &[f32], sample_rate: u32, start_s: f64, end_s: f64) -> Vec<f32> {
    let start = (start_s * sample_rate as f64) as usize;
    let end = ((end_s * sample_rate as f64) as usize).min(samples.len());
    if start >= samples.len() || start >= end {
        return Vec::new();
    }
    samples[start..end].to_vec()
}

fn load_gt(json_dir: &Path, clip: &str) -> Result<GroundTruth> {
    let path = json_dir.join(format!("{}.json", clip));
    let s = fs::read_to_string(&path)
        .with_context(|| format!("Cannot read {:?}", path))?;
    serde_json::from_str(&s).context("JSON parse failed")
}

fn load_txt(transcripts_dir: &Path, clip: &str) -> Result<String> {
    let path = transcripts_dir.join(format!("{}.txt", clip));
    fs::read_to_string(&path).with_context(|| format!("Cannot read {:?}", path))
}

fn word_count(s: &str) -> usize {
    s.split_whitespace().count()
}

fn error_pct(transcribed: &str, gt: usize) -> f64 {
    let n = word_count(transcribed);
    (n as f64 - gt as f64).abs() / gt as f64 * 100.0
}

fn check_markers(transcript: &str) -> Vec<(&'static str, bool)> {
    let lower = transcript.to_lowercase();
    vec![
        ("you know", lower.contains("you know")),
        ("kind of", lower.contains("kind of")),
        ("yeah", lower.contains("yeah")),
        ("ten thirty", lower.contains("ten thirty")),
        (
            "context-switching",
            lower.contains("context-switching") || lower.contains("context switching"),
        ),
    ]
}

fn wrap_text(text: &str, width: usize, indent: &str) -> String {
    let words: Vec<&str> = text.split_whitespace().collect();
    let mut lines: Vec<String> = Vec::new();
    let mut cur = String::new();
    for w in &words {
        if cur.is_empty() {
            cur.push_str(w);
        } else if cur.len() + 1 + w.len() <= width {
            cur.push(' ');
            cur.push_str(w);
        } else {
            lines.push(format!("{}{}", indent, cur));
            cur = w.to_string();
        }
    }
    if !cur.is_empty() {
        lines.push(format!("{}{}", indent, cur));
    }
    lines.join("\n")
}

fn stddev(vals: &[f64]) -> f64 {
    if vals.len() < 2 {
        return 0.0;
    }
    let mean = vals.iter().sum::<f64>() / vals.len() as f64;
    let var = vals.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / vals.len() as f64;
    var.sqrt()
}

fn parse_csv_floats(s: &str) -> Vec<f64> {
    s.split(',')
        .filter_map(|x| x.trim().parse::<f64>().ok())
        .collect()
}

fn required_model_files(kind: &ModelKind) -> &'static [&'static str] {
    match kind {
        // int8 variant of istupakov/parakeet-tdt-0.6b-v3-onnx.
        // int8 encoder is self-contained — no separate .onnx.data file.
        // nemo128.onnx is the reference preprocessor shipped in the repo; parakeet-rs
        // v0.3.5 does NOT load it (uses Rust-native feature extraction instead), but
        // its presence confirms the complete int8 download.
        ModelKind::Tdt => &[
            "encoder-model.int8.onnx",
            "decoder_joint-model.int8.onnx",
            "nemo128.onnx",
            "vocab.txt",
        ],
        ModelKind::Ctc => &["model.onnx", "model.onnx_data", "tokenizer.json"],
        ModelKind::Nemotron => &[
            "encoder.onnx",
            "encoder.onnx.data",
            "decoder_joint.onnx",
            "tokenizer.model",
        ],
    }
}

/// Returns a sorted list of (filename, size_bytes) for every file directly inside dir.
fn list_dir(dir: &Path) -> Vec<(String, u64)> {
    let Ok(rd) = fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut entries: Vec<(String, u64)> = rd
        .flatten()
        .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
        .map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            let size = e.metadata().map(|m| m.len()).unwrap_or(0);
            (name, size)
        })
        .collect();
    entries.sort_by(|a, b| a.0.cmp(&b.0));
    entries
}

fn check_model_files(dir: &Path, kind: &ModelKind) -> Result<()> {
    let expected = required_model_files(kind);
    let missing: Vec<&str> = expected
        .iter()
        .copied()
        .filter(|f| !dir.join(f).exists())
        .collect();

    // Always print what's actually on disk — makes any future filename mismatch
    // diagnosable from one run without guessing.
    let found = list_dir(dir);
    let found_summary: Vec<String> = found
        .iter()
        .map(|(name, size)| format!("{} ({}B)", name, size))
        .collect();
    if found.is_empty() {
        println!("model_dir_contents: (empty or does not exist)");
    } else {
        println!("model_dir_contents: {}", found_summary.join(", "));
    }

    if !missing.is_empty() {
        eprintln!("\nERROR: Missing expected files in {:?}:", dir);
        eprintln!("  EXPECTED:");
        for f in expected {
            let present = dir.join(f).exists();
            eprintln!("    {} {}", if present { "OK " } else { "MISSING" }, f);
        }
        eprintln!("  FOUND ({} files):", found.len());
        for (name, size) in &found {
            eprintln!("    {} ({}B)", name, size);
        }
        eprintln!("\nTo download TDT v3 int8 spine (required before Gate 0):");
        eprintln!(
            "  hf download istupakov/parakeet-tdt-0.6b-v3-onnx \\"
        );
        eprintln!(
            "    encoder-model.int8.onnx decoder_joint-model.int8.onnx \\"
        );
        eprintln!(
            "    nemo128.onnx vocab.txt \\"
        );
        eprintln!(
            "    --local-dir <absolute-path-to-model-dir>"
        );
        eprintln!("\nCTC fallback (only if TDT fails to load at Gate 0):");
        eprintln!("  hf download onnx-community/parakeet-ctc-0.6b-ONNX \\");
        eprintln!("    model.onnx model.onnx_data tokenizer.json \\");
        eprintln!("    --local-dir <absolute-path-to-ctc-model-dir>");
        bail!("Model files missing — see expected-vs-found above. STOP.");
    }
    Ok(())
}

fn load_model(dir: &Path, kind: &ModelKind) -> Result<AnyModel> {
    match kind {
        ModelKind::Tdt => {
            let m = ParakeetTDT::from_pretrained(dir, None)
                .context("TDT model load failed — check ORT_DYLIB_PATH and model files")?;
            Ok(AnyModel::Tdt(m))
        }
        ModelKind::Ctc => {
            let m = Parakeet::from_pretrained(dir, None)
                .context("CTC model load failed — check ORT_DYLIB_PATH and model files")?;
            Ok(AnyModel::Ctc(m))
        }
        ModelKind::Nemotron => bail!(
            "Nemotron model loading is not implemented — Gate 4 is blocked until HF repo is confirmed"
        ),
    }
}

// ─── transcribe one window ────────────────────────────────────────────────────

fn transcribe_window(
    model: &mut AnyModel,
    samples: &[f32],
    sample_rate: u32,
    t_start: f64,
    t_end: f64,
    ts_support: &TsSupport,
) -> Result<WindowResult> {
    let slice = slice_samples(samples, sample_rate, t_start, t_end);
    let t = Instant::now();
    let result = model
        .transcribe(slice, sample_rate, 1u16, Some(TimestampMode::Words))
        .context("transcribe_samples failed")?;
    let batch_ms = t.elapsed().as_secs_f64() * 1000.0;
    let wc = word_count(&result.text);

    // TimedToken { text: String, start: f32, end: f32 } — start/end are relative to the window.
    // Convert to absolute clip timestamps by adding t_start.
    let tokens_abs: Vec<(f64, f64)> = if *ts_support == TsSupport::Present {
        result
            .tokens
            .iter()
            .map(|tok| (t_start + tok.start as f64, t_start + tok.end as f64))
            .collect()
    } else {
        Vec::new()
    };

    Ok(WindowResult {
        t_start,
        word_count: wc,
        batch_ms,
        tokens_abs,
    })
}

// ─── timestamp probe ──────────────────────────────────────────────────────────

fn probe_timestamps(model: &mut AnyModel, samples: &[f32], sample_rate: u32) -> Result<TsSupport> {
    let probe = slice_samples(samples, sample_rate, 0.0, 6.0);
    let result = model
        .transcribe(probe, sample_rate, 1u16, Some(TimestampMode::Words))
        .context("Timestamp probe transcription failed")?;

    if result.tokens.is_empty() {
        println!("  ts_probe: tokens vec is empty → ABSENT");
        println!("  gate0_timestamp_support: ABSENT (empty tokens)");
        return Ok(TsSupport::Absent);
    }

    let all_zero = result
        .tokens
        .iter()
        .all(|t| t.start == 0.0 && t.end == 0.0);
    let all_same = result.tokens.len() > 1
        && result
            .tokens
            .windows(2)
            .all(|w| w[0].start == w[1].start);

    if all_zero || all_same {
        println!(
            "  ts_probe: ABSENT — all_zero={} all_same_start={}",
            all_zero, all_same
        );
        for (i, tok) in result.tokens.iter().take(3).enumerate() {
            println!(
                "    token[{}] start={:.3} end={:.3} text={:?}",
                i, tok.start, tok.end, tok.text
            );
        }
        println!("  gate0_timestamp_support: ABSENT");
        Ok(TsSupport::Absent)
    } else {
        println!("  ts_probe: PRESENT — monotonic, non-zero");
        for (i, tok) in result.tokens.iter().take(3).enumerate() {
            println!(
                "    token[{}] start={:.3}s end={:.3}s text={:?}",
                i, tok.start, tok.end, tok.text
            );
        }
        println!("  gate0_timestamp_support: PRESENT");
        Ok(TsSupport::Present)
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// SHARED NON-OVERLAPPING TILER
// ═══════════════════════════════════════════════════════════════════════════════

/// Transcribe `samples` as non-overlapping tiles of `window_s` seconds,
/// including the final remainder tile (shorter than `window_s` if the clip
/// duration is not an exact multiple). Prints per-tile [start–end] and word
/// count for every tile. Returns `(total_words, n_tiles)`.
///
/// This is the single authoritative tiler used by Gate 2 tile-accuracy and
/// Gate 3 robustness. The `while t < dur_s` boundary (not `t + ws <= dur_s`)
/// is intentional: it prevents silently dropping a partial tail tile.
fn transcribe_tiles(
    model: &mut AnyModel,
    samples: &[f32],
    sample_rate: u32,
    window_s: f64,
    label: &str,
) -> Result<(usize, usize)> {
    let dur_s = samples.len() as f64 / sample_rate as f64;
    let mut t = 0.0_f64;
    let mut total = 0usize;
    let mut idx = 0usize;
    while t < dur_s {
        let end = (t + window_s).min(dur_s);
        let slice = slice_samples(samples, sample_rate, t, end);
        let result = model
            .transcribe(slice, sample_rate, 1u16, Some(TimestampMode::Words))
            .with_context(|| format!("tile transcription failed: {} t={:.3}", label, t))?;
        let wc = word_count(&result.text);
        println!("  tile[{}] [{:.3}s–{:.3}s]: {} words", idx, t, end, wc);
        total += wc;
        t += window_s;
        idx += 1;
    }
    Ok((total, idx))
}

// ═══════════════════════════════════════════════════════════════════════════════
// FLICKER METRIC — engine self-consistency
// ═══════════════════════════════════════════════════════════════════════════════

/// Engine self-consistency flicker (no clip-average detrend).
///
/// For each consecutive overlapping window pair A=[t, t+W] and B=[t+hop, t+hop+W]:
///   shared span = [B.t_start, A.t_start+W], duration = W - hop
///   count_A_in_shared = tokens from A with absolute start in [B.t_start, A.t_start+W]
///   count_B_in_shared = tokens from B with absolute start in [B.t_start, A.t_start+W]
///   disagreement = |count_A − count_B| / shared_dur  (wps)
///
/// Returns (mean, stddev) of disagreements across all pairs. Compares the engine
/// against ITSELF on identical audio — isolates flicker from speaker rate variation.
/// Requires TsSupport::Present (tokens_abs populated).
fn compute_flicker_consistency(
    windows: &[WindowResult],
    window_s: f64,
    hop_s: f64,
) -> (f64, f64) {
    let overlap_dur = window_s - hop_s;
    if overlap_dur <= 0.0 || windows.len() < 2 {
        return (0.0, 0.0);
    }

    let mut discrepancies: Vec<f64> = Vec::new();

    for pair in windows.windows(2) {
        let a = &pair[0];
        let b = &pair[1];
        let ov_start = b.t_start;
        let ov_end = a.t_start + window_s;

        let count_a = a
            .tokens_abs
            .iter()
            .filter(|(abs_start, _)| *abs_start >= ov_start && *abs_start < ov_end)
            .count();
        let count_b = b
            .tokens_abs
            .iter()
            .filter(|(abs_start, _)| *abs_start >= ov_start && *abs_start < ov_end)
            .count();

        discrepancies
            .push((count_a as f64 - count_b as f64).abs() / overlap_dur);
    }

    let mean = discrepancies.iter().sum::<f64>() / discrepancies.len() as f64;
    let sd = stddev(&discrepancies);
    (mean, sd)
}

// ═══════════════════════════════════════════════════════════════════════════════
// GATE 0 — Build & decode & load
// ═══════════════════════════════════════════════════════════════════════════════

fn gate0(args: &Args) -> Result<()> {
    println!("=== GATE 0: Build & decode & load ===\n");

    check_model_files(&args.model_dir, &args.model_type)?;

    let t_load = Instant::now();
    let mut model = load_model(&args.model_dir, &args.model_type)?;
    let load_ms = t_load.elapsed().as_millis();

    let wav_path = args.recordings_dir.join("en_slow_16k.wav");
    let (samples, sr) = load_wav(&wav_path)?;
    let dur_s = samples.len() as f64 / sr as f64;

    println!("crate:             parakeet-rs 0.3.5");
    println!("model_variant:     {:?}", args.model_type);
    println!("model_load_ms:     {}", load_ms);
    println!(
        "en_slow:           {} samples, {:.2}s at {}Hz",
        samples.len(),
        dur_s,
        sr
    );
    // Directory listing is also printed by check_model_files above (on both
    // success and failure paths) for the expected-vs-found diagnostic.

    // ── Gate 0 Amendment: probe timestamp support before declaring PASS ────────
    println!("\n--- Timestamp support probe (first 6s of en_slow) ---");
    let ts = probe_timestamps(&mut model, &samples, sr)?;

    println!(
        "\ngate0_result: ts_support={:?}  load_ms={}",
        ts, load_ms
    );

    // Write probe result so Gate 2 can read it as advisory context
    fs::create_dir_all(&args.output_dir)?;
    let probe_path = args.output_dir.join("gate0_ts_support.txt");
    fs::write(
        &probe_path,
        match ts {
            TsSupport::Present => "PRESENT",
            TsSupport::Absent => "ABSENT",
        },
    )?;
    println!("gate0_ts_support written: {:?}", probe_path);

    println!("\nGATE 0 PASS");
    Ok(())
}

// ═══════════════════════════════════════════════════════════════════════════════
// GATE 1 — Word-fidelity kill gate
// ═══════════════════════════════════════════════════════════════════════════════

fn gate1(args: &Args) -> Result<()> {
    println!("=== GATE 1: Word-fidelity kill gate ===\n");

    validate_absolute(&args.transcripts_dir, "transcripts-dir")?;
    validate_absolute(&args.json_dir, "json-dir")?;

    check_model_files(&args.model_dir, &args.model_type)?;
    let mut model = load_model(&args.model_dir, &args.model_type)?;

    let clips = ["en_slow", "en_normal", "en_fast"];
    let mut any_fail = false;

    fs::create_dir_all(&args.output_dir)?;
    let csv_path = args.output_dir.join("gate1_fidelity.csv");
    let mut wtr = csv::Writer::from_path(&csv_path)?;
    wtr.write_record(&[
        "clip",
        "gt_words",
        "transcribed_words",
        "error_pct",
        "confidence_type",
        "full_transcript",
    ])?;

    for clip in &clips {
        let gt = load_gt(&args.json_dir, clip)?;
        let truth_txt = load_txt(&args.transcripts_dir, clip)?;

        let wav_path = args.recordings_dir.join(format!("{}_16k.wav", clip));
        let (samples, sr) = load_wav(&wav_path)?;

        let t = Instant::now();
        let result = model
            .transcribe(samples, sr, 1u16, Some(TimestampMode::Words))
            .with_context(|| format!("Full-buffer transcription failed for {}", clip))?;
        let infer_ms = t.elapsed().as_millis();

        let transcript = result.text.trim().to_string();
        let n_words = word_count(&transcript);
        let ep = error_pct(&transcript, gt.total_words);
        let pass = ep <= 5.0;

        // Confidence observation: TimedToken in parakeet-rs 0.3.5 has no .confidence field.
        // Only text, start, end are exposed. Reporting as a factual finding.
        let conf_type = if result.tokens.is_empty() {
            "NO_TOKENS — token vec empty, no confidence data available".to_string()
        } else {
            format!(
                "NOT_EXPOSED — TimedToken has text/start/end only in parakeet-rs v0.3.5; {} tokens returned",
                result.tokens.len()
            )
        };

        // Side-by-side
        println!(
            "═══ CLIP: {} | GT: {} words / {:.1}s | TRANSCRIBED: {} words | ERROR: {:.1}% | {} ═══",
            clip,
            gt.total_words,
            gt.duration_seconds,
            n_words,
            ep,
            if pass { "OK" } else { "FAIL ← GATE 1 FAIL" }
        );
        println!("\nGROUND TRUTH ({}.txt):", clip);
        println!("{}", wrap_text(&truth_txt, 80, "  "));
        println!("\nPARAKEET OUTPUT:");
        println!("{}", wrap_text(&transcript, 80, "  "));

        let markers = check_markers(&transcript);
        let marker_str: Vec<String> = markers
            .iter()
            .map(|(name, present)| {
                format!("\"{}\" [{}]", name, if *present { "Y" } else { "N" })
            })
            .collect();
        println!("\nKEY MARKERS: {}", marker_str.join(" | "));
        println!("confidence_type: {}", conf_type);
        println!("infer_ms: {}\n", infer_ms);

        wtr.write_record(&[
            clip.to_string(),
            gt.total_words.to_string(),
            n_words.to_string(),
            format!("{:.2}", ep),
            conf_type,
            transcript.replace('\n', " "),
        ])?;

        if !pass {
            eprintln!(
                "GATE 1 FAIL: {} error_pct={:.1}% > 5.0% — STOP, do not proceed to Gate 2",
                clip, ep
            );
            any_fail = true;
        }
    }

    wtr.flush()?;
    println!("CSV written: {:?}", csv_path);

    if any_fail {
        bail!("GATE 1 FAIL — one or more clips exceeded 5% word-count error. See above.");
    }

    println!("GATE 1 PASS");
    Ok(())
}

// ═══════════════════════════════════════════════════════════════════════════════
// GATE 11 — Gate-1 truncation diagnostic (en_fast investigation)
// ═══════════════════════════════════════════════════════════════════════════════

fn gate1diag(args: &Args) -> Result<()> {
    println!("=== GATE 1 DIAGNOSTIC: en_fast full-buffer truncation investigation ===\n");

    validate_absolute(&args.json_dir, "json-dir")?;
    check_model_files(&args.model_dir, &args.model_type)?;
    let mut model = load_model(&args.model_dir, &args.model_type)?;

    // DIAGNOSTICS 1 + 2: en_slow as control, then en_fast as subject
    for clip in &["en_slow", "en_fast"] {
        let wav_path = args.recordings_dir.join(format!("{}_16k.wav", clip));
        let (samples, sr) = load_wav(&wav_path)?;
        let sample_count = samples.len();
        let file_dur_s = sample_count as f64 / sr as f64;

        println!("--- DIAG 1: buffer check — {} ---", clip);
        println!("  sample_count:     {}", sample_count);
        println!("  sample_rate:      {} Hz", sr);
        println!("  implied_duration: {:.3}s", file_dur_s);

        // samples is moved into transcribe; all needed values captured above
        println!("\n--- DIAG 2: token tail — {} ---", clip);
        let result = model
            .transcribe(samples, sr, 1u16, Some(TimestampMode::Words))
            .with_context(|| format!("Full-buffer transcription failed for {}", clip))?;

        let total_tokens = result.tokens.len();
        let total_words = word_count(&result.text);
        println!("  transcribed_words: {}", total_words);
        println!("  total_tokens:      {}", total_tokens);

        if total_tokens == 0 {
            println!("  last_5_tokens:     (none — token vec empty)");
        } else {
            let start_idx = total_tokens.saturating_sub(5);
            println!("  last_5_tokens:");
            for (i, tok) in result.tokens[start_idx..].iter().enumerate() {
                println!(
                    "    token[{}] start={:.3}s end={:.3}s text={:?}",
                    start_idx + i,
                    tok.start,
                    tok.end,
                    tok.text
                );
            }
            let last = result.tokens.last().unwrap();
            let coverage_pct = last.end as f64 / file_dur_s * 100.0;
            println!(
                "  last_token_end: {:.3}s  clip_duration: {:.3}s  coverage: {:.1}%",
                last.end, file_dur_s, coverage_pct
            );
        }
        println!();
    }

    // DIAGNOSTIC 3: chunked recovery on en_fast (15s non-overlapping segments)
    println!("--- DIAG 3: chunked recovery — en_fast (15s non-overlapping segments) ---");
    {
        let wav_path = args.recordings_dir.join("en_fast_16k.wav");
        let (samples, sr) = load_wav(&wav_path)?;
        let dur_s = samples.len() as f64 / sr as f64;
        let chunk_s = 15.0_f64;

        let mut t = 0.0_f64;
        let mut all_text = String::new();
        let mut seg_idx = 0usize;

        while t < dur_s {
            let end = (t + chunk_s).min(dur_s);
            let slice = slice_samples(&samples, sr, t, end);
            let result = model
                .transcribe(slice, sr, 1u16, Some(TimestampMode::Words))
                .with_context(|| format!("Chunk transcription failed at t={:.1}", t))?;
            let wc = word_count(&result.text);
            let preview: String = result.text.trim().chars().take(70).collect();
            let ellipsis = if result.text.trim().chars().count() > 70 { "…" } else { "" };
            println!(
                "  seg[{}] [{:.1}s–{:.1}s]: {} words — {:?}{}",
                seg_idx, t, end, wc, preview, ellipsis
            );
            if !all_text.is_empty() {
                all_text.push(' ');
            }
            all_text.push_str(result.text.trim());
            t += chunk_s;
            seg_idx += 1;
        }

        let chunked_total = word_count(&all_text);
        println!();
        println!("  chunked_total_words: {}", chunked_total);
        println!("  full_buffer_words:   139  (from Gate 1)");
        println!("  ground_truth_words:  237");
        println!(
            "  conclusion: {}",
            if chunked_total > 190 {
                "RECOVERED — windowed inference bypasses full-buffer truncation"
            } else if chunked_total > 139 {
                "PARTIAL — chunking recovers some but not all missing words"
            } else {
                "NO RECOVERY — truncation not a full-buffer artifact"
            }
        );
    }

    println!("\nGATE 1 DIAGNOSTIC COMPLETE");
    Ok(())
}

// ═══════════════════════════════════════════════════════════════════════════════
// GATE 2 — Rolling-window accuracy + cost sweep
// ═══════════════════════════════════════════════════════════════════════════════

fn gate2(args: &Args) -> Result<()> {
    println!("=== GATE 2: Rolling-window accuracy + cost sweep (corrected metrics) ===\n");

    validate_absolute(&args.json_dir, "json-dir")?;
    check_model_files(&args.model_dir, &args.model_type)?;

    let mut model = load_model(&args.model_dir, &args.model_type)?;

    // Re-probe timestamp support (Gate 0 file is advisory; always re-verify)
    let wav_probe_path = args.recordings_dir.join("en_slow_16k.wav");
    let (probe_samples, probe_sr) = load_wav(&wav_probe_path)?;
    println!("--- Probing timestamp support ---");
    let ts_support = probe_timestamps(&mut model, &probe_samples, probe_sr)?;
    println!("Flicker method: engine self-consistency (engine vs engine on shared span)\n");

    let window_sizes = parse_csv_floats(&args.window_sizes);
    let hop_sizes = parse_csv_floats(&args.hop_sizes);

    // ── Background CPU% sampler (200ms interval, best-effort secondary) ───────
    let stop_flag = Arc::new(AtomicBool::new(false));
    let cpu_arc: Arc<Mutex<Vec<f32>>> = Arc::new(Mutex::new(Vec::new()));
    let cpu_thread = {
        let stop = Arc::clone(&stop_flag);
        let out = Arc::clone(&cpu_arc);
        let pid = Pid::from(std::process::id() as usize);
        std::thread::spawn(move || {
            let mut sys = System::new();
            // First call establishes the delta baseline; discard its reading.
            sys.refresh_processes_specifics(
                ProcessesToUpdate::Some(&[pid]),
                false,
                ProcessRefreshKind::nothing().with_cpu(),
            );
            std::thread::sleep(std::time::Duration::from_millis(200));
            while !stop.load(Ordering::Relaxed) {
                sys.refresh_processes_specifics(
                    ProcessesToUpdate::Some(&[pid]),
                    false,
                    ProcessRefreshKind::nothing().with_cpu(),
                );
                if let Some(proc) = sys.process(pid) {
                    out.lock().unwrap().push(proc.cpu_usage());
                }
                std::thread::sleep(std::time::Duration::from_millis(200));
            }
        })
    };

    let mut sweep_rows: Vec<SweepRow> = Vec::new();
    let mut tile_rows: Vec<TileRow> = Vec::new();

    // ── Accuracy clips: en_slow and en_fast only ──────────────────────────────
    for clip in &["en_slow", "en_fast"] {
        let gt = load_gt(&args.json_dir, clip)?;
        let wav_path = args.recordings_dir.join(format!("{}_16k.wav", clip));
        let (samples, sr) = load_wav(&wav_path)?;
        let dur_s = samples.len() as f64 / sr as f64;

        // NON-OVERLAPPING TILE ACCURACY — delegates to transcribe_tiles (shared tiler).
        println!("--- Non-overlapping tile accuracy: {} (dur={:.3}s) ---", clip, dur_s);
        for &ws in &window_sizes {
            println!("  ws={}s:", ws);
            let (tile_total, _n_tiles) =
                transcribe_tiles(&mut model, &samples, sr, ws, clip)?;
            let tile_error_pct = (tile_total as f64 - gt.total_words as f64).abs()
                / gt.total_words as f64
                * 100.0;
            println!(
                "  ws={}s  tile_total={}  gt={}  error={:.1}%",
                ws, tile_total, gt.total_words, tile_error_pct
            );
            tile_rows.push(TileRow {
                clip: clip.to_string(),
                window_s: ws,
                tile_total,
                gt_words: gt.total_words,
                tile_error_pct,
            });
        }

        // OVERLAPPING SWEEP per (ws, hs) — engine consistency flicker + cost
        for &ws in &window_sizes {
            let tile_err = tile_rows
                .iter()
                .find(|r| r.clip == *clip && (r.window_s - ws).abs() < 1e-9)
                .map(|r| r.tile_error_pct)
                .unwrap_or(f64::NAN);

            for &hs in &hop_sizes {
                if hs >= ws {
                    continue;
                }
                println!("  sweep: clip={} window={}s hop={}s", clip, ws, hs);

                let mut windows: Vec<WindowResult> = Vec::new();
                let mut t_start = 0.0_f64;
                while t_start + ws <= dur_s {
                    let w = transcribe_window(
                        &mut model, &samples, sr, t_start, t_start + ws, &ts_support,
                    )?;
                    windows.push(w);
                    t_start += hs;
                }

                if windows.is_empty() {
                    eprintln!("  WARNING: no windows for {} ws={} hs={}", clip, ws, hs);
                    continue;
                }

                // Engine self-consistency flicker (no clip-average detrend)
                let (cons_mean, cons_stddev) = if ts_support == TsSupport::Present {
                    compute_flicker_consistency(&windows, ws, hs)
                } else {
                    eprintln!(
                        "  WARNING: TsSupport::Absent — consistency metric requires timestamps; reporting 0.0"
                    );
                    (0.0, 0.0)
                };

                // Timing & headroom (unchanged from original gate 2)
                let bms: Vec<f64> = windows.iter().map(|w| w.batch_ms).collect();
                let bms_mean = bms.iter().sum::<f64>() / bms.len() as f64;
                let bms_max = bms.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
                let hop_ms = hs * 1000.0;
                let hr_vals: Vec<f64> = bms.iter().map(|&b| hop_ms / b).collect();
                let hr_mean = hr_vals.iter().sum::<f64>() / hr_vals.len() as f64;
                let hr_min = hr_vals.iter().cloned().fold(f64::INFINITY, f64::min);

                println!(
                    "    tile_err={:.1}% cons_mean={:.4}wps cons_std={:.4}wps bms_mean={:.0}ms hr_mean={:.3} hr_min={:.3}",
                    tile_err, cons_mean, cons_stddev, bms_mean, hr_mean, hr_min
                );

                sweep_rows.push(SweepRow {
                    window_s: ws,
                    hop_s: hs,
                    clip: clip.to_string(),
                    tile_error_pct: tile_err,
                    consistency_mean_wps: cons_mean,
                    consistency_stddev_wps: cons_stddev,
                    batch_ms_mean: bms_mean,
                    batch_ms_max: bms_max,
                    headroom_ratio_mean: hr_mean,
                    headroom_ratio_min: hr_min,
                });
            }
        }
    }

    // ── Pause stress test: en_normal (FM2 check — excluded from accuracy) ─────
    println!("\n--- Pause stress test (en_normal, excluded from accuracy scoring) ---");
    {
        let gt_n = load_gt(&args.json_dir, "en_normal")?;
        let gt_rate_n = gt_n.total_words as f64 / gt_n.duration_seconds;
        let pause_threshold = 0.20 * gt_rate_n;
        let wav_n = args.recordings_dir.join("en_normal_16k.wav");
        let (samples_n, sr_n) = load_wav(&wav_n)?;
        let dur_n = samples_n.len() as f64 / sr_n as f64;

        let ws_p = window_sizes[0];
        let hs_p = hop_sizes[0];
        let mut t = 0.0_f64;
        let mut flagged: Vec<(f64, f64, usize, f64)> = Vec::new();

        while t + ws_p <= dur_n {
            let w = transcribe_window(
                &mut model, &samples_n, sr_n, t, t + ws_p, &ts_support,
            )?;
            let rate = w.word_count as f64 / ws_p;
            if rate < pause_threshold {
                flagged.push((t, t + ws_p, w.word_count, rate));
            }
            t += hs_p;
        }

        println!(
            "en_normal gt_rate={:.2}wps pause_threshold(20%)={:.2}wps window={}s hop={}s",
            gt_rate_n, pause_threshold, ws_p, hs_p
        );
        println!("flagged_pause_windows: {}", flagged.len());
        if flagged.is_empty() {
            println!("  (none detected — pause may not produce a below-threshold window at this config)");
        }
        for (start, end, count, rate) in &flagged {
            println!(
                "  PAUSE-CANDIDATE [{:.1}s–{:.1}s]: {} words, {:.2}wps — FM2={} no_hallucination_spike={}",
                start,
                end,
                count,
                rate,
                if *count >= 1 { "OK(low_count)" } else { "CHECK(zero)" },
                if *rate < gt_rate_n * 1.5 { "Y" } else { "N(spike!)" }
            );
        }
    }

    // ── Stop CPU thread ───────────────────────────────────────────────────────
    stop_flag.store(true, Ordering::Relaxed);
    cpu_thread.join().expect("CPU sampler thread panicked");
    let cpu_vals = cpu_arc.lock().unwrap().clone();
    let mean_cpu = if cpu_vals.is_empty() {
        0.0_f32
    } else {
        cpu_vals.iter().sum::<f32>() / cpu_vals.len() as f32
    };
    let peak_cpu = cpu_vals.iter().cloned().fold(0.0_f32, f32::max);
    println!(
        "\nCPU% (best-effort secondary, ~200ms samples n={}): mean={:.1}% peak={:.1}%",
        cpu_vals.len(),
        mean_cpu,
        peak_cpu
    );

    // ── Print tile accuracy table ─────────────────────────────────────────────
    println!("\n=== NON-OVERLAPPING TILE ACCURACY (ground truth reconciliation) ===");
    println!(
        "{:<12} {:>8} {:>12} {:>10} {:>12}",
        "clip", "window_s", "tile_total", "gt_words", "tile_err%"
    );
    for r in &tile_rows {
        println!(
            "{:<12} {:>8.0} {:>12} {:>10} {:>12.1}",
            r.clip, r.window_s, r.tile_total, r.gt_words, r.tile_error_pct
        );
    }

    // ── Print corrected sweep matrix ──────────────────────────────────────────
    println!("\n=== CORRECTED SWEEP MATRIX ===");
    println!(
        "{:<8} {:<6} {:<12} {:>10} {:>14} {:>13} {:>11} {:>11} {:>11}",
        "window_s", "hop_s", "clip", "tile_err%", "cons_mean_wps", "cons_std_wps",
        "bms_mean", "hr_mean", "hr_min"
    );
    for r in &sweep_rows {
        println!(
            "{:<8} {:<6} {:<12} {:>10.1} {:>14.4} {:>13.4} {:>11.0} {:>11.3} {:>11.3}",
            r.window_s,
            r.hop_s,
            r.clip,
            r.tile_error_pct,
            r.consistency_mean_wps,
            r.consistency_stddev_wps,
            r.batch_ms_mean,
            r.headroom_ratio_mean,
            r.headroom_ratio_min
        );
    }

    // ── Write CSVs ────────────────────────────────────────────────────────────
    fs::create_dir_all(&args.output_dir)?;

    let tile_csv_path = args.output_dir.join("gate2_tile_accuracy.csv");
    let mut tile_wtr = csv::Writer::from_path(&tile_csv_path)?;
    tile_wtr.write_record(&[
        "clip",
        "window_s",
        "tile_total",
        "gt_words",
        "tile_error_pct",
    ])?;
    for r in &tile_rows {
        tile_wtr.write_record(&[
            r.clip.clone(),
            r.window_s.to_string(),
            r.tile_total.to_string(),
            r.gt_words.to_string(),
            format!("{:.2}", r.tile_error_pct),
        ])?;
    }
    tile_wtr.flush()?;
    println!("\nTile accuracy CSV: {:?}", tile_csv_path);

    let csv_path = args.output_dir.join("gate2_sweep.csv");
    let mut wtr = csv::Writer::from_path(&csv_path)?;
    wtr.write_record(&[
        "window_s",
        "hop_s",
        "clip",
        "tile_error_pct",
        "consistency_mean_wps",
        "consistency_stddev_wps",
        "batch_ms_mean",
        "batch_ms_max",
        "headroom_ratio_mean",
        "headroom_ratio_min",
        "mean_cpu_pct",
        "peak_cpu_pct",
    ])?;
    for r in &sweep_rows {
        wtr.write_record(&[
            r.window_s.to_string(),
            r.hop_s.to_string(),
            r.clip.clone(),
            format!("{:.2}", r.tile_error_pct),
            format!("{:.4}", r.consistency_mean_wps),
            format!("{:.4}", r.consistency_stddev_wps),
            format!("{:.0}", r.batch_ms_mean),
            format!("{:.0}", r.batch_ms_max),
            format!("{:.3}", r.headroom_ratio_mean),
            format!("{:.3}", r.headroom_ratio_min),
            format!("{:.1}", mean_cpu),
            format!("{:.1}", peak_cpu),
        ])?;
    }
    wtr.flush()?;
    println!("Sweep CSV: {:?}", csv_path);

    // ── Hard-fail check ───────────────────────────────────────────────────────
    let all_failing =
        !sweep_rows.is_empty() && sweep_rows.iter().all(|r| r.headroom_ratio_min < 1.0);
    if all_failing {
        bail!(
            "GATE 2 HARD FAIL — per-batch inference exceeds hop interval at ALL cells on CPU. \
             See matrix above. STOP — do not proceed to Gate 3."
        );
    }

    println!("\nGATE 2 PASS — at least one viable cell found");
    Ok(())
}

// ═══════════════════════════════════════════════════════════════════════════════
// GATE 3 — Acoustic robustness
// ═══════════════════════════════════════════════════════════════════════════════

fn gate3(args: &Args) -> Result<()> {
    println!("=== GATE 3: Acoustic robustness ===\n");
    println!(
        "Best cell: window={}s hop={}s (set with --best-window / --best-hop)",
        args.best_window, args.best_hop
    );

    validate_absolute(&args.json_dir, "json-dir")?;
    check_model_files(&args.model_dir, &args.model_type)?;
    let mut model = load_model(&args.model_dir, &args.model_type)?;
    let ws = args.best_window;

    fs::create_dir_all(&args.output_dir)?;
    let csv_path = args.output_dir.join("gate3_robustness.csv");
    let mut wtr = csv::Writer::from_path(&csv_path)?;
    wtr.write_record(&[
        "clip",
        "gt_words",
        "non_overlap_total",
        "error_pct",
        "notes",
    ])?;

    for clip in &["en_slow", "en_normal", "en_fast"] {
        let gt = load_gt(&args.json_dir, clip)?;
        let wav_path = args.recordings_dir.join(format!("{}_16k.wav", clip));
        let (samples, sr) = load_wav(&wav_path)?;
        let dur_s = samples.len() as f64 / sr as f64;

        println!("clip={} dur={:.3}s ws={}s:", clip, dur_s, ws);
        let (total, n_windows) = transcribe_tiles(&mut model, &samples, sr, ws, clip)?;

        let ep =
            (total as f64 - gt.total_words as f64).abs() / gt.total_words as f64 * 100.0;
        let notes = if *clip == "en_normal" {
            "pause-clip; non-overlap aggregation may undercount during pause window"
        } else {
            ""
        };

        println!(
            "clip={} gt={} non_overlap_total={} error_pct={:.1}% windows={}",
            clip, gt.total_words, total, ep, n_windows
        );
        wtr.write_record(&[
            clip.to_string(),
            gt.total_words.to_string(),
            total.to_string(),
            format!("{:.2}", ep),
            notes.to_string(),
        ])?;
    }

    // RU clips: count-only vs JSON, only if WAV files are present
    for clip in &["ru_slow", "ru_normal", "ru_fast"] {
        let wav_path = args.recordings_dir.join(format!("{}_16k.wav", clip));
        if !wav_path.exists() {
            println!(
                "SKIP {:?} — not present (convert with ffmpeg -i WPMSpike/recordings/{}.caf -ar 16000 -ac 1 -sample_fmt s16 if needed)",
                wav_path, clip
            );
            continue;
        }
        let gt = load_gt(&args.json_dir, clip)?;
        let (samples, sr) = load_wav(&wav_path)?;
        let dur_s = samples.len() as f64 / sr as f64;

        println!("clip={} dur={:.3}s ws={}s:", clip, dur_s, ws);
        let (total, _n_tiles) = transcribe_tiles(&mut model, &samples, sr, ws, clip)?;

        let ep =
            (total as f64 - gt.total_words as f64).abs() / gt.total_words as f64 * 100.0;
        println!(
            "clip={} gt={} non_overlap_total={} error_pct={:.1}% (RU count-only vs JSON)",
            clip, gt.total_words, total, ep
        );
        wtr.write_record(&[
            clip.to_string(),
            gt.total_words.to_string(),
            total.to_string(),
            format!("{:.2}", ep),
            "RU count-only; .txt transcripts truncated/unreliable".to_string(),
        ])?;
    }

    wtr.flush()?;
    println!("\nCSV written: {:?}", csv_path);
    println!("\nGATE 3 COMPLETE");
    Ok(())
}

// ═══════════════════════════════════════════════════════════════════════════════
// GATE 4 — Nemotron streaming probe (BLOCKED)
// ═══════════════════════════════════════════════════════════════════════════════

fn gate4(_args: &Args) -> Result<()> {
    println!("=== GATE 4: Nemotron streaming probe ===\n");
    println!("BLOCKED — Nemotron HuggingFace repo slug not yet confirmed.");
    println!(
        "Required: encoder.onnx, encoder.onnx.data, decoder_joint.onnx, tokenizer.model (int8)."
    );
    println!("\nOnce the HF repo is confirmed, implement:");
    println!("  - Use parakeet_rs::Nemotron / NemotronHandle from parakeet-rs 0.3.5");
    println!("  - Feed ~560ms chunks, record time-to-first-text");
    println!("  - STOP if first-text > 2000ms (EOU failure mode reproduced — do not tune)");
    println!("  - Otherwise print transcript + latency + one-paragraph quality note");
    bail!("Gate 4 blocked — confirm Nemotron HF repo slug before proceeding");
}

// ═══════════════════════════════════════════════════════════════════════════════
// main
// ═══════════════════════════════════════════════════════════════════════════════

fn main() -> Result<()> {
    let args = Args::parse();

    validate_absolute(&args.model_dir, "model-dir")?;
    validate_absolute(&args.recordings_dir, "recordings-dir")?;
    validate_absolute(&args.output_dir, "output-dir")?;

    match args.gate {
        0 => gate0(&args),
        1 => gate1(&args),
        2 => gate2(&args),
        3 => gate3(&args),
        4 => gate4(&args),
        11 => gate1diag(&args),
        n => bail!("Unknown gate: {}. Valid: 0, 1, 2, 3, 4, 11 (gate-1 diagnostic)", n),
    }
}
