import Foundation

/// The core loop, driven entirely over the control socket: begin → the WAV drains →
/// finish → transcript → insertion. No TCC grants required, so this is the scenario
/// that must pass on any machine.
struct HappyPathScenario: Scenario {
    static let name = "happy-path"
    static let summary = "Control-driven record → transcribe → insert, with event ordering"
    // The assertions are all on the event log, but the app still performs a real
    // Cmd+V at the end of the take, so this needs a paste target like any other
    // dictation — without one the transcript lands in whatever the user is using.
    static var requiresAutomation: Bool { true }

    func run(_ ctx: ScenarioContext) throws {
        let target = try ctx.acquirePasteTarget()
        defer { target.release() }

        let mark = ctx.events.mark()

        try ctx.control.require("begin")
        try ctx.events.waitForFlow("recordingStarted", since: mark, timeout: 8)
        ctx.log("recording started")

        // `VX_AUDIO_SOURCE` replays the fixture in real time and holds the source open
        // once drained, so the harness stops the recording rather than racing the file.
        try ctx.events.waitForFlow("audioSourceDrained", since: mark, timeout: 20)
        ctx.log("fixture drained")

        try ctx.control.require("finish")
        let inserted = try ctx.events.waitForFlow("textInserted", since: mark, timeout: 30)

        let text = try Expect.notNil(inserted.firstValue, "textInserted payload (_0)")
        try Expect.contains(text, "quick brown fox", "inserted transcript")

        try ctx.events.assertOrder([
            "recordingStarted",
            "audioSourceDrained",
            "recordingWillStop",
            "transcribing",
            "transcriptReceived",
            "textInserted"
        ], since: mark)

        ctx.write(ctx.events.transcript(since: mark), to: "events.txt")
        // Let the app's pasteboard restore finish before the next scenario runs.
        usleep(1_200_000)
    }
}

/// The same flow, but proving the paste actually lands in a foreign app.
struct HappyPathTextEditScenario: Scenario {
    static let name = "happy-path-textedit"
    static let summary = "Record → transcribe → paste into a real TextEdit document"
    static var requiresAutomation: Bool { true }

    func run(_ ctx: ScenarioContext) throws {
        let target = try ctx.acquirePasteTarget()
        defer { target.release() }

        let mark = ctx.events.mark()
        try ctx.control.require("begin")
        try ctx.events.waitForFlow("recordingStarted", since: mark, timeout: 8)
        try ctx.events.waitForFlow("audioSourceDrained", since: mark, timeout: 20)
        try ctx.control.require("finish")
        try ctx.events.waitForFlow("textInserted", since: mark, timeout: 30)

        // The app restores the user's previous pasteboard shortly after pasting.
        // Reading (let alone writing) the pasteboard inside that window would race
        // the restore and could corrupt the user's clipboard — so the assertion is
        // made against the document text only, and nothing here touches NSPasteboard.
        guard let text = target.waitForText(containing: "quick brown fox", timeout: 5) else {
            let actual = target.text() ?? "<no document>"
            throw ScenarioFailure("TextEdit document never received the transcript; content was \"\(actual)\"")
        }
        ctx.write(text, to: "textedit-document.txt")
        ctx.write(ctx.events.transcript(since: mark), to: "events.txt")

        // Let the app's pasteboard restore finish before the next scenario runs.
        usleep(1_200_000)
    }
}

/// Hold-to-talk over real ⌥Space CGEvents. The only scenario that exercises the
/// CGEventTap itself, which is why it needs Input Monitoring and is gated on `--hotkey`.
struct HotkeyScenario: Scenario {
    static let name = "hotkey"
    static let summary = "Real ⌥Space hold-to-talk into TextEdit (requires --hotkey)"
    static var requiresHotkey: Bool { true }
    static var requiresAutomation: Bool { true }

