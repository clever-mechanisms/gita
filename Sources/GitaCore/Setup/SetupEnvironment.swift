import Foundation

/// The command-line tools the first-run setup checks: what is installed and which account each CLI session uses.
/// Read-only: versions, `git config --global user.*`, `gh api user`, `vercel whoami`. Nothing here installs, signs in
/// or writes; the app runs those only from an explicit button.
public enum SetupTool: String, CaseIterable, Sendable {
    case git, github, vercel

    public var displayName: String {
        switch self {
        case .git: "Git"
        case .github: "GitHub CLI"
        case .vercel: "Vercel CLI"
        }
    }
    public var executable: String {
        switch self {
        case .git: "git"
        case .github: "gh"
        case .vercel: "vercel"
        }
    }
    /// The environment the tool runs with, the same one its provider uses.
    var environment: ChildEnvironmentPolicy {
        switch self {
        case .git: ProviderTool.git.environment
        case .github: ProviderTool.gh.environment
        case .vercel: ProviderTool.vercel.environment
        }
    }
    /// The Homebrew formula that installs the tool.
    public var formula: String {
        switch self {
        case .git: "git"
        case .github: "gh"
        case .vercel: "vercel-cli"
        }
    }
    /// Where to get it without Homebrew.
    public var downloadURL: URL {
        switch self {
        case .git: URL(string: "https://git-scm.com/downloads/mac")!
        case .github: URL(string: "https://cli.github.com")!
        case .vercel: URL(string: "https://vercel.com/docs/cli")!
        }
    }
    /// The interactive sign-in, run in a terminal window.
    public var signInArguments: [String] {
        switch self {
        case .git: []
        case .github: ["auth", "login"]
        case .vercel: ["login"]
        }
    }
}

public enum SetupToolState: Equatable, Sendable {
    case missing
    /// Git: installed, but `user.name` / `user.email` are not set.
    case needsIdentity(version: String)
    case signedOut(version: String)
    /// `detail`: the account login for a CLI, "version · name" for Git.
    case ready(detail: String)
    case failed(String)
}

public struct SetupProbe: Sendable {
    /// Where the probe looks for tools: Homebrew's folders first, then the system's.
    struct Locations: Sendable {
        var installFolders: [String]
        var systemFolders: [String]
        var xcodeSelect: String

        static let standard = Self(
            installFolders: ["/opt/homebrew/bin", "/usr/local/bin"], systemFolders: ["/usr/bin", "/bin"],
            xcodeSelect: "/usr/bin/xcode-select")
    }

