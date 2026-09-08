import XCTest
@testable import VXLib

final class DictationFlowEventCodingTests: XCTestCase {
    private let allCases: [DictationFlowEvent] = [
        .captureWillStart(goMode: true),
        .captureWillStart(goMode: false),
        .recordingStarted,
        .recordingWillStop,
        .transcribing,
        .transcriptReceived("hello world"),
        .processed(mode: "plainText", profile: "generic", detectedContext: "terminal", ruleCount: 3, transformed: true),
        .processed(mode: "code", profile: "swift", detectedContext: nil, ruleCount: 0, transformed: false),
        .textInserted("hi", behavior: "returnKey"),
        .submittedWithoutText(behavior: "terminalReturnKey"),
        .noSpeech,
        .cancelled,
        .failed("backend exited 1"),
        .goModeStarted,
        .goModeStopped(cancelled: true),
        .goModeStopped(cancelled: false),
        .audioSourceDrained,
    ]

    func testRoundTripsEveryCase() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for event in allCases {
            let data = try encoder.encode(event)
            let decoded = try decoder.decode(DictationFlowEvent.self, from: data)
            XCTAssertEqual(decoded, event, "Round trip changed \(event.name)")
        }
    }

    /// Pins the synthesized Codable shape so a Swift-version change can't silently rewrite
    /// the JSONL event log format.
    func testPinnedJSONShape() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let inserted = try encoder.encode(DictationFlowEvent.textInserted("hi", behavior: "returnKey"))
        XCTAssertEqual(String(decoding: inserted, as: UTF8.self),
                       #"{"textInserted":{"_0":"hi","behavior":"returnKey"}}"#)

        let started = try encoder.encode(DictationFlowEvent.recordingStarted)
        XCTAssertEqual(String(decoding: started, as: UTF8.self), #"{"recordingStarted":{}}"#)
    }

    func testNameMatchesCaseName() {
        XCTAssertEqual(DictationFlowEvent.textInserted("x", behavior: "none").name, "textInserted")
        XCTAssertEqual(DictationFlowEvent.recordingStarted.name, "recordingStarted")
        XCTAssertEqual(DictationFlowEvent.goModeStopped(cancelled: true).name, "goModeStopped")
        XCTAssertEqual(DictationFlowEvent.audioSourceDrained.name, "audioSourceDrained")
    }
}
