import CoreGraphics
import Foundation

/// Synthetic keyboard input.
///
/// The app listens with a CGEventTap at `.cghidEventTap`, so events must be posted
/// to that tap (not to the app's PID) to be seen. Posting requires the *responsible
/// process* — the terminal, or the Claude Code host — to hold Input Monitoring;
/// without it `CGEvent.post` silently does nothing, which is why `--hotkey` is opt-in
/// and `preflight` checks `CGPreflightListenEventAccess()`.
enum Keys {
    static let space: CGKeyCode = 49
    static let escape: CGKeyCode = 53

    static var canPostEvents: Bool { CGPreflightListenEventAccess() }

    @discardableResult
    static func requestPostAccess() -> Bool { CGRequestListenEventAccess() }

    static func keyDown(virtualKey: CGKeyCode, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true) else { return }
        // Assign flags exactly — `CGEvent` seeds them from the current hardware state,
        // and a stray held modifier would make ⌥Space arrive as, say, ⌃⌥Space and miss.
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    static func keyUp(virtualKey: CGKeyCode, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: false) else { return }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }

    static func tap(virtualKey: CGKeyCode, flags: CGEventFlags, holdFor: TimeInterval = 0.05) {
        keyDown(virtualKey: virtualKey, flags: flags)
        usleep(useconds_t(holdFor * 1_000_000))
        keyUp(virtualKey: virtualKey, flags: flags)
    }

    // MARK: - ⌥Space

    /// The default vx binding: `Shortcut.combo(keyCode: kVK_Space, modifiers: [.maskAlternate])`.
    static let optionSpaceFlags: CGEventFlags = .maskAlternate

    /// Pressing the hotkey starts a real dictation, which ends in a real paste into
    /// the frontmost app — so it carries the same paste-target guard as `begin`.
    /// The *up* stroke is deliberately unguarded: a stuck ⌥ or Space would be far
    /// worse for the user than a late release.
    static func optionSpaceDown() throws {
        guard PasteTarget.isActive else {
            throw ScenarioFailure(
                "⌥Space would start a dictation with no paste target: vx pastes into whatever "
                    + "app is frontmost. Acquire a PasteTarget first (see PasteTarget.acquire())."
            )
        }
        try PasteTarget.active?.ensureFrontmost()
        keyDown(virtualKey: space, flags: optionSpaceFlags)
    }

    static func optionSpaceUp() { keyUp(virtualKey: space, flags: optionSpaceFlags) }

    /// Hold-to-talk press-and-release with a caller-controlled hold, so a scenario can
    /// wait for `recordingStarted` and `audioSourceDrained` between down and up.
    static func optionSpaceTap(holdFor: TimeInterval = 0.1) throws {
        try optionSpaceDown()
        usleep(useconds_t(holdFor * 1_000_000))
        optionSpaceUp()
    }
}
