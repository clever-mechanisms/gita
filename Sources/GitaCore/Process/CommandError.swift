import Foundation

public enum CommandError: Error, LocalizedError, Sendable {
    case executableNotFound(String)
    case invalidArgument
    case launchFailed(Int32)
    case timedOut
    case outputLimitExceeded(Int)
    case ioFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let name): return String(localized: "\(name) is not installed.")
        case .invalidArgument: return String(localized: "The command contains an invalid argument.")
        case .launchFailed(let code): return String(localized: "Could not start the command (\(code)).")
        case .timedOut: return String(localized: "The command timed out.")
        case .outputLimitExceeded(let limit):
            return String(localized: "The result exceeds the \(limit / 1_024) KB limit.")
        case .ioFailed(let code): return String(localized: "Could not read the command output (\(code)).")
        }
    }
}
