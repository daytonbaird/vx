import Foundation

/// A scenario assertion that did not hold. Distinct from thrown infrastructure
/// errors so the report can tell "the app misbehaved" from "the harness broke".
struct ScenarioFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// An environment problem that means a scenario cannot run at all (missing TCC
/// grant, `--hotkey` not passed). Reported as `skipped`, not `failed`.
struct ScenarioSkipped: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum ScenarioStatus: String {
    case passed
    case failed
    case skipped
}

struct ScenarioResult {
    let name: String
    var status: ScenarioStatus
    var duration: TimeInterval
    var message: String
    /// Paths (absolute) to files the scenario produced: screenshots, event dumps, logs.
    var artifacts: [URL]

    var passed: Bool { status == .passed }
}

/// What a scenario is handed: the running app, its event log, the control socket,
/// and the artifact directory it may write into.
final class ScenarioContext {
    let options: Options
    /// The app under test. Scenarios that need a different launch environment call
    /// `relaunch(env:)`, which replaces the process and resets the event stream.
    private(set) var app: AppUnderTest
    /// Per-scenario artifact directory (`<out>/<scenario-name>/`), created lazily.
    let artifactDir: URL
    private(set) var artifacts: [URL] = []

    init(options: Options, app: AppUnderTest, artifactDir: URL) {
        self.options = options
        self.app = app
        self.artifactDir = artifactDir
    }

    /// Guarded on purpose: a dictation-starting command is refused unless the
    /// scenario is holding a `PasteTarget`. See `GuardedControl`.
    var control: GuardedControl { GuardedControl(control: app.control) }
    /// The raw channel, for the runner's own teardown (`quit`) — not for scenarios.
    var rawControl: Control { app.control }
    var events: EventStream { app.events }

    /// Opens a scratch TextEdit document to catch everything vx pastes, and keeps
    /// it frontmost. Every scenario that can produce a `textInserted` must call this
    /// before the first `begin`/`go start`/hotkey press.
    ///
    /// Release it with `defer { target.release() }`; the runner also releases any
    /// straggler after each scenario so a thrown error cannot leave a document open.
    func acquirePasteTarget() throws -> PasteTarget {
        try PasteTarget.acquire()
    }

    func log(_ message: String) {
        if options.verbose { FileHandle.standardError.write(Data("      \(message)\n".utf8)) }
    }

    /// Registers a file as an artifact of this scenario (shows up in the report).
    @discardableResult
    func record(artifact url: URL) -> URL {
        artifacts.append(url)
        return url
    }

    func artifactURL(_ name: String) -> URL {
        try? FileManager.default.createDirectory(at: artifactDir, withIntermediateDirectories: true)
        return artifactDir.appendingPathComponent(name)
    }

    /// Writes text into the scenario's artifact dir and registers it.
    @discardableResult
    func write(_ text: String, to name: String) -> URL {
        let url = artifactURL(name)
        try? text.write(to: url, atomically: true, encoding: .utf8)
        return record(artifact: url)
    }

    /// Restarts the app under test with extra/overridden environment variables.
    /// Used by `error-backend` (broken backend) and `go-mode` (different fixture).
    ///
    /// `audioSource: nil` means "keep the standard fixture", *not* "no fixture".
    /// Dropping `VX_AUDIO_SOURCE` makes the app fall back to the real microphone,
    /// which records the user's room — never what a scenario wants.
    func relaunchApp(extraEnv: [String: String] = [:], audioSource: URL? = nil) throws {
        try app.relaunch(
            extraEnv: extraEnv,
            audioSource: audioSource ?? options.fixture("short-phrase.wav")
        )
    }

    /// Puts the app back on the default fixture/env after a scenario changed it.
    func restoreDefaultLaunch() throws {
        try app.relaunch(extraEnv: [:], audioSource: options.fixture("short-phrase.wav"))
    }
}

protocol Scenario {
    /// CLI name, e.g. `happy-path`.
    static var name: String { get }
    static var summary: String { get }
    /// True when the scenario posts real CGEvents and therefore needs `--hotkey`.
    static var requiresHotkey: Bool { get }
    /// True when the scenario captures the screen and therefore needs Screen Recording.
    static var requiresScreenCapture: Bool { get }
    /// True when the scenario drives TextEdit and therefore needs Automation.
    static var requiresAutomation: Bool { get }
    /// The scenario changes the launch environment; the runner restores the default
    /// launch before the next scenario.
    static var mutatesLaunchEnvironment: Bool { get }

    init()
    func run(_ ctx: ScenarioContext) throws
}

extension Scenario {
    static var requiresHotkey: Bool { false }
    static var requiresScreenCapture: Bool { false }
    static var requiresAutomation: Bool { false }
    static var mutatesLaunchEnvironment: Bool { false }
}

/// Small assertion helpers so scenarios read as assertions, not as `if … throw`.
enum Expect {
    static func isTrue(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw ScenarioFailure(message()) }
    }

    static func equal<T: Equatable>(_ actual: T, _ expected: T, _ what: String) throws {
        if actual != expected {
            throw ScenarioFailure("\(what): expected \(expected), got \(actual)")
        }
    }

    static func contains(_ haystack: String, _ needle: String, _ what: String) throws {
        if !Normalize.text(haystack).contains(Normalize.text(needle)) {
            throw ScenarioFailure("\(what): expected to contain \"\(needle)\", got \"\(haystack)\"")
        }
    }

    static func notNil<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw ScenarioFailure("\(what): was nil") }
        return value
    }
}

/// Transcripts vary in punctuation and casing run to run; assertions compare on a
/// normalized form so `"The quick brown fox…"` matches `"the quick brown fox"`.
enum Normalize {
    static func text(_ s: String) -> String {
        let lowered = s.lowercased()
        let stripped = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(stripped).split(separator: " ").joined(separator: " ")
    }
}
