import ApplicationServices
import CoreGraphics
import Foundation

/// Menu item identifiers and their title fallbacks, in one place so a rename shows
/// up as one edit rather than a scavenger hunt through the scenarios.
enum MenuIDs {
    static let statusItem = "vx.menu.statusItem"
    static let preferences = ("vx.menu.preferences", "Preferences")
    static let mode = ("vx.menu.mode", "Mode")
    static let modeAuto = ("vx.menu.mode.auto", "Auto-detect")
    static let profile = ("vx.menu.profile", "Code Profile")
    static let history = ("vx.menu.history", "History")
    static let historyShowAll = ("vx.menu.history.showAll", "Show All")
    static let update = ("vx.menu.update", nil as String?)
    static let relaunch = ("vx.menu.relaunch", "Relaunch vx")
    static let quit = ("vx.menu.quit", "Quit vx")

    /// `vx.menu.mode.<DictationMode rawValue>` paired with the mode's display name.
    static func mode(_ rawValue: String, title: String) -> (String, String) {
        ("vx.menu.mode.\(rawValue)", title)
    }

    static func historyEntry(_ index: Int) -> String { "vx.menu.history.entry.\(index)" }
}

/// Switching Mode ▸ Code from the status menu must persist the choice and mark the item.
struct MenuModeScenario: Scenario {
    static let name = "menu-mode"
    static let summary = "Status menu Mode ▸ Code persists vx.dictation-mode and checks the item"

    func run(_ ctx: ScenarioContext) throws {
        guard AX.isTrusted else {
            throw ScenarioSkipped("Accessibility is not granted to the responsible process")
        }
        let mark = ctx.events.mark()

        // --- Open the menu and pick Mode ▸ Code -----------------------------------
        guard let opened = AX.openStatusMenu(pid: ctx.app.pid) else {
            throw ScenarioFailure(
                "could not find or open the vx status item (\(MenuIDs.statusItem)).\n"
                    + AX.statusItemDiagnostics(pid: ctx.app.pid)
            )
        }
        defer { AX.closeMenuWithEscape() }

        let (modeID, modeTitle) = MenuIDs.mode
        guard let modeItem = AX.waitFor(identifier: modeID, orTitle: modeTitle, in: opened.menu, timeout: 3) else {
            throw ScenarioFailure("no Mode item in the status menu; saw \(AX.menuItemTitles(opened.menu))")
        }
        guard let modeMenu = AX.submenu(of: modeItem) else {
            throw ScenarioFailure("Mode item has no submenu")
        }
        let (codeID, codeTitle) = MenuIDs.mode("code", title: "Code")
        guard let codeItem = AX.waitFor(identifier: codeID, orTitle: codeTitle, in: modeMenu, timeout: 3) else {
            throw ScenarioFailure("no Code item in the Mode submenu; saw \(AX.menuItemTitles(modeMenu))")
        }
        try Expect.isTrue(AX.press(codeItem), "pressing the Code mode item should succeed")
        usleep(600_000)

        // --- It persisted --------------------------------------------------------
        // Poll: UserDefaults writes go through cfprefsd, so the value can lag the click.
        var persisted: String?
        let deadline = Date().addingTimeInterval(3)
        repeat {
            persisted = ctx.app.readDefault("vx.dictation-mode")
            if persisted == "code" { break }
            usleep(200_000)
        } while Date() < deadline
        try Expect.equal(persisted ?? "<unset>", "code", "vx.dictation-mode after Mode ▸ Code")

        _ = try ctx.events.waitForRecord(kind: "menuAction", since: mark, timeout: 5)

        // --- It shows as checked next time the menu opens -------------------------
        AX.closeMenuWithEscape()
        guard let reopened = AX.openStatusMenu(pid: ctx.app.pid) else {
            throw ScenarioFailure("could not reopen the status menu")
        }
        guard let modeItem2 = AX.waitFor(identifier: modeID, orTitle: modeTitle, in: reopened.menu, timeout: 3),
              let modeMenu2 = AX.submenu(of: modeItem2),
              let codeItem2 = AX.waitFor(identifier: codeID, orTitle: codeTitle, in: modeMenu2, timeout: 3) else {
            throw ScenarioFailure("could not re-find Mode ▸ Code after reopening the menu")
        }
        let markChar = AX.markChar(codeItem2) ?? ""
        try Expect.isTrue(
            !markChar.isEmpty,
            "Code should be checked (AXMenuItemMarkChar non-empty) once selected; got \"\(markChar)\""
        )
        ctx.write(ctx.events.transcript(since: mark), to: "events.txt")
    }
}

/// A completed dictation must show up in the History submenu, and Show All must open
/// the History window.
struct MenuHistoryScenario: Scenario {
    static let name = "menu-history"
    static let summary = "A transcript appears in History ▸ entry 0 and Show All opens the window"
    // The scenario dictates to fill the history, and that dictation ends in a real
    // paste — so it needs a paste target just like happy-path does.
    static var requiresAutomation: Bool { true }

