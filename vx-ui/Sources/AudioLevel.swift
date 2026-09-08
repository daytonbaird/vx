import AVFoundation
import Foundation

/// Audio level math and the canonical capture format, shared by the microphone adapter
/// (`AudioCapture`) and the WAV replay adapter (`WAVFileAudioSource`) so both produce
/// identical frames and identical HUD levels.
enum AudioLevel {
    /// The format every audio source delivers: 16 kHz mono float32, non-interleaved.
    static let mono16kFloat32 = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    static func averagePower(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return -160 }
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, channelCount > 0 else { return -160 }
        var sumOfSquares: Float = 0
        for ch in 0..<channelCount {
            let data = channelData[ch]
            for i in 0..<frameCount {
                sumOfSquares += data[i] * data[i]
            }
        }
        let rms = sqrt(sumOfSquares / Float(channelCount * frameCount))
        return rms > 0 ? 20 * log10(rms) : -160
    }

    /// Same RMS -> dBFS conversion as the buffer overload, for an already-deinterleaved
    /// single-channel chunk.
    static func averagePower(from samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -160 }
        var sumOfSquares: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
        }
        let rms = sqrt(sumOfSquares / Float(samples.count))
        return rms > 0 ? 20 * log10(rms) : -160
    }

    static func normalize(power: Float) -> Double {
        let minDb: Double = -60
        let maxDb: Double = -12
        let db = Double(power)
        if db <= minDb { return 0 }
        if db >= maxDb { return 1 }
        let normalized = min(max((db - minDb) / (maxDb - minDb), 0), 1)
        return pow(normalized, 0.7)
    }
}
