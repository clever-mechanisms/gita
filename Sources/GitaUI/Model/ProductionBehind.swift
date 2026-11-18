import GitaCore

/// Where the "production is N commits behind" count is measured to: the production branch's remote-tracking ref
/// (origin's first), else the local branch.
enum ProductionBehind {
    static func tip(of branch: String, in references: [GitReference]) -> GitReference? {
        let remote = references.filter { $0.kind == .remote && $0.name.hasSuffix("/" + branch) }
        return remote.first { $0.name.split(separator: "/").first == "origin" } ?? remote.first
            ?? references.first { $0.kind == .branch && $0.name == branch }
    }
}
