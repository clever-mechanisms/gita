import Foundation

public enum TeleportParser {
    public static func parse(_ raw: String) -> ParsedTeleportInput? { parse(raw, depth: 0) }

    public static func parse(url: URL) -> ParsedTeleportInput? { parse(url.absoluteString) }

    private static func parse(_ raw: String, depth: Int) -> ParsedTeleportInput? {
        guard raw.utf8.count <= 8192, depth <= 4 else { return nil }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<"), value.hasSuffix(">") { value = String(value.dropFirst().dropLast()) }
        guard safe(value), !value.contains(where: \.isWhitespace) else { return nil }
        if value.contains("://") {
            guard let url = URL(string: value, encodingInvalidCharacters: false),
                let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
                parts.user == nil, parts.password == nil, parts.port == nil,
                let decoded = value.removingPercentEncoding, !GitInput.containsControlCharacters(decoded)
            else { return nil }
            if parts.scheme?.lowercased() == "gita" { return deepLink(parts, raw: raw, depth: depth) }
            guard parts.scheme?.lowercased() == "https", let query = hosted(parts, url: url) else { return nil }
            return .init(query: query, rawInput: raw)
        }
        if let sha = sha(value) {
            return .init(query: .commit(owner: nil, repo: nil, sha: sha, sourceURL: nil), rawInput: raw)
        }
        return branch(value).map { .init(query: .branch(owner: nil, repo: nil, name: $0), rawInput: raw) }
    }

