import XCTest
@testable import VXLib

final class TestControlCommandTests: XCTestCase {

    private func parsed(_ line: String, file: StaticString = #filePath, line lineNumber: UInt = #line) -> TestControlCommand? {
        switch TestControlCommand.parse(line) {
        case .success(let command):
            return command
        case .failure(let error):
            XCTFail("Expected '\(line)' to parse, got \(error.message)", file: file, line: lineNumber)
            return nil
        }
    }

    private func failure(_ line: String, file: StaticString = #filePath, line lineNumber: UInt = #line) -> TestControlError? {
        switch TestControlCommand.parse(line) {
        case .success(let command):
            XCTFail("Expected '\(line)' to fail, got \(command)", file: file, line: lineNumber)
            return nil
        case .failure(let error):
            return error
        }
    }

    func testParsesBareVerbs() {
        let table: [(String, TestControlCommand)] = [
            ("ping", .ping),
            ("state", .state),
            ("begin", .begin),
            ("finish", .finish),
            ("cancel", .cancel),
            ("toggle", .toggle),
            ("quit", .quit),
        ]
        for (input, expected) in table {
            XCTAssertEqual(parsed(input), expected, input)
        }
    }

    func testParsesGoSubcommands() {
        XCTAssertEqual(parsed("go start"), .goStart)
        XCTAssertEqual(parsed("go stop"), .goStop)
        XCTAssertEqual(parsed("go cancel"), .goCancel)
    }

    func testParsesHud() {
        XCTAssertEqual(parsed("hud recording"), .hud("recording"))
        XCTAssertEqual(parsed("hud hint"), .hud("hint"))
        XCTAssertEqual(parsed("hud hide"), .hud("hide"))
    }

    func testParsesOpen() {
        XCTAssertEqual(parsed("open preferences"), .open("preferences", tab: nil))
        XCTAssertEqual(parsed("open preferences:ai"), .open("preferences", tab: "ai"))
        XCTAssertEqual(parsed("open history"), .open("history", tab: nil))
        XCTAssertEqual(parsed("open debugLog"), .open("debugLog", tab: nil))
        XCTAssertEqual(parsed("open contextInspector"), .open("contextInspector", tab: nil))
    }

    func testIgnoresSurroundingWhitespaceAndNewlines() {
        XCTAssertEqual(parsed("  ping\n"), .ping)
        XCTAssertEqual(parsed("\tgo   start  \r\n"), .goStart)
        XCTAssertEqual(parsed("open  preferences:rules "), .open("preferences", tab: "rules"))
    }

    func testCommandsAreCaseSensitive() {
        XCTAssertEqual(failure("Ping"), .unknownCommand("Ping"))
        XCTAssertEqual(failure("PING"), .unknownCommand("PING"))
        XCTAssertEqual(failure("open Preferences"), .badArguments("unknown window 'Preferences'"))
    }

    func testRejectsEmptyInput() {
        XCTAssertEqual(failure(""), .empty)
        XCTAssertEqual(failure("   \n"), .empty)
    }

    func testRejectsUnknownVerb() {
        XCTAssertEqual(failure("bogus"), .unknownCommand("bogus"))
        XCTAssertEqual(failure("bogus arg"), .unknownCommand("bogus"))
    }

    func testRejectsExtraArguments() {
        XCTAssertEqual(failure("ping pong"), .badArguments("ping takes no arguments"))
        XCTAssertEqual(failure("quit now"), .badArguments("quit takes no arguments"))
    }

    func testRejectsBadGoArguments() {
        XCTAssertEqual(failure("go"), .badArguments("go expects one of: start, stop, cancel"))
        XCTAssertEqual(failure("go start now"), .badArguments("go expects one of: start, stop, cancel"))
        XCTAssertEqual(failure("go pause"), .badArguments("unknown go argument 'pause'"))
    }

    func testRejectsBadHudArguments() {
        XCTAssertNotNil(failure("hud"))
        XCTAssertNotNil(failure("hud recording extra"))
    }

    func testRejectsBadOpenArguments() {
        XCTAssertEqual(failure("open nowhere"), .badArguments("unknown window 'nowhere'"))
        XCTAssertEqual(failure("open history:main"), .badArguments("only preferences takes a tab"))
        XCTAssertEqual(failure("open preferences:"), .badArguments("empty preferences tab"))
        XCTAssertNotNil(failure("open"))
        XCTAssertNotNil(failure("open preferences ai"))
    }

    func testNameRoundTripsThroughTheParser() {
        let commands: [TestControlCommand] = [
            .ping, .state, .begin, .finish, .cancel, .toggle, .quit,
            .goStart, .goStop, .goCancel,
            .hud("processing"),
            .open("preferences", tab: "sound"),
            .open("history", tab: nil),
        ]
        for command in commands {
            XCTAssertEqual(parsed(command.name), command, command.name)
        }
    }

    func testReplyWireFormat() {
        XCTAssertEqual(TestControlReply.ok.wireLine, "ok\n")
        XCTAssertEqual(TestControlReply.okJSON(#"{"mode":"code"}"#).wireLine, "ok {\"mode\":\"code\"}\n")
        XCTAssertEqual(TestControlReply.error("nope").wireLine, "err nope\n")
    }
}
