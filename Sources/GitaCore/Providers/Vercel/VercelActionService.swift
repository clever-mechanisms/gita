import Foundation

/// User-started deployment changes. Never called by refreshes; every call follows an explicit confirmation in the
/// app. Uses the existing CLI session in the linked checkout.
public struct VercelActionService: Sendable {
    public enum Action: String, Sendable, CaseIterable { case promote, rollback, redeploy, cancel }

    /// Rolling release steps, each after an explicit confirmation in the app.
    public enum RolloutAction: String, Sendable, CaseIterable { case approve, complete, abort }

    public struct ActionResult: Sendable, Hashable {
        public var succeeded: Bool
        public var message: String
    }

    private let executor: ProviderCommandExecutor

    public init(runner: any CommandRunning = CommandRunner()) { executor = ProviderCommandExecutor(runner: runner) }

    // MARK: Deployments

    public static func isOffered(_ action: Action, for item: ProviderItem, context: VercelContext?) -> Bool {
        guard item.kind == .deployment, item.target != nil else { return false }
        let live = context?.isLive(item) == true
        let liveCreatedAt = context?.production?.createdAt
        // A production build older than the live one is a rollback; anything newer, or a preview, is a promote.
        let older =
            item.deployment?.environment == .production
            && item.date.flatMap { date in liveCreatedAt.map { date < $0 } } == true
        let ready = item.state == .success && !live
        switch action {
        case .promote: return ready && context?.production != nil && !older
        case .rollback: return ready && older
        case .redeploy: return item.state == .failure || item.state == .cancelled
        case .cancel: return item.state == .running || item.state == .pending
        }
    }

    public func perform(_ action: Action, item: ProviderItem, root: URL) async -> ActionResult {
        guard case .deployment(let reference, _, let scope)? = item.target,
            let reference = VercelIdentifiers.deploymentReference(reference), VercelIdentifiers.isScope(scope)
        else { return .failed(.invalidIdentity) }
        guard let link = await VercelLinkResolver(executor: executor).resolve(root) else { return .failed(.notLinked) }
        let scopeArguments = VercelIdentifiers.scopeArguments(scope)
        let arguments: [String]
        switch action {
        case .promote, .rollback:
            arguments = [action.rawValue, reference, "--timeout", "0", "--yes", "--non-interactive"] + scopeArguments
        case .redeploy: arguments = ["redeploy", reference, "--no-wait", "--non-interactive"] + scopeArguments
        case .cancel:
            switch await deploymentID(reference, scope: scope, root: link.root) {
            case .failure(let failure): return .failed(failure)
            case .success(let id):
                arguments =
                    ["api", "/v12/deployments/\(id)/cancel", "--method", "PATCH", "--raw", "--non-interactive"]
                    + scopeArguments
            }
        }
        return await run(arguments, in: link.root, success: Self.requested(action))
    }

    /// Cancelling needs the immutable id; a host is looked up and must come back as the same deployment.
    private func deploymentID(_ reference: String, scope: String?, root: URL) async -> Result<String, ProviderFailure> {
        if VercelIdentifiers.isDeploymentID(reference) { return .success(reference) }
        return await executor.execute(
            .vercel, VercelCommands.get("/v13/deployments/\(reference)", scope: scope), in: root
        )
        .flatMap { data in
            guard let raw = try? JSONDecoder().decode(IDOnly.self, from: data),
                VercelIdentifiers.isDeploymentID(raw.id),
                raw.url.flatMap(VercelIdentifiers.deploymentReference) == reference
            else { return .failure(.unverified(.vercel)) }
            return .success(raw.id)
        }
    }

    static func requested(_ action: Action) -> String {
        switch action {
        case .promote: String(localized: "Promotion requested. Production switches when Vercel finishes.")
        case .rollback: String(localized: "Rollback requested. Production switches when Vercel finishes.")
        case .redeploy: String(localized: "Redeploy started.")
        case .cancel: String(localized: "Deployment cancelled.")
        }
    }

    // MARK: Rolling releases

    /// Steps on an active rollout as last read. Approve stays offered while paused: a manual-approval release pauses
    /// at the stage that waits for it. A rollout kept from before a failed read offers nothing, since its stage index
    /// or its very state may be out of date.
    public static func isOffered(_ action: RolloutAction, rollout: VercelSignals.Rollout?) -> Bool {
        guard let rollout, rollout.isActive, rollout.freshness == .current else { return false }
        switch action {
        case .approve: return rollout.nextStageNeedsApproval && rollout.stageIndex != nil
        case .complete, .abort: return true
        }
    }

    public func perform(
        _ action: RolloutAction, rollout: VercelSignals.Rollout, root: URL, scope: String?
    ) async -> ActionResult {
        guard Self.isOffered(action, rollout: rollout),
            let id = VercelIdentifiers.deploymentID(rollout.canaryDeploymentID),
            VercelIdentifiers.isScope(scope)
        else { return .failed(.invalidIdentity) }
        guard let link = await VercelLinkResolver(executor: executor).resolve(root) else { return .failed(.notLinked) }
        var arguments = ["rolling-release", action.rawValue]
        if action == .approve, let index = rollout.stageIndex { arguments.append("--currentStageIndex=\(index)") }
        arguments += ["--deployment=\(id)", "--non-interactive"] + VercelIdentifiers.scopeArguments(scope)
        return await run(arguments, in: link.root, success: Self.completed(action))
    }

    static func completed(_ action: RolloutAction) -> String {
        switch action {
        case .approve: String(localized: "Next stage approved. Traffic shifts when Vercel finishes.")
        case .complete: String(localized: "Rollout completed. The new deployment serves all traffic.")
        case .abort: String(localized: "Rollout aborted. Production stays on the previous deployment.")
        }
    }

    // MARK: Running

    private func run(_ arguments: [String], in root: URL, success: String) async -> ActionResult {
        switch await executor.run(.vercel, arguments, in: root, limits: .action) {
        case .success(let result) where result.exitCode == 0: ActionResult(succeeded: true, message: success)
        case .success(let result): .failed(ProviderCommandExecutor.commandFailure(result, tool: .vercel))
        case .failure(let failure) where failure.status == .cancelled: .failed(failure)
        case .failure: .failed(.incomplete(.vercel))
        }
    }

    private struct IDOnly: Decodable {
        var id: String
        var url: String?
    }
}

extension VercelActionService.ActionResult {
    static func failed(_ failure: ProviderFailure) -> Self { Self(succeeded: false, message: failure.diagnostic) }
}
