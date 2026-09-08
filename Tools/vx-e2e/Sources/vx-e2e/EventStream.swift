import Foundation

/// One record from the app's JSONL event log.
///
/// The log carries two shapes and the harness parses both leniently — an unknown
/// case name or `kind` is data, not a failure, so adding an event app-side never
/// breaks an existing scenario.
///
///   flow:   {"event":{"<caseName>":{...payload...}},"t":"<ISO8601>"}
///   record: {"fields":{...},"kind":"launched|hudState|menuAction|window|control","t":"..."}
enum Event {
    case flow(name: String, payload: [String: Any], t: Date?)
    case record(kind: String, fields: [String: Any], t: Date?)
    case unknown(raw: String, t: Date?)

    var timestamp: Date? {
        switch self {
        case .flow(_, _, let t), .record(_, _, let t), .unknown(_, let t): return t
        }
    }

    var name: String {
        switch self {
        case .flow(let name, _, _):   return name
        case .record(let kind, _, _): return kind
        case .unknown:                return "?"
        }
    }

    var body: [String: Any] {
        switch self {
        case .flow(_, let payload, _):  return payload
        case .record(_, let fields, _): return fields
        case .unknown:                  return [:]
        }
    }

    /// Flow payloads use `_0` for an unlabeled associated value.
    func string(_ key: String) -> String? { body[key] as? String }
    func bool(_ key: String) -> Bool? { body[key] as? Bool }
    func int(_ key: String) -> Int? { (body[key] as? NSNumber)?.intValue }

    /// The unlabeled first associated value of a flow event (`transcriptReceived`,
    /// `textInserted`, `failed`).
    var firstValue: String? { string("_0") }

    var isFlow: Bool { if case .flow = self { return true }; return false }

    func isFlow(_ named: String) -> Bool { isFlow && name == named }

    func isRecord(_ kind: String) -> Bool {
        if case .record(let k, _, _) = self { return k == kind }
        return false
    }

