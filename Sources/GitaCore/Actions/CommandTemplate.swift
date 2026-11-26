import Foundation

/// Match names in the template itself. Inserted values are never scanned.
enum CommandTemplate {
    static let actionPlaceholders = ["$SHA", "$BRANCH", "$FILE", "$WORKTREE", "$REPO_ROOT", "$REMOTE_URL"]
    static let toolPlaceholders = ["$LEFT", "$RIGHT", "$BASE", "$MERGED"]

    private static let shells: Set<String> = [
        "sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish", "ash", "mksh", "rbash", "rzsh", "posh", "pwsh",
        "busybox", "script",
    ]
    private static let wrappers: Set<String> = [
        "env", "arch", "nice", "nohup", "time", "caffeinate", "timeout", "xargs", "stdbuf", "command", "exec", "sudo",
        "doas",
    ]
    private static let inlineCodeLongFlags = ["--eval", "--command", "--exec"]

    static func expand(_ token: String, value: (String) throws -> String?) rethrows -> String {
        var result = ""
        var rest = token[...]
        while let dollar = rest.firstIndex(of: "$") {
            result += rest[..<dollar]
            rest = rest[rest.index(after: dollar)...]
            let name = rest.prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
            let key = "$" + name
            result += try value(key) ?? key
            rest = rest.dropFirst(name.count)
        }
        return result + rest
    }

    static func referencedPlaceholders(in tokens: [String], known: [String]) -> [String] {
        var found: [String] = []
        let allowed = Set(known)
        for token in tokens {
            _ = expand(token) { key in
                if allowed.contains(key), !found.contains(key) { found.append(key) }
                return nil
            }
        }
        return found
    }

    static func validateTemplate(executable: String, arguments: [String], knownPlaceholders: [String]) throws {
        try validate(executable: executable, arguments: arguments)
        for (index, token) in arguments.enumerated() where isInlineCodeFlag(token) {
            let inspected = inlineCodeWindow(from: index, in: arguments)
            if !referencedPlaceholders(in: inspected, known: knownPlaceholders).isEmpty {
                throw CustomActionError.shellCommand
            }
        }
    }

    static func validate(executable: String, arguments: [String]) throws {
        guard !executable.trimmingCharacters(in: .whitespaces).isEmpty,
            !GitInput.containsControlCharacters(executable)
        else { throw CustomActionError.invalidExecutable }
        guard !arguments.contains(where: { $0.contains("\0") }) else { throw CustomActionError.invalidArgument }
        try rejectIfShell(executable)
        let names = candidateNames(for: executable)
        guard let wrapper = names.first(where: { wrappers.contains($0) }) else { return }
        try validateWrapper(wrapper, arguments: arguments)
    }

    private static func validateWrapper(_ wrapper: String, arguments: [String]) throws {
        if wrapper == "sudo" || wrapper == "doas" {
            for token in arguments {
                if token == "--" { break }
                if isSudoShellFlag(token) { throw CustomActionError.shellCommand }
            }
        }
        if wrapper == "env" {
            for token in arguments {
                if token == "--" { break }
                if isEnvSplitFlag(token) { throw CustomActionError.shellCommand }
            }
        }
        if wrapper == "xargs", arguments.allSatisfy({ $0.hasPrefix("-") }) {
            throw CustomActionError.shellCommand
        }
        // Defense in depth: once any wrapper is used, reject any subsequent argument that resolves to a shell.
        for token in arguments {
            try rejectIfShell(token)
        }
    }

    private static func isSudoShellFlag(_ token: String) -> Bool {
        if ["--shell", "--login"].contains(token) { return true }
        guard token.hasPrefix("-"), !token.hasPrefix("--"), token.count > 1 else { return false }
        let flags = token.dropFirst()
        return flags.allSatisfy(\.isLetter) && (flags.contains("s") || flags.contains("i"))
    }

    private static func isEnvSplitFlag(_ token: String) -> Bool {
        if token.hasPrefix("--split-string") { return true }
        guard token.hasPrefix("-"), !token.hasPrefix("--"), token.count > 1 else { return false }
        return token.dropFirst().contains("S")
    }

    private static func isInlineCodeFlag(_ token: String) -> Bool {
        if inlineCodeLongFlags.contains(token) { return true }
        if ["-c=", "-e=", "-E=", "--eval=", "--command=", "--exec="].contains(where: { token.hasPrefix($0) }) {
            return true
        }
        guard token.hasPrefix("-"), !token.hasPrefix("--"), token.count >= 2, token.count <= 4 else { return false }
        let letters = token.dropFirst()
        return letters.allSatisfy { $0.isASCII && $0.isLetter } && letters.last.map { "ceE".contains($0) } == true
    }

    private static func inlineCodeWindow(from index: Int, in arguments: [String]) -> [String] {
        var window = [arguments[index]]
        var cursor = index + 1
        var afterTerminator = false
        while cursor < arguments.count {
            let token = arguments[cursor]
            window.append(token)
            if !afterTerminator, token == "--" {
                afterTerminator = true
                cursor += 1
                continue
            }
            if afterTerminator || !token.hasPrefix("-") { break }
            cursor += 1
        }
        return window
    }

    private static func rejectIfShell(_ program: String) throws {
        if candidateNames(for: program).contains(where: { shells.contains($0) }) {
            throw CustomActionError.shellCommand
        }
    }

    private static func candidateNames(for program: String) -> [String] {
        var paths = [program]
        if program.contains("/") {
            paths.append(URL(fileURLWithPath: program).resolvingSymlinksInPath().path)
        }
        return paths.map { normalizeName(URL(fileURLWithPath: $0).lastPathComponent) }
    }

    private static func normalizeName(_ basename: String) -> String {
        let lower = basename.lowercased()
        let stripped = lower.replacingOccurrences(
            of: #"([-._]?[0-9]+(\.[0-9]+)*)$"#, with: "", options: .regularExpression)
        return stripped.isEmpty ? lower : stripped
    }
}
