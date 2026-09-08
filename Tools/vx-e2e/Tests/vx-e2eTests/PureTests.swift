import Darwin
import XCTest
@testable import vx_e2e

// These tests cover only the pure parts of the harness — parsing, encoding, and the
// file-tailing logic. Nothing here touches AX, TCC, the control socket, or a real app,
// so `swift test` is safe to run anywhere, including CI without a signed-in session.

// MARK: - Event parsing

final class EventParsingTests: XCTestCase {
    func testParsesFlowEventWithUnlabeledPayload() throws {
        let line = #"{"event":{"textInserted":{"_0":"The quick brown fox.","behavior":"paste"}},"t":"2026-09-08T12:00:00Z"}"#
        let event = try XCTUnwrap(Event.parse(line: line))
        XCTAssertTrue(event.isFlow("textInserted"))
        XCTAssertEqual(event.firstValue, "The quick brown fox.")
        XCTAssertEqual(event.string("behavior"), "paste")
        XCTAssertNotNil(event.timestamp)
    }

    func testParsesFlowEventWithEmptyPayload() throws {
        let event = try XCTUnwrap(Event.parse(line: #"{"event":{"recordingStarted":{}},"t":"2026-09-08T12:00:00Z"}"#))
        XCTAssertTrue(event.isFlow("recordingStarted"))
        XCTAssertNil(event.firstValue)
    }

    func testParsesFlowEventWithTypedPayload() throws {
        let line = #"{"event":{"processed":{"mode":"plain","profile":"generic","ruleCount":3,"transformed":true}},"t":"2026-09-08T12:00:00Z"}"#
        let event = try XCTUnwrap(Event.parse(line: line))
        XCTAssertEqual(event.string("mode"), "plain")
        XCTAssertEqual(event.int("ruleCount"), 3)
        XCTAssertEqual(event.bool("transformed"), true)
    }

    func testParsesRecordShape() throws {
        let line = #"{"fields":{"pid":4242,"version":"1.0.44"},"kind":"launched","t":"2026-09-08T12:00:00Z"}"#
        let event = try XCTUnwrap(Event.parse(line: line))
        XCTAssertTrue(event.isRecord("launched"))
        XCTAssertEqual(event.string("version"), "1.0.44")
        XCTAssertEqual(event.int("pid"), 4242)
        XCTAssertFalse(event.isFlow)
    }

    func testParsesHudStateRecord() throws {
        let line = #"{"fields":{"state":"listening","style":"recording"},"kind":"hudState","t":"2026-09-08T12:00:00Z"}"#
        let event = try XCTUnwrap(Event.parse(line: line))
        XCTAssertEqual(event.string("style"), "recording")
        XCTAssertEqual(event.string("state"), "listening")
    }

    func testUnknownKindsAndCasesParseLeniently() throws {
        // Forward compatibility: the app adding an event must never break the harness.
        let newCase = try XCTUnwrap(Event.parse(line: #"{"event":{"someFutureThing":{"x":1}},"t":"2026-09-08T12:00:00Z"}"#))
        XCTAssertTrue(newCase.isFlow("someFutureThing"))

        let newKind = try XCTUnwrap(Event.parse(line: #"{"fields":{},"kind":"telemetry","t":"2026-09-08T12:00:00Z"}"#))
        XCTAssertTrue(newKind.isRecord("telemetry"))
    }

    func testMalformedLineBecomesUnknownRatherThanThrowing() throws {
        let event = try XCTUnwrap(Event.parse(line: "not json at all"))
        if case .unknown = event {} else { XCTFail("expected .unknown, got \(event)") }
    }

    func testBlankLinesAreIgnored() {
        XCTAssertNil(Event.parse(line: ""))
        XCTAssertNil(Event.parse(line: "   \n"))
    }

    func testFractionalAndPlainTimestampsBothParse() {
        XCTAssertNotNil(Event.parseTimestamp("2026-09-08T12:00:00Z"))
        XCTAssertNotNil(Event.parseTimestamp("2026-09-08T12:00:00.123Z"))
        XCTAssertNil(Event.parseTimestamp("yesterday"))
    }
}

// MARK: - Tailing

final class EventStreamTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vx-e2e-test-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    private func append(_ line: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func flow(_ name: String) -> String {
        #"{"event":{"\#(name)":{}},"t":"2026-09-08T12:00:00Z"}"#
    }

    func testDrainReadsOnlyNewBytes() throws {
        let stream = EventStream(url: url)
        try append(flow("recordingStarted"))
        XCTAssertEqual(stream.drain().count, 1)
        XCTAssertEqual(stream.drain().count, 0, "a second drain with no new bytes should yield nothing")
        try append(flow("transcribing"))
        XCTAssertEqual(stream.drain().map(\.name), ["transcribing"])
        XCTAssertEqual(stream.events.count, 2)
    }

    func testPartialLineIsBufferedUntilItsNewlineArrives() throws {
        let stream = EventStream(url: url)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        // Simulate catching the app mid-write.
        try handle.write(contentsOf: Data(#"{"event":{"transcribing"#.utf8))
        try handle.close()
        XCTAssertEqual(stream.drain().count, 0, "an incomplete line must not be parsed")

        try append(#"":{}},"t":"2026-09-08T12:00:00Z"}"#)
        XCTAssertEqual(stream.drain().map(\.name), ["transcribing"])
    }

    func testWaitSucceedsWhenTheFileGrows() throws {
        let stream = EventStream(url: url)
        let writer = DispatchQueue(label: "writer")
        writer.asyncAfter(deadline: .now() + 0.3) { try? self.append(self.flow("textInserted")) }
        let event = try stream.wait(for: "textInserted", timeout: 5) { $0.isFlow("textInserted") }
        XCTAssertEqual(event.name, "textInserted")
    }

    func testWaitTimesOutWithTheEventsItDidSee() throws {
        let stream = EventStream(url: url)
        try append(flow("recordingStarted"))
        XCTAssertThrowsError(try stream.waitForFlow("textInserted", timeout: 0.4)) { error in
            guard case EventStreamError.timeout(_, let seen) = error else {
                return XCTFail("expected .timeout, got \(error)")
            }
            XCTAssertEqual(seen.map(\.name), ["recordingStarted"])
        }
    }

    func testMarkScopesWaitsToAPhase() throws {
        let stream = EventStream(url: url)
        try append(flow("textInserted"))
        _ = stream.drain()
        let mark = stream.mark()
        // The earlier textInserted is before the mark, so this must time out.
        XCTAssertThrowsError(try stream.waitForFlow("textInserted", since: mark, timeout: 0.3))
        try append(flow("textInserted"))
        XCTAssertNoThrow(try stream.waitForFlow("textInserted", since: mark, timeout: 2))
    }

    func testAssertOrderAcceptsInterleavedEvents() throws {
        let stream = EventStream(url: url)
        for name in ["recordingStarted", "audioSourceDrained", "hudNoise", "recordingWillStop",
                     "transcribing", "transcriptReceived", "textInserted"] {
            try append(flow(name))
        }
        _ = stream.drain()
        XCTAssertNoThrow(try stream.assertOrder([
            "recordingStarted", "audioSourceDrained", "recordingWillStop",
            "transcribing", "transcriptReceived", "textInserted"
        ]))
    }

    func testAssertOrderRejectsAnOutOfOrderFlow() throws {
        let stream = EventStream(url: url)
        try append(flow("textInserted"))
        try append(flow("transcribing"))
        _ = stream.drain()
        XCTAssertThrowsError(try stream.assertOrder(["transcribing", "textInserted"]))
    }

    func testExpectAbsentThrowsWhenTheEventShowsUp() throws {
        let stream = EventStream(url: url)
        try append(flow("textInserted"))
        XCTAssertThrowsError(try stream.expectAbsent("textInserted", window: 0.3) { $0.isFlow("textInserted") })
    }

    func testResetRewindsForARelaunch() throws {
        let stream = EventStream(url: url)
        try append(flow("recordingStarted"))
        _ = stream.drain()
        stream.reset()
        XCTAssertEqual(stream.events.count, 0)
        XCTAssertEqual(stream.drain().count, 1, "after reset the whole file is re-read")
    }
}

// MARK: - Control replies

final class ControlReplyTests: XCTestCase {
    func testParsesBareOK() {
        XCTAssertEqual(ControlReply.parse("ok"), .ok)
        XCTAssertEqual(ControlReply.parse("ok\n"), .ok)
        XCTAssertEqual(ControlReply.parse("  ok  "), .ok)
    }

    func testParsesOKWithJSON() throws {
        let reply = ControlReply.parse(#"ok {"isRecording":true,"isGoModeActive":false,"hud":{"state":"listening","style":"recording"}}"#)
        XCTAssertTrue(reply.isOK)
        let json = try XCTUnwrap(reply.json)
        XCTAssertEqual(json["isRecording"] as? Bool, true)
        let hud = try XCTUnwrap(json["hud"] as? [String: Any])
        XCTAssertEqual(hud["style"] as? String, "recording")
    }

    func testParsesError() {
        let reply = ControlReply.parse("err no such command: frobnicate")
        XCTAssertFalse(reply.isOK)
        XCTAssertEqual(reply, .error("no such command: frobnicate"))
    }

    func testUnparseableReplyIsAnErrorNotASilentOK() {
        let reply = ControlReply.parse("what?")
        XCTAssertFalse(reply.isOK)
    }

    func testOKWithNoPayloadAfterSpaceIsStillOK() {
        XCTAssertEqual(ControlReply.parse("ok "), .ok)
    }
}

// MARK: - Options

final class OptionsTests: XCTestCase {
    func testParsesRunWithFlags() throws {
        let opts = try Options.parse(["run", "happy-path", "--kill-existing", "--hotkey", "--out", "/tmp/x"])
        XCTAssertEqual(opts.command, .run(scenarios: ["happy-path"]))
        XCTAssertTrue(opts.killExisting)
        XCTAssertTrue(opts.hotkey)
        XCTAssertEqual(opts.outDir?.path, "/tmp/x")
    }

    func testParsesCommaSeparatedScenarios() throws {
        let opts = try Options.parse(["run", "happy-path,cancel"])
        XCTAssertEqual(opts.command, .run(scenarios: ["happy-path", "cancel"]))
    }

    func testParsesSpaceSeparatedScenarios() throws {
        let opts = try Options.parse(["run", "happy-path", "cancel"])
        XCTAssertEqual(opts.command, .run(scenarios: ["happy-path", "cancel"]))
    }

    func testPreflightAndList() throws {
        XCTAssertEqual(try Options.parse(["preflight"]).command, .preflight(prompt: false))
        XCTAssertEqual(try Options.parse(["preflight", "--prompt"]).command, .preflight(prompt: true))
        XCTAssertEqual(try Options.parse(["list"]).command, .list)
        XCTAssertEqual(try Options.parse([]).command, .help)
        XCTAssertEqual(try Options.parse(["run", "--help"]).command, .help)
    }

    func testRejectsBadInput() {
        XCTAssertThrowsError(try Options.parse(["frobnicate"]))
        XCTAssertThrowsError(try Options.parse(["run"]))
        XCTAssertThrowsError(try Options.parse(["run", "happy-path", "--nope"]))
        XCTAssertThrowsError(try Options.parse(["run", "happy-path", "--out"]))
    }

    func testDefaultsPointAtTheWorkspace() throws {
        let opts = try Options.parse(["list"])
        XCTAssertTrue(opts.appBundle.path.hasSuffix("vx-ui/build/vx.app"))
        XCTAssertEqual(opts.executableURL.lastPathComponent, "vx")
        XCTAssertTrue(opts.fixture("short-phrase.wav").path.hasSuffix("fixtures/audio/short-phrase.wav"))
    }

    func testDefaultOutDirIsTimestampedUnderBuildVerify() throws {
        let opts = try Options.parse(["run", "happy-path"])
        let path = opts.resolvedOutDir().path
        XCTAssertTrue(path.contains("vx-ui/build/verify/"), path)
        let stamp = URL(fileURLWithPath: path).lastPathComponent
        XCTAssertEqual(stamp.count, 15, "expected yyyyMMdd-HHmmss, got \(stamp)")
    }
}

// MARK: - Defaults seeding

final class DefaultsSeedTests: XCTestCase {
    func testOptionSpaceUsesTheAppsCompactSerialization() {
        // CONTRACT: Shortcut.serialize() is "<keyCode>:<CGEventFlags.rawValue>", not JSON.
        // kVK_Space = 49, .maskAlternate = 0x80000 = 524288.
        XCTAssertEqual(ShortcutSeed.optionSpace, "49:524288")
        XCTAssertEqual(ShortcutSeed.maskAlternate, 524_288)
    }

    func testShortcutSeedIsWrittenAsAString() {
        let seed = DefaultsSeed(key: "vx.shortcut", value: .string(ShortcutSeed.optionSpace))
        XCTAssertEqual(
            seed.writeArguments(suite: "com.example.vx.e2e.1"),
            ["write", "com.example.vx.e2e.1", "vx.shortcut", "-string", "49:524288"]
        )
    }

    func testValueEncodings() {
        XCTAssertEqual(DefaultsSeed.Value.bool(false).arguments, ["-bool", "false"])
        XCTAssertEqual(DefaultsSeed.Value.bool(true).arguments, ["-bool", "true"])
        XCTAssertEqual(DefaultsSeed.Value.int(7).arguments, ["-int", "7"])
        XCTAssertEqual(DefaultsSeed.Value.string("plain").arguments, ["-string", "plain"])
    }

    func testHermeticSeedsCoverEveryNondeterministicSetting() {
        let seeds = HermeticSeeds.all()
        let keys = Set(seeds.map(\.key))
        for key in ["vx.sound-effects-enabled", "vx.duck-audio", "vx.auto-detect-mode",
                    "vx.ai-post-processing-enabled", "vx.dictation-mode",
                    "vx.activation-mode", "vx.shortcut"] {
            XCTAssertTrue(keys.contains(key), "missing hermetic seed for \(key)")
        }
        // DictationMode.plainText's raw value is "plain", not "plainText".
        let mode = seeds.first { $0.key == "vx.dictation-mode" }
        XCTAssertEqual(mode?.value, .string("plain"))
        // ActivationMode has no custom raw values, so the case name is the raw value.
        let activation = seeds.first { $0.key == "vx.activation-mode" }
        XCTAssertEqual(activation?.value, .string("holdToTalk"))
        XCTAssertEqual(HermeticSeeds.all(activationMode: "toggle").first { $0.key == "vx.activation-mode" }?.value,
                       .string("toggle"))
    }
}

// MARK: - Normalization & registry

final class MiscTests: XCTestCase {
    func testNormalizeIgnoresPunctuationAndCase() {
        XCTAssertEqual(Normalize.text("The quick, brown FOX!"), "the quick brown fox")
        XCTAssertTrue(Normalize.text("The quick brown fox jumps.").contains(Normalize.text("quick brown fox")))
    }

    func testExpectContainsComparesNormalized() {
        XCTAssertNoThrow(try Expect.contains("The Quick, Brown Fox.", "quick brown fox", "transcript"))
        XCTAssertThrowsError(try Expect.contains("something else", "quick brown fox", "transcript"))
    }

    func testRegistryNamesAreUniqueAndResolvable() throws {
        let names = Registry.all.map { $0.name }
        XCTAssertEqual(Set(names).count, names.count, "duplicate scenario name")
        XCTAssertEqual(try Registry.resolve(["all"]).count, Registry.all.count)
        XCTAssertEqual(try Registry.resolve(["happy-path"]).map { $0.name }, ["happy-path"])
        XCTAssertThrowsError(try Registry.resolve(["nope"]))
    }

    func testEveryScenarioMentionedInThePlanIsRegistered() {
        let names = Set(Registry.all.map { $0.name })
        for expected in ["happy-path", "happy-path-textedit", "hotkey", "menu-mode", "menu-history",
                         "prefs", "error-backend", "cancel", "go-mode", "visual"] {
            XCTAssertTrue(names.contains(expected), "scenario \(expected) is not registered")
        }
    }

    /// vx pastes into whatever app is frontmost, so a scenario that starts a
    /// dictation without a TextEdit paste target types the transcript into the
    /// user's own session. That happened; these two tests are the regression guard.
    func testDictationStartingCommandsAreRecognised() {
        for command in ["begin", "toggle", "go start", "GO START", "go   start"] {
            XCTAssertTrue(
                ControlCommand.startsDictation(command),
                "\(command) starts a dictation and must require a paste target"
            )
        }
        for command in ["ping", "state", "finish", "cancel", "go stop", "go cancel",
                        "hud recording", "open preferences:sound", "history", "quit"] {
            XCTAssertFalse(
                ControlCommand.startsDictation(command),
                "\(command) does not start a dictation and must not be gated"
            )
        }
    }

    func testEveryScenarioThatCanPasteDeclaresAutomation() {
        // Anything that sends begin/toggle/go start, or presses the hotkey, ends in a
        // real Cmd+V — so it needs the Automation grant to open a paste target, and
        // must be skipped rather than run (and leak text) when that grant is missing.
        let canPaste = ["happy-path", "happy-path-textedit", "hotkey", "cancel",
                        "menu-history", "error-backend", "go-mode"]
        for name in canPaste {
            guard let type = Registry.lookup(name) else {
                XCTFail("scenario \(name) is not registered")
                continue
            }
            XCTAssertTrue(
                type.requiresAutomation,
                "\(name) can trigger a paste and must declare requiresAutomation"
            )
        }
        // `visual` only drives the HUD and never dictates, so it needs no target.
        XCTAssertEqual(Registry.lookup("visual")?.requiresAutomation, false)
    }

    func testReportSummaryJSONIsWellFormed() throws {
        let results = [
            ScenarioResult(name: "happy-path", status: .passed, duration: 1.5, message: "", artifacts: []),
            ScenarioResult(name: "hotkey", status: .skipped, duration: 0, message: "needs --hotkey", artifacts: [])
        ]
        let json = Report.summaryJSON(results, totalDuration: 1.5)
        let obj = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(obj["passed"] as? Int, 1)
        XCTAssertEqual(obj["skipped"] as? Int, 1)
        XCTAssertEqual(obj["failed"] as? Int, 0)
        XCTAssertEqual((obj["scenarios"] as? [[String: Any]])?.count, 2)
    }
}

// MARK: - Control client against a loopback server

/// Exercises the POSIX socket client against a stub server in this process. Still
/// pure — no app, no TCC — but it is the only way to cover connect/write/read framing.
final class ControlClientTests: XCTestCase {
    private var socketPath: String!
    private var listenFD: Int32 = -1
    private var serverQueue: DispatchQueue!
    private var shouldStop = false

    override func setUpWithError() throws {
        // Short path: sockaddr_un caps sun_path at 104 bytes.
        socketPath = "/tmp/vx-e2e-t-\(UInt32.random(in: 100_000...999_999)).sock"
        serverQueue = DispatchQueue(label: "stub-control-server")
    }

    override func tearDownWithError() throws {
        shouldStop = true
        if listenFD >= 0 { Darwin.close(listenFD) }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    /// Accepts connections and answers each newline-terminated command with `handler`.
    private func startServer(handler: @escaping (String) -> String) throws {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        listenFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listenFD, 0)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0, "bind failed: \(String(cString: strerror(errno)))")
        XCTAssertEqual(Darwin.listen(listenFD, 8), 0)

        let fd = listenFD
        serverQueue.async { [weak self] in
            while self?.shouldStop == false {
                let client = Darwin.accept(fd, nil, nil)
                if client < 0 { return }
                var buffer = [UInt8](repeating: 0, count: 1024)
                let n = Darwin.read(client, &buffer, buffer.count)
                if n > 0 {
                    let command = String(decoding: buffer[0..<n], as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let reply = handler(command) + "\n"
                    _ = Array(reply.utf8).withUnsafeBytes { Darwin.write(client, $0.baseAddress!, $0.count) }
                }
                Darwin.close(client)
            }
        }
        // Let the listener come up before the first connect.
        usleep(200_000)
    }

    func testPingAndStateRoundTrip() throws {
        try startServer { command in
            switch command {
            case "ping":  return "ok"
            case "state": return #"ok {"isRecording":false,"isGoModeActive":false,"isTranscribing":false}"#
            default:      return "err unknown command: \(command)"
            }
        }
        let control = Control(socketPath: socketPath, timeout: 3)
        XCTAssertTrue(control.socketExists)
        XCTAssertTrue(control.pings())
        XCTAssertTrue(control.waitUntilReady(timeout: 2))

        let state = try control.state()
        XCTAssertEqual(state["isRecording"] as? Bool, false)

        // `require` must surface an `err` reply as a thrown error, not a silent pass.
        XCTAssertThrowsError(try control.require("frobnicate"))
        XCTAssertEqual(try control.send("frobnicate"), .error("unknown command: frobnicate"))
    }

    func testWaitUntilReadyFailsWhenNothingIsListening() {
        let control = Control(socketPath: "/tmp/vx-e2e-definitely-not-here.sock", timeout: 1)
        XCTAssertFalse(control.socketExists)
        XCTAssertFalse(control.pings())
        XCTAssertFalse(control.waitUntilReady(timeout: 0.5))
    }

    func testConnectingToAMissingSocketThrows() {
        let control = Control(socketPath: "/tmp/vx-e2e-definitely-not-here.sock", timeout: 1)
        XCTAssertThrowsError(try control.send("ping"))
    }
}