    public let home: URL
    private let runner: any CommandRunning
    private let locations: Locations

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(home: home, runner: CommandRunner(), locations: .standard)
    }

    init(home: URL, runner: any CommandRunning, locations: Locations) {
        self.home = home
        self.runner = runner
        self.locations = locations
    }

    /// Folders a GUI app's PATH misses but installers use.
    public var searchPaths: [String] {
        locations.installFolders + [
            home.appendingPathComponent(".local/bin").path, home.appendingPathComponent(".npm-global/bin").path,
            home.appendingPathComponent(".bun/bin").path, home.appendingPathComponent("Library/pnpm").path,
        ] + locations.systemFolders
    }

    public func executable(_ name: String) -> String? {
        searchPaths.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public var homebrew: String? { installed("brew") }

    /// `name` in one of the Homebrew folders.
    private func installed(_ name: String) -> String? {
        locations.installFolders.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func run(
        executable: String, arguments: [String], timeout: TimeInterval,
        outputLimit: Int = CommandRequest.defaultOutputLimit, environment: ChildEnvironmentPolicy = .tool
    ) async throws -> CommandResult {
        var request = CommandRequest(
            executable: executable, arguments: arguments, timeout: timeout, outputLimit: outputLimit)
        request.environment = environment
        return try await runner.run(request)
    }

    /// The system Git (`/usr/bin/git`), a stub until the Command Line Tools are installed.
    private var systemGit: String { (locations.systemFolders.first ?? "/usr/bin") + "/git" }

    public func check(_ tool: SetupTool) async -> SetupToolState {
        switch tool {
        case .git: await checkGit()
        case .github: await checkCLI(tool, account: ["api", "user", "--jq", ".login"])
        case .vercel: await checkCLI(tool, account: ["whoami"])
        }
    }

    private func checkGit() async -> SetupToolState {
        // `/usr/bin/git` is a stub that pops up the Command Line Tools installer when they are missing; ask
        // `xcode-select` first so a check never triggers that dialog.
        var path = installed("git")
        if path == nil,
            let developer = try? await self.run(executable: locations.xcodeSelect, arguments: ["-p"], timeout: 10),
            developer.exitCode == 0
        {
            path = systemGit
        }
        guard let path,
            let result = try? await self.run(
                executable: path, arguments: ["--version"], timeout: 15, environment: SetupTool.git.environment),
            result.exitCode == 0
        else { return .missing }
        let version = Self.version(String(decoding: result.stdout, as: UTF8.self)) ?? ""
        async let name = config(path, "user.name")
        async let email = config(path, "user.email")
        let (userName, userEmail) = await (name, email)
        guard let userName, userEmail != nil else { return .needsIdentity(version: version) }
        return .ready(detail: [version, userName].filter { !$0.isEmpty }.joined(separator: " · "))
    }

    private func config(_ git: String, _ key: String) async -> String? {
        guard
            let result = try? await self.run(
                executable: git, arguments: ["config", "--global", "--get", key], timeout: 10,
                environment: SetupTool.git.environment),
            result.exitCode == 0
        else { return nil }
        let value = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func checkCLI(_ tool: SetupTool, account: [String]) async -> SetupToolState {
        guard let path = executable(tool.executable) else { return .missing }
        let version: String
        do {
            let result = try await self.run(
                executable: path, arguments: ["--version"], timeout: 20, outputLimit: 64 * 1_024,
                environment: tool.environment)
            version = Self.version(String(decoding: result.stdout + result.stderr, as: UTF8.self)) ?? ""
        } catch { return .failed(error.localizedDescription) }
        do {
            let result = try await self.run(
                executable: path, arguments: account, timeout: 20, outputLimit: 64 * 1_024,
                environment: tool.environment)
            let login = String(decoding: result.stdout, as: UTF8.self).split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
            if result.exitCode == 0, let login, Self.plausibleLogin(login) { return .ready(detail: login) }
            let message = String(decoding: result.stderr, as: UTF8.self).lowercased()
            if ["login", "log in", "auth", "credentials", "token"].contains(where: message.contains) {
                return .signedOut(version: version)
            }
            if result.exitCode != 0, message.isEmpty || message.contains("not logged") {
                return .signedOut(version: version)
            }
            return .failed(String(localized: "\(tool.displayName) did not answer."))
        } catch CommandError.timedOut {
            return .failed(String(localized: "\(tool.displayName) timed out."))
        } catch { return .failed(error.localizedDescription) }
    }

    /// "git version 2.47.1 (Apple Git-154)" → "2.47.1"; "gh version 2.63.0 (2024-11-27)" → "2.63.0";
    /// "Vercel CLI 39.1.1" → "39.1.1".
    public static func version(_ output: String) -> String? {
        guard let line = output.split(whereSeparator: \.isNewline).first(where: { $0.contains(where: \.isNumber) })
        else { return nil }
        return line.split(separator: " ").first { part in
            part.first?.isNumber == true && part.contains(".")
        }.map(String.init)
    }

    static func plausibleLogin(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.allSatisfy { $0.isLetter || $0.isNumber || "-_.@".contains($0) }
    }

    /// `brew install <formula>`; long, but bounded.
    public func install(_ tool: SetupTool) async throws -> CommandResult {
        guard let brew = homebrew else { throw CommandError.executableNotFound("brew") }
        return try await self.run(
            executable: brew, arguments: ["install", tool.formula], timeout: 900, outputLimit: 4 * 1_024 * 1_024)
    }

    /// Sets the global Git identity from an explicit choice.
    public func setIdentity(name: String, email: String) async throws {
        let git = installed("git") ?? systemGit
        for (key, value) in [("user.name", name), ("user.email", email)] {
            let result = try await self.run(
                executable: git, arguments: ["config", "--global", key, value], timeout: 10,
                environment: SetupTool.git.environment)
            guard result.exitCode == 0 else {
                throw SetupError.command(
                    String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
}

enum SetupError: Error, LocalizedError, Sendable {
    case command(String)
    var errorDescription: String? {
        switch self {
        case .command(let message): message.isEmpty ? String(localized: "The command failed.") : message
        }
    }
}
