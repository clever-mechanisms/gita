import Foundation

/// Maps a working directory to its checkout with one `git rev-parse` per folder, cached. The branch is read from the
/// checkout's `HEAD` file on every call, so a `git switch` shows up without another subprocess.
///
/// Folders macOS protects with a privacy prompt (Desktop, Documents, Downloads, iCloud Drive, removable volumes) are
/// never touched unless they are inside a repository the user opened in Gita (`allowedRoots`).
public actor AgentCheckoutResolver {
    private struct Entry {
        var checkout: AgentCheckout?
        var expires: Date
    }
    private let runner: any CommandRunning
    private let home: String
    private var cache: [String: Entry] = [:]
    private var inFlight: [String: Task<AgentCheckout?, Never>] = [:]
    private let positiveLifetime: TimeInterval = 10 * 60
    private let negativeLifetime: TimeInterval = 60

    public init(runner: any CommandRunning = CommandRunner(), home: String = NSHomeDirectory()) {
        self.runner = runner
        self.home = home
    }

    public func resolve(_ directory: String, allowedRoots: [String] = [], now: Date = Date()) async -> AgentCheckout? {
        guard directory.hasPrefix("/") else { return nil }
        if let entry = cache[directory], entry.expires > now { return entry.checkout.map(Self.refreshingBranch) }
        if Self.isProtected(directory, home: home)
            && !allowedRoots.contains(where: { Self.isInside(directory, root: $0) })
        {
            cache[directory] = Entry(checkout: nil, expires: now.addingTimeInterval(negativeLifetime))
            return nil
        }
        if let running = inFlight[directory] { return await running.value }
        let runner = self.runner
        let task = Task { await Self.query(directory, runner: runner) }
        inFlight[directory] = task
        let checkout = await task.value
        inFlight[directory] = nil
        cache[directory] = Entry(
            checkout: checkout, expires: now.addingTimeInterval(checkout == nil ? negativeLifetime : positiveLifetime))
        return checkout
    }

    private static func query(_ directory: String, runner: any CommandRunning) async -> AgentCheckout? {
        guard FileManager.default.fileExists(atPath: directory) else { return nil }
        let result = try? await runner.run(
            CommandRequest.git(
                [
                    "--no-optional-locks", "rev-parse", "--path-format=absolute",
                    "--show-toplevel", "--git-dir", "--git-common-dir",
                ], directory: URL(fileURLWithPath: directory, isDirectory: true),
                timeout: 5, outputLimit: 64 * 1_024))
        guard let result, result.exitCode == 0 else { return nil }
        let lines = LossyText.decode(result.stdout).split(separator: "\n").map(String.init)
        guard lines.count == 3, lines.allSatisfy({ $0.hasPrefix("/") }) else { return nil }
        let checkout = URL(fileURLWithPath: lines[0], isDirectory: true).standardizedFileURL
        let gitDirectory = URL(fileURLWithPath: lines[1], isDirectory: true).standardizedFileURL
        let common = URL(fileURLWithPath: lines[2], isDirectory: true).standardizedFileURL
        // `<main>/.git` stands for `<main>`; a bare common directory (`repo.git` with worktrees) stands for the
        // repository itself.
        let repository = common.lastPathComponent == ".git" ? common.deletingLastPathComponent() : common
        return refreshingBranch(
            AgentCheckout(checkoutRoot: checkout, repositoryRoot: repository, gitDirectory: gitDirectory, branch: nil))
    }

    static func refreshingBranch(_ checkout: AgentCheckout) -> AgentCheckout {
        var copy = checkout
        copy.branch = branch(gitDirectory: checkout.gitDirectory)
        return copy
    }

    /// `ref: refs/heads/<name>` → name; detached or unreadable → nil.
    public static func branch(gitDirectory: URL) -> String? {
        guard let handle = FileHandle(forReadingAtPath: gitDirectory.appendingPathComponent("HEAD").path) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_024) else { return nil }
        let text = LossyText.decode(data).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("ref: refs/heads/") else { return nil }
        let name = String(text.dropFirst("ref: refs/heads/".count))
        return name.isEmpty ? nil : name
    }

    public static func isProtected(_ path: String, home: String) -> Bool {
        let protected =
            [
                "Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage", "Pictures",
                "Movies", "Music",
            ]
            .map { home + "/" + $0 } + ["/Volumes"]
        return protected.contains { isInside(path, root: $0) }
    }

    public static func isInside(_ path: String, root: String) -> Bool {
        let trimmed = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
        return path == trimmed || path.hasPrefix(trimmed + "/")
    }
}
