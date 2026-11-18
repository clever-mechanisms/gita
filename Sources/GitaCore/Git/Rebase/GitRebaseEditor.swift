import CryptoKit
import Darwin
import Foundation

/// Entrypoint used before AppKit starts. Helper invocations never open a window or
/// execute repository-supplied commands; all editable content travels in files.
public enum GitRebaseEditor {
    static let argument = "--gita-rebase-editor"

    public static func handleInvocation(arguments: [String]) -> Int32? {
        guard arguments.dropFirst().first == argument else { return nil }
        do {
            guard arguments.count == 6, ["sequence", "message"].contains(arguments[2]) else {
                throw RebaseEditorError.invalidInvocation
            }
            let directory = URL(fileURLWithPath: arguments[3], isDirectory: true)
            let session = try RebaseSession.load(directory: directory, id: arguments[4])
            let target = URL(fileURLWithPath: RebaseFiles.lexicalPath(URL(fileURLWithPath: arguments[5])))
            if arguments[2] == "sequence" {
                try session.installSequence(at: target)
            } else {
                try session.editMessage(at: target)
            }
            return 0
        } catch {
            // A bounded fixed diagnostic keeps commit text and filesystem details
            // out of stderr and lets Git leave the operation resumable.
            let diagnostic = Data(
                (String(
                    localized:
                        "Gitā could not validate this rebase editor session. Reload the operation or abort it.")
                    + "\n").utf8)
            diagnostic.withUnsafeBytes { _ = Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
            return 1
        }
    }
}

struct RebaseManifest: Codable, Sendable {
    let version: Int
    let id: String
    let root: String
    let rootIdentity: String
    let gitDirectory: String
    let gitIdentity: String
    let baseID: String
    let headID: String
    let headName: String
    let originalIDs: [String]
    let steps: [GitRebaseStep]
    let commentPrefix: String
}

/// A file that names a rebase session by id: the pending pointer before Git starts, the marker while it runs.
protocol RebaseSessionPointer {
    var id: String { get }
}

struct RebaseMarker: Codable, Sendable, RebaseSessionPointer {
    let version: Int
    let id: String
    let manifestDigest: String
    let rebaseIdentity: String
}

struct RebasePending: Codable, RebaseSessionPointer {
    let version: Int
    let id: String
    let manifestDigest: String
}

struct RebaseInstruction: Equatable {
    let action: GitRebaseAction
    let commitID: String
}
