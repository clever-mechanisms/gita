import Foundation

/// What a child gets on top of the app's own environment. The code that starts a program knows what it is and
/// passes the policy in; nothing is inferred from the executable's name.
struct ChildEnvironmentPolicy: Sendable, Equatable {
    /// Git and the user hooks it runs: only Git's non-interactive settings, and no Orca CLI folder in `PATH`.
    static let git = Self(isGit: true, removed: [])
    /// Provider and helper CLIs: also their prompt and telemetry switches.
    static let tool = Self(isGit: false, removed: [])
    /// The Orca CLI: a tool whose `PATH` also has the folder inside Orca's app bundle where `orca` is installed.
    static let orca = Self(isGit: false, removed: [], searchesOrca: true)

    let isGit: Bool
    /// Inherited variables the program must not see, such as overrides of what Gita verified.
    let removed: Set<String>
    /// `ChildEnvironment.orcaPath` is searched, after the system folders.
    var searchesOrca = false

    /// A provider CLI that must not see `variables`.
    static func tool(removing variables: Set<String>) -> Self { Self(isGit: false, removed: variables) }
}

/// The environment a child starts with: the app's own, minus anything that could redirect Git, plus
/// non-interactive defaults chosen by a `ChildEnvironmentPolicy`.
enum ChildEnvironment {
    static let systemPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
    static let orcaPath = "/Applications/Orca.app/Contents/Resources/bin"

    private static let shared = [
        "GIT_TERMINAL_PROMPT": "0", "GIT_PAGER": "cat", "PAGER": "cat", "GIT_EDITOR": "true", "NO_COLOR": "1",
        "TERM": "dumb", "LC_ALL": "en_US.UTF-8",
    ]
    private static let toolOnly = ["GH_PROMPT_DISABLED": "1", "VERCEL_TELEMETRY_DISABLED": "1", "CI": "1"]
    /// An inherited Git checkout, index, config or history override must never redirect this app's commands.
    private static let gitOverrides: Set<String> = [
        "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_PREFIX", "GIT_LITERAL_PATHSPECS",
        "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS", "GIT_SEQUENCE_EDITOR", "GIT_CONFIG",
        "GIT_SHALLOW_FILE", "GIT_REPLACE_REF_BASE", "GIT_NO_REPLACE_OBJECTS", "GIT_CEILING_DIRECTORIES",
    ]

    /// Directories searched for a bare executable name, in order, without duplicates. Git never searches the Orca
    /// CLI folder, even when it is inherited; only the Orca policy adds it.
    static func searchPaths(policy: ChildEnvironmentPolicy, inherited: [String: String]) -> [String] {
        let inheritedPaths = (inherited["PATH"] ?? "").split(separator: ":").map(String.init).filter {
            $0.hasPrefix("/")
        }
        var seen = Set<String>()
        return (systemPaths + (policy.searchesOrca ? [orcaPath] : []) + inheritedPaths).filter {
            (!policy.isGit || $0 != orcaPath) && seen.insert($0).inserted
        }
    }

    static func make(
        policy: ChildEnvironmentPolicy, editors: GitEditorEnvironment?, inherited: [String: String]
    ) -> [String: String] {
        var environment = inherited.filter { !isRedirect($0.key) && !policy.removed.contains($0.key) }
        environment.merge(shared) { _, new in new }
        if !policy.isGit { environment.merge(toolOnly) { _, new in new } }
        environment["PATH"] = searchPaths(policy: policy, inherited: inherited).joined(separator: ":")
        if let editors {
            environment["GIT_EDITOR"] = editors.editor
            environment["GIT_SEQUENCE_EDITOR"] = editors.sequenceEditor
        }
        if environment["GIT_SSH_COMMAND"] == nil { environment["GIT_SSH_COMMAND"] = "/usr/bin/ssh -oBatchMode=yes" }
        return environment
    }

    private static func isRedirect(_ key: String) -> Bool { key.hasPrefix("GIT_CONFIG_") || gitOverrides.contains(key) }

    /// macOS's `/usr/bin/git` is a stub that asks `xcrun` for the selected developer directory's Git on every run
    /// (3–10 ms a command, and a history refresh runs several in a row). That Git is run directly instead.
    static let gitStub = "/usr/bin/git"
    private static let developerGit = selectedDeveloperGit(
        environment: ProcessInfo.processInfo.environment,
        selection: (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")))

    /// `path`, or for the Git stub the Git it would run.
    static func direct(_ path: String) -> String { path == gitStub ? developerGit ?? path : path }

    /// The Git `xcrun` picks: in `DEVELOPER_DIR`, else in the `xcode-select` choice, else in the Command Line Tools;
    /// nil when that folder has none (the stub then stays, and offers to install the tools).
    static func selectedDeveloperGit(environment: [String: String], selection: String?) -> String? {
        let chosen = [environment["DEVELOPER_DIR"], selection].compactMap { $0 }.first { $0.hasPrefix("/") }
        let developer = chosen ?? "/Library/Developer/CommandLineTools"
        let git = URL(fileURLWithPath: developer).appendingPathComponent("usr/bin/git").standardizedFileURL.path
        return git != gitStub && access(git, X_OK) == 0 ? git : nil
    }

    /// An absolute path, or the first executable match in `searchPaths` for a bare name; never a relative path.
    static func resolve(_ executable: String, searchPaths: [String]) throws -> String {
        let candidate: String?
        if executable.hasPrefix("/") {
            candidate = executable
        } else if executable.contains("/") {
            candidate = nil
        } else {
            candidate = searchPaths.map { $0 + "/" + executable }.first { access($0, X_OK) == 0 }
        }
        guard let candidate, access(candidate, X_OK) == 0 else { throw CommandError.executableNotFound(executable) }
        return direct(candidate)
    }
}
