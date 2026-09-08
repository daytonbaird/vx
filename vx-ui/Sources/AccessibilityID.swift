import Foundation

/// Stable accessibility identifiers for every surface a UI test drives.
///
/// Scheme: `vx.<surface>.<element>[.<variant>]`. These strings are a contract with the
/// verification harness — rename a control's label freely, but never a constant here
/// without updating the tests that query it.
public enum AXID {

    // MARK: Status item menu

    public static let statusItem = "vx.menu.statusItem"
    public static let menuPreferences = "vx.menu.preferences"
    public static let menuMode = "vx.menu.mode"
    public static let menuModeAuto = "vx.menu.mode.auto"
    public static func menuMode(_ mode: DictationMode) -> String { "vx.menu.mode.\(mode.rawValue)" }
    public static let menuProfile = "vx.menu.profile"
    public static func menuProfile(_ profile: CodeProfile) -> String { "vx.menu.profile.\(profile.rawValue)" }
    public static let menuHistory = "vx.menu.history"
    public static func menuHistoryEntry(_ index: Int) -> String { "vx.menu.history.entry.\(index)" }
    public static let menuHistoryShowAll = "vx.menu.history.showAll"
    public static let menuUpdate = "vx.menu.update"
    public static let menuRelaunch = "vx.menu.relaunch"
    public static let menuQuit = "vx.menu.quit"

    // MARK: HUD

    public static let hudWindow = "vx.hud.window"
    public static let hudCancel = "vx.hud.cancel"
    public static let hudStop = "vx.hud.stop"
    public static let hudStatus = "vx.hud.status"

    // MARK: Preferences

    public static let prefsWindow = "vx.prefs.window"
    public static func prefsTab(_ id: String) -> String { "vx.prefs.tab.\(id)" }

    public static let prefsConfigInputDevice = "vx.prefs.config.inputDevice"
    public static let prefsConfigActivationMode = "vx.prefs.config.activationMode"
    public static let prefsConfigShortcutChange = "vx.prefs.config.shortcut.change"
    public static let prefsConfigCopyShortcutChange = "vx.prefs.config.copyShortcut.change"
    public static let prefsConfigGoModeShortcutChange = "vx.prefs.config.goModeShortcut.change"
    public static let prefsConfigSubmitDelay = "vx.prefs.config.submitDelay"
    public static func prefsConfigModelRow(_ id: String) -> String { "vx.prefs.config.model.\(id)" }

    public static let prefsRulesMode = "vx.prefs.rules.mode"
    public static let prefsRulesProfile = "vx.prefs.rules.profile"
    public static let prefsRulesReload = "vx.prefs.rules.reload"
    public static let prefsRulesSave = "vx.prefs.rules.save"
    public static let prefsRulesApply = "vx.prefs.rules.apply"

    public static let prefsAIAutoDetect = "vx.prefs.ai.autoDetect"
    public static let prefsAIEnabled = "vx.prefs.ai.enabled"
    public static let prefsAIGoMode = "vx.prefs.ai.goMode"
    public static let prefsAIProvider = "vx.prefs.ai.provider"
    public static let prefsAIAPIKey = "vx.prefs.ai.apiKey"
    public static let prefsAISmoothDisfluencies = "vx.prefs.ai.smoothDisfluencies"

    public static let prefsSoundPlaySounds = "vx.prefs.sound.playSounds"
    public static let prefsSoundDuckAudio = "vx.prefs.sound.duckAudio"
    public static let prefsSoundDuckVolume = "vx.prefs.sound.duckVolume"

    /// `name` may be the row's display title ("Input Monitoring"); it is slugified so the
    /// identifier stays a single dotted token.
    public static func prefsPermissionsRequest(_ name: String) -> String {
        let slug = name
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .enumerated()
            .map { index, word in index == 0 ? word.lowercased() : word.capitalized }
            .joined()
        return "vx.prefs.permissions.request.\(slug)"
    }

    public static let prefsDeveloperDebugMode = "vx.prefs.developer.debugMode"
    public static let prefsDeveloperShowLog = "vx.prefs.developer.showLog"

    // MARK: Auxiliary windows

    public static let historyWindow = "vx.history.window"
    public static let historyClear = "vx.history.clear"
    public static let debugLogWindow = "vx.debugLog.window"
    public static let debugLogClear = "vx.debugLog.clear"
    public static let contextInspectorWindow = "vx.contextInspector.window"
}

#if canImport(AppKit)
import AppKit

extension NSWindow {
    /// Applies an AXID to both the accessibility tree and `NSWindow.identifier`, so a test
    /// can find the window either through the AX API or through AppKit.
    func applyAXID(_ identifier: String) {
        setAccessibilityIdentifier(identifier)
        self.identifier = NSUserInterfaceItemIdentifier(identifier)
    }
}
#endif