    func run(_ ctx: ScenarioContext) throws {
        guard AX.isTrusted else {
            throw ScenarioSkipped("Accessibility is not granted to the responsible process")
        }

        // Produce something to put in the history.
        let target = try ctx.acquirePasteTarget()
        // Released before the menu work: an open TextEdit window over the screen is
        // not needed once the transcript exists, and closing it early keeps the
        // History window assertion looking at a clean desktop.
        var releasedTarget = false
        defer { if !releasedTarget { target.release() } }

        let mark = ctx.events.mark()
        try ctx.control.require("begin")
        try ctx.events.waitForFlow("recordingStarted", since: mark, timeout: 8)
        try ctx.events.waitForFlow("audioSourceDrained", since: mark, timeout: 20)
        try ctx.control.require("finish")
        let inserted = try ctx.events.waitForFlow("textInserted", since: mark, timeout: 30)
        let transcript = try Expect.notNil(inserted.firstValue, "textInserted payload")
        // Let the app's pasteboard restore land before closing the document.
        usleep(1_200_000)
        target.release()
        releasedTarget = true

        guard let opened = AX.openStatusMenu(pid: ctx.app.pid) else {
            throw ScenarioFailure(
                "could not open the status menu.\n" + AX.statusItemDiagnostics(pid: ctx.app.pid)
            )
        }
        var menuClosed = false
        defer { if !menuClosed { AX.closeMenuWithEscape() } }

        let (historyID, historyTitle) = MenuIDs.history
        guard let historyItem = AX.waitFor(identifier: historyID, orTitle: historyTitle, in: opened.menu, timeout: 3) else {
            throw ScenarioFailure("no History item; saw \(AX.menuItemTitles(opened.menu))")
        }
        guard let historyMenu = AX.submenu(of: historyItem) else {
            throw ScenarioFailure("History item has no submenu")
        }

        // Entry 0 is the most recent transcript. Menu titles get truncated, so compare
        // on a prefix of the normalized transcript rather than the whole string.
        let entries = AX.children(historyMenu)
        let entry0 = AX.find(identifier: MenuIDs.historyEntry(0), in: historyMenu, maxDepth: 3)
            ?? entries.first(where: { (AX.title($0) ?? "").isEmpty == false })
        guard let entry0, let entryTitle = AX.title(entry0) else {
            throw ScenarioFailure("no History entry 0; submenu items were \(AX.menuItemTitles(historyMenu))")
        }
        let prefix = String(Normalize.text(transcript).prefix(20))
        try Expect.isTrue(
            Normalize.text(entryTitle).hasPrefix(prefix),
            "History entry 0 (\"\(entryTitle)\") should start with the transcript prefix \"\(prefix)\""
        )

        // --- Show All opens the History window ------------------------------------
        let (showAllID, showAllTitle) = MenuIDs.historyShowAll
        guard let showAll = AX.waitFor(identifier: showAllID, orTitle: showAllTitle, in: historyMenu, timeout: 3) else {
            throw ScenarioFailure("no Show All item; saw \(AX.menuItemTitles(historyMenu))")
        }
        try Expect.isTrue(AX.press(showAll), "pressing Show All should succeed")
        menuClosed = true

        // Checked through AX, not CGWindowList: window *names* in the CG window list are
        // redacted unless the caller holds Screen Recording, so on a machine without
        // that grant every window reads as "" and a name match can never pass. The app
        // also logs a `window` record, which is asserted below as a second, independent
        // witness that this was a real open and not just a stale AX element.
        guard AX.waitForWindow(
            pid: ctx.app.pid,
            identifier: "vx.history.window",
            orTitle: "vx History",
            timeout: 8
        ) != nil else {
            throw ScenarioFailure(
                "\"vx History\" window never appeared; the app's windows were "
                    + "\(AX.windowDescriptions(pid: ctx.app.pid))"
            )
        }
        _ = try ctx.events.waitForRecord(
            kind: "window", field: "title", equals: "vx History", since: mark, timeout: 5
        )
        ctx.log("history window is up")
        ctx.write(ctx.events.transcript(since: mark), to: "events.txt")
    }
}

/// Preferences: open the Sound tab, flip a toggle, and prove it reached UserDefaults.
struct PrefsScenario: Scenario {
    static let name = "prefs"
    static let summary = "Preferences ▸ Sound toggle writes through to vx.sound-effects-enabled"

    func run(_ ctx: ScenarioContext) throws {
        guard AX.isTrusted else {
            throw ScenarioSkipped("Accessibility is not granted to the responsible process")
        }
        let app = AX.application(pid: ctx.app.pid)

        try ctx.control.require("open preferences:sound")
        guard AX.waitFor(identifier: "vx.prefs.window", orTitle: "vx Preferences", in: app, timeout: 6) != nil else {
            throw ScenarioFailure("the Preferences window never appeared")
        }

        // The control command should already have selected the tab; pressing the tab
        // is a fallback for a build where `open preferences:<tab>` ignores the suffix.
        if let tab = AX.find(identifier: "vx.prefs.tab.sound", in: app) {
            AX.press(tab)
            usleep(400_000)
        }

        guard let toggle = AX.waitFor(identifier: "vx.prefs.sound.playSounds", in: app, timeout: 5) else {
            throw ScenarioFailure("could not find vx.prefs.sound.playSounds in the Preferences window")
        }

        let before = ctx.app.readDefault("vx.sound-effects-enabled") ?? "0"
        try Expect.isTrue(AX.press(toggle), "pressing the Play Sounds toggle should succeed")
        let flipped = try waitForDefault(ctx, key: "vx.sound-effects-enabled", toChangeFrom: before)
        ctx.log("vx.sound-effects-enabled \(before) → \(flipped)")

        // Put it back so later scenarios stay hermetic (sounds off).
        AX.press(toggle)
        _ = try? waitForDefault(ctx, key: "vx.sound-effects-enabled", toChangeFrom: flipped)
        let restored = ctx.app.readDefault("vx.sound-effects-enabled") ?? "?"
        try Expect.equal(restored, before, "vx.sound-effects-enabled should be restored")

        _ = try? ctx.control.require("open preferences")
    }

    private func waitForDefault(_ ctx: ScenarioContext, key: String, toChangeFrom old: String) throws -> String {
        let deadline = Date().addingTimeInterval(4)
        repeat {
            if let now = ctx.app.readDefault(key), now != old { return now }
            usleep(200_000)
        } while Date() < deadline
        throw ScenarioFailure("\(key) never changed from \(old) after toggling the control")
    }
}