    static func sha(_ value: String) -> String? {
        guard (7...40).contains(value.utf8.count),
            value.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            })
        else { return nil }
        return value.lowercased()
    }

    private static func safe(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && !GitInput.containsControlCharacters(value)
    }

    static func branch(_ ref: String) -> String? {
        let name = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref
        guard safe(name), name.utf8.count <= 1024, name != "@", name != "HEAD", !name.hasSuffix("."),
            !name.contains(".."), !name.contains("@{"), !name.contains(where: { ";|&$`".contains($0) }),
            !name.contains(where: { $0.isWhitespace || "~^:?*[\\<>".contains($0) }),
            name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                !$0.isEmpty && !$0.hasPrefix(".") && !$0.hasSuffix(".lock")
            })
        else { return nil }
        return name
    }

    private static func hosted(_ url: URLComponents, url source: URL) -> TeleportQuery? {
        guard let host = url.host?.lowercased() else { return nil }
        if host.hasSuffix(".vercel.app"), VercelIdentifiers.deploymentReference(host) == host {
            let project = previewProject(host)
            return .deployment(teamSlug: nil, projectName: project, deploymentRef: host, sourceURL: source)
        }
        let path = url.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        var segments = path.dropFirst()
        if segments.last?.isEmpty == true { segments = segments.dropLast() }
        let p = segments.compactMap { $0.removingPercentEncoding }
        guard p.count == segments.count, p.allSatisfy(ProviderValidation.isSlug) else { return nil }
        if host == "vercel.com", p.count == 3 {
            return .deployment(teamSlug: p[0], projectName: p[1], deploymentRef: p[2], sourceURL: source)
        }
        guard host == "github.com", p.count >= 4,
            let repo = GitHubRepository(nameWithOwner: p[0] + "/" + p[1])
        else { return nil }
        return github(Array(p.dropFirst(2)), repo: repo, url: source)
    }

    private static func previewProject(_ host: String) -> String {
        let label = String(host.dropLast(".vercel.app".count))
        let parts = label.components(separatedBy: "-")
        if let branchMarker = label.range(of: "-git-") { return String(label[..<branchMarker.lowerBound]) }
        let hash = parts.indices.dropFirst().dropLast().first { index in
            let token = parts[index]
            return (6...12).contains(token.count) && (token.count == 9 || token.contains(where: \.isNumber))
                && token.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) }
        }
        if let hash { return parts[..<hash].joined(separator: "-") }
        return label
    }

    private static func github(_ path: [String], repo: GitHubRepository, url: URL) -> TeleportQuery? {
        switch path[0] {
        case "pull":
            guard let number = positive(path[1]).flatMap(Int.init(exactly:)) else { return nil }
            if path.count == 4, path[2] == "commits", let id = sha(path[3]) {
                return .commit(owner: repo.owner, repo: repo.name, sha: id, sourceURL: url)
            }
            guard path.count == 2 || (path.count == 3 && ["files", "commits", "checks"].contains(path[2])) else {
                return nil
            }
            return .pullRequest(owner: repo.owner, repo: repo.name, number: number, sourceURL: url)
        case "commit" where path.count == 2:
            return sha(path[1]).map { .commit(owner: repo.owner, repo: repo.name, sha: $0, sourceURL: url) }
        case "actions" where path.count >= 3 && path[1] == "runs":
            guard let run = positive(path[2]) else { return nil }
            var job: Int64?
            if path.count != 3 {
                guard path.count == 5, ["attempts", "job"].contains(path[3]), let id = positive(path[4]) else {
                    return nil
                }
                if path[3] == "job" { job = id }
            }
            return .workflowRun(owner: repo.owner, repo: repo.name, runID: run, jobID: job, sourceURL: url)
        default: return nil
        }
    }

    private static func positive(_ text: String) -> Int64? {
        guard text.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int64(text), n > 0 else { return nil }
        return n
    }

    private static func deepLink(_ url: URLComponents, raw: String, depth: Int) -> ParsedTeleportInput? {
        guard url.host == "open", ["", "/"].contains(url.path), url.fragment == nil else { return nil }
        var fields: [String: String] = [:]
        let aliases = ["pull": "pr", "sha": "commit", "ref": "branch"]
        for item in url.queryItems ?? [] {
            let key = aliases[item.name] ?? item.name
            guard let value = item.value, safe(value), fields.updateValue(value, forKey: key) == nil else { return nil }
        }
        let workspace = fields.removeValue(forKey: "workspace")
        let hint = fields.removeValue(forKey: "repo")
        guard
            [workspace, hint].compactMap({ $0 }).allSatisfy({ value in
                value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                    && !value.contains(where: { ";|&$`".contains($0) })
            })
        else { return nil }
        let job = fields.removeValue(forKey: "job")
        guard fields.count == 1, let (key, value) = fields.first, job == nil || key == "run" else { return nil }
        if key == "url" {
            guard let inner = parse(value, depth: depth + 1),
                workspace == nil || inner.workspaceHint == nil || workspace == inner.workspaceHint,
                hint == nil || inner.repoHint == nil || hint == inner.repoHint
            else { return nil }
            return .init(
                query: inner.query, workspaceHint: workspace ?? inner.workspaceHint, repoHint: hint ?? inner.repoHint,
                rawInput: raw)
        }
        guard
            let query = deepLinkQuery(
                key, value: value, job: job, repo: hint.flatMap(GitHubRepository.init(nameWithOwner:)))
        else { return nil }
        return .init(query: query, workspaceHint: workspace, repoHint: hint, rawInput: raw)
    }

    private static func deepLinkQuery(
        _ key: String, value: String, job: String?, repo: GitHubRepository?
    ) -> TeleportQuery? {
        switch key {
        case "pr":
            guard let n = positive(value).flatMap(Int.init(exactly:)) else { return nil }
            guard let repo else { return .deepLink(inner: .pullRequest(number: n)) }
            return .pullRequest(owner: repo.owner, repo: repo.name, number: n, sourceURL: nil)
        case "run":
            guard let n = positive(value), job == nil || job.flatMap(positive) != nil else { return nil }
            guard let repo else { return .deepLink(inner: .workflowRun(runID: n, jobID: job.flatMap(positive))) }
            return .workflowRun(
                owner: repo.owner, repo: repo.name, runID: n, jobID: job.flatMap(positive), sourceURL: nil)
        case "commit":
            guard let id = sha(value) else { return nil }
            return .commit(owner: repo?.owner, repo: repo?.name, sha: id, sourceURL: nil)
        case "branch":
            guard let name = branch(value) else { return nil }
            return .branch(owner: repo?.owner, repo: repo?.name, name: name)
        case "deployment":
            guard
                let ref = VercelIdentifiers.deploymentReference(value)
                    ?? (ProviderValidation.isSlug(value) ? value : nil)
            else { return nil }
            return .deployment(
                teamSlug: nil, projectName: ref.hasSuffix(".vercel.app") ? previewProject(ref) : nil,
                deploymentRef: ref, sourceURL: nil)
        default: return nil
        }
    }
}
