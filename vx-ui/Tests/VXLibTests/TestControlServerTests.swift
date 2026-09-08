import Darwin
import XCTest
@testable import VXLib

/// Records what it was asked to do and answers without touching any app state.
private final class FakeTestControlHandler: TestControlHandler {
    private(set) var received: [TestControlCommand] = []

    @MainActor func handle(_ command: TestControlCommand) -> TestControlReply {
        received.append(command)
        switch command {
        case .ping:
            return .ok
        case .state:
            return .okJSON(#"{"recording":false}"#)
        case .quit:
            return .error("refused in tests")
        default:
            return .ok
        }
    }
}

final class TestControlServerTests: XCTestCase {
    private var socketPath: String!
    private var server: TestControlServer?
    private var handler: FakeTestControlHandler!

    override func setUpWithError() throws {
        // Short path: sockaddr_un.sun_path caps out at 104 bytes.
        socketPath = "/tmp/vx-ctl-\(UUID().uuidString.prefix(8)).sock"
        handler = FakeTestControlHandler()
    }

    override func tearDownWithError() throws {
        server?.stop()
        server = nil
        unlink(socketPath)
    }

    private func startServer() throws -> TestControlServer {
        let server = TestControlServer(socketPath: socketPath, handler: handler)
        try server.start()
        self.server = server
        return server
    }

    /// Sends `input` on a background thread and returns the reply lines once `expectedLines`
    /// have arrived. All socket work stays off the main thread so the handler — which runs on
    /// the main thread — is never blocked by the test itself.
    private func exchange(
        _ input: String,
        expectedLines: Int,
        halfCloseAfterWriting: Bool = false,
        timeout: TimeInterval = 5
    ) -> [String] {
        let done = expectation(description: "replies for \(input)")
        var replies: [String] = []
        let path = socketPath!

        DispatchQueue.global(qos: .userInitiated).async {
            defer { done.fulfill() }
            guard let fd = Self.connect(to: path) else {
                XCTFail("Could not connect to \(path)")
                return
            }
            defer { close(fd) }

            let bytes = Array(input.utf8)
            let written = bytes.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress!, bytes.count) }
            XCTAssertEqual(written, bytes.count)
            if halfCloseAfterWriting {
                shutdown(fd, SHUT_WR)
            }

            var buffer = Data()
            var chunk = [UInt8](repeating: 0, count: 1024)
            while buffer.filter({ $0 == UInt8(ascii: "\n") }).count < expectedLines {
                let count = read(fd, &chunk, chunk.count)
                if count <= 0 { break }
                buffer.append(contentsOf: chunk[0..<count])
            }
            replies = String(decoding: buffer, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        }

        wait(for: [done], timeout: timeout)
        return replies
    }

    // MARK: - Tests

    func testStartCreatesTheSocketFile() throws {
        _ = try startServer()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
    }

    func testPingRepliesOK() throws {
        _ = try startServer()
        XCTAssertEqual(exchange("ping\n", expectedLines: 1), ["ok"])
    }

    func testUnknownCommandRepliesErr() throws {
        _ = try startServer()
        XCTAssertEqual(exchange("bogus\n", expectedLines: 1), ["err unknown command 'bogus'"])
    }

    func testJSONReplyIsPrefixedWithOK() throws {
        _ = try startServer()
        XCTAssertEqual(exchange("state\n", expectedLines: 1), [#"ok {"recording":false}"#])
    }

    func testMultipleNewlineDelimitedCommandsOnOneConnection() throws {
        _ = try startServer()

        let replies = exchange("ping\nbogus\nstate\n", expectedLines: 3)

        XCTAssertEqual(replies, [
            "ok",
            "err unknown command 'bogus'",
            #"ok {"recording":false}"#,
        ])
    }

    func testHandlerSeesTheParsedCommands() throws {
        _ = try startServer()
        _ = exchange("ping\ngo start\nhud recording\n", expectedLines: 3)

        // The test body is already on the main thread, where the handler ran.
        XCTAssertEqual(handler.received, [.ping, .goStart, .hud("recording")])
    }

    /// What `printf 'ping\n' | nc -N -U <path>` does: send, half-close, wait for the reply.
    func testRepliesAfterTheClientHalfCloses() throws {
        _ = try startServer()
        XCTAssertEqual(exchange("ping\n", expectedLines: 1, halfCloseAfterWriting: true), ["ok"])
    }

    func testSuccessiveConnectionsAreServed() throws {
        _ = try startServer()
        XCTAssertEqual(exchange("ping\n", expectedLines: 1), ["ok"])
        XCTAssertEqual(exchange("ping\n", expectedLines: 1), ["ok"])
    }

    func testStopRemovesTheSocketFile() throws {
        let server = try startServer()
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        server.stop()
        self.server = nil

        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testStartReplacesAStaleSocketFile() throws {
        FileManager.default.createFile(atPath: socketPath, contents: Data("stale".utf8))
        _ = try startServer()
        XCTAssertEqual(exchange("ping\n", expectedLines: 1), ["ok"])
    }

    func testRejectsAnOverlongSocketPath() {
        let longPath = "/tmp/" + String(repeating: "x", count: 120) + ".sock"
        let server = TestControlServer(socketPath: longPath, handler: handler)
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertEqual(error as? TestControlServerError, .socketPathTooLong(longPath))
        }
    }

    // MARK: - POSIX client

    private static func connect(to path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { close(fd); return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (index, byte) in bytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[bytes.count] = 0
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard result == 0 else { close(fd); return nil }
        return fd
    }
}
