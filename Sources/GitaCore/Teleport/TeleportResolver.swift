import Foundation

public struct TeleportResolver: Sendable {
    private let runner: any CommandRunning

    public init(runner: any CommandRunning = CommandRunner()) { self.runner = runner }

    public func resolve(
        _ parsed: ParsedTeleportInput, in repositories: [TeleportRepositoryEntry]
    ) async throws -> TeleportResolution {
        try Task.checkCancellation()
        let candidates = repositories.filter { entry in
            parsed.workspaceHint.map { $0 == entry.workspaceID || $0 == entry.workspaceTitle } ?? true
        }
        let matches = try await withThrowingTaskGroup(of: TeleportDestination?.self) { group in
            var pending = candidates.makeIterator()
            func enqueue(_ entry: TeleportRepositoryEntry) {
                group.addTask { try await destination(parsed, entry: entry) }
            }
            for _ in 0..<8 { if let entry = pending.next() { enqueue(entry) } }
            var results: Set<TeleportDestination> = []
            for try await result in group {
                try Task.checkCancellation()
                if let result { results.insert(result) }
                if let entry = pending.next() { enqueue(entry) }
            }
            return results
        }
        try Task.checkCancellation()
        if matches.count == 1, let first = matches.first { return .resolved(first) }
        guard !matches.isEmpty else { return .notFound(parsed) }
        let preferred = repositories.first?.workspaceID
        return .ambiguous(
            matches.sorted { lhs, rhs in
                (lhs.workspaceID == preferred ? 0 : 1, lhs.repoDisplayName, lhs.workspaceID, lhs.repoPath.path)
                    < (rhs.workspaceID == preferred ? 0 : 1, rhs.repoDisplayName, rhs.workspaceID, rhs.repoPath.path)
            })
    }

    private func destination(
        _ parsed: ParsedTeleportInput, entry: TeleportRepositoryEntry
    ) async throws -> TeleportDestination? {
        try Task.checkCancellation()
        let hosted = Self.githubTarget(parsed.query)
        guard await acceptsRepository(parsed.repoHint, hostedSlug: hosted?.0, entry: entry) else { return nil }
        let target: TeleportTarget
        let reason: TeleportDestination.MatchReason
        switch parsed.query {
        case .deepLink(let hint):
            guard let repository = await inferredRepository(entry) else { return nil }
            target = Self.target(hint, repository)
            reason = parsed.workspaceHint == nil && parsed.repoHint == nil ? .githubRemote : .workspaceHint
        case .deployment(let team, let project, let ref, let url):
            guard
                await matchesDeployment(
                    team, project: project, ref: ref, hint: parsed.repoHint ?? parsed.workspaceHint, entry: entry)
            else {
                return nil
            }
            target = .deployment(reference: ref, projectName: project ?? entry.vercelProjectName, url: url)
            reason = project == nil ? .workspaceHint : .vercelProject
        case .commit(nil, nil, let sha, let url):
            guard let sha = TeleportParser.sha(sha), let full = try await verify(sha + "^{commit}", entry) else {
                return nil
            }
            target = .commit(sha: full, url: url)
            reason = .localObject
        case .branch(nil, nil, let ref):
            guard let name = TeleportParser.branch(ref), try await hasBranch(name, entry) else { return nil }
            target = .branch(name: name)
            reason = .localBranch
        default:
            guard let (slug, hosted) = hosted, await matchesGitHub(slug, entry) else { return nil }
            target = hosted
            reason = .githubRemote
        }
        return .init(
            workspaceID: entry.workspaceID, workspaceTitle: entry.workspaceTitle, repoPath: entry.repoPath,
            repoDisplayName: entry.displayName, target: target, matchReason: reason)
    }

    private static func target(_ hint: TeleportTargetHint, _ repo: GitHubRepository) -> TeleportTarget {
        switch hint {
        case .pullRequest(let number): .pullRequest(number: number, owner: repo.owner, repo: repo.name, url: nil)
        case .workflowRun(let run, let job):
            .workflowRun(runID: run, jobID: job, owner: repo.owner, repo: repo.name, url: nil)
        }
    }

    private func hasBranch(_ name: String, _ entry: TeleportRepositoryEntry) async throws -> Bool {
        if try await verify("refs/heads/" + name, entry) != nil { return true }
        let remote = name.hasPrefix("origin/") ? name : "origin/" + name
        return try await verify("refs/remotes/" + remote, entry) != nil
    }

