import GitaCore

/// Remote-branch names: `origin/feature/x` is remote `origin`, branch `feature/x`.
enum RemoteBranchName {
    /// `origin/feature/x` for a local `feature/x` (origin first, then any other remote), or nil when it was never
    /// pushed.
    static func remote(of branch: String, in references: [GitReference]) -> String? {
        let depth = branch.split(separator: "/").count + 1
        let matches = references.filter {
            $0.kind == .remote && $0.name.hasSuffix("/" + branch) && !$0.name.hasSuffix("/HEAD")
        }.map(\.name)
        return matches.first { $0 == "origin/" + branch } ?? matches.first { $0.split(separator: "/").count == depth }
    }

    /// "origin" for origin/feature/x.
    static func remoteName(_ reference: GitReference) -> String {
        reference.name.split(separator: "/", maxSplits: 1).first.map(String.init) ?? reference.name
    }

    /// "feature/x" for origin/feature/x.
    static func branchName(_ reference: GitReference) -> String {
        let parts = reference.name.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : reference.name
    }

    /// The configured remotes the references name, sorted.
    static func remotes(in references: [GitReference]) -> [String] {
        Array(
            Set(
                references.filter { $0.kind == .remote }.compactMap {
                    $0.name.split(separator: "/").first.map(String.init)
                })
        )
        .sorted()
    }
}
