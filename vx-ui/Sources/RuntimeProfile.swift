import Foundation

/// Runtime Profile: the single place that answers "where does this process read and write
/// its state?" — user defaults, `~/.vx` config, downloaded models, the debug log, the audio
/// input, and the test-only control surfaces.
///
/// Production behaviour is unchanged: with no `VX_*` environment variables set the profile
/// resolves to exactly the paths the app used before it existed (the user's home directory
/// and `UserDefaults.standard`). A verification harness sets the env vars to redirect the
/// whole app into a scratch directory so a run leaves no trace in the real home, which is
/// what `isHermetic` reports.
public struct RuntimeProfile {
    /// The profile for this process. Resolved once from the environment at first use.
    public static let current = RuntimeProfile(environment: ProcessInfo.processInfo.environment)

    // MARK: Environment variable names

    public enum Key {
        public static let defaultsSuite = "VX_DEFAULTS_SUITE"
        public static let configHome = "VX_CONFIG_HOME"
        public static let audioSource = "VX_AUDIO_SOURCE"
        public static let disableUpdateCheck = "VX_DISABLE_UPDATE_CHECK"
        public static let eventLog = "VX_EVENT_LOG"
        public static let testControl = "VX_TEST_CONTROL"

        static let all = [
            defaultsSuite, configHome, audioSource, disableUpdateCheck, eventLog, testControl,
        ]
    }

    // MARK: Stored properties

    /// Defaults store the app reads and writes. `VX_DEFAULTS_SUITE` swaps in a throwaway suite.
    public let defaults: UserDefaults
    /// The suite name behind `defaults`, or nil when using `.standard`.
    public let defaultsSuiteName: String?
    /// Stands in for the user's home directory for every vx-owned path.
    public let configHome: URL
    /// A WAV file to transcribe instead of opening the microphone, or nil for live capture.
    public let audioSourceURL: URL?
    /// True when the automatic update check must not run.
    public let disableUpdateCheck: Bool
    /// JSONL event log destination, or nil when event logging is off.
    public let eventLogURL: URL?
    /// Unix-domain socket path for the test control channel, or nil when it must not listen.
    public let testControlSocketPath: String?

    // MARK: Derived paths

    public var vxDirectory: URL { configHome.appendingPathComponent(".vx", isDirectory: true) }
    public var rulesDirectory: URL { vxDirectory.appendingPathComponent("rules", isDirectory: true) }
    public var promptsDirectory: URL { vxDirectory.appendingPathComponent("prompts", isDirectory: true) }
    public var appContextsFileURL: URL { vxDirectory.appendingPathComponent("app-contexts.yaml") }
    public var logFileURL: URL { configHome.appendingPathComponent("Library/Logs/vx-debug.log") }
    public var userModelsDirectory: URL {
        configHome.appendingPathComponent("Library/Application Support/vx/Models", isDirectory: true)
    }

    /// True when at least one `VX_*` override is in effect, i.e. this process is not reading
    /// and writing the real user's state.
    public let isHermetic: Bool

    // MARK: Init

    init(environment: [String: String], home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let suite = Self.nonEmpty(environment[Key.defaultsSuite])
        defaultsSuiteName = suite
        defaults = suite.flatMap { UserDefaults(suiteName: $0) } ?? .standard

        if let configOverride = Self.nonEmpty(environment[Key.configHome]) {
            configHome = Self.absoluteURL(configOverride)
        } else {
            configHome = home
        }

        audioSourceURL = Self.nonEmpty(environment[Key.audioSource]).map { Self.absoluteURL($0) }
        disableUpdateCheck = environment[Key.disableUpdateCheck] == "1"
        eventLogURL = Self.nonEmpty(environment[Key.eventLog]).map { Self.absoluteURL($0) }
        testControlSocketPath = Self.nonEmpty(environment[Key.testControl]).map { Self.absoluteURL($0).path }

        isHermetic = Key.all.contains { Self.nonEmpty(environment[$0]) != nil }
    }

    /// One-line description of the active overrides, for the debug log.
    public var summary: String {
        var parts: [String] = []
        if let defaultsSuiteName { parts.append("defaults=\(defaultsSuiteName)") }
        parts.append("configHome=\(configHome.path)")
        if let audioSourceURL { parts.append("audio=\(audioSourceURL.path)") }
        if disableUpdateCheck { parts.append("updateCheck=disabled") }
        if let eventLogURL { parts.append("eventLog=\(eventLogURL.path)") }
        if let testControlSocketPath { parts.append("testControl=\(testControlSocketPath)") }
        return parts.joined(separator: " ")
    }

    // MARK: Helpers

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Expands a leading `~` and resolves a relative path against the current working
    /// directory, so every path the profile hands out is absolute.
    private static func absoluteURL(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
}
