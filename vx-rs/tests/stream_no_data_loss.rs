//! Regression test: stream mode must not lose audio from the beginning of long
//! recordings.
//!
//! The bug this guards against: `AudioBuffer` was once capped at a 30-second rolling
//! window, silently draining the oldest samples on overflow — so any recording longer
//! than 30 seconds lost everything spoken before `(duration − 30 s)`. Stream mode now
//! constructs the buffer with `usize::MAX` so the whole recording is retained and
//! chunked for inference (see `run_stream` in `src/main.rs`).
//!
//! The unit tests in `src/main.rs` assert `AudioBuffer` retains its samples; this test
//! covers the same regression end-to-end through the real binary, where a cap could
//! also creep back in via the reader thread or the final chunking loop.
//!
//! It feeds the 61-second `long-60s` fixture into `vx-rs stream` and asserts that words
//! from both the beginning AND the end appear in the transcript. With the cap bug only
//! the last 30 seconds survive, so the opening lines would be absent.
//!
//! Skips when no model is present; `VX_REQUIRE_MODEL=1` makes that a failure.

mod common;

use common::{fixture, model_guard, normalize, read_wav_f32, run_stream, stdout_text};

#[test]
fn stream_mode_preserves_beginning_of_long_recording() {
    require_model!(model);
    let _guard = model_guard();

    // ~61 seconds. Without the fix the 30 s cap discards the first ~31 seconds, so
    // words from the opening lines would be missing from the transcript.
    let samples = read_wav_f32(&fixture("long-60s"));
    let transcript = stdout_text(&run_stream(&model, &samples));
    let words = normalize(&transcript);
    let has = |w: &str| words.iter().any(|x| x == w);

    // Opening lines (first ~15 seconds) — absent if the buffer-cap bug is present.
    let has_opening = ["sarah", "house", "maple", "yellow", "walls"].iter().any(|w| has(w));
    // Closing lines (last 30 seconds) — present even with the bug.
    let has_closing = ["fifty", "earth", "sun", "worlds", "scrubbing"].iter().any(|w| has(w));

    assert!(
        has_opening,
        "Transcript is missing words from the first 30 seconds of a 61-second recording.\n\
         This is the buffer-cap data-loss regression: oldest audio is being dropped.\n\
         Transcript:\n{transcript}"
    );

    assert!(
        has_closing,
        "Transcript is missing words from the end of the recording.\n\
         Transcript:\n{transcript}"
    );
}
