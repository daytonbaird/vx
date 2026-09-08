//! Shared helpers for the vx-rs integration tests.
//!
//! # Environment variables
//!
//! - `VX_REQUIRE_MODEL=1` — model-using tests **fail** instead of skipping when the
//!   Whisper model is missing. Set this in CI (after `Scripts/ensure-model.sh`) so a
//!   missing model can never make the suite pass vacuously.
//! - `VX_MODEL_PATH=<path>` — override the model location. Handy for pointing the
//!   suite at a different GGML model (base.en, small.en, …) and for exercising the
//!   skip-vs-fail branches of [`model_path`] without moving the real 78 MB file.
//! - `VX_UPDATE_GOLDENS=1` — [`assert_golden`] rewrites the `text` field of
//!   `fixtures/audio/goldens.json` from the observed transcript instead of asserting.
//!   Use it to re-key goldens after regenerating fixtures (`Scripts/make-fixtures.sh`)
//!   or adding an engine.
//!
//! # Model serialization
//!
//! whisper.cpp uses the Metal GPU. Loading several contexts concurrently contends for
//! the device and slows every test down (and can fail outright), so every test that
//! spawns vx-rs against a real model must hold [`model_guard`] for its duration.
//! Note this only serializes *within* one test binary — each integration test file is
//! its own process, and cargo runs those sequentially.

#![allow(dead_code)]

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::{Mutex, MutexGuard};

use serde::{Deserialize, Serialize};

/// Serializes access to the Whisper model across threads in one test binary.
static MODEL_LOCK: Mutex<()> = Mutex::new(());

/// Acquires [`MODEL_LOCK`], recovering from poisoning.
///
/// A panicking test (i.e. a failing assertion) poisons the mutex. Without recovery the
/// first real failure would cascade into "PoisonError" noise from every later test in
/// the file, hiding the actual problem. The lock guards a GPU, not invariants over
/// shared data, so a poisoned lock is still perfectly safe to take.
pub fn model_guard() -> MutexGuard<'static, ()> {
    MODEL_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Path to the freshly built vx-rs binary under test.
pub fn vxrs_bin() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_vx-rs"))
}

/// Repository root (the parent of `vx-rs/`).
fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("CARGO_MANIFEST_DIR has no parent")
        .to_path_buf()
}

/// Resolves the Whisper model, honouring `VX_MODEL_PATH`.
///
/// Returns `None` when the model is absent so tests can skip — **unless**
/// `VX_REQUIRE_MODEL=1`, in which case a missing model is a hard failure.
pub fn model_path() -> Option<PathBuf> {
    let path = match std::env::var_os("VX_MODEL_PATH") {
        Some(p) => PathBuf::from(p),
        None => repo_root().join("vx-ui/Resources/Models/ggml-tiny.en.bin"),
    };

    if path.exists() {
        return Some(path);
    }

    if std::env::var_os("VX_REQUIRE_MODEL").is_some_and(|v| v == "1") {
        panic!(
            "VX_REQUIRE_MODEL=1 but no Whisper model at {}.\n\
             Fetch it with: Scripts/ensure-model.sh\n\
             (or point VX_MODEL_PATH at an existing GGML model)",
            path.display()
        );
    }

    None
}

/// Binds `$name` to the model path, or skips the test when no model is available.
///
/// One code path for skip-vs-fail: [`model_path`] decides, based on
/// `VX_REQUIRE_MODEL`, whether "no model" means skip or panic.
#[macro_export]
macro_rules! require_model {
    ($name:ident) => {
        let $name = match $crate::common::model_path() {
            Some(path) => path,
            None => {
                eprintln!(
                    "SKIP {}: no Whisper model (run Scripts/ensure-model.sh, or set \
                     VX_REQUIRE_MODEL=1 to make this a failure)",
                    stringify!($name)
                );
                return;
            }
        };
    };
}

