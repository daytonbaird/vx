import ApplicationServices
import CoreGraphics
import Foundation

/// Thin, synchronous wrappers over the C Accessibility API.
///
/// The harness drives the app out-of-process, so AX is the only way to reach the
/// status menu and window controls. Everything here is best-effort and returns
/// optionals: a missing element is a scenario failure, not a crash.
enum AX {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestTrust() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func application(pid: pid_t) -> AXUIElement {
        AXUIElementCreateApplication(pid)
    }

    // MARK: - Attributes

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func identifier(_ element: AXUIElement) -> String? {
        string(element, kAXIdentifierAttribute)
    }

    static func title(_ element: AXUIElement) -> String? {
        string(element, kAXTitleAttribute)
    }

    static func role(_ element: AXUIElement) -> String? {
        string(element, kAXRoleAttribute)
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// `AXMenuItemMarkChar` — the checkmark glyph on a checked menu item. Non-empty
    /// means "selected"; that is how the harness asserts which Mode is active.
    static func markChar(_ element: AXUIElement) -> String? {
        string(element, "AXMenuItemMarkChar")
    }

    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let raw = attribute(element, "AXFrame") else { return nil }
        var rect = CGRect.zero
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(raw as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    static func setValue(_ element: AXUIElement, _ name: String, _ value: AnyObject) -> Bool {
        AXUIElementSetAttributeValue(element, name as CFString, value) == .success
    }

    // MARK: - Actions

    @discardableResult
    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    // MARK: - Search

    /// Depth-first search with a depth cap.
    ///
    /// The cap matters: an AX tree with a cycle (or just a deep SwiftUI hierarchy)
    /// will otherwise walk for minutes. 12 is comfortably deeper than any surface
    /// vx presents while still bounding a pathological tree.
    static func find(
        in root: AXUIElement,
        maxDepth: Int = 12,
        where predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        if predicate(root) { return root }
        guard maxDepth > 0 else { return nil }
        for child in children(root) {
            if let hit = find(in: child, maxDepth: maxDepth - 1, where: predicate) { return hit }
        }
        return nil
    }

    static func findAll(
        in root: AXUIElement,
        maxDepth: Int = 12,
        where predicate: (AXUIElement) -> Bool
    ) -> [AXUIElement] {
        var results: [AXUIElement] = []
        if predicate(root) { results.append(root) }
        guard maxDepth > 0 else { return results }
        for child in children(root) {
            results.append(contentsOf: findAll(in: child, maxDepth: maxDepth - 1, where: predicate))
        }
        return results
    }

    static func find(identifier id: String, in root: AXUIElement, maxDepth: Int = 12) -> AXUIElement? {
        find(in: root, maxDepth: maxDepth) { AX.identifier($0) == id }
    }

    static func find(title: String, in root: AXUIElement, maxDepth: Int = 12) -> AXUIElement? {
        find(in: root, maxDepth: maxDepth) { AX.title($0) == title }
    }

    /// Identifier first, title as a fallback.
    ///
    /// The identifier is the real contract and it *is* visible out-of-process — an
    /// `NSMenuItem` that was given one through `setAccessibilityIdentifier` reports it
    /// on its AX element. The title fallback exists for items that never got one.
    ///
    /// The fallback matches exactly first and then by prefix, because several of vx's
    /// menu titles carry a live suffix: the Mode item reads "Mode (Plain Text)" and
    /// the profile item "Code Profile (Generic)", so an exact-only fallback would miss
    /// exactly the items it was written to cover. Exact wins to keep "Code" from
    /// resolving to "Code Profile (Generic)" when both are in scope.
    static func find(
        identifier id: String,
        orTitle title: String?,
        in root: AXUIElement,
        maxDepth: Int = 12
    ) -> AXUIElement? {
        if let hit = find(identifier: id, in: root, maxDepth: maxDepth) { return hit }
        guard let title else { return nil }
        if let exact = find(in: root, maxDepth: maxDepth, where: { AX.title($0) == title }) { return exact }
        return find(in: root, maxDepth: maxDepth) { (AX.title($0) ?? "").hasPrefix(title) }
    }

    /// True when `element` is the one named by `id`, or (failing that) by `title`.
    /// Same exact-then-prefix rule as `find(identifier:orTitle:)`.
    static func matches(_ element: AXUIElement, identifier id: String, orTitle title: String?) -> Bool {
        if identifier(element) == id { return true }
        guard let title else { return false }
        let actual = self.title(element) ?? ""
        return actual == title || actual.hasPrefix(title)
    }

    /// Polls for an element until `timeout`; AX trees populate asynchronously after
    /// a window opens, so a bare lookup right after `open preferences` often misses.
    static func waitFor(
        in root: AXUIElement,
        timeout: TimeInterval = 5,
        maxDepth: Int = 12,
        where predicate: @escaping (AXUIElement) -> Bool
    ) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let hit = find(in: root, maxDepth: maxDepth, where: predicate) { return hit }
            usleep(100_000)
        } while Date() < deadline
        return nil
    }

