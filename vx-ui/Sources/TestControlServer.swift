import Darwin
import Foundation

// MARK: - Command

/// Test Control Channel command. The grammar is deliberately tiny and case-sensitive so a
/// shell one-liner can drive the app:
///
///     printf 'ping\n' | nc -U /tmp/vx.sock
///
///     ping                                  liveness probe
///     state                                 dump coordinator state as JSON
///     begin | finish | cancel | toggle      dictation lifecycle
///     go start | go stop | go cancel        go-mode lifecycle
///     hud <style|hint|hide>                 force a HUD appearance, no timers
///     open preferences[:<tab>]              open a window
///     open history | debugLog | contextInspector
///     quit                                  terminate the app
public enum TestControlCommand: Equatable {
    case ping
    case state
    case begin
    case finish
    case cancel
    case toggle
    case goStart
    case goStop
    case goCancel
    case hud(String)
    case open(String, tab: String?)
    case quit

    /// Surfaces `open` accepts.
    public static let openSurfaces = ["preferences", "history", "debugLog", "contextInspector"]

    /// Parses one line of the control grammar. Leading and trailing whitespace (including the
    /// trailing newline) is ignored; everything else is exact.
    public static func parse(_ line: String) -> Result<TestControlCommand, TestControlError> {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        let words = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let verb = words.first else { return .failure(.empty) }
        let arguments = Array(words.dropFirst())

        switch verb {
        case "ping":   return simple(.ping, verb: verb, arguments: arguments)
        case "state":  return simple(.state, verb: verb, arguments: arguments)
        case "begin":  return simple(.begin, verb: verb, arguments: arguments)
        case "finish": return simple(.finish, verb: verb, arguments: arguments)
        case "cancel": return simple(.cancel, verb: verb, arguments: arguments)
        case "toggle": return simple(.toggle, verb: verb, arguments: arguments)
        case "quit":   return simple(.quit, verb: verb, arguments: arguments)

        case "go":
            guard arguments.count == 1 else {
                return .failure(.badArguments("go expects one of: start, stop, cancel"))
            }
            switch arguments[0] {
            case "start":  return .success(.goStart)
            case "stop":   return .success(.goStop)
            case "cancel": return .success(.goCancel)
            default:       return .failure(.badArguments("unknown go argument '\(arguments[0])'"))
            }

        case "hud":
            guard arguments.count == 1 else {
                return .failure(.badArguments("hud expects one argument: a style, hint, or hide"))
            }
            return .success(.hud(arguments[0]))

        case "open":
            guard arguments.count == 1 else {
                return .failure(.badArguments("open expects one argument: \(openSurfaces.joined(separator: ", "))"))
            }
            let parts = arguments[0].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let surface = parts[0]
            let tab: String? = parts.count == 2 ? parts[1] : nil
            guard openSurfaces.contains(surface) else {
                return .failure(.badArguments("unknown window '\(surface)'"))
            }
            if let tab {
                guard surface == "preferences" else {
                    return .failure(.badArguments("only preferences takes a tab"))
                }
                guard !tab.isEmpty else {
                    return .failure(.badArguments("empty preferences tab"))
                }
            }
            return .success(.open(surface, tab: tab))

        default:
            return .failure(.unknownCommand(verb))
        }
    }

    private static func simple(
        _ command: TestControlCommand,
        verb: String,
        arguments: [String]
    ) -> Result<TestControlCommand, TestControlError> {
        guard arguments.isEmpty else {
            return .failure(.badArguments("\(verb) takes no arguments"))
        }
        return .success(command)
    }

    /// Bare verb, for log lines and event records.
    public var name: String {
        switch self {
        case .ping:    return "ping"
        case .state:   return "state"
        case .begin:   return "begin"
        case .finish:  return "finish"
        case .cancel:  return "cancel"
        case .toggle:  return "toggle"
        case .goStart: return "go start"
        case .goStop:  return "go stop"
        case .goCancel: return "go cancel"
        case .hud(let style): return "hud \(style)"
        case .open(let surface, let tab): return "open \(surface)\(tab.map { ":\($0)" } ?? "")"
        case .quit:    return "quit"
        }
    }
}

public enum TestControlError: Error, Equatable {
    case empty
    case unknownCommand(String)
    case badArguments(String)

    /// Text sent back after `err `.
    public var message: String {
        switch self {
        case .empty: return "empty command"
        case .unknownCommand(let verb): return "unknown command '\(verb)'"
        case .badArguments(let detail): return detail
        }
    }
}

// MARK: - Reply

public enum TestControlReply: Equatable {
    case ok
    case okJSON(String)
    case error(String)

    /// The bytes written back to the client, newline terminated.
    public var wireLine: String {
        switch self {
        case .ok: return "ok\n"
        case .okJSON(let json): return "ok \(json)\n"
        case .error(let message): return "err \(message)\n"
        }
    }
}

/// Implemented by whatever object can actually perform the commands — in the app, the
/// coordinator. Always called on the main thread.
public protocol TestControlHandler: AnyObject {
    @MainActor func handle(_ command: TestControlCommand) -> TestControlReply
}

// MARK: - Server

public enum TestControlServerError: Error, Equatable {
    case socketPathTooLong(String)
    case socketFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
}

