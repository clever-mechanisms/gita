import Foundation

/// A conflicted working file, its replacement, or the input for its staged result could not be read or written.
enum ConflictFileError: Error, LocalizedError, Sendable {
    case inspectWorkingFile
    case removeFile
    case replaceFile
    case prepareSymbolicLink
    case prepareResult
    case writeResult
    case finishWritingResult
    case createDirectory
    case openTemporaryDirectory
    case prepareInput
    case finishInput

    var errorDescription: String? {
        switch self {
        case .inspectWorkingFile: String(localized: "Could not inspect the working file.")
        case .removeFile: String(localized: "Could not remove the conflicted file.")
        case .replaceFile: String(localized: "Could not replace the conflicted file; reload before retrying.")
        case .prepareSymbolicLink: String(localized: "Could not prepare the symbolic link.")
        case .prepareResult: String(localized: "Could not prepare the conflict result.")
        case .writeResult: String(localized: "Could not write the conflict result.")
        case .finishWritingResult: String(localized: "Could not finish writing the conflict result.")
        case .createDirectory: String(localized: "Could not create the conflict file's directory.")
        case .openTemporaryDirectory: String(localized: "Could not open the temporary conflict directory.")
        case .prepareInput: String(localized: "Could not prepare the conflict input.")
        case .finishInput: String(localized: "Could not finish the conflict input.")
        }
    }
}
