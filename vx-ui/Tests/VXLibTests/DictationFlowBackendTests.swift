import Foundation
import XCTest
@testable import VXLib

/// Swift-side engine contract test: drives a whole Dictation Flow against the *real*
/// `vx-rs` subprocess and the bundled tiny.en model, replaying a WAV fixture through the
/// Audio Source seam instead of a microphone.
///
/// Opt-in (`VX_FLOW_BACKEND=1`) because it needs a built backend and takes seconds rather
/// than milliseconds. This is the test to extend when a second engine lands (Parakeet):
/// the assertions here are engine-agnostic — a real backend, real audio, real text — so a
/// new adapter proves itself by passing the same case.
@MainActor
final class DictationFlowBackendTests: XCTestCase {

    /// `<package>/Tests/VXLibTests/DictationFlowBackendTests.swift` -> `<package>`
    private static var packageDirectory: URL {
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { dir.deleteLastPathComponent() }
        return dir
    }

    private static var backendURL: URL {
        packageDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("vx-rs/target/release/vx-rs")
    }

    private static var modelURL: URL {
        packageDirectory.appendingPathComponent("Resources/Models/ggml-tiny.en.bin")
    }

    func testRealBackendTranscribesFixtureAndInsertsText() async throws {
        guard ProcessInfo.processInfo.environment["VX_FLOW_BACKEND"] == "1" else {
            throw XCTSkip("Set VX_FLOW_BACKEND=1 to run the real-backend flow test.")
        }
        let backendURL = Self.backendURL
        let modelURL = Self.modelURL
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: backendURL.path) else {
            throw XCTSkip("vx-rs not built at \(backendURL.path) — run `cargo build --release`.")
        }
        guard fm.fileExists(atPath: modelURL.path) else {
            throw XCTSkip("Model missing at \(modelURL.path).")
        }
        guard Fixtures.exists("short-phrase") else {
            throw XCTSkip("Fixture short-phrase.wav is missing.")
        }

        let relay = DrainRelay()
        let source = WAVFileAudioSource(
            url: Fixtures.url("short-phrase"),
            pacing: .immediate,
            onDrained: { relay.fire() }
        )
        let inserter = RecordingTextInserter()
        let suite = TestDefaults.makeSuite(prefix: "vx-flow-backend")
        let history = TranscriptionHistory(defaults: suite.defaults)
        defer { TestDefaults.destroy(suite.name) }

        let settings = DictationSettings(
            backendURL: backendURL,
            modelURL: modelURL,
            inputDeviceUID: nil,
            autoDetectMode: false,
            manualMode: .plainText,
            manualProfile: .generic,
            spokenSubmitPhrases: [],
            goModeSubmitDelay: 0,
            postProcessing: { _, _ in nil }
        )

        let flow = DictationFlow(dependencies: DictationFlow.Dependencies(
            audioSource: source,
            transcriber: SubprocessTranscriber(backendURL: backendURL),
            processor: DictationProcessor(store: .shared, postProcessor: PassthroughPostProcessor()),
            contextResolver: DictationContextResolver(),
            textInserter: inserter,
            history: history,
            settings: { settings },
            frontmostApp: { TargetApp(bundleID: "com.apple.TextEdit", name: "TextEdit", pid: 1) },
            validateResources: { try FileValidator.validate(backendURL: $0, modelURL: $1) },
            captureRetryDelay: 0,
            captureAttempts: 1
        ))
        let recorder = EventRecorder()
        flow.delegate = recorder
        relay.onDrain = { [weak flow] in Task { @MainActor in flow?.audioSourceDidDrain() } }

        flow.beginRecording()
        try await recorder.wait(forEventNamed: "recordingStarted", timeout: 30)
        try await recorder.wait(forEventNamed: "audioSourceDrained", timeout: 30)
        flow.finishRecording()
        try await recorder.wait(forEventNamed: "textInserted", timeout: 120)
        await flow.waitForIdle()

        let inserted = inserter.insertions.first?.text ?? ""
        XCTAssertTrue(
            inserted.lowercased().contains("quick brown fox"),
            "expected the fixture phrase, got \(inserted.debugDescription); events: \(recorder.names)"
        )
        XCTAssertEqual(history.entries.first?.text, inserted)
    }
}