    func run(_ ctx: ScenarioContext) throws {
        guard ctx.options.hotkey else {
            throw ScenarioSkipped("posts real CGEvents; pass --hotkey to enable")
        }
        guard Keys.canPostEvents else {
            throw ScenarioSkipped("Input Monitoring is not granted to the responsible process")
        }
        let target = try ctx.acquirePasteTarget()
        defer { target.release() }

        let mark = ctx.events.mark()
        try Keys.optionSpaceDown()
        do {
            try ctx.events.waitForFlow("recordingStarted", since: mark, timeout: 8)
            try ctx.events.waitForFlow("audioSourceDrained", since: mark, timeout: 20)
        } catch {
            // Never leave a modifier or key stuck down for the user.
            Keys.optionSpaceUp()
            throw error
        }
        Keys.optionSpaceUp()

        try ctx.events.waitForFlow("textInserted", since: mark, timeout: 30)
        guard let text = target.waitForText(containing: "quick brown fox", timeout: 5) else {
            throw ScenarioFailure(
                "hotkey flow inserted no matching text into TextEdit; document was "
                    + "\"\(target.text() ?? "<no document>")\""
            )
        }
        ctx.write(text, to: "textedit-document.txt")
        ctx.write(ctx.events.transcript(since: mark), to: "events.txt")
        usleep(1_200_000)
    }
}

/// begin → cancel discards the take: `cancelled` fires and nothing is ever pasted.
struct CancelScenario: Scenario {
    static let name = "cancel"
    static let summary = "begin → cancel emits `cancelled` and inserts nothing"
    // Nothing *should* be pasted here — which is exactly why a paste target is
    // required. If the cancel path ever regresses into pasting, the text lands in
    // the scratch document instead of in whatever the user was typing into.
    static var requiresAutomation: Bool { true }

    func run(_ ctx: ScenarioContext) throws {
        let target = try ctx.acquirePasteTarget()
        defer { target.release() }

        let mark = ctx.events.mark()
        try ctx.control.require("begin")
        try ctx.events.waitForFlow("recordingStarted", since: mark, timeout: 8)
        try ctx.control.require("cancel")
        try ctx.events.waitForFlow("cancelled", since: mark, timeout: 8)

        // The real regression risk is a cancel that still pastes; watch for it.
        try ctx.events.expectAbsent("textInserted after cancel", since: mark, window: 2) {
            $0.isFlow("textInserted")
        }
        // Belt and braces: the event log says nothing was inserted, and the document
        // agrees. A paste that bypassed the flow events would show up here.
        let leftover = target.text() ?? ""
        try Expect.isTrue(
            leftover.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "cancel should leave the paste target empty, but it contained \"\(leftover)\""
        )
        ctx.write(ctx.events.transcript(since: mark), to: "events.txt")
    }
}

/// Go Mode: continuous dictation that submits each utterance separately.
struct GoModeScenario: Scenario {
    static let name = "go-mode"
    static let summary = "Go Mode inserts both utterances from two-utterances.wav"
    static var mutatesLaunchEnvironment: Bool { true }
    static var requiresAutomation: Bool { true }

    func run(_ ctx: ScenarioContext) throws {
        let fixture = ctx.options.fixture("two-utterances.wav")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw ScenarioSkipped("fixture missing: \(fixture.path)")
        }
        try ctx.relaunchApp(audioSource: fixture)

        // Go Mode inserts each utterance as it is segmented, so the target has to be
        // in place — and stay frontmost — for the whole run, not just at the end.
        let target = try ctx.acquirePasteTarget()
        defer { target.release() }

        let mark = ctx.events.mark()
        try ctx.control.require("go start")
        try ctx.events.waitForFlow("goModeStarted", since: mark, timeout: 8)

        // The fixture is two sentences with a 1.5 s gap, replayed in real time. The gap
        // segments the first utterance mid-file, so that one lands on its own. The
        // second has no trailing silence to segment against — the file simply ends, and
        // the replay source then goes quiet rather than feeding silence — so it stays
        // pending until Go Mode is stopped, which is also what a user does when they
        // finish speaking. Hence: drain, stop, then require *both*.
        try ctx.events.waitForFlow("audioSourceDrained", since: mark, timeout: 30)
        ctx.log("fixture drained; insertions so far: \(insertions(ctx, since: mark).count)")

