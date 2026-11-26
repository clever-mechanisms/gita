import Foundation

public struct GitIgnoreClassifier: Sendable {
    private let git: StorageGit

    public init(runner: any CommandRunning = CommandRunner()) { git = StorageGit(runner: runner) }

    public func classify(candidates: [HeavyFolderEntry], in root: URL) async throws -> [HeavyFolderEntry] {
        let known = candidates.filter { $0.category != .otherLarge && !$0.containsProtectedContent }
        var verified = Set<String>()
        for batch in batches(known.map(\.relativePath)) {
            try Task.checkCancellation()
            let ignored = try await ignoredPaths(batch, at: root)
            let tracked = try await trackedFolders(in: Array(ignored), at: root)
            verified.formUnion(ignored.subtracting(tracked))
        }
        return candidates.map { entry in
            var classified = entry
            if entry.category == .otherLarge {
                classified.status = .otherLarge
            } else {
                classified.status = verified.contains(entry.relativePath) ? .reclaimable : .trackedOrUnignored
            }
            return classified
        }
    }

    func verification(_ path: String, in root: URL) async throws -> StorageCleanupError? {
        guard HeavyFolderCatalog.isKnownHeavyFolder(URL(fileURLWithPath: path).lastPathComponent) else {
            return .notReclaimable(path)
        }
        if try await !trackedFolders(in: [path], at: root).isEmpty { return .stillTracked(path) }
        return try await ignoredPaths([path], at: root).contains(path) ? nil : .notReclaimable(path)
    }

    private func ignoredPaths(_ paths: [String], at root: URL) async throws -> Set<String> {
        let input = paths.map { "./" + $0 }
        let result = try await GitIgnoreInput.run(input, at: root)
        if result.exitCode == 1 { return [] }
        let output = try StorageGit.checked(result).stdout
        return Set(GitOutput.nulFields(output).compactMap { $0.dropPrefix("./") })
    }

    private func trackedFolders(in paths: [String], at root: URL) async throws -> Set<String> {
        guard !paths.isEmpty else { return [] }
        let command = ["-c", "core.fsmonitor=false", "ls-files", "-z", "--"]
        let result: CommandResult
        do {
            result = try await git.read(command + paths.map { ":(icase,literal)" + $0 }, at: root)
        } catch CommandError.outputLimitExceeded {
            // An oversized index response must never authorize cleanup.
            guard paths.count > 1 else { return Set(paths) }
            let middle = paths.count / 2
            let first = try await trackedFolders(in: Array(paths[..<middle]), at: root)
            return try await first.union(trackedFolders(in: Array(paths[middle...]), at: root))
        }
        let candidates = Dictionary(grouping: paths, by: { $0.lowercased() })
        var tracked = Set<String>()
        for file in GitOutput.nulFields(result.stdout) {
            var path = file[...]
            while !path.isEmpty {
                if let matches = candidates[path.lowercased()] {
                    tracked.formUnion(matches)
                    break
                }
                guard let slash = path.lastIndex(of: "/") else { break }
                path = path[..<slash]
            }
        }
        return tracked
    }

    private func batches(_ paths: [String]) -> [[String]] {
        var result = [[String]]()
        var batch = [String]()
        var bytes = 0
        for path in paths {
            if bytes + path.utf8.count > 32_768 || batch.count >= 256 {
                result.append(batch)
                batch.removeAll(keepingCapacity: true)
                bytes = 0
            }
            batch.append(path)
            bytes += path.utf8.count + 3
        }
        if !batch.isEmpty { result.append(batch) }
        return result
    }
}
