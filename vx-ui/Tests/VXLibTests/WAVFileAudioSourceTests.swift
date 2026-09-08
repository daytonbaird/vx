import AVFoundation
import Combine
import XCTest
@testable import VXLib

final class WAVFileAudioSourceTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTSkipUnless(Fixtures.exists(name), "Missing audio fixture \(name).wav")
        return Fixtures.url(name)
    }

    /// Runs the main run loop briefly so `receive(on: RunLoop.main)` level values land.
    private func drainMainRunLoop(_ seconds: TimeInterval = 0.2) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testImmediateReplayDeliversEveryFrameOnceAndPublishesLevels() throws {
        let url = try fixture("short-phrase")
        let file = try AVAudioFile(forReading: url)
        let expectedFrames = Int((Double(file.length) * 16_000 / file.fileFormat.sampleRate).rounded())

        let chunkFrames = 4096
        let lock = NSLock()
        var chunkSizes: [Int] = []
        var totalFrames = 0
        var drainCount = 0

        let drained = expectation(description: "onDrained fires")
        let source = WAVFileAudioSource(url: url, pacing: .immediate, chunkFrames: chunkFrames) {
            lock.lock(); drainCount += 1; lock.unlock()
            drained.fulfill()
        }

        var levels: [Double] = []
        source.levelPublisher.sink { levels.append($0) }.store(in: &cancellables)

        try source.start(deviceUID: nil) { samples in
            lock.lock()
            chunkSizes.append(samples.count)
            totalFrames += samples.count
            lock.unlock()
        }
        wait(for: [drained], timeout: 10)
        drainMainRunLoop()

        lock.lock()
        let sizes = chunkSizes
        let total = totalFrames
        let drains = drainCount
        lock.unlock()

        XCTAssertEqual(drains, 1, "onDrained must fire exactly once")
        XCTAssertLessThanOrEqual(abs(total - expectedFrames), chunkFrames,
                                 "Replayed \(total) frames, expected ~\(expectedFrames)")
        XCTAssertFalse(sizes.isEmpty)
        XCTAssertTrue(sizes.allSatisfy { $0 <= chunkFrames }, "A chunk exceeded chunkFrames: \(sizes.max() ?? 0)")
        XCTAssertTrue(levels.contains { $0 > 0 }, "Expected a non-zero level during speech")

        source.stop()
        drainMainRunLoop()
        XCTAssertEqual(levels.last, 0, "Level must fall back to 0 after stop()")
    }

    func testRealtimePacingSleepsBetweenChunks() throws {
        let url = try fixture("short-phrase")
        let chunkFrames = 4096
        let targetChunk = 5

        let lock = NSLock()
        var count = 0
        var elapsedAtTarget: TimeInterval = 0
        let reached = expectation(description: "reached chunk \(targetChunk)")

        let source = WAVFileAudioSource(url: url, pacing: .realtime, chunkFrames: chunkFrames)
        let started = Date()
        try source.start(deviceUID: nil) { _ in
            lock.lock()
            count += 1
            let isTarget = count == targetChunk
            if isTarget { elapsedAtTarget = Date().timeIntervalSince(started) }
            lock.unlock()
            if isTarget { reached.fulfill() }
        }
        wait(for: [reached], timeout: 10)
        source.stop()

        lock.lock()
        let elapsed = elapsedAtTarget
        lock.unlock()

        // Four inter-chunk sleeps have happened by the time chunk 5 is delivered.
        let expectedSleep = Double(targetChunk - 1) * Double(chunkFrames) / 16_000
        XCTAssertGreaterThanOrEqual(elapsed, expectedSleep * 0.8,
                                    "Realtime pacing delivered \(targetChunk) chunks in \(elapsed)s, expected >= \(expectedSleep * 0.8)s")
    }

    func testStartTwiceThrows() throws {
        let url = try fixture("short-phrase")
        let source = WAVFileAudioSource(url: url, pacing: .realtime, chunkFrames: 1600)
        try source.start(deviceUID: nil) { _ in }
        XCTAssertThrowsError(try source.start(deviceUID: nil) { _ in }) { error in
            XCTAssertEqual(error as? WAVReplayError, .alreadyStarted)
        }
        source.stop()
    }

    /// An end-to-end run drives several recordings through one app launch, so the replay
    /// source has to replay the file again after `stop()` — from the beginning, with
    /// `onDrained` firing once per replay rather than once per process.
    func testRestartAfterStopReplaysFromTheBeginning() throws {
        let url = try fixture("short-phrase")
        let chunkFrames = 4096
        let lock = NSLock()
        var drainCount = 0
        var framesThisRun = 0

        let firstDrain = expectation(description: "first replay drains")
        let secondDrain = expectation(description: "second replay drains")
        let source = WAVFileAudioSource(url: url, pacing: .immediate, chunkFrames: chunkFrames) {
            lock.lock()
            drainCount += 1
            let count = drainCount
            lock.unlock()
            if count == 1 { firstDrain.fulfill() } else if count == 2 { secondDrain.fulfill() }
        }

        try source.start(deviceUID: nil) { samples in
            lock.lock(); framesThisRun += samples.count; lock.unlock()
        }
        wait(for: [firstDrain], timeout: 10)
        source.stop()

        lock.lock()
        let firstRunFrames = framesThisRun
        framesThisRun = 0
        lock.unlock()

        try source.start(deviceUID: nil) { samples in
            lock.lock(); framesThisRun += samples.count; lock.unlock()
        }
        wait(for: [secondDrain], timeout: 10)
        source.stop()

        lock.lock()
        let secondRunFrames = framesThisRun
        let drains = drainCount
        lock.unlock()

        XCTAssertGreaterThan(firstRunFrames, 0)
        XCTAssertEqual(secondRunFrames, firstRunFrames, "The restart must replay the whole file again")
        XCTAssertEqual(drains, 2, "onDrained must fire once per replay")
    }

    func testStopBeforeDrainCancelsWithoutFiringOnDrained() throws {
        let url = try fixture("short-phrase")
        let lock = NSLock()
        var drainFired = false
        let firstChunk = expectation(description: "first chunk delivered")

        let source = WAVFileAudioSource(url: url, pacing: .realtime, chunkFrames: 1600) {
            lock.lock(); drainFired = true; lock.unlock()
        }
        var fulfilled = false
        try source.start(deviceUID: nil) { _ in
            lock.lock()
            let first = !fulfilled
            fulfilled = true
            lock.unlock()
            if first { firstChunk.fulfill() }
        }
        wait(for: [firstChunk], timeout: 10)
        source.stop()
        drainMainRunLoop(0.4)

        lock.lock()
        let fired = drainFired
        lock.unlock()
        XCTAssertFalse(fired, "onDrained must not fire when stop() cancels the replay")
    }
}
