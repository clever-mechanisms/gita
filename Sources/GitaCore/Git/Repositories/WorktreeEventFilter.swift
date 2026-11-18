import Foundation

/// Decides whether file-system events in a working copy can change what Git reports, so a build writing thousands
/// of files into a gitignored `.build/` or `node_modules/` costs no refresh. Classifies with `git check-ignore`
/// top-down by directory and caches the answers: once `node_modules/` is known ignored, nothing below it spawns a
/// process again. Conservative everywhere else: Git-directory paths, paths outside the root, any `.gitignore` or
/// `info/exclude` change (which also resets the cache), a failed check, and ignored directories that still contain
/// tracked files all count as relevant.
public actor WorktreeEventFilter {
    private let roots: [String]
    private let runner: any CommandRunning
    private var directories: [String: Bool] = [:] // relative directory → ignored and holds no tracked files
    private var files: [String: Bool] = [:] // relative file path → ignored
    private static let cacheLimit = 20_000
    private static let batch = 400

    public init(root: URL, runner: any CommandRunning = CommandRunner()) {
        // FSEvents reports real paths (`/private/var/…`); `URL.resolvingSymlinksInPath()` strips `/private`, so
        // the root is matched in its standardized, Foundation-resolved and realpath(3) spellings.
        let standard = root.standardizedFileURL.path
        var spellings = [standard, root.resolvingSymlinksInPath().standardizedFileURL.path]
        if let real = realpath(standard, nil) {
            spellings.append(String(cString: real))
            free(real)
        }
        roots = Array(Set(spellings.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }))
        self.runner = runner
    }

    private enum Verdict {
        case relevant, ignored
        case unknown(directory: String?, leaf: String?)
    }

    public func isRelevant(_ paths: [String]) async -> Bool {
        var pending = paths
        // Each round resolves the top-most unknown directory of every path (one batched `check-ignore`), so a burst
        // inside an ignored tree costs one round; leaves are asked about only under directories that matter.
        for _ in 0..<64 {
            var directoryQueries = Set<String>()
            var leafQueries = Set<String>()
            var next: [String] = []
            for path in pending {
                switch verdict(path) {
                case .relevant: return true
                case .ignored: continue
                case .unknown(let directory, let leaf):
                    next.append(path)
                    if let directory {
                        directoryQueries.insert(directory)
                    } else if let leaf {
                        leafQueries.insert(leaf)
                    }
                }
            }
            guard !next.isEmpty else { return false }
            let answered =
                directoryQueries.isEmpty
                ? await classify(files: Array(leafQueries)) : await classify(directories: Array(directoryQueries))
            guard answered else { return true }
            pending = next
        }
        return true
    }

    private func relative(_ path: String) -> String? {
        for root in roots {
            if path == root { return "" }
            if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        }
        return nil
    }

    private func verdict(_ path: String) -> Verdict {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard let relative = relative(trimmed), !relative.isEmpty else { return .relevant }
        let components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = components.first, first != ".git", components.last != ".gitignore" else {
            if components.last == ".gitignore" || relative.hasSuffix("info/exclude") {
                directories.removeAll()
                files.removeAll()
            }
            return .relevant
        }
        var prefix = ""
        for component in components.dropLast() {
            prefix = prefix.isEmpty ? component : prefix + "/" + component
            switch directories[prefix] {
            case true?: return .ignored
            case false?: continue
            case nil: return .unknown(directory: prefix, leaf: nil)
            }
        }
        // FSEvents names a file or a directory as the leaf; Git checks a directory leaf by its type on disk.
        switch files[relative] {
        case true?: return .ignored
        case false?: return .relevant
        case nil: return .unknown(directory: nil, leaf: relative)
        }
    }

    /// False when Git could not answer (the caller then treats the events as relevant).
    private func classify(directories queryDirectories: [String]) async -> Bool {
        if directories.count > Self.cacheLimit { directories.removeAll() }
        guard let ignoredDirectories = try? await ignored(queryDirectories.sorted().map { $0 + "/" }) else {
            return false
        }
        var candidates = queryDirectories.filter { ignoredDirectories.contains($0 + "/") }
        if !candidates.isEmpty {
            // An ignored directory with tracked (force-added) files still matters: its tracked files do.
            guard let tracked = try? await trackedPrefixes(candidates) else { return false }
            candidates.removeAll { tracked.contains($0) }
        }
        let ignoredSet = Set(candidates)
        for directory in queryDirectories { directories[directory] = ignoredSet.contains(directory) }
        return true
    }
    private func classify(files queryFiles: [String]) async -> Bool {
        if files.count > Self.cacheLimit { files.removeAll() }
        guard let ignoredFiles = try? await ignored(queryFiles) else { return false }
        for file in queryFiles { files[file] = ignoredFiles.contains(file) }
        return true
    }

    private func git(_ arguments: [String], outputLimit: Int) async -> CommandResult? {
        guard let root = roots.first else { return nil }
        let directory = URL(fileURLWithPath: root, isDirectory: true)
        // `check-ignore` and `ls-files` refresh the index, which runs a repository-supplied fsmonitor hook.
        let hardening = await FSMonitorHardening.shared.readOptions(root: directory, runner: runner)
        return try? await runner.run(
            CommandRequest.git(
                ["--no-pager", "--no-optional-locks", "-c", "core.quotepath=false"] + hardening + arguments,
                directory: directory, timeout: 10, outputLimit: outputLimit))
    }

    /// `check-ignore` takes `-z` only with `--stdin`, and this runner has no stdin; plain output is one path per
    /// line, C-quoted when unusual. Paths Git would quote are never asked about: they count as not ignored.
    private static func plainlyPrintable(_ path: String) -> Bool {
        !path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || $0 == "\"" || $0 == "\\" }
    }
    /// Git could not answer a query; the events then count as relevant.
    private struct Unanswered: Error {}

    private func ignored(_ paths: [String]) async throws -> Set<String> {
        var result = Set<String>()
        let askable = paths.filter(Self.plainlyPrintable)
        for start in stride(from: 0, to: askable.count, by: Self.batch) {
            let slice = Array(askable[start..<min(askable.count, start + Self.batch)])
            guard let output = await git(["check-ignore", "--"] + slice, outputLimit: 1_024 * 1_024) else {
                throw Unanswered()
            }
            // 0: some ignored, 1: none ignored; anything else is an error.
            guard output.exitCode == 0 || output.exitCode == 1 else { throw Unanswered() }
            let asked = Set(slice)
            for line in output.stdout.split(separator: 10) {
                let path = String(decoding: line, as: UTF8.self)
                if asked.contains(path) { result.insert(path) }
            }
        }
        return result
    }

    private func trackedPrefixes(_ directories: [String]) async throws -> Set<String> {
        var result = Set<String>()
        for start in stride(from: 0, to: directories.count, by: Self.batch) {
            let slice = Array(directories[start..<min(directories.count, start + Self.batch)])
            // Literal pathspecs: directory names are data, never glob magic.
            guard
                let output = await git(
                    ["--literal-pathspecs", "ls-files", "-z", "--"] + slice, outputLimit: 4 * 1_024 * 1_024),
                output.exitCode == 0
            else { throw Unanswered() }
            let tracked = output.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            for directory in slice where tracked.contains(where: { $0.hasPrefix(directory + "/") }) {
                result.insert(directory)
            }
        }
        return result
    }
}
