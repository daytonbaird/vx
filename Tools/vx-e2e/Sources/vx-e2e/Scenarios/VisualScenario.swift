import ApplicationServices
import CoreGraphics
import Foundation

/// Screenshots every surface vx can show, into one directory with an `index.md`.
///
/// This is a *catalogue*, not an assertion suite: it fails only when a surface it
/// asked for never appeared. Pixel diffs against `--baseline` are reported as
/// percentages and never fail the run — rendering legitimately shifts between OS
/// versions, displays, and appearance settings.
struct VisualScenario: Scenario {
    static let name = "visual"
    static let summary = "Screenshot every HUD style, Preferences tab, and auxiliary window"
    static var requiresScreenCapture: Bool { true }

    private struct Shot {
        let file: String
        let caption: String
        var diff: Screenshots.Diff?
        var note: String?
    }

    func run(_ ctx: ScenarioContext) throws {
        guard Screenshots.canCapture else {
            throw ScenarioSkipped("Screen Recording is not granted to the responsible process")
        }
        let app = AX.application(pid: ctx.app.pid)
        var shots: [Shot] = []
        var missing: [String] = []

        // --- HUD styles ----------------------------------------------------------
        // `hud <style>` forces a presentation without running a dictation, so every
        // style is reachable including the ones that only occur on failure.
        let styles = ["idle", "recording", "goMode", "processing", "success", "finishing", "cancelled", "warning", "error"]
        for style in styles {
            guard (try? ctx.control.require("hud \(style)")) != nil else {
                missing.append("hud \(style) (control command rejected)")
                continue
            }
            usleep(500_000)
            if let shot = capture(ctx, windowNamed: "vx HUD", file: "hud-\(style).png", caption: "HUD — \(style)") {
                shots.append(shot)
            } else {
                missing.append("hud \(style) window")
            }
        }

        _ = try? ctx.control.require("hud hint")
        usleep(500_000)
        if let shot = capture(ctx, windowNamed: "vx HUD", file: "hud-hint.png", caption: "HUD — hint") {
            shots.append(shot)
        } else {
            missing.append("hud hint window")
        }
        _ = try? ctx.control.require("hud hide")
        usleep(300_000)

        // --- Preferences tabs ----------------------------------------------------
        for tab in ["config", "rules", "ai", "sound", "permissions", "developer"] {
            guard (try? ctx.control.require("open preferences:\(tab)")) != nil else {
                missing.append("preferences:\(tab) (control command rejected)")
                continue
            }
            _ = AX.waitFor(identifier: "vx.prefs.window", orTitle: "vx Preferences", in: app, timeout: 4)
            usleep(600_000)
            if let shot = capture(ctx, windowNamed: "vx Preferences", file: "prefs-\(tab).png", caption: "Preferences — \(tab)") {
                shots.append(shot)
            } else {
                missing.append("preferences window for tab \(tab)")
            }
        }

        // --- Auxiliary windows ---------------------------------------------------
        let windows: [(command: String, title: String, file: String)] = [
            ("open history", "vx History", "window-history.png"),
            ("open debugLog", "vx Debug Log", "window-debug-log.png"),
            ("open contextInspector", "vx Context Inspector", "window-context-inspector.png")
        ]
        for entry in windows {
            guard (try? ctx.control.require(entry.command)) != nil else {
                missing.append("\(entry.command) (control command rejected)")
                continue
            }
            usleep(800_000)
            if let shot = capture(ctx, windowNamed: entry.title, file: entry.file, caption: entry.title) {
                shots.append(shot)
            } else {
                missing.append(entry.title)
            }
        }

        // --- The open status menu ------------------------------------------------
        // The menu is a system-owned window, so it is captured by screen region
        // derived from the status item's AX frame rather than by window ID.
        if AX.isTrusted, let opened = AX.openStatusMenu(pid: ctx.app.pid) {
            usleep(500_000)
            if let frame = AX.frame(opened.item) {
                let region = Screenshots.statusMenuRegion(statusItemFrame: frame)
                let url = ctx.artifactURL("status-menu.png")
                if Screenshots.captureRegion(region, to: url) {
                    ctx.record(artifact: url)
                    shots.append(finish(ctx, shot: Shot(file: "status-menu.png", caption: "Status menu (open)")))
                } else {
                    missing.append("status menu region capture")
                }
            } else {
                missing.append("status item AX frame")
            }
            AX.closeMenuWithEscape()
        } else {
            missing.append("status menu (Accessibility not granted or status item not found)")
        }

        // --- index.md ------------------------------------------------------------
        ctx.write(indexMarkdown(shots: shots, missing: missing, ctx: ctx), to: "index.md")

        try Expect.isTrue(
            !shots.isEmpty,
            "captured no screenshots at all; missing: \(missing.joined(separator: ", "))"
        )
        if !missing.isEmpty {
            // Surfaces that never appeared are a real finding, so fail — but only
            // after writing the index, so the shots that did work are still usable.
            throw ScenarioFailure("could not capture: \(missing.joined(separator: ", "))")
        }
    }

    private func capture(_ ctx: ScenarioContext, windowNamed name: String, file: String, caption: String) -> Shot? {
        // Panels sometimes report an empty kCGWindowName; fall back to the largest
        // on-screen window the app owns.
        let info = WindowList.waitForWindow(ownerPID: ctx.app.pid, named: name, timeout: 4)
            ?? WindowList.largestWindow(ownerPID: ctx.app.pid)
        guard let info else { return nil }
        let url = ctx.artifactURL(file)
        guard Screenshots.captureWindow(id: info.windowID, to: url) else { return nil }
        ctx.record(artifact: url)
        return finish(ctx, shot: Shot(file: file, caption: caption))
    }

    /// Attaches an advisory baseline diff, if a baseline of the same filename exists.
    private func finish(_ ctx: ScenarioContext, shot: Shot) -> Shot {
        var shot = shot
        guard let baselineDir = ctx.options.baselineDir else { return shot }
        let baseline = baselineDir.appendingPathComponent(shot.file)
        guard FileManager.default.fileExists(atPath: baseline.path) else {
            shot.note = "no baseline"
            return shot
        }
        if let diff = Screenshots.diff(ctx.artifactURL(shot.file), baseline) {
            shot.diff = diff
        } else {
            shot.note = "baseline size mismatch (not comparable)"
        }
        return shot
    }

    private func indexMarkdown(shots: [Shot], missing: [String], ctx: ScenarioContext) -> String {
        var lines = ["# vx visual catalogue", ""]
        lines.append("Captured \(shots.count) surface\(shots.count == 1 ? "" : "s") on \(Date()).")
        if ctx.options.baselineDir != nil {
            lines.append("")
            lines.append("Pixel diffs are **advisory** — rendering shifts between displays and OS versions.")
        }
        lines.append("")
        for shot in shots {
            lines.append("## \(shot.caption)")
            lines.append("")
            lines.append("![\(shot.caption)](\(shot.file))")
            if let diff = shot.diff {
                lines.append("")
                lines.append(String(format: "Baseline diff: %.2f%% of pixels (%d / %d).",
                                    diff.percentage, diff.differingPixels, diff.totalPixels))
            } else if let note = shot.note {
                lines.append("")
                lines.append("_\(note)_")
            }
            lines.append("")
        }
        if !missing.isEmpty {
            lines.append("## Not captured")
            lines.append("")
            for entry in missing { lines.append("- \(entry)") }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
