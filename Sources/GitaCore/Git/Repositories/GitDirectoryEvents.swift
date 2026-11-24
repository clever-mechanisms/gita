import Foundation

/// Which file-system events in a checkout's Git folders can change what Gitā shows for that checkout.
///
/// Agents run Git in every linked worktree all day, and each `git status` there rewrites that worktree's index under
/// the shared `worktrees/<name>/` folder; commits append to reflogs. None of that changes this checkout's status,
/// history or worktree list, so those events never refresh it. Another worktree counts only through its `HEAD` (the
/// commit or branch it holds), its `locked` mark, its `gitdir` pointer, or its folder appearing or going. Reflogs
/// (`logs/`) always travel with a ref or `HEAD` change that is watched anyway. In a linked worktree, the main
/// checkout's index belongs to another checkout too. Everything else in the Git folders still counts.
public struct GitDirectoryEvents: Sendable {
    private let gitDirectories: Set<String>
    private let commonDirectories: [String]
    private let isLinked: Bool
    /// What a linked worktree's folder holds that `git worktree list` reports.
    private static let worktreeFacts: Set<Substring> = ["HEAD", "locked", "gitdir"]

    public init(gitDirectory: URL, commonDirectory: URL) {
        gitDirectories = Set(Self.spellings(gitDirectory))
        commonDirectories = Self.spellings(commonDirectory)
        isLinked = gitDirectories.isDisjoint(with: commonDirectories)
    }

    /// False only for a path known not to matter; paths outside the common Git folder always matter.
    public func matters(_ path: String) -> Bool {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        for common in commonDirectories where trimmed.hasPrefix(common + "/") {
            let parts = trimmed.dropFirst(common.count + 1).split(separator: "/")
            guard let first = parts.first else { return true }
            switch first {
            case "logs": return false
            case "index", "index.lock": return parts.count > 1 || !isLinked
            case "worktrees": return worktreeEventMatters(parts.dropFirst(), common: common)
            default: return true
            }
        }
        return true
    }

    /// `parts` follow `<common>/worktrees/`: the worktree's folder name, then the path inside it.
    private func worktreeEventMatters(_ parts: ArraySlice<Substring>, common: String) -> Bool {
        guard let name = parts.first else { return true }
        let inside = parts.dropFirst()
        if gitDirectories.contains(common + "/worktrees/" + name) { return inside.first != "logs" }
        guard let leaf = inside.first else { return true }
        return inside.count == 1 && Self.worktreeFacts.contains(leaf)
    }

    /// The folder as given (standardized) and as `realpath(3)` spells it, which is how FSEvents reports paths.
    private static func spellings(_ url: URL) -> [String] {
        let standard = url.standardizedFileURL.path
        var result = [standard]
        if let real = realpath(standard, nil) {
            result.append(String(cString: real))
            free(real)
        }
        return Array(Set(result.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }))
    }
}
