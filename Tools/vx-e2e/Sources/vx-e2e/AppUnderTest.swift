import AppKit
import Foundation

/// Shell helper. Everything here is short-lived and synchronous on purpose — the
/// harness is a serial test driver, not a server.
enum Shell {
    @discardableResult
    static func run(
        _ launchPath: String,
        _ args: [String],
        env: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        if let env { process.environment = env }
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Drain both pipes on background queues, *before* waiting.
        //
        // Reading them inline (readDataToEndOfFile on this thread) both deadlocks on a
        // chatty child and — worse — makes `timeout` a lie: the read only returns when
        // the child closes its pipes, so a hung child blocks here forever and the
        // deadline below is never even reached. That is how a wedged `osascript`
        // turned into a two-minute stall in the middle of a run.
        var outData = Data(), errData = Data()
        let lock = NSLock()
        let group = DispatchGroup()
        for (pipe, isOut) in [(outPipe, true), (errPipe, false)] {
            group.enter()
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                if isOut { outData = data } else { errData = data }
                lock.unlock()
                group.leave()
            }
        }

        do { try process.run() } catch {
            return (-1, "", "failed to launch \(launchPath): \(error)")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            let hardDeadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < hardDeadline { usleep(20_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        // The readers finish once the child's pipe ends close, which the exit above
        // guarantees; the wait is bounded anyway so a stuck reader cannot wedge a run.
        _ = group.wait(timeout: .now() + 5)

        lock.lock()
        let out = String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var err = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()
        if timedOut {
            err = "timed out after \(Int(timeout))s and was killed\(err.isEmpty ? "" : "; \(err)")"
        }
        return (timedOut ? -2 : process.terminationStatus, out, err)
    }

    @discardableResult
    static func osascript(_ script: String, timeout: TimeInterval = 20) -> (status: Int32, out: String, err: String) {
        run("/usr/bin/osascript", ["-e", script], timeout: timeout)
    }
}

/// UserDefaults seeds written with `/usr/bin/defaults` before launch.
///
/// `defaults write` is used rather than a plist file because the app reads through
/// `UserDefaults(suiteName:)`, which goes via `cfprefsd` — writing the plist behind
/// its back gets clobbered or cached stale.
struct DefaultsSeed {
    enum Value: Equatable {
        case string(String)
        case bool(Bool)
        case int(Int)
        case float(Double)

        /// The `defaults write` argument pair for this value.
        var arguments: [String] {
            switch self {
            case .string(let s): return ["-string", s]
            case .bool(let b):   return ["-bool", b ? "true" : "false"]
            case .int(let i):    return ["-int", String(i)]
            case .float(let d):  return ["-float", String(d)]
            }
        }
    }

    let key: String
    let value: Value

    /// The full argv for `/usr/bin/defaults write <suite> <key> …`.
    func writeArguments(suite: String) -> [String] {
        ["write", suite, key] + value.arguments
    }
}

/// The persisted form of ⌥Space.
///
/// CONTRACT NOTE: `Shortcut` is *not* Codable-as-JSON despite the plan's wording —
/// `HotkeyMonitor.Shortcut.serialize()` produces the compact string
/// `"<keyCode>:<CGEventFlags.rawValue>"`. kVK_Space = 49, `.maskAlternate` = 0x80000.
/// Keep this in sync with `Shortcut.deserialize`.
enum ShortcutSeed {
    static let spaceKeyCode = 49
    static let maskAlternate: UInt64 = 0x0008_0000

    static var optionSpace: String { "\(spaceKeyCode):\(maskAlternate)" }

    static func combo(keyCode: Int, flags: UInt64) -> String { "\(keyCode):\(flags)" }
}

/// The seeds that make a run hermetic: no sounds, no ducking, no network, no LLM,
/// a known mode and a known hotkey. Anything not listed keeps the app's own default.
enum HermeticSeeds {
    static func all(activationMode: String = "holdToTalk") -> [DefaultsSeed] {
        [
            DefaultsSeed(key: "vx.sound-effects-enabled", value: .bool(false)),
            DefaultsSeed(key: "vx.duck-audio", value: .bool(false)),
            DefaultsSeed(key: "vx.auto-detect-mode", value: .bool(false)),
            DefaultsSeed(key: "vx.ai-post-processing-enabled", value: .bool(false)),
            DefaultsSeed(key: "vx.go-mode-ai-post-processing-enabled", value: .bool(false)),
            // Debug mode auto-opens the Debug Log and Context Inspector windows on
            // launch, which is not hermetic (and makes `visual` capture the wrong
            // window). `DebugLogger` writes vx-debug.log unconditionally, so the
            // `error-backend` log assertion does not need this on.
            DefaultsSeed(key: "vx.debug-mode", value: .bool(false)),
            DefaultsSeed(key: "vx.dictation-mode", value: .string("plain")),
            DefaultsSeed(key: "vx.code-profile", value: .string("generic")),
            DefaultsSeed(key: "vx.activation-mode", value: .string(activationMode)),
            DefaultsSeed(key: "vx.shortcut", value: .string(ShortcutSeed.optionSpace))
        ]
    }
}

enum AppError: Error, CustomStringConvertible {
    case bundleMissing(URL)
    case executableMissing(URL)
    case launchFailed(String)
    case controlNeverAnswered(socket: String, diagnostics: String)
    case died(Int32)

    var description: String {
        switch self {
        case .bundleMissing(let url):
            return "app bundle not found at \(url.path) — run `SKIP_PUBLISH=1 Scripts/package-app.sh` first"
        case .executableMissing(let url):
            return "bundle executable not found at \(url.path)"
        case .launchFailed(let m):
            return "failed to launch the app under test: \(m)"
        case .controlNeverAnswered(let socket, let diagnostics):
            return """
            the app never answered on its control socket (\(socket)).
            This usually means the VX_TEST_CONTROL wiring is not present in the build.
            \(diagnostics)
            """
        case .died(let status):
            return "the app under test exited early (status \(status)) — check the debug log. "
                + "Note the app self-SIGKILLs on a 12 s main-thread watchdog trip."
        }
    }
}

/// Owns the hermetic profile directory, the launched `vx` process, and teardown.
final class AppUnderTest {
    let options: Options
    /// Root for this run's artifacts (`--out`, or a timestamped dir).
    let outDir: URL
    /// UserDefaults suite unique to this run, deleted on teardown.
    let defaultsSuite: String
    /// `VX_CONFIG_HOME` — the app's whole `~` substitute for this run.
    let configHome: URL
    let eventLogURL: URL
    let controlSocketPath: String

    private(set) var process: Process?
    private(set) var pid: pid_t = 0
    private(set) var events: EventStream
    private(set) var control: Control
    /// The bundle path of the user's own `vx` that we quit, so we can put it back.
    private var displacedBundlePath: String?
    private var currentExtraEnv: [String: String] = [:]
    private var currentAudioSource: URL?

    init(options: Options, outDir: URL) {
        self.options = options
        self.outDir = outDir
        // A per-run suite keeps concurrent/repeat runs from colliding and makes the
        // teardown `defaults delete` unambiguous.
        self.defaultsSuite = "com.example.vx.e2e.\(UInt32.random(in: 100_000...999_999))"
        self.configHome = outDir.appendingPathComponent("home")
        self.eventLogURL = outDir.appendingPathComponent("events.jsonl")
        // sockaddr_un caps the path at 104 bytes, and the out dir can be deep, so the
        // socket lives in a short temp path rather than under the profile.
        self.controlSocketPath = "/tmp/vx-e2e-\(UInt32.random(in: 100_000...999_999)).sock"
        self.events = EventStream(url: eventLogURL)
        self.control = Control(socketPath: controlSocketPath)
    }

    var debugLogURL: URL {
        configHome.appendingPathComponent("Library/Logs/vx-debug.log")
    }

    // MARK: - Profile

    /// Creates the profile tree and seeds UserDefaults. Must run before launch:
    /// the app reads its defaults once at init.
    func prepareProfile(activationMode: String = "holdToTalk") throws {
        let fm = FileManager.default
        for sub in ["", "Library/Logs", "Library/Application Support/vx/Models", ".vx"] {
            try fm.createDirectory(at: configHome.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: eventLogURL.path) {
            fm.createFile(atPath: eventLogURL.path, contents: Data())
        }
        for seed in HermeticSeeds.all(activationMode: activationMode) {
            let result = Shell.run("/usr/bin/defaults", seed.writeArguments(suite: defaultsSuite))
            if result.status != 0 {
                throw AppError.launchFailed("defaults write \(seed.key) failed: \(result.err)")
            }
        }
    }

    /// Reads a single key back out of the run's suite. Returns nil when unset.
    func readDefault(_ key: String) -> String? {
        let result = Shell.run("/usr/bin/defaults", ["read", defaultsSuite, key])
        guard result.status == 0 else { return nil }
        return result.out
    }

    func writeDefault(_ seed: DefaultsSeed) {
        Shell.run("/usr/bin/defaults", seed.writeArguments(suite: defaultsSuite))
    }

    // MARK: - Foreign instances

    /// The bundle path of a running `vx`, or nil.
    static func runningVXBundlePath() -> String? {
        let running = NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.example.vx" || $0.localizedName == "vx"
        }
        if let url = running?.bundleURL { return url.path }
        // Fall back to `ps` for a directly-launched executable with no bundle registration.
        let ps = Shell.run("/bin/ps", ["-Axo", "pid=,comm="])
        for line in ps.out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[1].hasSuffix("/vx.app/Contents/MacOS/vx") else { continue }
            return String(parts[1].dropLast("/Contents/MacOS/vx".count))
        }
        return nil
    }

    /// Quits any running `vx`, remembering where it lived so teardown can restore it.
    /// Two instances install competing CGEventTaps for the hotkey, so this is not optional.
    func displaceExistingInstance() {
        guard let path = AppUnderTest.runningVXBundlePath() else { return }
        // Never "restore" the very bundle we are about to drive.
        displacedBundlePath = (path == options.appBundle.path) ? nil : path
        Shell.osascript("tell application \"vx\" to quit", timeout: 8)
        let deadline = Date().addingTimeInterval(6)
        while AppUnderTest.runningVXBundlePath() != nil, Date() < deadline { usleep(150_000) }
        if AppUnderTest.runningVXBundlePath() != nil {
            Shell.run("/usr/bin/pkill", ["-x", "vx"])
            usleep(500_000)
        }
    }

    /// Relaunches whatever copy of `vx` was running before the harness took over.
    func restoreDisplacedInstance() {
        guard let path = displacedBundlePath else { return }
        Shell.run("/usr/bin/open", ["-a", path])
        displacedBundlePath = nil
    }

    // MARK: - Launch

    /// Builds the Runtime Profile environment for a launch.
    func environment(extraEnv: [String: String], audioSource: URL?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["VX_DEFAULTS_SUITE"] = defaultsSuite
        env["VX_CONFIG_HOME"] = configHome.path
        env["VX_EVENT_LOG"] = eventLogURL.path
        env["VX_TEST_CONTROL"] = controlSocketPath
        env["VX_DISABLE_UPDATE_CHECK"] = "1"
        if let audioSource { env["VX_AUDIO_SOURCE"] = audioSource.path }
        for (k, v) in extraEnv { env[k] = v }
        return env
    }

    /// Launches the bundle executable directly.
    ///
    /// `open` is deliberately not used: it hands the launch to launchservices, which
    /// does not pass our environment through, and the whole Runtime Profile is env-based.
    func launch(extraEnv: [String: String] = [:], audioSource: URL? = nil) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: options.appBundle.path) else {
            throw AppError.bundleMissing(options.appBundle)
        }
        guard fm.isExecutableFile(atPath: options.executableURL.path) else {
            throw AppError.executableMissing(options.executableURL)
        }
        currentExtraEnv = extraEnv
        currentAudioSource = audioSource