    /// Parses one JSONL line. Returns nil for blank lines only.
    static func parse(line: String) -> Event? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unknown(raw: trimmed, t: nil)
        }
        let t = (obj["t"] as? String).flatMap(Event.parseTimestamp)

        if let flow = obj["event"] as? [String: Any], let (name, rawBody) = flow.first {
            // Swift's synthesized Codable emits `{"caseName": {...}}`; a no-payload case
            // may serialize as `{"caseName": {}}`.
            return .flow(name: name, payload: (rawBody as? [String: Any]) ?? [:], t: t)
        }
        // Defensive: accept a bare-string form `{"event":"caseName"}` too.
        if let name = obj["event"] as? String {
            return .flow(name: name, payload: [:], t: t)
        }
        if let kind = obj["kind"] as? String {
            return .record(kind: kind, fields: (obj["fields"] as? [String: Any]) ?? [:], t: t)
        }
        return .unknown(raw: trimmed, t: t)
    }

    static func parseTimestamp(_ s: String) -> Date? {
        // The app writes ISO8601; tolerate both with and without fractional seconds.
        if let d = iso8601Fractional.date(from: s) { return d }
        return iso8601Plain.date(from: s)
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

extension Event: CustomStringConvertible {
    var description: String {
        switch self {
        case .flow(let name, let payload, _):
            return payload.isEmpty ? name : "\(name)(\(Event.render(payload)))"
        case .record(let kind, let fields, _):
            return fields.isEmpty ? "[\(kind)]" : "[\(kind)] \(Event.render(fields))"
        case .unknown(let raw, _):
            return "<unparsed> \(raw.prefix(120))"
        }
    }

    private static func render(_ dict: [String: Any]) -> String {
        dict.keys.sorted().map { "\($0)=\(dict[$0] ?? "")" }.joined(separator: " ")
    }
}

enum EventStreamError: Error, CustomStringConvertible {
    case timeout(String, [Event])

    var description: String {
        switch self {
        case .timeout(let what, let seen):
            let tail = seen.suffix(15).map { "    \($0)" }.joined(separator: "\n")
            return "timed out waiting for \(what)\n  events seen so far:\n\(tail.isEmpty ? "    (none)" : tail)"
        }
    }
}

/// Tails the app's JSONL event log from a byte offset.
///
/// Deliberately offset-based rather than FSEvents-based: scenarios need to say
/// "from *here*, wait for X", and re-reading from a recorded offset makes that a
/// one-liner while also surviving the app being relaunched mid-run (call `reset`).
final class EventStream {
    let url: URL
    private(set) var offset: UInt64 = 0
    private(set) var events: [Event] = []
    private var partial = ""

    init(url: URL) {
        self.url = url
    }

    /// A mark you can pass to `since:` to scope assertions to a phase of a scenario.
    func mark() -> Int {
        drain()
        return events.count
    }

    /// Rewinds to the start of the file — use after relaunching the app with a fresh log.
    func reset() {
        offset = 0
        partial = ""
        events.removeAll()
    }

    /// Reads whatever has been appended since the last call.
    @discardableResult
    func drain() -> [Event] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            return []
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return [] }
        offset += UInt64(data.count)

        partial += String(decoding: data, as: UTF8.self)
        var fresh: [Event] = []
        // Keep the last fragment buffered: the app may be mid-write on a line.
        while let idx = partial.firstIndex(of: "\n") {
            let line = String(partial[partial.startIndex..<idx])
            partial = String(partial[partial.index(after: idx)...])
            if let event = Event.parse(line: line) { fresh.append(event) }
        }
        events.append(contentsOf: fresh)
        return fresh
    }

    private func firstMatch(since: Int, _ predicate: (Event) -> Bool) -> Event? {
        let start = max(0, min(since, events.count))
        return events[start...].first(where: predicate)
    }

    /// Polls every 50 ms until `predicate` matches an event at or after `since`.
    @discardableResult
    func wait(
        for description: String,
        since: Int = 0,
        timeout: TimeInterval = 15,
        predicate: (Event) -> Bool
    ) throws -> Event {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            drain()
            if let hit = firstMatch(since: since, predicate) { return hit }
            usleep(50_000)
        } while Date() < deadline
        drain()
        if let hit = firstMatch(since: since, predicate) { return hit }
        throw EventStreamError.timeout(description, events)
    }

    /// Convenience: wait for a flow event by case name.
    @discardableResult
    func waitForFlow(_ name: String, since: Int = 0, timeout: TimeInterval = 15) throws -> Event {
        try wait(for: "flow event '\(name)'", since: since, timeout: timeout) { $0.isFlow(name) }
    }

    /// Convenience: wait for a non-flow record, optionally matching one field.
    @discardableResult
    func waitForRecord(
        kind: String,
        field: String? = nil,
        equals value: String? = nil,
        since: Int = 0,
        timeout: TimeInterval = 15
    ) throws -> Event {
        let what = field.map { "record '\(kind)' with \($0)=\(value ?? "")" } ?? "record '\(kind)'"
        return try wait(for: what, since: since, timeout: timeout) { event in
            guard event.isRecord(kind) else { return false }
            guard let field, let value else { return true }
            return event.string(field) == value
        }
    }

    /// Asserts nothing matching `predicate` shows up within `window` seconds.
    func expectAbsent(
        _ description: String,
        since: Int = 0,
        window: TimeInterval,
        predicate: (Event) -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(window)
        while Date() < deadline {
            drain()
            if let hit = firstMatch(since: since, predicate) {
                throw ScenarioFailure("expected no \(description), but saw \(hit)")
            }
            usleep(50_000)
        }
    }

    /// Index of the first flow event with `name` at or after `since`, or nil.
    func indexOfFlow(_ name: String, since: Int = 0) -> Int? {
        let start = max(0, min(since, events.count))
        guard start < events.count else { return nil }
        for i in start..<events.count where events[i].isFlow(name) { return i }
        return nil
    }

    /// Asserts the named flow events appear in this relative order. Extra events
    /// in between are fine — this checks ordering, not exclusivity.
    func assertOrder(_ names: [String], since: Int = 0) throws {
        var cursor = since
        var previous = "start of scenario"
        for name in names {
            guard let idx = indexOfFlow(name, since: cursor) else {
                let start = max(0, min(since, events.count))
                let seen = events[start...].filter(\.isFlow).map(\.name).joined(separator: " → ")
                throw ScenarioFailure(
                    "expected flow event '\(name)' after \(previous); actual order was: \(seen.isEmpty ? "(no flow events)" : seen)"
                )
            }
            cursor = idx + 1
            previous = "'\(name)'"
        }
    }

    /// Everything logged since `mark`, for report artifacts.
    func transcript(since: Int = 0) -> String {
        let start = max(0, min(since, events.count))
        return events[start...].map(\.description).joined(separator: "\n")
    }
}
