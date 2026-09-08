import Foundation

/// Everything the harness needs to know before it can launch anything.
///
/// Parsing is hand-rolled (no ArgumentParser dependency) so the harness stays a
/// zero-dependency package that builds in a couple of seconds — important because
/// `verify.sh` builds it on every run.
struct Options {
    enum Command: Equatable {
        case preflight(prompt: Bool)
        case list
        case run(scenarios: [String])
        case help
    }

    var command: Command = .help

    /// Post real ⌥Space CGEvents instead of driving via the control socket.
    /// Requires Input Monitoring for the responsible process, so it is opt-in.
    var hotkey = false

    /// Quit any already-running `vx` before launching the app under test.
    /// Two instances fight over the CGEventTap, so scenarios are unreliable
    /// without this unless the user has already quit their copy.
    var killExisting = false

    /// Leave the app under test running after the run (for manual poking).
    var keepApp = false

    /// Root for the run's artifacts. Defaults to a timestamped dir under `build/verify/`.
    var outDir: URL?

    /// The `.app` bundle to drive.
    var appBundle = URL(fileURLWithPath: "/Users/tdoot/dev/vx-workspace/app/vx-ui/build/vx.app")

    /// Directory holding `short-phrase.wav` and friends.
    var fixturesDir = URL(fileURLWithPath: "/Users/tdoot/dev/vx-workspace/app/fixtures/audio")

    /// Optional directory of baseline screenshots for the `visual` scenario.
    /// Diffs are advisory — they never fail a run.
    var baselineDir: URL?

    var verbose = false

    static let usage = """
    vx-e2e — black-box end-to-end harness for the vx menubar app

    USAGE
      vx-e2e preflight [--prompt]
      vx-e2e list
      vx-e2e run <scenario>|all [options]

    SUBCOMMANDS
      preflight   Check TCC grants, bundle, signature and fixtures. Exits non-zero
                  if a hard requirement is missing.
      list        Print the available scenarios.
      run         Run one scenario, several (comma- or space-separated), or `all`.

    OPTIONS
      --kill-existing     Quit any running `vx` first, relaunch the user's copy after.
      --hotkey            Enable scenarios that post real CGEvents (needs Input Monitoring).
      --keep-app          Do not terminate the app under test at the end.
      --out <dir>         Artifact directory (default: <app>/vx-ui/build/verify/<timestamp>).
      --app <bundle>      Path to vx.app.
      --fixtures <dir>    Path to the audio fixtures directory.
      --baseline <dir>    Baseline screenshots for `visual` (advisory pixel diff).
      --prompt            preflight only: show the macOS Accessibility prompt.
      -v, --verbose       Chatty logging.
      -h, --help          This text.

    NOTES
      TCC grants attach to the *responsible process* (your terminal, or the Claude
      Code host), never to the vx-e2e binary itself. See `preflight` output.
    """

    /// Throws `OptionsError` on malformed input so `main` can print usage and exit 2.
    static func parse(_ argv: [String]) throws -> Options {
        var opts = Options()
        var args = argv
        guard !args.isEmpty else { opts.command = .help; return opts }

        // Global help can appear anywhere.
        if args.contains("-h") || args.contains("--help") {
            opts.command = .help
            return opts
        }

        let sub = args.removeFirst()
        var scenarios: [String] = []
        var prompt = false

        var i = 0
        while i < args.count {
            let arg = args[i]
            func value(_ name: String) throws -> String {
                guard i + 1 < args.count else { throw OptionsError.missingValue(name) }
                i += 1
                return args[i]
            }
            switch arg {
            case "--kill-existing": opts.killExisting = true
            case "--hotkey":        opts.hotkey = true
            case "--keep-app":      opts.keepApp = true
            case "--prompt":        prompt = true
            case "-v", "--verbose": opts.verbose = true
            case "--out":           opts.outDir = URL(fileURLWithPath: try value("--out")).standardizedFileURL
            case "--app":           opts.appBundle = URL(fileURLWithPath: try value("--app")).standardizedFileURL
            case "--fixtures":      opts.fixturesDir = URL(fileURLWithPath: try value("--fixtures")).standardizedFileURL
            case "--baseline":      opts.baselineDir = URL(fileURLWithPath: try value("--baseline")).standardizedFileURL
            default:
                if arg.hasPrefix("-") { throw OptionsError.unknownFlag(arg) }
                // Allow both `run a b` and `run a,b`.
                scenarios.append(contentsOf: arg.split(separator: ",").map(String.init))
            }
            i += 1
        }

        switch sub {
        case "preflight": opts.command = .preflight(prompt: prompt)
        case "list":      opts.command = .list
        case "run":
            guard !scenarios.isEmpty else { throw OptionsError.missingScenario }
            opts.command = .run(scenarios: scenarios)
        case "help":      opts.command = .help
        default:          throw OptionsError.unknownSubcommand(sub)
        }
        return opts
    }

    /// Resolved artifact directory, creating the timestamped default if needed.
    func resolvedOutDir() -> URL {
        if let outDir { return outDir }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return URL(fileURLWithPath: "/Users/tdoot/dev/vx-workspace/app/vx-ui/build/verify")
            .appendingPathComponent(fmt.string(from: Date()))
    }

    var executableURL: URL {
        appBundle.appendingPathComponent("Contents/MacOS/vx")
    }

    func fixture(_ name: String) -> URL {
        fixturesDir.appendingPathComponent(name)
    }
}

enum OptionsError: Error, CustomStringConvertible, Equatable {
    case unknownSubcommand(String)
    case unknownFlag(String)
    case missingValue(String)
    case missingScenario

    var description: String {
        switch self {
        case .unknownSubcommand(let s): return "unknown subcommand '\(s)'"
        case .unknownFlag(let f):       return "unknown flag '\(f)'"
        case .missingValue(let n):      return "\(n) requires a value"
        case .missingScenario:          return "run requires a scenario name (or `all`)"
        }
    }
}