        // Stale socket from a crashed previous run would make `connect` succeed-ish.
        try? fm.removeItem(atPath: controlSocketPath)

        let process = Process()
        process.executableURL = options.executableURL
        process.environment = environment(extraEnv: extraEnv, audioSource: audioSource)
        let stdoutURL = outDir.appendingPathComponent("app-stdout.log")
        if !fm.fileExists(atPath: stdoutURL.path) { fm.createFile(atPath: stdoutURL.path, contents: Data()) }
        if let handle = try? FileHandle(forWritingTo: stdoutURL) {
            _ = try? handle.seekToEnd()
            process.standardOutput = handle
            process.standardError = handle
        }
        do { try process.run() } catch {
            throw AppError.launchFailed("\(error)")
        }
        self.process = process
        self.pid = process.processIdentifier

        try waitUntilReady()
    }

    /// Terminates and launches again with a different environment. The event log is
    /// left in place (append-only) but the stream is reset so `since:` marks stay honest.
    func relaunch(extraEnv: [String: String] = [:], audioSource: URL? = nil) throws {
        terminate()
        // Truncate rather than delete: a fresh file keeps offsets and marks simple, and
        // the previous run's log is already captured in the scenario's artifacts.
        try? Data().write(to: eventLogURL)
        events.reset()
        try launch(extraEnv: extraEnv, audioSource: audioSource)
    }

    /// Waits for the control socket to answer `ping`, then for `launched` if it shows up.
    private func waitUntilReady(timeout: TimeInterval = 10) throws {
        if control.waitUntilReady(timeout: timeout) {
            // `launched` is best-effort: it may be written before we start tailing.
            _ = try? events.waitForRecord(kind: "launched", timeout: 2)
            return
        }
        if let process, !process.isRunning {
            throw AppError.died(process.terminationStatus)
        }
        throw AppError.controlNeverAnswered(socket: controlSocketPath, diagnostics: diagnostics())
    }

    /// A dump of everything useful when a launch goes wrong. Printed verbatim in the
    /// report so the failure is actionable without re-running by hand.
    func diagnostics() -> String {
        var lines: [String] = []
        let fm = FileManager.default
        lines.append("  socket file present: \(fm.fileExists(atPath: controlSocketPath))  (\(controlSocketPath))")
        lines.append("  process running: \(process?.isRunning ?? false)  pid=\(pid)")
        if let process, !process.isRunning {
            lines.append("  exit status: \(process.terminationStatus)")
        }
        lines.append("  event log: \(eventLogURL.path)")
        let eventText = (try? String(contentsOf: eventLogURL, encoding: .utf8)) ?? ""
        if eventText.isEmpty {
            lines.append("    (empty — no VX_EVENT_LOG output)")
        } else {
            for line in eventText.split(separator: "\n").suffix(20) { lines.append("    \(line)") }
        }
        lines.append("  debug log: \(debugLogURL.path)")
        let debugText = (try? String(contentsOf: debugLogURL, encoding: .utf8)) ?? ""
        if debugText.isEmpty {
            lines.append("    (missing or empty — VX_CONFIG_HOME may not be honored)")
        } else {
            for line in debugText.split(separator: "\n").suffix(25) { lines.append("    \(line)") }
        }
        let stdoutURL = outDir.appendingPathComponent("app-stdout.log")
        let stdoutText = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        if !stdoutText.isEmpty {
            lines.append("  app stdout/stderr tail:")
            for line in stdoutText.split(separator: "\n").suffix(25) { lines.append("    \(line)") }
        }
        return lines.joined(separator: "\n")
    }

    var debugLogContents: String {
        (try? String(contentsOf: debugLogURL, encoding: .utf8)) ?? ""
    }

    // MARK: - Teardown

    /// Asks nicely over the control channel, then SIGTERM, then SIGKILL.
    func terminate() {
        guard let process, process.isRunning else { self.process = nil; return }
        _ = try? control.send("quit")
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { usleep(100_000) }
        if process.isRunning {
            process.terminate()
            let hardDeadline = Date().addingTimeInterval(3)
            while process.isRunning, Date() < hardDeadline { usleep(100_000) }
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        self.process = nil
    }

    /// Full cleanup: kill the app, drop the throwaway defaults domain, remove the
    /// socket, and put the user's own copy of vx back where it was.
    func teardown(keepApp: Bool) {
        if !keepApp {
            terminate()
            deleteDefaultsSuite()
            try? FileManager.default.removeItem(atPath: controlSocketPath)
            PasteTarget.releaseActive()
            restoreDisplacedInstance()
        }
    }

    /// Drops the run's throwaway UserDefaults domain, file and all.
    ///
    /// `defaults delete` empties the domain but leaves a zero-key plist sitting in
    /// ~/Library/Preferences forever, so a machine that has run the harness a few
    /// hundred times accumulates a few hundred `com.example.vx.e2e.*.plist` files.
    /// Deleting the file after the domain is what actually makes a run leave no
    /// trace. (cfprefsd may rewrite it between the two steps, so the removal runs
    /// after a short settle and is retried once.)
    private func deleteDefaultsSuite() {
        Shell.run("/usr/bin/defaults", ["delete", defaultsSuite])
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(defaultsSuite).plist")
        for attempt in 0..<2 {
            if attempt > 0 { usleep(300_000) }
            try? FileManager.default.removeItem(at: plist)
            if !FileManager.default.fileExists(atPath: plist.path) { return }
        }
    }
}
