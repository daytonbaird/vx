//! Integration tests for error paths: missing model, missing audio, missing stdin.
//!
//! These tests verify that vx-rs exits with a non-zero status when given bad
//! inputs, and exits cleanly (zero) when given empty or silent input.
//!
//! Tests needing a real model skip when it is absent; set `VX_REQUIRE_MODEL=1` to
//! turn those skips into failures (see `tests/common/mod.rs`).

mod common;

use common::{model_guard, vxrs_bin};
use std::process::{Command, Stdio};

#[test]
fn file_mode_missing_model_exits_nonzero() {
    let status = Command::new(vxrs_bin())
        .args(["file", "/nonexistent/model.bin", "/nonexistent/audio.wav"])
        .status()
        .expect("failed to launch vx-rs");
    assert!(!status.success(), "Expected non-zero exit for missing model");
}

#[test]
fn file_mode_missing_audio_exits_nonzero() {
    require_model!(model);
    let _guard = model_guard();

    let status = Command::new(vxrs_bin())
        .args(["file", model.to_str().unwrap(), "/nonexistent/audio.wav"])
        .status()
        .expect("failed to launch vx-rs");
    assert!(!status.success(), "Expected non-zero exit for missing audio");
}

#[test]
fn stream_mode_missing_model_exits_nonzero() {
    let mut child = Command::new(vxrs_bin())
        .args(["stream", "/nonexistent/model.bin"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("failed to launch vx-rs");
    let status = child.wait().expect("failed to wait");
    assert!(!status.success(), "Expected non-zero exit for missing model");
}

#[test]
fn stream_mode_rejects_a_truncated_float32_sample() {
    use std::io::Write;

    require_model!(model);
    let _guard = model_guard();

    let mut child = Command::new(vxrs_bin())
        .args(["stream", model.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .expect("failed to launch vx-rs");
    child
        .stdin
        .take()
        .unwrap()
        .write_all(&[0, 1, 2])
        .expect("failed to write malformed input");

    let output = child.wait_with_output().expect("failed to wait for vx-rs");
    assert!(!output.status.success(), "truncated f32 input must fail");
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("incomplete byte"),
        "expected a clear framing error, stderr was: {:?}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn stream_mode_empty_stdin_exits_cleanly() {
    require_model!(model);
    let _guard = model_guard();

    let output = Command::new(vxrs_bin())
        .args(["stream", model.to_str().unwrap()])
        .stdin(Stdio::null())
        .output()
        .expect("failed to launch vx-rs");
    assert!(output.status.success(), "Empty stdin must exit 0");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.trim().is_empty(),
        "Empty stdin must produce no output, got: {:?}",
        stdout
    );
}

#[test]
fn stream_mode_silence_produces_no_output() {
    require_model!(model);
    let _guard = model_guard();

    // 5 seconds of silence at 16 kHz.
    let silence = vec![0.0f32; 5 * 16_000];
    let output = common::run_stream(&model, &silence);
    assert!(output.status.success(), "Silence input must exit 0");
    let stdout = String::from_utf8_lossy(&output.stdout);
    assert!(
        stdout.trim().is_empty(),
        "Silence must produce no transcript output, got: {:?}",
        stdout
    );
}