    static func waitFor(identifier id: String, orTitle title: String? = nil, in root: AXUIElement, timeout: TimeInterval = 5) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let hit = find(identifier: id, orTitle: title, in: root) { return hit }
            usleep(100_000)
        } while Date() < deadline
        return nil
    }

    // MARK: - Status item

    /// The menubar "extras" element holding vx's `NSStatusItem`.
    ///
    /// System Events cannot see it (image-only status items expose no title), so the
    /// harness goes at the app element's own `AXExtrasMenuBar` attribute instead.
    static func extrasMenuBar(pid: pid_t) -> AXUIElement? {
        attribute(application(pid: pid), "AXExtrasMenuBar").map { $0 as! AXUIElement }
    }

    /// vx's status item button. Prefers the `vx.menu.statusItem` identifier (the string
    /// the app actually sets — `AXID.statusItem`) and falls back to the AX description
    /// "vx", which is the only string an image-only item carries.
    static func statusItem(pid: pid_t, timeout: TimeInterval = 5) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let bar = extrasMenuBar(pid: pid) {
                let candidates = children(bar)
                if let hit = candidates.first(where: { identifier($0) == "vx.menu.statusItem" }) { return hit }
                if let hit = candidates.first(where: { string($0, kAXDescriptionAttribute) == "vx" }) { return hit }
                if candidates.count == 1 { return candidates[0] }
            }
            usleep(150_000)
        } while Date() < deadline
        return nil
    }

    /// Opens the status menu and returns the `AXMenu` element.
    ///
    /// Three ways to open it, because no single one is reliable for an `NSStatusItem`:
    /// `AXPress` is the documented action but returns failure on a status-item button
    /// often enough to break a run; `AXShowMenu` is what AppKit actually wires up for
    /// an item that owns a menu; and a synthetic click on the item's frame is the last
    /// resort that behaves exactly like a user. Whichever one lands, the menu shows up
    /// as an `AXMenu` child of the item.
    static func openStatusMenu(pid: pid_t) -> (item: AXUIElement, menu: AXUIElement)? {
        guard let item = statusItem(pid: pid) else { return nil }

        for attempt in ["AXPress", "AXShowMenu", "click"] {
            switch attempt {
            case "AXPress":
                _ = press(item)
            case "AXShowMenu":
                _ = AXUIElementPerformAction(item, "AXShowMenu" as CFString)
            default:
                guard let frame = frame(item) else { continue }
                Mouse.click(at: CGPoint(x: frame.midX, y: frame.midY))
            }
            let deadline = Date().addingTimeInterval(1.5)
            repeat {
                if let menu = children(item).first(where: { role($0) == kAXMenuRole as String }) {
                    return (item, menu)
                }
                usleep(100_000)
            } while Date() < deadline
        }
        return nil
    }

    /// What the extras menubar actually contains, for a failure message. Without this
    /// a status-item failure is just "could not find it", which is unactionable.
    static func statusItemDiagnostics(pid: pid_t) -> String {
        guard let bar = extrasMenuBar(pid: pid) else {
            return "the app (pid \(pid)) exposes no AXExtrasMenuBar at all"
        }
        let kids = children(bar)
        if kids.isEmpty { return "AXExtrasMenuBar has no children" }
        let described = kids.enumerated().map { index, element in
            let id = identifier(element) ?? "<no AXIdentifier>"
            let desc = string(element, kAXDescriptionAttribute) ?? "<no AXDescription>"
            let title = self.title(element) ?? "<no AXTitle>"
            return "    [\(index)] role=\(role(element) ?? "?") id=\(id) desc=\(desc) "
                + "title=\(title) actions=\(actions(element))"
        }
        return "AXExtrasMenuBar children:\n" + described.joined(separator: "\n")
    }

    /// Escape closes an open NSMenu; `AXCancel` on the menu is unreliable for status items.
    static func closeMenuWithEscape() {
        Keys.tap(virtualKey: 53, flags: [])
        usleep(200_000)
    }

    /// A synthetic left click, used only to open the status menu when both AX actions
    /// have been refused.
    enum Mouse {
        static func click(at point: CGPoint) {
            let source = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                               mouseCursorPosition: point, mouseButton: .left)
            let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                             mouseCursorPosition: point, mouseButton: .left)
            down?.post(tap: .cghidEventTap)
            usleep(80_000)
            up?.post(tap: .cghidEventTap)
            usleep(250_000)
        }
    }

    /// A submenu's `AXMenu` child, opening it by pressing the parent item if needed.
    static func submenu(of item: AXUIElement, timeout: TimeInterval = 3) -> AXUIElement? {
        if let menu = children(item).first(where: { role($0) == kAXMenuRole as String }) { return menu }
        press(item)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let menu = children(item).first(where: { role($0) == kAXMenuRole as String }) { return menu }
            usleep(100_000)
        } while Date() < deadline
        return nil
    }

    /// Every AXMenuItem title in a menu, for failure messages.
    static func menuItemTitles(_ menu: AXUIElement) -> [String] {
        children(menu).compactMap { title($0) }
    }

    // MARK: - Windows

    /// Polls the app's `AXWindows` for one matching an identifier or a title.
    ///
    /// Preferred over `WindowList` for *existence* checks: `CGWindowListCopyWindowInfo`
    /// only fills in `kCGWindowName` when the caller holds Screen Recording, so on a
    /// machine without that grant every window comes back named "" and a name match can
    /// never succeed. AX only needs Accessibility, which the menu scenarios already
    /// require. `WindowList` is still the right tool for a window *id* to screenshot.
    static func waitForWindow(
        pid: pid_t,
        identifier id: String,
        orTitle title: String?,
        timeout: TimeInterval = 6
    ) -> AXUIElement? {
        let app = application(pid: pid)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let windows = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            if let hit = windows.first(where: { window in
                if identifier(window) == id { return true }
                if let title { return self.title(window) == title }
                return false
            }) {
                return hit
            }
            usleep(150_000)
        } while Date() < deadline
        return nil
    }

    /// Identifier + title of every window the app currently exposes, for failure text.
    static func windowDescriptions(pid: pid_t) -> [String] {
        let windows = (attribute(application(pid: pid), kAXWindowsAttribute) as? [AXUIElement]) ?? []
        return windows.map { "\(title($0) ?? "<untitled>") [\(identifier($0) ?? "no id")]" }
    }
}