/// Path to a checked-in audio fixture, e.g. `fixture("short-phrase")`.
pub fn fixture(name: &str) -> PathBuf {
    let path = repo_root().join("fixtures/audio").join(format!("{name}.wav"));
    assert!(
        path.exists(),
        "missing fixture {}\nRegenerate with: Scripts/make-fixtures.sh {name}",
        path.display()
    );
    path
}

/// Reads a fixture WAV as the f32 sample buffer vx-rs `stream` mode expects.
///
/// Asserts the fixture is in canonical form (16 kHz, mono, 16-bit signed PCM) so a
/// badly regenerated fixture fails loudly here rather than as a mystery transcript.
pub fn read_wav_f32(path: &Path) -> Vec<f32> {
    let mut reader = hound::WavReader::open(path)
        .unwrap_or_else(|e| panic!("failed to open {}: {e}", path.display()));
    let spec = reader.spec();
    assert_eq!(spec.sample_rate, 16_000, "{} must be 16 kHz", path.display());
    assert_eq!(spec.channels, 1, "{} must be mono", path.display());
    assert_eq!(spec.bits_per_sample, 16, "{} must be 16-bit", path.display());
    assert_eq!(
        spec.sample_format,
        hound::SampleFormat::Int,
        "{} must be signed PCM",
        path.display()
    );

    reader
        .samples::<i16>()
        .map(|s| s.expect("malformed WAV sample") as f32 / 32768.0)
        .collect()
}

/// Encodes samples as the raw little-endian f32 byte stream vx-rs reads from stdin.
pub fn f32_to_le_bytes(samples: &[f32]) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(samples.len() * 4);
    for s in samples {
        bytes.extend_from_slice(&s.to_le_bytes());
    }
    bytes
}

