import XCTest
@testable import VXLib

final class EventLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vx-eventlog-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// `<dir>/nested/events.jsonl` where neither directory exists yet.
    private func makeLog() -> (EventLog, URL) {
        let url = directory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("events.jsonl")
        return (EventLog(url: url), url)
    }

    private func lines(of url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Splits `{"t":"<stamp>",<rest>}` into the timestamp and the rest of the object body.
    private func split(_ line: String) throws -> (timestamp: String, body: String) {
        let prefix = "{\"t\":\""
        let separator = "\","
        let unwrapped = try XCTUnwrap(line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil,
                                      "Line does not start with the timestamp key: \(line)")
        let range = try XCTUnwrap(unwrapped.range(of: separator), "No timestamp terminator: \(line)")
        let timestamp = String(unwrapped[unwrapped.startIndex..<range.lowerBound])
        var body = String(unwrapped[range.upperBound...])
        XCTAssertTrue(body.hasSuffix("}"), line)
        body.removeLast()
        return (timestamp, body)
    }

    func testCreatesParentDirectoryAndFile() throws {
        let (_, url) = makeLog()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testWritesOneJSONLineForAFlowEventAndOneForAKind() throws {
        let (log, url) = makeLog()

        log.record(.recordingStarted)
        log.record(kind: EventLog.Kind.launched, ["version": "1.0.44", "pid": "421"])

        let written = try lines(of: url)
        XCTAssertEqual(written.count, 2)

        let event = try split(written[0])
        XCTAssertEqual(event.body, #""event":{"recordingStarted":{}}"#)

        let launched = try split(written[1])
        XCTAssertEqual(launched.body, #""kind":"launched","fields":{"pid":"421","version":"1.0.44"}"#)
    }

    func testEventPayloadKeysAreSorted() throws {
        let (log, url) = makeLog()

        log.record(.processed(mode: "code", profile: "swift", detectedContext: "terminal", ruleCount: 2, transformed: true))

        let body = try split(try XCTUnwrap(lines(of: url).first)).body
        XCTAssertEqual(
            body,
            #""event":{"processed":{"detectedContext":"terminal","mode":"code","profile":"swift","ruleCount":2,"transformed":true}}"#
        )
    }

    func testFieldKeysAreSortedRegardlessOfInsertionOrder() throws {
        let (log, url) = makeLog()

        log.record(kind: EventLog.Kind.hudState, ["style": "recording", "state": "listening"])

        let body = try split(try XCTUnwrap(lines(of: url).first)).body
        XCTAssertEqual(body, #""kind":"hudState","fields":{"state":"listening","style":"recording"}"#)
    }

    func testTimestampIsISO8601WithFractionalSeconds() throws {
        let (log, url) = makeLog()
        log.record(kind: EventLog.Kind.control, ["command": "ping", "result": "ok"])

        let timestamp = try split(try XCTUnwrap(lines(of: url).first)).timestamp
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertNotNil(formatter.date(from: timestamp), "Not ISO8601 with fractional seconds: \(timestamp)")
        XCTAssertTrue(timestamp.contains("."), timestamp)
    }

    func testAppendsRatherThanTruncating() throws {
        let (first, url) = makeLog()
        first.record(kind: "one")

        let second = EventLog(url: url)
        second.record(kind: "two")

        let written = try lines(of: url)
        XCTAssertEqual(written.count, 2)
        XCTAssertTrue(written[0].contains(#""kind":"one""#))
        XCTAssertTrue(written[1].contains(#""kind":"two""#))
    }

    func testEveryLineIsValidJSON() throws {
        let (log, url) = makeLog()
        log.record(.transcriptReceived("hello \"world\""))
        log.record(kind: EventLog.Kind.window, ["title": "vx History", "event": "opened"])

        for line in try lines(of: url) {
            let data = Data(line.utf8)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data), line)
        }
    }
}
