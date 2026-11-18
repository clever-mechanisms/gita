import Foundation

/// All file paths cross the Git boundary with NUL framing, never newline/quote parsing.
enum GitParsers {
    typealias Status = StatusParser.Status

    /// `%D` joins decorations with ", ". A refname cannot contain a space, so this split is exact even for names
    /// containing commas.
    private static let decorationSeparator = ", "
    private static let commitFields = 7
    private static let referenceFields = 6

    static func status(_ data: Data) -> Status { StatusParser.parse(data) }

    /// Records of `GitArguments.commitFormat`.
    static func commits(_ data: Data) -> [GitCommit] {
        let fields = GitOutput.nulFields(data)
        var commits: [GitCommit] = []
        commits.reserveCapacity(fields.count / commitFields)
        var index = 0
        while index + commitFields - 1 < fields.count {
            let id = fields[index].trimmingCharacters(in: .newlines)
            guard isObjectID(id) else {
                index += 1
                continue
            }
            commits.append(
                GitCommit(
                    id: id, parents: fields[index + 1].split(separator: " ").map(String.init),
                    subject: fields[index + 6], author: fields[index + 2], email: fields[index + 3],
                    date: Date(timeIntervalSince1970: Double(fields[index + 4]) ?? 0),
                    decorations: decorations(fields[index + 5])))
            index += commitFields
        }
        return commits
    }

    static func decorations(_ field: String) -> [String] {
        field.components(separatedBy: decorationSeparator).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Records of `GitArguments.referenceList`; other namespaces (stash, replace, notes) are skipped.
    static func references(_ data: Data) -> [GitReference] {
        let fields = GitOutput.nulFields(data)
        var refs: [GitReference] = []
        var index = 0
        while index + referenceFields - 1 < fields.count {
            let full = fields[index].trimmingCharacters(in: .newlines)
            guard let kind = GitReference.Kind(fullName: full) else {
                index += 1
                continue
            }
            refs.append(
                GitReference(
                    name: String(full.dropFirst(kind.prefix.count)), fullName: full,
                    commit: fields[index + 3].isEmpty ? fields[index + 1] : fields[index + 3],
                    kind: kind, isCurrent: fields[index + 2] == "*"))
            index += referenceFields
        }
        return refs
    }

    /// `git worktree list --porcelain -z`.
    static func worktrees(_ data: Data) -> [GitWorktree] {
        var trees: [GitWorktree] = []
        for field in GitOutput.nulFields(data) {
            if let path = field.dropPrefix("worktree ") {
                trees.append(GitWorktree(path: path, branch: nil, head: ""))
            } else if !trees.isEmpty {
                apply(field, to: &trees[trees.count - 1])
            }
        }
        return trees
    }

    private static func apply(_ field: String, to tree: inout GitWorktree) {
        if let head = field.dropPrefix("HEAD ") {
            tree.head = head
        } else if let branch = field.dropPrefix("branch ") {
            tree.branch = branch.dropPrefix(GitReference.Kind.branch.prefix) ?? branch
        } else if field == "bare" {
            tree.isBare = true
            tree.branch = nil
        } else if field == "locked" || field.hasPrefix("locked ") {
            tree.isLocked = true
        } else if field == "prunable" || field.hasPrefix("prunable ") {
            tree.isPrunable = true
        }
    }

    /// `git stash list --format=%gd%x00%s -z`.
    static func stashes(_ data: Data) -> [GitStash] {
        let fields = GitOutput.nulFields(data)
        return stride(from: 0, to: max(0, fields.count - 1), by: 2).map {
            GitStash(ref: fields[$0].trimmingCharacters(in: .newlines), subject: fields[$0 + 1])
        }
    }

    /// `--name-status -z`: renames and copies carry the original path first.
    static func changedFiles(_ data: Data) -> [FileChange] {
        let fields = GitOutput.nulFields(data)
        var result: [FileChange] = []
        var index = 0
        while index + 1 < fields.count {
            guard let status = fields[index].trimmingCharacters(in: .newlines).first else {
                index += 1
                continue
            }
            guard status == "R" || status == "C" else {
                result.append(FileChange(path: fields[index + 1], indexStatus: String(status), worktreeStatus: " "))
                index += 2
                continue
            }
            guard index + 2 < fields.count else { break }
            result.append(
                FileChange(
                    path: fields[index + 2], originalPath: fields[index + 1], indexStatus: String(status),
                    worktreeStatus: " "))
            index += 3
        }
        return result
    }

    /// `git ls-tree -z`: folders first, then Finder order.
    static func tree(_ data: Data, prefix: String = "") -> [TreeEntry] {
        GitOutput.nulFields(data).compactMap { field in
            guard let tab = field.firstIndex(of: "\t") else { return nil }
            let metadata = field[..<tab].split(separator: " ")
            guard metadata.count == 3 else { return nil }
            let name = String(field[field.index(after: tab)...])
            return TreeEntry(
                path: prefix.isEmpty ? name : prefix + "/" + name, kind: String(metadata[1]),
                objectID: String(metadata[2]))
        }.sorted {
            if $0.isTree != $1.isTree { return $0.isTree }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    /// A full SHA-1 or SHA-256 object ID in Git's lower-case hexadecimal.
    static func isObjectID(_ string: String) -> Bool {
        (string.utf8.count == 40 || string.utf8.count == 64) && isLowercaseHex(string)
    }

    static func isLowercaseHex(_ string: String) -> Bool {
        string.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
