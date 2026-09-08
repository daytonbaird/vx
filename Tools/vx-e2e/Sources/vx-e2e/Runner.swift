import Foundation

/// The scenario registry and the serial driver that runs them.
enum Registry {
    /// Order matters: cheap control-driven checks first, so a broken build fails fast
    /// before the slow AX and screenshot scenarios spend a minute finding out.
    static let all: [Scenario.Type] = [
        HappyPathScenario.self,
        HappyPathTextEditScenario.self,
        HotkeyScenario.self,
        CancelScenario.self,
        MenuModeScenario.self,
        MenuHistoryScenario.self,
        PrefsScenario.self,
        ErrorBackendScenario.self,
        GoModeScenario.self,
        VisualScenario.self
    ]

    static func lookup(_ name: String) -> Scenario.Type? {
        all.first { $0.name == name }
    }

    static func resolve(_ names: [String]) throws -> [Scenario.Type] {
        if names.count == 1, names[0] == "all" { return all }
        return try names.map { name in
            guard let type = lookup(name) else {
                throw RunnerError.unknownScenario(name, available: all.map { $0.name })
            }
            return type
        }
    }

    static func listing() -> String {
        var lines = ["Available scenarios:", ""]
        let width = all.map { $0.name.count }.max() ?? 20
        for type in all {
            var flags: [String] = []
            if type.requiresHotkey { flags.append("--hotkey") }
            if type.requiresScreenCapture { flags.append("screen recording") }
            if type.requiresAutomation { flags.append("automation") }
            let suffix = flags.isEmpty ? "" : "  [needs: \(flags.joined(separator: ", "))]"
            lines.append("  \(type.name.padding(toLength: width, withPad: " ", startingAt: 0))  \(type.summary)\(suffix)")
        }
        lines.append("")
        lines.append("  all\(String(repeating: " ", count: max(1, width - 3)))  Every scenario above, in order")
        return lines.joined(separator: "\n")
    }
}

enum RunnerError: Error, CustomStringConvertible {
    case unknownScenario(String, available: [String])

    var description: String {
        switch self {
        case .unknownScenario(let name, let available):
            return "unknown scenario '\(name)'. Available: \(available.joined(separator: ", ")), all"
        }
    }
}

/// Runs a list of scenarios against one app instance, restarting the app when a
/// scenario has changed its launch environment.
struct Runner {
    let options: Options

    /// - Returns: true when nothing failed (skips are not failures).
    func run(_ types: [Scenario.Type]) throws -> Bool {
        let outDir = options.resolvedOutDir()
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        print("vx-e2e: \(types.count) scenario(s) → \(outDir.path)")

        let app = AppUnderTest(options: options, outDir: outDir)
        if options.killExisting {
            app.displaceExistingInstance()
        } else if let existing = AppUnderTest.runningVXBundlePath() {
            print("""
            error: vx is already running from \(existing).
                   Two instances install competing hotkey event taps, so scenarios would be
                   unreliable. Quit it, or re-run with --kill-existing (the harness relaunches
                   your copy when it is done).
            """)
            return false
        }

        try app.prepareProfile()
        // Everything is torn down even on a thrown error — a leaked `vx` with a live
        // event tap is a genuinely annoying thing to leave on someone's machine.
        defer { app.teardown(keepApp: options.keepApp) }

        do {
            try app.launch(audioSource: options.fixture("short-phrase.wav"))
        } catch {
            print("\nvx-e2e: could not start the app under test.\n")
            print(describe(error))
            let dump = outDir.appendingPathComponent("launch-failure.txt")
            try? describe(error).write(to: dump, atomically: true, encoding: .utf8)
            print("\nDiagnostics also written to \(dump.path)")
            return false
        }
        print("vx-e2e: app under test is up (pid \(app.pid), suite \(app.defaultsSuite))")

        var results: [ScenarioResult] = []
        let started = Date()
        var needsRestore = false

        for type in types {
            if needsRestore {
                // The previous scenario changed the launch env; put the default back so
                // the next one starts from the same place a fresh run would.
                do {
                    try app.relaunch(audioSource: options.fixture("short-phrase.wav"))
                } catch {
                    results.append(ScenarioResult(
                        name: type.name, status: .failed, duration: 0,
                        message: "could not restore the default launch environment: \(describe(error))",
                        artifacts: []
                    ))
                    break
                }
                needsRestore = false
            }

            let ctx = ScenarioContext(
                options: options,
                app: app,
                artifactDir: outDir.appendingPathComponent(type.name)
            )
            print("  ▸ \(type.name) …")
            let scenarioStart = Date()
            var status = ScenarioStatus.passed
            var message = ""
            do {
                try type.init().run(ctx)
            } catch let skip as ScenarioSkipped {
                status = .skipped
                message = skip.description
            } catch {
                status = .failed
                message = describe(error)
                // A failing scenario usually leaves useful state behind.
                ctx.write(app.diagnostics(), to: "diagnostics.txt")
                ctx.write(app.debugLogContents, to: "vx-debug.log")
            }
            // Safety net: a scenario that threw past its own `defer` (or forgot one)
            // must not leave a TextEdit document open, and must not leave a stale
            // paste target registered for the *next* scenario to rely on.
            PasteTarget.releaseActive()
            if type.mutatesLaunchEnvironment { needsRestore = true }

            results.append(ScenarioResult(
                name: type.name,
                status: status,
                duration: Date().timeIntervalSince(scenarioStart),
                message: message,
                artifacts: ctx.artifacts
            ))
            print("    \(status.rawValue)\(message.isEmpty ? "" : ": \(message.split(separator: "\n").first.map(String.init) ?? "")")")
        }

        let total = Date().timeIntervalSince(started)
        Report.write(results, outDir: outDir, totalDuration: total)
        print(Report.console(results, outDir: outDir, totalDuration: total))
        return !results.contains { $0.status == .failed }
    }

    /// `CustomStringConvertible` errors carry a curated message; everything else falls
    /// back to `localizedDescription`, which for a plain Swift error is useless noise.
    private func describe(_ error: Error) -> String {
        String(describing: error)
    }
}