    private func acceptsRepository(_ hint: String?, hostedSlug: String?, entry: TeleportRepositoryEntry) async -> Bool {
        guard let hint, hint.lowercased() != hostedSlug?.lowercased() else { return true }
        let names = [
            entry.displayName, entry.repoPath.path, entry.repoPath.lastPathComponent, entry.vercelProjectName,
            entry.vercelProjectID,
        ]
        if names.contains(hint) { return true }
        guard GitHubRepository(nameWithOwner: hint) != nil else { return false }
        return await matchesGitHub(hint, entry)
    }

    private func inferredRepository(_ entry: TeleportRepositoryEntry) async -> GitHubRepository? {
        if let known = entry.githubSlug.flatMap(GitHubRepository.init(nameWithOwner:)) { return known }
        let resolver = GitHubRemoteResolver(runner: runner)
        var match: GitHubRepository?
        for url in entry.remoteURLs {
            if Task.isCancelled { return nil }
            guard let remote = await resolver.resolve(url) else { continue }
            if let match, match.sourceID != remote.sourceID { return nil }
            match = remote.repository
        }
        return match
    }

    private static func githubTarget(_ query: TeleportQuery) -> (String, TeleportTarget)? {
        switch query {
        case .pullRequest(let owner, let repo, let n, let url):
            (owner + "/" + repo, .pullRequest(number: n, owner: owner, repo: repo, url: url))
        case .workflowRun(let owner, let repo, let run, let job, let url):
            (owner + "/" + repo, .workflowRun(runID: run, jobID: job, owner: owner, repo: repo, url: url))
        case .commit(let owner?, let repo?, let sha, let url):
            (owner + "/" + repo, .commit(sha: sha, url: url))
        case .branch(let owner?, let repo?, let name):
            (owner + "/" + repo, .branch(name: name))
        default: nil
        }
    }

    private func matchesGitHub(_ slug: String, _ entry: TeleportRepositoryEntry) async -> Bool {
        let key = slug.lowercased()
        if entry.githubSlug?.lowercased() == key { return true }
        let remotes = entry.remoteURLs.compactMap(RemoteAddress.init)
        if remotes.contains(where: { GitHubRemote(address: $0)?.repository.nameWithOwner.lowercased() == key }) {
            return true
        }
        let resolver = GitHubRemoteResolver(runner: runner)
        for remote in entry.remoteURLs where RemoteAddress(remote)?.mayBeGitHubAlias == true {
            if Task.isCancelled { return false }
            if await resolver.resolve(remote)?.repository.nameWithOwner.lowercased() == key { return true }
        }
        return false
    }

    private func matchesDeployment(
        _ team: String?, project: String?, ref: String, hint: String?,
        entry: TeleportRepositoryEntry
    ) async -> Bool {
        if let team, let known = entry.vercelTeamSlug, team.lowercased() != known.lowercased() { return false }
        let name = entry.vercelProjectName?.lowercased()
        if let project, [name, entry.vercelProjectID?.lowercased()].contains(project.lowercased()) { return true }
        if let name, Self.matchesHost(name, ref: ref, project: project) {
            return true
        }
        if project == nil, hint != nil, entry.vercelProjectID != nil || name != nil { return true }
        guard let link = await VercelLinkResolver(executor: .init(runner: runner)).resolve(entry.repoPath) else {
            return false
        }
        if project == nil, hint != nil { return true }
        if let project, link.parts?.project == project { return true }
        return TeleportLinkedProject.name(link).map {
            $0 == project?.lowercased() || Self.matchesHost($0, ref: ref, project: project)
        } ?? false
    }

    private static func matchesHost(_ name: String, ref: String, project: String?) -> Bool {
        if ref == name + ".vercel.app" { return true }
        // A fully inferred project is authoritative. Only an unparsed alias needs prefix matching.
        guard let project, ref == project + ".vercel.app" else { return false }
        return ref.hasPrefix(name + "-")
    }

    private func verify(_ ref: String, _ entry: TeleportRepositoryEntry) async throws -> String? {
        try Task.checkCancellation()
        let result = try await runner.run(
            .git(
                ["--no-optional-locks", "rev-parse", "--verify", "--quiet", ref],
                directory: entry.repoPath, timeout: 5, outputLimit: 4096))
        try Task.checkCancellation()
        let sha = GitOutput.withoutTerminalLF(result.text)
        return result.exitCode == 0 && GitParsers.isObjectID(sha) ? sha.lowercased() : nil
    }
}
