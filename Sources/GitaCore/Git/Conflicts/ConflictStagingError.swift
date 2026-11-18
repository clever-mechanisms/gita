import Foundation

/// Git could not turn a conflict version or the saved result into what the working file or the index needs. Each
/// case carries Git's own diagnostic, shown after the explanation.
enum ConflictStagingError: Error, LocalizedError, Sendable {
    case preview(String)
    case conversion(String)
    case reviewedResult(String)
    case notStaged(String)

    var errorDescription: String? {
        switch self {
        case .preview(let detail): String(localized: "Git could not prepare the conflict preview. \(detail)")
        case .conversion(let detail):
            String(localized: "Git could not prepare a clean working-file conversion. \(detail)")
        case .reviewedResult(let detail):
            String(localized: "Git could not prepare the reviewed result for staging. \(detail)")
        case .notStaged(let detail):
            String(
                localized:
                    "The result was saved but could not be staged. Your saved file is preserved. \(detail)")
        }
    }
}
