import AVFoundation
import Combine
import Foundation

enum WAVReplayError: LocalizedError {
    case alreadyStarted
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            return "Replay is already running."
        case .conversionFailed:
            return "Could not convert the WAV file to 16 kHz mono float32."
        }
    }
}

/// Replays a WAV file as if it were the microphone: converts to 16 kHz mono f32 and pushes
/// chunks to the sink on a background queue, publishing the same normalized levels the real
/// capture path publishes. After the last chunk it stays "started" (delivering nothing) until
/// `stop()`, mimicking a hotkey held past the end of speech.
///
/// Re-startable: `stop()` then `start()` replays the file again from the beginning, which is
/// what an end-to-end run needs when it drives several recordings through one app launch.
/// Each replay carries a generation token so a still-draining previous replay can never
/// deliver chunks into the new run's sink or re-fire its `onDrained`.
final class WAVFileAudioSource: AudioSource {
    enum Pacing {
        /// Deliver every chunk back to back, as fast as the sink accepts them.
        case immediate
        /// Deliver in wall-clock time, sleeping one chunk duration between chunks.
        case realtime
    }

    private let url: URL
    private let pacing: Pacing
    private let chunkFrames: Int
    private let onDrained: (() -> Void)?

    private let queue = DispatchQueue(label: "com.vx.audio.replay")
    private let levelSubject = CurrentValueSubject<Double, Never>(0)
    private let lock = NSLock()
    private var started = false
    private var cancelled = false
    private var drainedFired = false
    /// Bumped on every start and every stop. The replay body carries the value it was
    /// launched with and stops the moment the counter moves past it.
    private var generation = 0

    init(url: URL, pacing: Pacing = .immediate, chunkFrames: Int = 4096, onDrained: (() -> Void)? = nil) {
        self.url = url
        self.pacing = pacing
        self.chunkFrames = max(1, chunkFrames)
        self.onDrained = onDrained
    }

    var levelPublisher: AnyPublisher<Double, Never> {
        levelSubject
            .receive(on: RunLoop.main)
            .eraseToAnyPublisher()
    }

    func start(deviceUID: String? = nil, sink: @escaping ([Float]) -> Void) throws {
        lock.lock()
        if started {
            lock.unlock()
            vxLog("[audio/replay] start() called while already started")
            throw WAVReplayError.alreadyStarted
        }
        started = true
        cancelled = false
        drainedFired = false
        generation += 1
        let generation = self.generation
        lock.unlock()

        if let deviceUID {
            vxLog("[audio/replay] Ignoring device UID '\(deviceUID)' — replaying \(url.lastPathComponent)")
        }

        let samples: [Float]
        do {
            samples = try WAVFileAudioSource.loadSamples(from: url)
        } catch {
            lock.lock(); started = false; lock.unlock()
            vxLog("[audio/replay] Could not read \(url.lastPathComponent): \(error.localizedDescription)")
            throw error
        }

        vxLog("[audio/replay] Replaying \(url.lastPathComponent): \(samples.count) frames, pacing \(pacing == .realtime ? "realtime" : "immediate")")
        levelSubject.send(0)

        let chunkFrames = self.chunkFrames
        let pacing = self.pacing
        queue.async { [weak self] in
            guard let self else { return }
            let chunkInterval = Double(chunkFrames) / 16_000
            var offset = 0
            while offset < samples.count {
                if self.isStale(generation) { vxLog("[audio/replay] Replay cancelled after \(offset) frames"); return }
                let end = min(offset + chunkFrames, samples.count)
                let chunk = Array(samples[offset..<end])
                offset = end

                self.levelSubject.send(AudioLevel.normalize(power: AudioLevel.averagePower(from: chunk)))
                sink(chunk)

                if pacing == .realtime && offset < samples.count {
                    Thread.sleep(forTimeInterval: chunkInterval)
                }
            }
            self.lock.lock()
            let fire = !self.drainedFired && !self.cancelled && self.generation == generation
            if fire { self.drainedFired = true }
            self.lock.unlock()
            if fire {
                vxLog("[audio/replay] Drained \(samples.count) frames; holding until stop()")
                self.onDrained?()
            }
        }
    }

    func stop() {
        lock.lock()
        guard started else { lock.unlock(); return }
        started = false
        cancelled = true
        generation += 1
        lock.unlock()
        levelSubject.send(0)
        vxLog("[audio/replay] Stopped \(url.lastPathComponent)")
    }

    /// True once the replay that was launched as `generation` has been superseded by a
    /// `stop()` or by a later `start()`.
    private func isStale(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled || self.generation != generation
    }

    /// Reads the whole file and converts it once to 16 kHz mono float32.
    private static func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else { return [] }
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames) else {
            throw WAVReplayError.conversionFailed
        }
        try file.read(into: inBuffer)

        let target = AudioLevel.mono16kFloat32
        if inFormat.sampleRate == target.sampleRate,
           inFormat.channelCount == 1,
           inFormat.commonFormat == .pcmFormatFloat32,
           let data = inBuffer.floatChannelData {
            return Array(UnsafeBufferPointer(start: data[0], count: Int(inBuffer.frameLength)))
        }

        guard let converter = AVAudioConverter(from: inFormat, to: target) else {
            throw WAVReplayError.conversionFailed
        }
        let ratio = target.sampleRate / inFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio + 1)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw WAVReplayError.conversionFailed
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return inBuffer
        }
        if let error { throw error }
        guard let data = outBuffer.floatChannelData else { throw WAVReplayError.conversionFailed }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(outBuffer.frameLength)))
    }
}
