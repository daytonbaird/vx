import Foundation

/// TextEdit as a real paste target.
///
/// The control-socket scenarios prove the flow; these prove the *insertion* — that
/// the synthesized Cmd+V actually lands text in a foreign app's text field. That
/// cannot be observed from vx's own event log.
///
/// All of this goes through osascript, so the responsible process needs an
/// Automation grant for TextEdit. AppleScript error -1743 is the "not authorized"
/// signal; `preflight` translates it.
enum TextEdit {
    static let automationDeniedCode = -1743

    struct AutomationDenied: Error, CustomStringConvertible {
        let detail: String
        var description: String {
            "Automation (Apple Events) for TextEdit is not granted to this process. \(detail)"
        }
    }

    /// A harmless probe used by `preflight`: asks TextEdit for its name.
    /// Returns nil when allowed, or a human-readable reason when not.
    static func automationProbe() -> String? {
        let result = Shell.osascript("tell application \"TextEdit\" to get name", timeout: 15)
        if result.status == 0 { return nil }
        if result.err.contains("\(automationDeniedCode)") || result.err.contains("Not authorized") {
            return "not granted (AppleScript error \(automationDeniedCode))"
        }
        return result.err.isEmpty ? "osascript exited \(result.status)" : result.err
    }

    /// Opens a fresh, empty document and brings TextEdit to the front so vx's
    /// Cmd+V paste has somewhere to land.
    static func openBlankDocument() throws {
        let script = """
        tell application "TextEdit"
            activate
            make new document
        end tell
        """
        let result = Shell.osascript(script, timeout: 20)
        guard result.status == 0 else { throw AutomationDenied(detail: result.err) }
        // Give the window server a beat to actually move focus; pasting into a
        // not-yet-frontmost app is the single most common flake here.
        usleep(700_000)
        activate()
    }

    /// Raises TextEdit, hard.
    ///
    /// `tell application "TextEdit" to activate` is only a *request*: when another
    /// app currently owns focus macOS often declines it, and the harness then
    /// happily dictates into that other app. Setting `frontmost` through System
    /// Events goes via Accessibility and actually raises the app, so both are sent —
    /// the second line is the one that works when the first is ignored.
    static func activate() {
        Shell.osascript(
            """
            tell application "TextEdit" to activate
            tell application "System Events" to set frontmost of process "TextEdit" to true
            """,
            timeout: 10
        )
        usleep(400_000)
    }

    /// The text of the frontmost document, or nil when there is no document.
    static func documentText() -> String? {
        let result = Shell.osascript(
            "tell application \"TextEdit\" to if (count of documents) > 0 then return text of document 1",
            timeout: 15
        )
        guard result.status == 0 else { return nil }
        return result.out
    }

    /// Polls `documentText()` until it contains `needle` (normalized) or times out.
    static func waitForText(containing needle: String, timeout: TimeInterval = 3) -> String? {
        let target = Normalize.text(needle)
        let deadline = Date().addingTimeInterval(timeout)
        var last: String?
        repeat {
            last = documentText()
            if let last, Normalize.text(last).contains(target) { return last }
            usleep(150_000)
        } while Date() < deadline
        return nil
    }

    /// Closes every open document without saving, leaving no "unsaved changes" sheet
    /// to block the next scenario.
    static func closeAllWithoutSaving() {
        Shell.osascript(
            """
            tell application "TextEdit"
                repeat while (count of documents) > 0
                    close document 1 saving no
                end repeat
            end tell
            """,
            timeout: 20
        )
    }

    static func quit() {
        Shell.osascript("tell application \"TextEdit\" to quit saving no", timeout: 15)
    }

    /// The name of the frontmost application, via System Events.
    static func frontmostApp() -> String? {
        let result = Shell.osascript(
            "tell application \"System Events\" to return name of first application process whose frontmost is true",
            timeout: 10
        )
        return result.status == 0 ? result.out : nil
    }
}

/// A scratch TextEdit document that owns focus for the duration of a dictation.
///
/// vx inserts by posting Cmd+V to *whatever app is frontmost*. A scenario that
/// starts a dictation without one of these types the transcript into whatever the
/// user happens to be looking at — their terminal, their editor, a chat window.
/// That is not a hypothetical: it is what this harness did before this type
/// existed. So every scenario that can produce a `textInserted` (or a
/// `submittedWithoutText`) acquires one first, and `GuardedControl` and `Keys`
/// both refuse to start a dictation while none is active.
final class PasteTarget {
    /// The currently-held target, if any. The guard reads this; nothing else should.
    private(set) static var active: PasteTarget?
    static var isActive: Bool { active != nil }

    private var released = false

    private init() {}

    /// Opens a blank TextEdit document, makes TextEdit frontmost, and registers
    /// itself as the active target.
    ///
    /// - Throws: `ScenarioSkipped` when Automation ▸ TextEdit is not granted (the
    ///   scenario genuinely cannot run), `ScenarioFailure` when TextEdit is there
    ///   but never comes to the front (pasting then would hit the wrong app).
    static func acquire() throws -> PasteTarget {
        if let existing = active { return existing }
        if let reason = TextEdit.automationProbe() {
            throw ScenarioSkipped("TextEdit automation unavailable: \(reason)")
        }
        // Start from a clean slate: a document left over from an earlier scenario
        // would make the transcript assertions match stale text.
        TextEdit.closeAllWithoutSaving()
        do {
            try TextEdit.openBlankDocument()
        } catch {
            throw ScenarioSkipped("could not open a TextEdit paste target: \(error)")
        }

        let target = PasteTarget()
        active = target
        do {
            try target.ensureFrontmost()
        } catch {
            target.release()
            throw error
        }
        return target
    }

    /// Re-activates TextEdit if something stole focus, and fails if it will not come
    /// forward — better to fail the scenario than to paste into the user's session.
    func ensureFrontmost(timeout: TimeInterval = 12) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var seen: String?
        repeat {
            seen = TextEdit.frontmostApp()
            if seen == "TextEdit" { return }
            TextEdit.activate()
        } while Date() < deadline
        throw ScenarioFailure(
            "TextEdit never became frontmost (saw \"\(seen ?? "?")\"); refusing to dictate, "
                + "because vx would paste into that app instead"
        )
    }

    func text() -> String? { TextEdit.documentText() }

    func waitForText(containing needle: String, timeout: TimeInterval = 3) -> String? {
        TextEdit.waitForText(containing: needle, timeout: timeout)
    }

    /// Closes the scratch document without saving and clears the active target.
    /// Idempotent, so a `defer` plus the Runner's safety net cannot double-close.
    func release() {
        guard !released else { return }
        released = true
        TextEdit.closeAllWithoutSaving()
        if PasteTarget.active === self { PasteTarget.active = nil }
    }

    /// Runner safety net: releases whatever is held, whatever happened.
    static func releaseActive() {
        active?.release()
        active = nil
    }
}