        try ctx.control.require("go stop")
        let stopped = try ctx.events.waitForFlow("goModeStopped", since: mark, timeout: 15)
        try Expect.equal(stopped.bool("cancelled") ?? false, false, "goModeStopped.cancelled")

        // The flush of the final utterance follows the stop, so keep collecting after it.
        var found: [String] = []
        let deadline = Date().addingTimeInterval(20)
        repeat {
            found = insertions(ctx, since: mark)
            if found.count >= 2 { break }
            usleep(200_000)
        } while Date() < deadline

        ctx.write(ctx.events.transcript(since: mark), to: "events.txt")
        try Expect.isTrue(
            found.count >= 2,
            "Go Mode should segment two-utterances.wav into two insertions; saw \(found.count): \(found)"
        )
        // Both utterances, and in the order they were spoken.
        try Expect.contains(found[0], "first sentence", "Go Mode insertion 1")
        try Expect.contains(found[1], "second sentence", "Go Mode insertion 2")

        // Everything Go Mode inserted must have landed in the scratch document.
        let document = target.text() ?? ""
        try Expect.contains(document, "first sentence", "Go Mode paste target")
        try Expect.contains(document, "second sentence", "Go Mode paste target")
        usleep(1_200_000)
    }

    /// Every `textInserted` payload logged since `mark`.
    private func insertions(_ ctx: ScenarioContext, since mark: Int) -> [String] {
        ctx.events.drain()
        return ctx.events.events[min(mark, ctx.events.events.count)...]
            .filter { $0.isFlow("textInserted") }
            .compactMap(\.firstValue)
    }
}

/// A backend that cannot run must surface as a `failed` event, an error HUD, and a
/// log line — not a silent no-op or a hang.
struct ErrorBackendScenario: Scenario {
    static let name = "error-backend"
    static let summary = "A broken VX_BACKEND_PATH surfaces `failed`, an error HUD, and a log line"
    static var mutatesLaunchEnvironment: Bool { true }
    static var requiresAutomation: Bool { true }

    func run(_ ctx: ScenarioContext) throws {
        // /usr/bin/false is executable (so the path override is honored) and exits 1.
        //
        // The fixture must be passed explicitly: `relaunchApp` defaults `audioSource`
        // to nil, which drops VX_AUDIO_SOURCE and makes the app open the *real
        // microphone* — recording the user's room for the length of the scenario.
        try ctx.relaunchApp(
            extraEnv: ["VX_BACKEND_PATH": "/usr/bin/false"],
            audioSource: ctx.options.fixture("short-phrase.wav")
        )

        // A failing backend should insert nothing, but "should" is the thing under
        // test — hold a paste target so a regression cannot escape into the session.
        let target = try ctx.acquirePasteTarget()
        defer { target.release() }

        let mark = ctx.events.mark()
        try ctx.control.require("begin")
        try ctx.events.waitForFlow("recordingStarted", since: mark, timeout: 8)
        try ctx.control.require("finish")

        let failure = try ctx.events.waitForFlow("failed", since: mark, timeout: 30)
        ctx.log("failed: \(failure.firstValue ?? "")")
        try ctx.events.waitForRecord(kind: "hudState", field: "style", equals: "error", since: mark, timeout: 10)

        // The hermetic profile's own log — proof VX_CONFIG_HOME redirected logging too.
        let log = ctx.app.debugLogContents
        ctx.write(log, to: "vx-debug.log")
        try Expect.isTrue(
            log.contains("[coordinator/error]"),
            "hermetic debug log (\(ctx.app.debugLogURL.path)) should contain [coordinator/error]"
        )
        ctx.write(ctx.events.transcript(since: mark), to: "events.txt")
    }
}
