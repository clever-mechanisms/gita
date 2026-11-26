import Foundation

public struct FlightCheckCommand: Sendable, Codable, Equatable {
    public let executable: String
    public let arguments: [String]
    public let timeoutSeconds: TimeInterval

    public init(executable: String, arguments: [String], timeoutSeconds: TimeInterval = 300) {
        self.executable = executable
        self.arguments = arguments
        self.timeoutSeconds = timeoutSeconds
    }

    public func validate() throws {
        let invalid = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
            .union(CharacterSet(charactersIn: ";&|<>$\u{60}\"'"))
        let shell = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh"].contains(
            URL(fileURLWithPath: executable).lastPathComponent)
        guard !executable.isEmpty, !executable.hasPrefix("-"), executable.rangeOfCharacter(from: invalid) == nil,
            !arguments.contains(where: { $0.contains("\0") }),
            !(shell && arguments.contains(where: { $0 == "--command" || ($0.hasPrefix("-") && $0.contains("c")) })),
            timeoutSeconds.isFinite, timeoutSeconds > 0
        else {
            throw ControlPlaneError(
                String(localized: "Enter one executable and separate arguments, with a positive timeout."))
        }
    }

    public static let presets = [
        Self(executable: "swift", arguments: ["test"]), Self(executable: "swift", arguments: ["build"]),
        Self(executable: "npm", arguments: ["test"]), Self(executable: "scripts/test.sh", arguments: []),
    ]
}

@MainActor
public struct FlightCheckSettingsStore {
    private let defaults: UserDefaults
    private let key = "controlPlane.flightCheck.commands"
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func command(for root: URL) -> FlightCheckCommand? {
        guard let command = entries[root.standardizedFileURL.resolvingSymlinksInPath().path],
            (try? command.validate()) != nil
        else { return nil }
        return command
    }

    public func save(_ command: FlightCheckCommand?, for root: URL) throws {
        try command?.validate()
        var commands = entries
        commands[root.standardizedFileURL.resolvingSymlinksInPath().path] = command
        defaults.set(try JSONEncoder().encode(commands), forKey: key)
    }

    private var entries: [String: FlightCheckCommand] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([String: FlightCheckCommand].self, from: $0) }
            ?? [:]
    }
}

public struct FlightCheckOutput: Sendable, Equatable {
    public internal(set) var lines: [String] = []
    public internal(set) var wasTruncated = false
    public init() {}
    public var text: String { lines.joined(separator: "\n") }

    mutating func append(_ raw: String) {
        let cleaned = ControlPlaneLog.clean(raw)
        var added = cleaned.components(separatedBy: "\n")
        if added.last?.isEmpty == true { added.removeLast() }
        lines.append(contentsOf: added)
        if lines.count > 300 {
            lines.removeFirst(lines.count - 300)
            wasTruncated = true
        }
        let joined = text
        if joined.utf8.count > 32_768 {
            lines = ControlPlaneLog.suffix(joined, bytes: 32_768).components(separatedBy: "\n")
            wasTruncated = true
        }
    }
}

public struct FlightCheckResult: Sendable, Equatable {
    public let commitSHA: String
    public let command: FlightCheckCommand
    public let succeeded: Bool
    public let exitCode: Int32
    public let duration: TimeInterval
    public let output: FlightCheckOutput
}

public enum FlightCheckState: Sendable, Equatable {
    case unconfigured
    case idle(lastResult: FlightCheckResult?)
    case preparing(commitSHA: String)
    case running(commitSHA: String, startedAt: Date, tail: FlightCheckOutput)
    case passed(FlightCheckResult)
    case failed(FlightCheckResult)
    case error(message: String)
    case cancelled
}