/// CoreGraphics window-list lookups. Used to prove a window actually appeared on
/// screen (AX can report a window that is not yet mapped) and to get the window ID
/// `screencapture -l` needs.
enum WindowList {
    struct Info {
        let windowID: CGWindowID
        let name: String
        let ownerPID: pid_t
        let bounds: CGRect
    }

    static func windows(ownerPID: pid_t) -> [Info] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let owner = entry[kCGWindowOwnerPID as String] as? pid_t, owner == ownerPID,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID else { return nil }
            let name = (entry[kCGWindowName as String] as? String) ?? ""
            var rect = CGRect.zero
            if let boundsDict = entry[kCGWindowBounds as String] as? [String: Any] {
                rect = CGRect(
                    x: (boundsDict["X"] as? CGFloat) ?? 0,
                    y: (boundsDict["Y"] as? CGFloat) ?? 0,
                    width: (boundsDict["Width"] as? CGFloat) ?? 0,
                    height: (boundsDict["Height"] as? CGFloat) ?? 0
                )
            }
            return Info(windowID: id, name: name, ownerPID: owner, bounds: rect)
        }
    }

    /// Polls for a window whose name matches, e.g. "vx History".
    static func waitForWindow(ownerPID: pid_t, named name: String, timeout: TimeInterval = 5) -> Info? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let hit = windows(ownerPID: ownerPID).first(where: { $0.name == name }) { return hit }
            usleep(150_000)
        } while Date() < deadline
        return nil
    }

    /// Any on-screen window belonging to the app, largest first. A last resort when
    /// a panel reports an empty `kCGWindowName` (HUD panels sometimes do).
    static func largestWindow(ownerPID: pid_t) -> Info? {
        windows(ownerPID: ownerPID)
            .filter { $0.bounds.width > 1 && $0.bounds.height > 1 }
            .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }
}
