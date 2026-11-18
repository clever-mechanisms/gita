import Foundation

/// One deployment's metadata and its project. `inspect --json` enriches the metadata with every build resource,
/// which can exceed several MiB, so the deployment endpoint is read directly.
extension VercelProvider {
    func deploymentDetails(
        root: URL, target: ProviderTarget, reference: String, projectName: String, scope: String?
    ) async -> ProviderDetailReport {
        guard let link = await links.resolve(root) else {
            return ProviderDetailReport(target: target, failure: .notLinked)
        }
        let endpoint = "/v13/deployments/\(reference)?withGitRepoInfo=true"
        let response = await executor.execute(.vercel, VercelCommands.get(endpoint, scope: scope), in: link.root)
            .flatMap { data in
                Result {
                    try VercelDeploymentParser.detail(
                        data, reference: reference, projectName: projectName, scope: scope)
                }
                .mapError { _ in ProviderFailure.unverified(.vercel) }
            }
        switch response {
        case .failure(let failure): return ProviderDetailReport(target: target, failure: failure)
        case .success(let detail):
            guard let projectID = detail.projectID else {
                return ProviderDetailReport(
                    target: target, content: .deployment(detail), status: .partial,
                    diagnostic: String(
                        localized:
                            "Vercel did not provide a verified project identity. Project details are unavailable."))
            }
            return await withProject(detail, projectID: projectID, root: link.root, target: target, scope: scope)
        }
    }

    /// The deployment stays available when its project cannot be read, except after cancellation.
    private func withProject(
        _ detail: DeploymentDetail, projectID: String, root: URL, target: ProviderTarget, scope: String?
    ) async -> ProviderDetailReport {
        var detail = detail
        let arguments =
            ["project", "inspect", projectID, "--json"] + VercelIdentifiers.scopeArguments(scope) + [
                "--non-interactive"
            ]
        switch await executor.execute(.vercel, arguments, in: root) {
        case .failure(let failure) where failure.status == .cancelled:
            return ProviderDetailReport(target: target, failure: failure)
        case .failure(let failure):
            return ProviderDetailReport(
                target: target, content: .deployment(detail), status: .partial,
                diagnostic: String(localized: "Project details are unavailable. \(failure.diagnostic)"))
        case .success(let data):
            guard let project = try? VercelDeploymentParser.project(data, projectID: projectID, scope: scope) else {
                return ProviderDetailReport(
                    target: target, content: .deployment(detail), status: .partial,
                    diagnostic: String(localized: "Vercel returned project details that could not be verified."))
            }
            detail.project = project
            return ProviderDetailReport(target: target, content: .deployment(detail), status: .connected)
        }
    }
}
