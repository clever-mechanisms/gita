import Foundation

/// Which agent CLIs are installed: an executable file of that name in the login shell's PATH or a usual install
/// folder (checked like Orca: the file, never by running it).
public enum ReviewAgentDetector {
    public static func searchPath(
        loginPATH: String?, processPATH: String? = ProcessInfo.processInfo.environment["PATH"],
        home: String = NSHomeDirectory()
    ) -> [String] {
        let fallbacks = [
            "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "\(home)/.local/bin", "\(home)/Library/pnpm",
            "\(home)/.yarn/bin", "\(home)/.bun/bin", "\(home)/.volta/bin", "\(home)/.asdf/shims",
            "\(home)/.local/share/mise/shims", "\(home)/.nix-profile/bin", "\(home)/.npm-global/bin",
            "\(home)/.opencode/bin", "\(home)/.grok/bin", "\(home)/.cursor/bin",
        ]
        var seen = Set<String>()
        var result: [String] = []
        for entry in (loginPATH ?? "").split(separator: ":").map(String.init)
            + (processPATH ?? "").split(separator: ":").map(String.init) + fallbacks
        where entry.hasPrefix("/") && seen.insert(entry).inserted { result.append(entry) }
        return result
    }

    /// First executable of each agent along `path`.
    public static func installed(in path: [String], fileManager: FileManager = .default) -> [ReviewAgent: URL] {
        var found: [ReviewAgent: URL] = [:]
        for agent in ReviewAgent.allCases {
            for directory in path {
                let candidate = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent(
                    agent.executable)
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                    fileManager.isExecutableFile(atPath: candidate.path)
                {
                    found[agent] = candidate
                    break
                }
            }
        }
        return found
    }

    /// The PATH an interactive login shell sets up (where nvm, Homebrew and installers put agent CLIs).
    public static func loginShellPATH(
        shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        runner: CommandRunning = CommandRunner()
    ) async -> String? {
        let marker = "__GITA_PATH__"
        guard shell.hasPrefix("/"), !shell.contains("\0"),
            let result = try? await runner.run(
                executable: shell, arguments: ["-ilc", "printf '%s%s%s' '\(marker)' \"$PATH\" '\(marker)'"],
                directory: nil, timeout: 8, outputLimit: 256 * 1_024),
            result.exitCode == 0
        else { return nil }
        let parts = result.text.components(separatedBy: marker)
        return parts.count >= 3 ? parts[1] : nil
    }

    /// The chosen agent if it's installed, else the first installed in `preferenceOrder`.
    public static func pick(_ saved: String, installed: [ReviewAgent: URL]) -> ReviewAgent? {
        if let agent = ReviewAgent(rawValue: saved), installed[agent] != nil { return agent }
        return ReviewAgent.preferenceOrder.first { installed[$0] != nil }
    }
}
