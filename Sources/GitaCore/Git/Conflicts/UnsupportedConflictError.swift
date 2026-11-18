import Foundation

/// A conflict the editor cannot show or write, to be resolved with Git instead.
enum UnsupportedConflictError: Error, LocalizedError, Sendable, Equatable, CaseIterable {
    case symbolicLinkTooLarge
    case invalidSymbolicLinkTarget
    case oversizedOrSpecialWorkingFile
    case submoduleOrOversizedVersion
    case notPlainText
    case resultTooLarge

    var errorDescription: String? {
        switch self {
        case .symbolicLinkTooLarge: String(localized: "The symbolic link is too large to review.")
        case .invalidSymbolicLinkTarget: String(localized: "This symbolic-link target is not valid.")
        case .oversizedOrSpecialWorkingFile:
            String(localized: "Resolve this oversized or special working file outside the editor, then stage it.")
        case .submoduleOrOversizedVersion:
            String(localized: "Resolve this submodule or oversized version with Git, then stage it.")
        case .notPlainText: String(localized: "This conflict cannot be edited as plain text.")
        case .resultTooLarge: String(localized: "The edited result exceeds the text preview limit.")
        }
    }
}
