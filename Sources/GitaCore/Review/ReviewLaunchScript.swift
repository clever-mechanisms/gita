import Foundation

/// The script a terminal runs for a review: into the checkout, the login PATH, then the agent in place of the shell.
public enum ReviewLaunchScript {
    public static func make(
        agent: ReviewAgent, executable: URL, directory: URL, prompt: String, path: [String]
    ) -> String {
        var lines = ["#!/bin/sh", "rm -f -- \"$0\"", "cd -- \(quote(directory.path)) || exit 1"]
        if !path.isEmpty { lines.append("export PATH=\(quote(path.joined(separator: ":")))") }
        for (key, value) in agent.environment.sorted(by: { $0.key < $1.key }) {
            lines.append("export \(key)=\(quote(value))")
        }
        lines.append("clear")
        lines.append("exec " + ([executable.path] + agent.arguments(prompt: prompt)).map(quote).joined(separator: " "))
        return lines.joined(separator: "\n") + "\n"
    }

    /// POSIX single quotes; a `'` inside becomes `'"'"'`.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
