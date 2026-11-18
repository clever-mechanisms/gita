import Darwin
import Foundation

/// One exact state change reported by an agent's hook through `gita-agent`. Only identifiers and the working
/// directory cross the socket: prompts, messages and transcript paths are never forwarded.
public struct AgentHookEvent: Codable, Sendable, Hashable {
    public enum Effect: String, Sendable, Hashable { case working, needsInput, done, cleared, ended, ignored }

    public var version = 1
    public var tool: AgentTool
    /// Claude Code hook name (`UserPromptSubmit`, `Notification`, `Stop`, `SessionEnd`) or `notify` for Codex.
    public var event: String
    public var sessionID: String?
    public var cwd: String?
    /// Claude `notification_type` or `SessionEnd` `reason`; Codex notification `type`.
    public var kind: String?
    /// The helper's ancestors, nearest first; the first one that is a known agent process owns the event.
    public var pids: [Int32]
    public var time: Double

    public init(
        tool: AgentTool, event: String, sessionID: String? = nil, cwd: String? = nil, kind: String? = nil,
        pids: [Int32] = [], time: Double = Date().timeIntervalSince1970
    ) {
        self.tool = tool
        self.event = Self.bounded(event, 64) ?? ""
        self.sessionID = Self.bounded(sessionID, 128)
        self.cwd = cwd.flatMap { $0.hasPrefix("/") ? Self.bounded($0, 1_024) : nil }
        self.kind = Self.bounded(kind, 64)
        self.pids = Array(pids.filter { $0 > 1 }.prefix(8))
        self.time = time
    }

    public var effect: Effect {
        switch (tool, event) {
        case (.claudeCode, "UserPromptSubmit"): return .working
        // `idle_prompt` repeats "waiting for your input" after a finished turn; `auth_success` is informational.
        case (.claudeCode, "Notification"):
            return ["idle_prompt", "auth_success"].contains(kind ?? "") ? .ignored : .needsInput
        case (.claudeCode, "Stop"): return .done
        // `/clear` ends one conversation and starts the next in the same process.
        case (.claudeCode, "SessionEnd"): return kind == "clear" ? .cleared : .ended
        case (.codex, "notify"): return kind == "agent-turn-complete" ? .done : .ignored
        default: return .ignored
        }
    }

    /// Claude Code writes the hook input as JSON on stdin.
    public static func claude(
        event: String, input: Data, pids: [Int32], time: Double = Date().timeIntervalSince1970
    ) -> Self {
        let object = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
        let kind = event == "SessionEnd" ? object["reason"] as? String : object["notification_type"] as? String
        return Self(
            tool: .claudeCode, event: event, sessionID: object["session_id"] as? String,
            cwd: object["cwd"] as? String, kind: kind, pids: pids, time: time)
    }

    /// Codex appends the notification JSON as the last argument of the `notify` program.
    public static func codex(
        argument: String?, pids: [Int32], time: Double = Date().timeIntervalSince1970
    ) -> Self {
        let object =
            argument.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] } ?? [:]
        return Self(
            tool: .codex, event: "notify", sessionID: object["thread-id"] as? String,
            cwd: object["cwd"] as? String, kind: object["type"] as? String, pids: pids, time: time)
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data()
    }

    /// Rejects anything that is not exactly one well-formed event of a supported version.
    public static func decode(_ data: Data) -> Self? {
        guard data.count <= AgentEventSocket.maximumMessage,
            let event = try? JSONDecoder().decode(Self.self, from: data),
            event.version == 1
        else { return nil }
        let checked = Self(
            tool: event.tool, event: event.event, sessionID: event.sessionID, cwd: event.cwd, kind: event.kind,
            pids: event.pids, time: event.time)
        return checked.event.isEmpty || !checked.time.isFinite ? nil : checked
    }

    private static func bounded(_ text: String?, _ limit: Int) -> String? {
        guard let text, !text.isEmpty, text.utf8.count <= limit, !text.contains("\0"), !text.contains("\n") else {
            return nil
        }
        return text
    }
}

/// Datagram Unix socket between the helper and the app. Datagrams need no connection: the helper fires one message
/// and exits even when the app is not running.
public enum AgentEventSocket {
    public static let maximumMessage = 2_000
    public static let fileName = "agents.sock"

    /// `~/Library/Application Support/Gita[ Development]/agents.sock`.
    public static func path(development: Bool, home: String = Self.userHome) -> String {
        home + "/Library/Application Support/" + (development ? "Gita Development" : "Gita") + "/" + fileName
    }

    /// The account's home from the user database, so an agent started with another `HOME` still reaches the app.
    public static var userHome: String {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir { return String(cString: directory) }
        return NSHomeDirectory()
    }

    /// Sends to every existing socket (installed and development app); never blocks, ignores every failure.
    public static func send(_ data: Data, to paths: [String]) {
        guard !data.isEmpty, data.count <= maximumMessage else { return }
        for path in paths {
            guard var address = address(path) else { continue }
            let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
            guard descriptor >= 0 else { continue }
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            _ = data.withUnsafeBytes { bytes in
                withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(
                            descriptor, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_un>.size)
                        )
                    }
                }
            }
            close(descriptor)
        }
    }

    static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }
}

/// The app side: binds the socket (owner-only), decodes datagrams off the main thread and hands valid events on.
public final class AgentEventListener: @unchecked Sendable {
    public let path: String
    private let source: DispatchSourceRead

    public enum Failure: Error {
        case pathTooLong
        case socket(Int32)
        case bind(Int32)
    }

    public init(
        path: String,
        queue: DispatchQueue = DispatchQueue(label: "dev.clevermechanisms.Gita.agent-events", qos: .utility),
        handler: @escaping @Sendable (AgentHookEvent) -> Void
    ) throws {
        guard var address = AgentEventSocket.address(path) else { throw Failure.pathTooLong }
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw Failure.socket(errno) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw Failure.bind(code)
        }
        chmod(path, 0o600)
        self.path = path
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: AgentEventSocket.maximumMessage + 1)
            while true {
                let count = recv(descriptor, &buffer, buffer.count, 0)
                guard count > 0 else { break }
                if count <= AgentEventSocket.maximumMessage, let event = AgentHookEvent.decode(Data(buffer[0..<count]))
                {
                    handler(event)
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit { cancel() }

    /// Stops listening and removes the socket file; later calls do nothing.
    public func cancel() {
        guard !source.isCancelled else { return }
        source.cancel()
        unlink(path)
    }
}
