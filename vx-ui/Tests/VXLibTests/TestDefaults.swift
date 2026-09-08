import Foundation

/// Creates and destroys throwaway `UserDefaults` suites for tests.
///
/// Two things make naive per-test suites (`UserDefaults(suiteName: UUID)`) a problem:
/// `removePersistentDomain(forName:)` clears the keys but cfprefsd keeps (and may
/// re-create) an empty `~/Library/Preferences/<suite>.plist`, and cfprefsd remembers
/// every domain it has ever seen. A few hundred of those per `swift test` run made
/// `defaults domains` take minutes on a developer machine.
///
/// So suite names come from a small fixed pool per prefix and are recycled: a suite is
/// wiped when it is handed out and again when it is destroyed. The number of leftover
/// plists is therefore bounded by the pool size, no matter how many tests run.
enum TestDefaults {
    private static let poolSize = 16
    private static let lock = NSLock()
    private static var counters: [String: Int] = [:]

    /// Returns a wiped suite from the pool. Always pair with `destroy(_:)`.
    static func makeSuite(prefix: String = "vx-test") -> (name: String, defaults: UserDefaults) {
        lock.lock()
        let index = counters[prefix, default: 0]
        counters[prefix] = (index + 1) % poolSize
        lock.unlock()

        let name = "\(prefix)-\(index)"
        wipe(name)
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("UserDefaults(suiteName:) returned nil for \(name)")
        }
        return (name, defaults)
    }

    /// Removes the suite's domain and its backing plist file (best effort).
    static func destroy(_ name: String) {
        wipe(name)
    }

    private static func wipe(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
        UserDefaults(suiteName: name)?.synchronize()
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(name).plist")
        try? FileManager.default.removeItem(at: plist)
    }
}
