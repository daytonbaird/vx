# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added

- Transcript contract test suite (`tests/transcript_contract.rs`) pinning what `file`
  and `stream` mode actually produce. It runs the real binary against the committed
  clips in `fixtures/audio/` and compares each transcript to `fixtures/audio/goldens.json`
  (per-engine golden text, required keywords, and a word-error-rate ceiling). Previously
  the unit tests covered buffering and the hallucination filter but nothing pinned the
  output, so a regression in chunking, prompt, or sampling could degrade every
  transcript and still ship green. Also covers `file`/`stream` agreement, chunk-boundary
  coverage on a 45 s clip, and the one-line-of-stdout contract the Swift side depends on.
- `tests/common/mod.rs` with shared fixture, WAV, WER, and golden helpers, plus a
  `MODEL_LOCK` that serializes model loads (concurrent Metal contexts contend).
- `Scripts/ensure-model.sh` fetches `ggml-tiny.en.bin` on demand and prints its path;
  `Scripts/package-app.sh` now calls it instead of duplicating the download.
- Test environment variables: `VX_REQUIRE_MODEL=1` turns model-absent skips into hard
  failures (so CI cannot pass vacuously), `VX_MODEL_PATH` points the suite at another
  GGML model, and `VX_UPDATE_GOLDENS=1` re-keys the golden transcripts.

### Changed

- `stream_no_data_loss` now runs by default instead of being `#[ignore]`d. It was
  pointed at a `test_sarahs_gone.wav` that is not in the repo, so it could never run;
  it now uses `fixtures/audio/long-60s.wav` and reads the WAV with `hound` rather than
  shelling out to `afconvert`, finishing in under a second.
- `error_paths` uses the shared model resolution, so its three model-dependent tests
  are no longer silently vacuous when the model is missing.

## [v1.0.0] - 2026-02-27

Initial release. Includes fix for super-linear transcription time on long recordings (>30s) — audio is now processed in 30-second chunks.
