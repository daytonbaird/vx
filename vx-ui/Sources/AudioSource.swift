import Combine
import Foundation

/// Audio Source: the seam that delivers 16 kHz mono f32 frames. Microphone adapter
/// (`AudioCapture`) in production, WAV replay adapter in tests.
protocol AudioSource: AnyObject {
    /// Emits normalized audio levels (0...1) while delivering.
    var levelPublisher: AnyPublisher<Double, Never> { get }

    /// Starts delivery. `sink` is called on an arbitrary non-main queue until `stop()`.
    func start(deviceUID: String?, sink: @escaping ([Float]) -> Void) throws

    func stop()
}

extension AudioCapture: AudioSource {
    func start(deviceUID: String?, sink: @escaping ([Float]) -> Void) throws {
        // Streaming mode only: the returned URL is a sentinel that is never written.
        _ = try startRecording(deviceUID: deviceUID, session: nil, sampleSink: sink)
    }

    func stop() {
        _ = stopRecording()
    }
}
