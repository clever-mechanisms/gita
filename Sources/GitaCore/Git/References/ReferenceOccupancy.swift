import Foundation

/// Which worktrees hold a branch: checked out there, or reserved by a rebase (its branch or an `update-refs`
/// entry) or a bisect in that worktree. `identity` covers every reservation found.
struct ReferenceOccupancy {
    private static let worktreeLimit = 1_024
    private static let gitfileLimit = 32_768

    /// One worktree: its administrative directory and its working-tree path.
    private struct Location {
        var directory: URL
        var path: String
    }

    var paths: [String] = []
    var identity = Data()

    static func read(
        _ fullName: String, directories: ReferenceDirectories, service: isolated GitService
    ) async throws -> Self {
        let output = try await service.referenceCommand(["worktree", "list", "--porcelain", "-z"])
        guard String(data: output.stdout, encoding: .utf8) != nil else { throw GitError.invalidPath }
        let worktrees = GitParsers.worktrees(output.stdout)
        guard let primary = worktrees.first, worktrees.count <= worktreeLimit else {
            throw WorktreeMetadataError.unsupportedList
        }
        let resolved = worktrees.map { (tree: $0, path: Self.resolvedPath($0.path)) }
        let locations =
            [Location(directory: directories.common, path: Self.resolvedPath(primary.path))]
            + (try linkedLocations(common: directories.common, listed: Set(resolved.map(\.path))))
        var result = Self()
        for location in locations.sorted(by: { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }) {
            guard let worktree = resolved.first(where: { GitOutput.same($0.path, location.path) })?.tree else {
                throw WorktreeMetadataError.changed
            }
            try result.add(location, worktree: worktree, fullName: fullName)
        }
        return result
    }

    private static func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private static func directoryExists(_ url: URL) throws -> Bool {
        try BoundedFile.directoryExists(
            url, failure: WorktreeMetadataError.operationMetadataUnreadable,
            notDirectory: WorktreeMetadataError.operationMetadataNotDirectory) != nil
    }

    /// Linked worktrees from `<common>/worktrees/*/gitdir`, each of which must be in Git's own list.
    private static func linkedLocations(common: URL, listed: Set<String>) throws -> [Location] {
        let linked = common.appendingPathComponent("worktrees", isDirectory: true)
        guard try directoryExists(linked) else { return [] }
        let children = try FileManager.default.contentsOfDirectory(at: linked, includingPropertiesForKeys: nil)
        guard children.count <= worktreeLimit else {
            throw WorktreeMetadataError.tooManyWorktrees
        }
        return try children.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }.map { directory in
            guard try directoryExists(directory),
                let pointer = try BoundedFile.contents(directory.appendingPathComponent("gitdir"), limit: gitfileLimit),
                let gitfile = GitOutput.line(pointer), !gitfile.isEmpty, !gitfile.contains("\0")
            else { throw WorktreeMetadataError.changed }
            // --relative-paths stores this backlink relative to its own
            // worktree admin directory, not to the repository working tree.
            let gitfileURL =
                gitfile.hasPrefix("/") ? URL(fileURLWithPath: gitfile) : directory.appendingPathComponent(gitfile)
            let path = gitfileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
            guard listed.contains(where: { GitOutput.same($0, path) }) else { throw WorktreeMetadataError.changed }
            return Location(directory: directory, path: path)
        }
    }

    private mutating func add(_ location: Location, worktree: GitWorktree, fullName: String) throws {
        var state = Fingerprint()
        // Use Git's ref backend, not an assumed loose HEAD file. Reftable
        // repositories may keep a discovery placeholder at that path.
        let attached = !worktree.isBare && worktree.branch.map { GitOutput.same("refs/heads/" + $0, fullName) } == true
        state.add("HEAD", worktree.head)
        state.add("branch", worktree.branch)
        var reserved = false
        for directory in ["rebase-merge", "rebase-apply"] {
            reserved = try Self.rebaseReserves(location.directory, directory, fullName, &state) || reserved
        }
        let bisect = try BoundedFile.contents(location.directory.appendingPathComponent("BISECT_START"))
        if let branch = bisect.flatMap(GitOutput.line),
            GitOutput.same(branch.hasPrefix("refs/heads/") ? branch : "refs/heads/" + branch, fullName)
        {
            reserved = true
            state.add("bisect", bisect)
        }
        guard attached || reserved else { return }
        paths.append(location.path)
        state.add("path", location.path)
        state.add("directory", location.directory.path)
        identity.append(contentsOf: state.hex.utf8)
        identity.append(GitOutput.nul)
    }

    /// A rebase in this worktree reserves its own branch and, for rebase-merge, every `update-refs` entry.
    private static func rebaseReserves(
        _ worktreeDirectory: URL, _ name: String, _ fullName: String, _ state: inout Fingerprint
    ) throws -> Bool {
        let path = worktreeDirectory.appendingPathComponent(name)
        guard try directoryExists(path) else { return false }
        let branch = try BoundedFile.contents(path.appendingPathComponent("head-name"))
        var reserved = branch.flatMap(GitOutput.line).map { GitOutput.same($0, fullName) } == true
        state.add(name, branch)
        guard name == "rebase-merge", let updates = try BoundedFile.contents(path.appendingPathComponent("update-refs"))
        else { return reserved }
        let lines = updates.split(separator: GitOutput.lineFeed)
        guard lines.count % 3 == 0 else {
            throw WorktreeMetadataError.reservedMetadataIncomplete
        }
        for index in stride(from: 0, to: lines.count, by: 3) where lines[index].elementsEqual(fullName.utf8) {
            reserved = true
            state.add("update-ref", Data(lines[index...index + 2].joined(separator: [GitOutput.lineFeed])))
        }
        return reserved
    }
}