/// Runs `vx-rs stream <model>`, feeding `samples` on stdin and waiting for EOF output.
///
/// stdin is written from a dedicated thread: the long fixtures are several megabytes,
/// far past the ~64 KB pipe buffer, so writing inline before `wait_with_output` would
/// deadlock (we would block on a full pipe while the child blocks writing stdout).
pub fn run_stream(model: &Path, samples: &[f32]) -> Output {
    let bytes = f32_to_le_bytes(samples);

    let mut child = Command::new(vxrs_bin())
        .args(["stream", model.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .expect("failed to launch vx-rs stream");

    let mut stdin = child.stdin.take().expect("stream stdin was not piped");
    let writer = std::thread::spawn(move || {
        stdin.write_all(&bytes).expect("failed to write audio to vx-rs stdin");
        // Dropping the handle closes the pipe: EOF tells vx-rs the recording is done.
        drop(stdin);
    });

    let output = child.wait_with_output().expect("failed to wait for vx-rs stream");
    writer.join().expect("stdin writer thread panicked");
    output
}

/// Runs `vx-rs file <model> <wav>`.
pub fn run_file(model: &Path, wav: &Path) -> Output {
    Command::new(vxrs_bin())
        .args(["file", model.to_str().unwrap(), wav.to_str().unwrap()])
        .stderr(Stdio::null())
        .output()
        .expect("failed to launch vx-rs file")
}

/// Decodes a completed run's stdout, asserting it exited cleanly.
pub fn stdout_text(output: &Output) -> String {
    assert!(
        output.status.success(),
        "vx-rs exited with {:?}\nstdout: {}",
        output.status,
        String::from_utf8_lossy(&output.stdout)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

/// Lowercases, strips punctuation, and splits into words for comparison.
///
/// Apostrophes are kept so "don't" stays one token rather than becoming "don t".
pub fn normalize(text: &str) -> Vec<String> {
    text.to_lowercase()
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '\'' { c } else { ' ' })
        .collect::<String>()
        .split_whitespace()
        .map(str::to_string)
        .collect()
}

/// Word-level error rate: Levenshtein distance / reference length.
///
/// 0.0 is a perfect match; values above 1.0 are possible when the hypothesis is much
/// longer than the reference.
pub fn wer(reference: &[String], hypothesis: &[String]) -> f64 {
    if reference.is_empty() {
        return if hypothesis.is_empty() { 0.0 } else { 1.0 };
    }

    // Two-row dynamic programming over the edit-distance matrix.
    let mut prev: Vec<usize> = (0..=hypothesis.len()).collect();
    let mut curr = vec![0usize; hypothesis.len() + 1];

    for (i, r) in reference.iter().enumerate() {
        curr[0] = i + 1;
        for (j, h) in hypothesis.iter().enumerate() {
            let substitution = prev[j] + usize::from(r != h);
            let deletion = prev[j + 1] + 1;
            let insertion = curr[j] + 1;
            curr[j + 1] = substitution.min(deletion).min(insertion);
        }
        std::mem::swap(&mut prev, &mut curr);
    }

    prev[hypothesis.len()] as f64 / reference.len() as f64
}

/// One fixture/engine expectation in `fixtures/audio/goldens.json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Golden {
    /// The transcript this engine actually produced, captured with `VX_UPDATE_GOLDENS=1`.
    pub text: String,
    /// Lowercase content words that must appear in any acceptable transcript.
    pub required: Vec<String>,
    /// Maximum tolerated word error rate against `text`.
    pub max_wer: f64,
}

/// fixture name → engine id → expectation. `BTreeMap` keeps key order stable so
/// `VX_UPDATE_GOLDENS=1` rewrites produce a minimal diff.
type Goldens = std::collections::BTreeMap<String, std::collections::BTreeMap<String, Golden>>;

fn goldens_path() -> PathBuf {
    repo_root().join("fixtures/audio/goldens.json")
}

fn load_goldens() -> Goldens {
    let path = goldens_path();
    let raw = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("failed to read {}: {e}", path.display()));
    serde_json::from_str(&raw)
        .unwrap_or_else(|e| panic!("failed to parse {}: {e}", path.display()))
}

/// Asserts `transcript` matches the recorded golden for `fixture`/`engine`.
///
/// Two independent checks:
/// 1. every `required` keyword appears — catches whole dropped chunks, which WER alone
///    can tolerate on a long transcript;
/// 2. WER against the golden `text` is within `max_wer` — catches broad drift.
///
/// With `VX_UPDATE_GOLDENS=1` this records the observed transcript instead of
/// asserting, preserving `required` and `max_wer`.
pub fn assert_golden(fixture: &str, engine: &str, transcript: &str) {
    let mut goldens = load_goldens();
    let path = goldens_path();

    let entry = goldens
        .get_mut(fixture)
        .unwrap_or_else(|| panic!("no entry for fixture {fixture:?} in {}", path.display()))
        .get_mut(engine)
        .unwrap_or_else(|| {
            panic!("no entry for engine {engine:?} under fixture {fixture:?} in {}", path.display())
        });

    if std::env::var_os("VX_UPDATE_GOLDENS").is_some_and(|v| v == "1") {
        entry.text = transcript.to_string();
        eprintln!("UPDATED golden {fixture}/{engine}: {transcript:?}");
        let mut json = serde_json::to_string_pretty(&goldens).expect("failed to serialize goldens");
        json.push('\n');
        std::fs::write(&path, json)
            .unwrap_or_else(|e| panic!("failed to write {}: {e}", path.display()));
        return;
    }

    let actual_words = normalize(transcript);
    let missing: Vec<&str> = entry
        .required
        .iter()
        .filter(|w| !actual_words.iter().any(|a| a == *w))
        .map(String::as_str)
        .collect();

    assert!(
        missing.is_empty(),
        "[{fixture}/{engine}] transcript is missing required words {missing:?}\n\
         expected (golden): {:?}\n\
         actual:            {transcript:?}",
        entry.text
    );

    let expected_words = normalize(&entry.text);
    let rate = wer(&expected_words, &actual_words);
    assert!(
        rate <= entry.max_wer,
        "[{fixture}/{engine}] word error rate {rate:.3} exceeds max_wer {:.3}\n\
         expected (golden): {:?}\n\
         actual:            {transcript:?}\n\
         Re-key with: VX_UPDATE_GOLDENS=1 VX_REQUIRE_MODEL=1 cargo test --test transcript_contract",
        entry.max_wer,
        entry.text
    );
}