/// Unix-domain-socket command interface, started only when `VX_TEST_CONTROL` names a socket
/// path. Every byte of socket work happens on a utility queue; commands hop to the main
/// thread just long enough for the handler to run, so the app's 12 s main-thread watchdog
/// can never see this server as the cause of a stall.
public final class TestControlServer {
    private let socketPath: String
    private weak var handler: TestControlHandler?
    private let queue = DispatchQueue(label: "com.vx.test-control", qos: .utility)

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [Int32: Connection] = [:]

    public init(socketPath: String, handler: TestControlHandler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    deinit {
        stop()
    }

    public func start() throws {
        let maxPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count <= maxPathLength else {
            throw TestControlServerError.socketPathTooLong(socketPath)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestControlServerError.socketFailed(errno) }

        // A stale socket file from a crashed run would make bind() fail with EADDRINUSE.
        unlink(socketPath)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength + 1) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[pathBytes.count] = 0
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bindResult == 0 else {
            let code = errno
            close(fd)
            throw TestControlServerError.bindFailed(code)
        }

        guard listen(fd, 4) == 0 else {
            let code = errno
            close(fd)
            unlink(socketPath)
            throw TestControlServerError.listenFailed(code)
        }

        Self.makeNonBlocking(fd)
        listenFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPendingConnections() }
        source.setCancelHandler { close(fd) }
        acceptSource = source
        source.resume()

        vxLog("[test-control] listening at \(socketPath)")
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        queue.sync {
            for connection in connections.values {
                connection.close()
            }
            connections.removeAll()
        }
        unlink(socketPath)
    }

    // MARK: Accept / read

    private func acceptPendingConnections() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            Self.makeNonBlocking(fd)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            let connection = Connection(fd: fd)
            connections[fd] = connection

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable(on: connection) }
            source.setCancelHandler { close(fd) }
            connection.source = source
            source.resume()
        }
    }

    private func readAvailable(on connection: Connection) {
        guard !connection.isClosed else { return }
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(connection.fd, &chunk, chunk.count)
            if count > 0 {
                connection.buffer.append(contentsOf: chunk[0..<count])
            } else if count == 0 {
                // EOF — the client stopped writing. It may still be waiting on replies for
                // commands already sent (`printf 'ping\n' | nc -N -U …`), so finish the queue
                // before tearing the connection down.
                connection.isHalfClosed = true
                // EOF is level-triggered: stop the source so it doesn't spin while the
                // in-flight command waits on the main thread.
                connection.suspendReads()
                break
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                if errno == EINTR { continue }
                finish(connection)
                return
            }
        }

        while let index = connection.buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: connection.buffer[connection.buffer.startIndex..<index], as: UTF8.self)
            connection.buffer.removeSubrange(connection.buffer.startIndex...index)
            connection.pending.append(line)
        }
        drain(connection)
    }

    /// Runs one command at a time per connection so replies come back in command order.
    private func drain(_ connection: Connection) {
        guard !connection.isClosed, !connection.isBusy else { return }
        guard !connection.pending.isEmpty else {
            if connection.isHalfClosed { finish(connection) }
            return
        }
        let line = connection.pending.removeFirst()
        connection.isBusy = true

        switch TestControlCommand.parse(line) {
        case .failure(let error):
            vxLog("[test-control/command] \(line) -> err \(error.message)")
            complete(connection, reply: .error(error.message))

        case .success(let command):
            vxLog("[test-control/command] \(command.name)")
            guard let handler else {
                complete(connection, reply: .error("no handler"))
                return
            }
            Task { @MainActor [weak self] in
                let reply = handler.handle(command)
                EventLog.shared?.record(kind: EventLog.Kind.control, [
                    "command": command.name,
                    "result": Self.resultLabel(reply),
                ])
                self?.queue.async { self?.complete(connection, reply: reply) }
            }
        }
    }

    private func complete(_ connection: Connection, reply: TestControlReply) {
        respond(reply.wireLine, on: connection)
        connection.isBusy = false
        drain(connection)
    }

    private func respond(_ text: String, on connection: Connection) {
        guard !connection.isClosed else { return }
        let bytes = Array(text.utf8)
        var offset = 0
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            while offset < bytes.count {
                let written = Darwin.write(connection.fd, base + offset, bytes.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    private func finish(_ connection: Connection) {
        connection.close()
        connections[connection.fd] = nil
    }

    private static func makeNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    private static func resultLabel(_ reply: TestControlReply) -> String {
        switch reply {
        case .ok: return "ok"
        case .okJSON: return "ok"
        case .error(let message): return "err \(message)"
        }
    }

    /// One accepted client. All fields are touched only on the server queue.
    private final class Connection {
        let fd: Int32
        var source: DispatchSourceRead?
        var buffer = Data()
        var pending: [String] = []
        var isBusy = false
        /// The client sent EOF; close once every queued command has been answered.
        var isHalfClosed = false
        private(set) var isClosed = false
        private var isSuspended = false

        init(fd: Int32) {
            self.fd = fd
        }

        func suspendReads() {
            guard !isSuspended, !isClosed else { return }
            isSuspended = true
            source?.suspend()
        }

        func close() {
            guard !isClosed else { return }
            isClosed = true
            // A suspended source never runs its cancel handler, which would leak the fd.
            if isSuspended {
                isSuspended = false
                source?.resume()
            }
            source?.cancel()
            source = nil
        }
    }
}
