import Foundation

/// Append-only JSONL log of machine-readable app events, written only when
/// `VX_EVENT_LOG` points at a file. A verification harness tails this instead of
/// scraping the human-readable debug log.
///
/// Two line shapes, one JSON object per line:
///
///     {"t":"2026-09-08T10:11:12.345Z","event":{"recordingStarted":{}}}
///     {"t":"2026-09-08T10:11:12.345Z","kind":"launched","fields":{"pid":"421","version":"1.0.44"}}
///
/// Writes are synchronous and lock-guarded, exactly like `DebugLogger.writeToFile`, so a
/// crash still leaves every event that had been recorded on disk.
public final class EventLog {
    /// The process-wide event log, or nil when event logging is not configured.
    public static let shared: EventLog? = RuntimeProfile.current.eventLogURL.map { EventLog(url: $0) }

    /// Well-known values for the `kind` field of non-flow records.
    public enum Kind {
        public static let launched = "launched"
        public static let hudState = "hudState"
        public static let menuAction = "menuAction"
        public static let window = "window"
        public static let control = "control"
    }

    public let url: URL

    private var fileHandle: FileHandle?
    private let lock = NSLock()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    public init(url: URL) {
        self.url = url
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        fileHandle?.seekToEndOfFile()
    }

    deinit {
        try? fileHandle?.close()
    }

    /// Records a dictation flow lifecycle event.
    func record(_ event: DictationFlowEvent) {
        guard let payload = encodedJSON(event) else { return }
        write("{\"t\":\"\(timestamp())\",\"event\":\(payload)}")
    }

    /// Records a non-flow event: a HUD transition, a menu action, a window open/close, a
    /// test-control command. See `EventLog.Kind` for the kinds in use.
    public func record(kind: String, _ fields: [String: String] = [:]) {
        guard let payload = encodedJSON(fields) else { return }
        write("{\"t\":\"\(timestamp())\",\"kind\":\(Self.jsonString(kind)),\"fields\":\(payload)}")
    }

    // MARK: - Private

    private func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }

    private func encodedJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Minimal JSON string literal, used for the one key we interpolate by hand.
    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return text
    }

    private func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        fileHandle?.write(data)
    }
}
