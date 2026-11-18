import Foundation

/// Input checks shared by every feature, and commit resolution.
extension GitService {
    func resolveCommit(_ ref: String, verify: Bool = false) async throws -> String {
        try GitInput.validateReference(ref)
        if !verify && GitParsers.isObjectID(ref) { return ref }
        let result = try await execute(["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"])
        let sha = GitOutput.withoutTerminalLF(result.text)
        guard GitParsers.isObjectID(sha) else { throw GitError.invalidReference }
        return sha
    }

    /// A branch name Git itself accepts (`check-ref-format --branch`).
    func validateBranch(_ ref: String) async throws {
        try GitInput.validateReference(ref)
        _ = try await execute(["check-ref-format", "--branch", ref])
    }
}

enum GitInput {
    static let pathByteLimit = 32_768
    /// What the parsers produce for bytes that are not UTF-8: such a name cannot be passed back to Git.
    private static let replacementCharacter: Character = "\u{FFFD}"

    /// Not empty, no option-like leading dash and no NUL or line break.
    static func validateReference(_ ref: String) throws {
        guard !ref.isEmpty, !ref.hasPrefix("-"), !ref.contains("\0"), !ref.contains("\n"), !ref.contains("\r") else {
            throw GitError.invalidReference
        }
    }

    /// A repository-relative path that cannot leave the working copy.
    static func validatePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), !path.contains(replacementCharacter),
            !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else { throw GitError.invalidPath }
    }

    static func validatePaths(_ paths: [String]) throws { for path in paths { try validatePath(path) } }

    /// Stricter, for paths the app opens itself: every component is a real name and none is `.git`.
    static func validateComponents(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= pathByteLimit,
            path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git"
            })
        else { throw GitError.invalidPath }
    }

    static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    static func isStashReference(_ ref: String) -> Bool {
        ref.range(of: #"^stash@\{[0-9]+\}$"#, options: .regularExpression) != nil
    }
}
