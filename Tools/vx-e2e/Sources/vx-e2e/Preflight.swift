import ApplicationServices
import CoreGraphics
import Foundation

/// Environment checks, run before anything is launched.
///
/// The headline fact this prints, because it trips everyone up: TCC grants attach to
/// the **responsible process** — the terminal, IDE, or Claude Code host that spawned
/// vx-e2e — never to the `vx-e2e` binary. Re-signing or moving the binary does not
/// help; granting the *terminal* does.
enum Preflight {
    struct Check {
        let name: String
        /// nil = satisfied. Non-nil = the reason it is not.
        let problem: String?
        /// A hard requirement blocks every run; a soft one only blocks some scenarios.
        let hard: Bool
        /// Which System Settings pane fixes it.
        let remedy: String?

        var ok: Bool { problem == nil }
    }

    struct Report {
        let checks: [Check]
        var hardFailures: [Check] { checks.filter { !$0.ok && $0.hard } }
        var softFailures: [Check] { checks.filter { !$0.ok && !$0.hard } }
        var passed: Bool { hardFailures.isEmpty }
    }

    static func run(options: Options, prompt: Bool) -> Report {
        var checks: [Check] = []
        let fm = FileManager.default

        // --- The build ------------------------------------------------------------
        let bundleExists = fm.fileExists(atPath: options.appBundle.path)
        checks.append(Check(
            name: "app bundle",
            problem: bundleExists ? nil : "not found at \(options.appBundle.path)",
            hard: true,
            remedy: "run `SKIP_PUBLISH=1 Scripts/package-app.sh` from the workspace root"
        ))

        let exeOK = fm.isExecutableFile(atPath: options.executableURL.path)
        checks.append(Check(
            name: "bundle executable",
            problem: exeOK ? nil : "not executable at \(options.executableURL.path)",
            hard: true,
            remedy: "repackage the app"
        ))

        if bundleExists {
            checks.append(signatureCheck(options.appBundle))
        }

        // --- Fixtures -------------------------------------------------------------
        let required = ["short-phrase.wav", "two-utterances.wav"]
        let absent = required.filter { !fm.fileExists(atPath: options.fixture($0).path) }
        checks.append(Check(
            name: "audio fixtures",
            problem: absent.isEmpty ? nil : "missing \(absent.joined(separator: ", ")) in \(options.fixturesDir.path)",
            hard: true,
            remedy: "run `app/Scripts/make-fixtures.sh`"
        ))

        // --- Stray instances ------------------------------------------------------
        let running = AppUnderTest.runningVXBundlePath()
        let strayOK = running == nil || options.killExisting
        checks.append(Check(
            name: "no stray vx running",
            problem: strayOK ? nil : "vx is running from \(running!) — two instances fight over the hotkey event tap",
            hard: true,
            remedy: "quit vx, or pass --kill-existing (the harness will relaunch your copy afterwards)"
        ))

        // --- TCC ------------------------------------------------------------------
        if prompt { AX.requestTrust() }
        checks.append(Check(
            name: "Accessibility (AXIsProcessTrusted)",
            problem: AX.isTrusted ? nil : "not granted",
            hard: true,
            remedy: "System Settings ▸ Privacy & Security ▸ Accessibility — add the *terminal / host app*, not vx-e2e"
        ))

        let listenOK = CGPreflightListenEventAccess()
        checks.append(Check(
            name: "Input Monitoring (for --hotkey)",
            problem: listenOK ? nil : "not granted — the `hotkey` scenario will be skipped",
            hard: options.hotkey,
            remedy: "System Settings ▸ Privacy & Security ▸ Input Monitoring — add the terminal / host app"
        ))

        let captureOK = CGPreflightScreenCaptureAccess()
        checks.append(Check(
            name: "Screen Recording (for `visual`)",
            problem: captureOK ? nil : "not granted — the `visual` scenario will be skipped",
            hard: false,
            remedy: "System Settings ▸ Privacy & Security ▸ Screen Recording — add the terminal / host app"
        ))

        let automationProblem = TextEdit.automationProbe()
        checks.append(Check(
            name: "Automation ▸ TextEdit",
            problem: automationProblem.map { "\($0) — TextEdit scenarios will be skipped" },
            hard: false,
            remedy: "System Settings ▸ Privacy & Security ▸ Automation ▸ <your terminal> ▸ TextEdit"
        ))

        return Report(checks: checks)
    }

    /// An ad-hoc signature means every launch gets a fresh code identity, which makes
    /// macOS drop the app's TCC grants — the app then silently loses Accessibility and
    /// the hotkey stops working mid-suite. Worth a loud warning.
    private static func signatureCheck(_ bundle: URL) -> Check {
        let result = Shell.run("/usr/bin/codesign", ["-dv", bundle.path])
        let output = result.out + "\n" + result.err
        if result.status != 0 {
            return Check(name: "code signature", problem: "codesign -dv failed: \(result.err)", hard: false,
                         remedy: "repackage the app")
        }
        if output.contains("Signature=adhoc") {
            return Check(
                name: "code signature",
                problem: "ad-hoc signed — macOS will reset the app's TCC grants on every rebuild",
                hard: false,
                remedy: "install a Developer ID or the `vx-local-dev` certificate (Scripts/create-signing-cert.sh)"
            )
        }
        return Check(name: "code signature", problem: nil, hard: false, remedy: nil)
    }

    static func render(_ report: Report) -> String {
        var lines: [String] = []
        lines.append("vx-e2e preflight")
        lines.append("")
        let width = report.checks.map(\.name.count).max() ?? 20
        for check in report.checks {
            let mark = check.ok ? "PASS" : (check.hard ? "FAIL" : "WARN")
            let padded = check.name.padding(toLength: width, withPad: " ", startingAt: 0)
            let detail = check.problem.map { "  \($0)" } ?? ""
            lines.append("  [\(mark)] \(padded)\(detail)")
        }
        let unresolved = report.checks.filter { !$0.ok && $0.remedy != nil }
        if !unresolved.isEmpty {
            lines.append("")
            lines.append("How to fix:")
            for check in unresolved {
                lines.append("  \(check.name):")
                lines.append("    \(check.remedy!)")
            }
            lines.append("")
            lines.append("  NOTE: macOS attaches privacy grants to the *responsible process* — the")
            lines.append("  terminal, IDE, or agent host that launched vx-e2e — not to the vx-e2e")
            lines.append("  binary. Grant the parent app, then restart it so the grant takes effect.")
        }
        lines.append("")
        lines.append(report.passed
            ? "Preflight OK\(report.softFailures.isEmpty ? "" : " (\(report.softFailures.count) scenario(s) will be skipped)")"
            : "Preflight FAILED — \(report.hardFailures.count) hard requirement(s) missing")
        return lines.joined(separator: "\n")
    }
}
