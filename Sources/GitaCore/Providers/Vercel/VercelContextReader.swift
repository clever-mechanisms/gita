import Foundation

/// Production, branch preview and comment context, read only when the deployment list changed.
/// Each Vercel CLI call costs about 0.3 s of CPU.
struct VercelContextReader: Sendable {
    let executor: ProviderCommandExecutor
    let clock: @Sendable () -> Date

    func read(link: VercelLink, items: [ProviderItem]) async -> VercelContext? {
        guard let project = link.parts?.project else { return nil }
        let team = link.teamID
        let projectArguments = VercelCommands.get(VercelCommands.path("/v9/projects/\(project)", teamID: team))
        let aliasArguments = VercelCommands.get(
            VercelCommands.path("/v4/aliases", ["projectId=\(project)", "limit=100"], teamID: team))
        let commentArguments = [
            "comments", "list", "--all-branches", "--status", "unresolved", "--json", "--limit", "100",
            "--non-interactive",
        ]
        async let projectData = executor.execute(.vercel, projectArguments, in: link.root)
        async let aliasData = executor.execute(.vercel, aliasArguments, in: link.root)
        async let commentData = executor.execute(.vercel, commentArguments, in: link.root)
        let (projectResult, aliasResult, commentResult) = await (projectData, aliasData, commentData)
        guard !Task.isCancelled else { return nil }
        let builder = VercelContextBuilder(
            project: try? VercelContextParser.project(projectResult.get(), projectID: project),
            aliases: (try? VercelContextParser.aliases(aliasResult.get())) ?? [],
            comments: try? VercelContextParser.comments(commentResult.get(), projectID: project), items: items,
            readAt: clock())
        var context = builder.context()
        if let detail = await liveDetail(context, builder: builder, link: link) {
            context = builder.context(liveDetail: detail)
        }
        // The link must still identify the same project after the reads.
        guard VercelLinkReader.sourceID(at: link.root) == link.sourceID else { return nil }
        return context
    }

    /// Production is pinned to a deployment outside the listed 30 and the alias list gave no host: one metadata
    /// read for its commit.
    private func liveDetail(
        _ context: VercelContext, builder: VercelContextBuilder, link: VercelLink
    ) async -> DeploymentDetail? {
        guard let production = context.production, production.commit == nil,
            production.deploymentID != builder.project?.target?.id
        else { return nil }
        let path = VercelCommands.path(
            "/v13/deployments/\(production.deploymentID)", ["withGitRepoInfo=true"], teamID: link.teamID)
        guard case .success(let data) = await executor.execute(.vercel, VercelCommands.get(path), in: link.root),
            let name = try? JSONDecoder().decode(NameOnly.self, from: data).name
        else { return nil }
        return try? VercelDeploymentParser.detail(
            data, reference: production.deploymentID, projectName: name, scope: nil)
    }

    private struct NameOnly: Decodable { var name: String }
}
