import Foundation

/// Shared, read-only branch and checkout inventory for cleanup and stack review.
struct WorkflowBranches {
    var refs: [GitReference]
    var worktrees: [GitWorktree]
    var root: URL
    var defaultReference: GitReference?
    var currentBranch: String?

    var mergeTarget: String { defaultReference?.fullName ?? "HEAD" }

    var protectedNames: Set<String> {
        Set(worktrees.compactMap(\.branch) + [currentBranch, defaultReference?.name].compactMap { $0 })
    }

    func isCurrentCheckout(_ path: String) -> Bool {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path == root.path
    }

    var removableWorktrees: [GitWorktree] {
        worktrees.dropFirst().filter { !$0.isLocked && !$0.isBare && !isCurrentCheckout($0.path) }
    }
}

extension GitService {
    func workflowBranches() async throws -> WorkflowBranches {
        async let refsRead = execute(GitArguments.referenceList + ["refs/heads/"])
        async let treesRead = execute(["worktree", "list", "--porcelain", "-z"])
        async let defaultRead = workflowSymbolicRef("refs/remotes/origin/HEAD")
        async let currentRead = workflowSymbolicRef("HEAD")
        let refs = try await GitParsers.references(refsRead.stdout)
        let trees = try await GitParsers.worktrees(treesRead.stdout).map { entry in
            var tree = entry
            let url = URL(fileURLWithPath: entry.path, isDirectory: true)
            // Standardize the parent even when Git is reporting a missing checkout.
            tree.path =
                url.deletingLastPathComponent().standardizedFileURL
                .appendingPathComponent(url.lastPathComponent, isDirectory: true).path
            return tree
        }
        let remote = try await defaultRead
        let current = try await currentRead?.dropPrefix("refs/heads/")
        let names = Set(refs.map(\.name))
        guard refs.count == names.count else { throw GitError.invalidReference }
        let base = try await workflowDefault(refs, originHead: remote)
        return try await WorkflowBranches(
            refs: refs, worktrees: trees, root: repositoryRoot(), defaultReference: base, currentBranch: current)
    }

    private func workflowDefault(_ refs: [GitReference], originHead: String?) async throws -> GitReference? {
        if let originHead, let name = originHead.dropPrefix("refs/remotes/origin/") {
            if let local = refs.first(where: { $0.name == name }) { return local }
            if let tracking = try await workflowReference(originHead) { return tracking }
        }
        return refs.first { $0.name == "main" } ?? refs.first { $0.name == "master" }
    }

    func workflowReference(_ fullName: String) async throws -> GitReference? {
        let result = try await execute(GitArguments.referenceList + ["--", fullName])
        return GitParsers.references(result.stdout).first { $0.fullName == fullName }
    }

    private func workflowSymbolicRef(_ ref: String) async throws -> String? {
        let result = try await execute(["symbolic-ref", "--quiet", ref], allowFailure: true)
        if result.exitCode == 1 { return nil }
        guard result.exitCode == 0 else { throw Self.failure(result) }
        return GitOutput.withoutTerminalLF(result.text)
    }
}
