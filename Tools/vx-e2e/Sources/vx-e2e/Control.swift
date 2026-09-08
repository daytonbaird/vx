import Darwin
import Foundation

/// A single reply line from the app's control channel.
enum ControlReply: Equatable {
    case ok
    case okJSON(String)
    case error(String)

    /// Parses one reply line. The wire format is deliberately trivial:
    ///   `ok` | `ok <json>` | `err <message>`
    /// Anything else is surfaced as an error so a protocol drift is loud, not silent.
    static func parse(_ line: String) -> ControlReply {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "ok" { return .ok }
        if trimmed.hasPrefix("ok ") {
            let payload = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            return payload.isEmpty ? .ok : .okJSON(payload)
        }
        if trimmed == "err" { return .error("") }
        if trimmed.hasPrefix("err ") {
            return .error(String(trimmed.dropFirst(4)))
        }
        return .error("unparseable reply: \(trimmed)")
    }

    var isOK: Bool {
        switch self {
        case .ok, .okJSON: return true
        case .error:       return false
        }
    }

    /// The `ok <json>` payload decoded as a dictionary, if it is one.
    var json: [String: Any]? {
        guard case .okJSON(let s) = self, let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

enum ControlError: Error, CustomStringConvertible {
    case socketPathTooLong(String)
    case cannotCreateSocket(Int32)
    case cannotConnect(String, Int32)
    case timedOut(String)
    case writeFailed(Int32)
    case replyFailed(String)

    var description: String {
        switch self {
        case .socketPathTooLong(let p): return "socket path too long for sockaddr_un: \(p)"
        case .cannotCreateSocket(let e): return "socket() failed: \(String(cString: strerror(e)))"
        case .cannotConnect(let p, let e): return "connect(\(p)) failed: \(String(cString: strerror(e)))"
        case .timedOut(let cmd): return "timed out waiting for reply to '\(cmd)'"
        case .writeFailed(let e): return "write failed: \(String(cString: strerror(e)))"
        case .replyFailed(let m): return m
        }
    }
}

/// Commands that make vx start capturing audio, and therefore make it paste into
/// whatever app is frontmost when the take completes.
///
/// A scenario must hold a `PasteTarget` before sending any of these; see
/// `GuardedControl`. Kept as data (not scattered `if`s) so a new dictation-starting
/// command is one line here rather than a leak waiting to happen.
enum ControlCommand {
    static let startsDictation: Set<String> = ["begin", "toggle", "go start"]

    /// The first token(s) of `line` normalized for lookup, e.g. `"go   start"` → `"go start"`.
    static func normalized(_ line: String) -> String {
        line.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    static func startsDictation(_ line: String) -> Bool {
        startsDictation.contains(normalized(line))
    }
}

/// `Control` plus the paste-target guard.
///
/// Scenarios get one of these instead of a raw `Control`, so the check cannot be
/// forgotten: a scenario that sends `begin` without first acquiring a `PasteTarget`
/// fails immediately rather than typing the transcript into the user's terminal.
struct GuardedControl {
    let control: Control

    private func check(_ command: String) throws {
        guard ControlCommand.startsDictation(command) else { return }
        guard PasteTarget.isActive else {
            throw ScenarioFailure(
                "'\(command)' would start a dictation with no paste target: vx pastes into "
                    + "whatever app is frontmost, so this would type the transcript into the "
                    + "user's session. Acquire a PasteTarget first (see PasteTarget.acquire())."
            )
        }
        // Focus can drift between acquiring the target and starting the take.
        try PasteTarget.active?.ensureFrontmost()
    }

    @discardableResult
    func send(_ command: String) throws -> ControlReply {
        try check(command)
        return try control.send(command)
    }

    @discardableResult
    func require(_ command: String) throws -> ControlReply {
        try check(command)
        return try control.require(command)
    }

    func state() throws -> [String: Any] { try control.state() }
    func pings() -> Bool { control.pings() }
}

/// Newline-delimited command client for the app's `VX_TEST_CONTROL` Unix socket.
///
/// Opens a fresh connection per command. That is a little wasteful, but it means a
/// scenario can never get out of sync with a half-read reply buffer, and a hung app
/// affects exactly one command instead of poisoning the session.
struct Control {
    let socketPath: String
    var timeout: TimeInterval = 5

    /// True once the app has created the socket file. Cheap enough to poll.
    var socketExists: Bool { FileManager.default.fileExists(atPath: socketPath) }

    @discardableResult
    func send(_ command: String) throws -> ControlReply {
        let fd = try connect()
        defer { close(fd) }

        var payload = Array((command + "\n").utf8)
        var written = 0
        while written < payload.count {
            let n = payload.withUnsafeBytes { buf -> Int in
                Darwin.write(fd, buf.baseAddress!.advanced(by: written), payload.count - written)
            }
            if n <= 0 {
                if errno == EINTR { continue }
                throw ControlError.writeFailed(errno)
            }
            written += n
        }
        payload.removeAll()

        var line = ""
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n > 0 {
                line += String(decoding: buffer[0..<n], as: UTF8.self)
                if let idx = line.firstIndex(of: "\n") {
                    return ControlReply.parse(String(line[line.startIndex..<idx]))
                }
                continue
            }
            if n == 0 {
                // Peer closed. If it sent something without a newline, take it anyway.
                guard !line.isEmpty else { throw ControlError.replyFailed("connection closed with no reply to '\(command)'") }
                return ControlReply.parse(line)
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { continue }
            throw ControlError.replyFailed("read failed: \(String(cString: strerror(errno)))")
        }
        throw ControlError.timedOut(command)
    }

    /// Sends a command and throws if the app answered `err …`.
    @discardableResult
    func require(_ command: String) throws -> ControlReply {
        let reply = try send(command)
        if case .error(let message) = reply {
            throw ControlError.replyFailed("'\(command)' → err \(message)")
        }
        return reply
    }

    /// `ping` → `ok`, swallowing connection failures (the app may not be up yet).
    func pings() -> Bool {
        (try? send("ping"))?.isOK ?? false
    }

    /// Polls `ping` until it answers or the deadline passes.
    func waitUntilReady(timeout waitTimeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(waitTimeout)
        while Date() < deadline {
            if socketExists, pings() { return true }
            usleep(100_000)
        }
        return false
    }

    /// Decoded `state` reply.
    func state() throws -> [String: Any] {
        let reply = try require("state")
        guard let json = reply.json else {
            throw ControlError.replyFailed("state did not return JSON: \(reply)")
        }
        return json
    }

    private func connect() throws -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else { throw ControlError.socketPathTooLong(socketPath) }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError.cannotCreateSocket(errno) }

        // Bound reads so a wedged app cannot hang a scenario forever.
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            let err = errno
            close(fd)
            throw ControlError.cannotConnect(socketPath, err)
        }
        return fd
    }
}
