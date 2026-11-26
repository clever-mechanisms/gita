import AppKit
import GitaCore

enum PermalinkCopyResult: Equatable {
    case copied(url: URL, message: String)
    case unavailable(message: String)
}

@MainActor
struct PermalinkHelper {
    var sink: (URL) -> Bool = { url in
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    func copyCommit(remote: String, sha: String) -> PermalinkCopyResult {
        copy(RemotePermalinkBuilder.commitURL(remote: remote, sha: sha))
    }

    func copyFile(remote: String, ref: String, path: String, lines: ClosedRange<Int>? = nil) -> PermalinkCopyResult {
        copy(RemotePermalinkBuilder.fileURL(remote: remote, ref: ref, path: path, lines: lines))
    }

    private func copy(_ url: URL?) -> PermalinkCopyResult {
        guard let url else {
            return .unavailable(message: String(localized: "No permalink is available for this selection."))
        }
        guard sink(url) else { return .unavailable(message: String(localized: "Could not write to the clipboard.")) }
        return .copied(url: url, message: String(localized: "Copied permalink."))
    }
}
