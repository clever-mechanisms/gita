import Foundation

extension GitService {
    public func detectBranchStacks(
        baseBranch: String? = nil, includeSingleLayerBranches: Bool = false
    ) async throws
        -> [BranchStack]
    {
        let inventory = try await workflowBranches()
        guard !inventory.refs.isEmpty else { return [] }
        guard let base = try await stackBase(baseBranch, inventory: inventory) else {
            throw BranchStackError.noBaseBranch
        }
        let unmergedNames = try await unmergedBranchNames(relativeTo: base.fullName)
        let candidates = inventory.refs.filter { unmergedNames.contains($0.fullName) }
        guard !candidates.isEmpty else { return [] }
        let tips = Set(candidates.map(\.commit) + [base.commit]).sorted()
        guard tips.count > 1 else { return [] }
        let commits = try await stackGraph(tips, base: base.commit)
        let topology = BranchStackTopologyInput(branches: candidates, base: base, commits: commits)
        try Task.checkCancellation()
        let work = Task.detached(priority: .userInitiated) {
            BranchStackDetector.detect(topology, includeSingleLayerBranches: includeSingleLayerBranches)
        }
        let stacks = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        try Task.checkCancellation()
        return stacks
    }

    private func unmergedBranchNames(relativeTo baseFullName: String) async throws -> Set<String> {
        let result = try await execute([
            "for-each-ref", "--no-merged=" + baseFullName, "--format=%(refname)", "refs/heads/",
        ])
        return Set(GitOutput.lines(result.text))
    }

    private func stackBase(_ name: String?, inventory: WorkflowBranches) async throws -> GitReference? {
        guard let name else { return inventory.defaultReference }
        if let local = inventory.refs.first(where: { $0.name == name || $0.fullName == name }) { return local }
        try GitInput.validateReference(name)
        let fullName = name.hasPrefix("refs/") ? name : "refs/remotes/" + name
        guard fullName.hasPrefix("refs/remotes/") else { return nil }
        return try await workflowReference(fullName)
    }

    /// Exclude history shared by every candidate tip. Its boundary represents the shared prefix for set differences.
    private func stackGraph(_ tips: [String], base: String) async throws -> [GitCommit] {
        let boundary = try await sharedStackBoundary(tips)
        let revisions = (tips.count <= 512 ? tips : ["--branches", base]) + (boundary.map { ["^" + $0] } ?? [])
        let records = try await execute(GitArguments.logRecord + revisions + ["--"], outputLimit: 32 * 1_024 * 1_024)
        var commits = GitParsers.commits(records.stdout)
        let included = Set(commits.map(\.id))
        guard tips.allSatisfy({ $0 == boundary || included.contains($0) }) else { throw GitError.staleReference }
        if let boundary {
            for index in commits.indices {
                commits[index].parents = commits[index].parents.map { included.contains($0) ? $0 : boundary }
            }
        }
        return commits
    }

    private func sharedStackBoundary(_ tips: [String]) async throws -> String? {
        var common: String?
        for start in stride(from: 0, to: tips.count, by: 512) {
            let batch = tips[start..<min(start + 512, tips.count)]
            let revisions = (common.map { [$0] } ?? []) + batch
            let result = try await execute(["merge-base", "--octopus"] + revisions, allowFailure: true)
            if result.exitCode == 1 { return nil }
            guard result.exitCode == 0 else { throw Self.failure(result) }
            common = GitOutput.withoutTerminalLF(result.text)
        }
        return common
    }

    public func previewStackRestack(
        stack: BranchStack, onto ontoRef: String? = nil
    ) async throws
        -> BranchStackRestackPreview
    {
        try await stackPreview(stack, onto: ontoRef, inventory: workflowBranches())
    }

    private func stackPreview(
        _ stack: BranchStack, onto: String?, inventory: WorkflowBranches
    ) async throws
        -> BranchStackRestackPreview
    {
        guard let top = stack.layers.last else { throw BranchStackError.emptyStack }
        let tips = Dictionary(uniqueKeysWithValues: inventory.refs.map { ($0.name, $0.commit) })
        guard try await resolveCommit(stack.baseFullName, verify: true) == stack.baseCommitID,
            stack.layers.allSatisfy({ tips[$0.branchName] == $0.commitID })
        else { throw GitError.staleReference }
        let target = onto ?? stack.baseBranch
        let targetRef =
            target == stack.baseBranch ? stack.baseFullName : (tips[target] == nil ? target : "refs/heads/" + target)
        let oid = try await resolveCommit(targetRef, verify: true)
        let log = try await execute(GitArguments.logRecord + [oid + ".." + top.commitID, "--"])
        let commits = GitParsers.commits(log.stdout)
        let replayIDs = Set(commits.map(\.id))
        let affected = inventory.refs.filter { replayIDs.contains($0.commit) || $0.name == top.branchName }
        let names = Set(affected.map(\.name))
        let siblings = try await forkedSiblings(
            stack: stack, ontoOID: oid, inventory: inventory, updated: names, replayIDs: replayIDs)
        let stackNames = Set(stack.layers.map(\.branchName))
        let blocked = inventory.worktrees.filter { tree in
            guard let branch = tree.branch else { return false }
            return (stackNames.contains(branch) || names.contains(branch)) && !inventory.isCurrentCheckout(tree.path)
        }
        let impact = BranchStackRestackPreview.Impact(
            commitsToReplay: commits, branchesToUpdate: affected.map(\.name).sorted(),
            forkedSiblingBranches: siblings, blockedByWorktreePaths: blocked.map(\.path).sorted())
        return BranchStackRestackPreview(
            stack: stack, ontoRef: target, ontoCommitID: oid, currentBranch: inventory.currentBranch, impact: impact)
    }

    private func forkedSiblings(
        stack: BranchStack, ontoOID: String, inventory: WorkflowBranches, updated: Set<String>, replayIDs: Set<String>
    ) async throws -> [String] {
        guard let topCommit = stack.layers.last?.commitID, !replayIDs.isEmpty else { return [] }
        let unmerged = try await unmergedBranchNames(relativeTo: ontoOID)
        var siblings: [String] = []
        for ref in inventory.refs where !updated.contains(ref.name) && ref.fullName != stack.baseFullName {
            guard unmerged.contains(ref.fullName) else { continue }
            let mergeBase = try await execute(["merge-base", ref.commit, topCommit], allowFailure: true)
            if mergeBase.exitCode == 0, replayIDs.contains(GitOutput.withoutTerminalLF(mergeBase.text)) {
                siblings.append(ref.name)
            }
        }
        return siblings.sorted()
    }

    /// Binds the mutation to the destination, commits and complete set of local refs shown in the review sheet.
    public func restackBranchStack(_ reviewed: BranchStackRestackPreview) async throws -> BranchStackRestackResult {
        try await mutate { service in
            try await service.requireCleanOperationStart()
            try await service.requireUpdateRefs()
            let before = try await service.workflowBranches()
            let preview = try await service.stackPreview(reviewed.stack, onto: reviewed.ontoRef, inventory: before)
            if let path = preview.blockedByWorktreePaths.first {
                throw BranchStackError.branchCheckedOutInOtherWorktree(path)
            }
            guard reviewed == preview else { throw GitError.staleReference }
            let originalHead = try await service.headCommit()
            let switched = try await service.switchToTopIfNeeded(
                reviewed.stack.topBranch, current: before.currentBranch)
            let outcome: GitOperationOutcome
            do {
                outcome = try await service.rebaseUpdatingRefs(onto: preview.ontoCommitID)
            } catch {
                if switched, (try? await service.operationState()) == nil {
                    await service.restoreCheckout(branch: before.currentBranch, detachedHead: originalHead)
                }
                throw error
            }
            var updated: [String] = []
            if case .completed = outcome {
                if switched { await service.restoreCheckout(branch: before.currentBranch, detachedHead: originalHead) }
                let after = try await service.workflowBranches()
                let previous = Dictionary(uniqueKeysWithValues: before.refs.map { ($0.name, $0.commit) })
                let names = Set(preview.branchesToUpdate)
                updated = after.refs.filter { names.contains($0.name) && $0.commit != previous[$0.name] }.map(\.name)
            }
            return BranchStackRestackResult(outcome: outcome, updatedBranches: updated)
        }
    }

    private func switchToTopIfNeeded(_ topBranch: String, current: String?) async throws -> Bool {
        guard current != topBranch else { return false }
        _ = try await execute(["switch", "--", topBranch], mutation: true)
        return true
    }

    private func restoreCheckout(branch: String?, detachedHead: String?) async {
        if let branch {
            _ = try? await execute(["switch", "--", branch], mutation: true)
        } else if let detachedHead {
            _ = try? await execute(["switch", "--detach", "--", detachedHead], mutation: true)
        }
    }

    private func requireUpdateRefs() async throws {
        let help = try await execute(["rebase", "-h"], allowFailure: true)
        guard String(decoding: help.stdout + help.stderr, as: UTF8.self).contains("update-refs") else {
            throw BranchStackError.updateRefsUnsupported
        }
    }

    private func rebaseUpdatingRefs(onto oid: String) async throws -> GitOperationOutcome {
        let settings = GitArguments.operationOverrides.map {
            $0 == "rebase.updateRefs=false" ? "rebase.updateRefs=true" : $0
        }
        let args = [
            "rebase", "--merge", "--no-autostash", "--no-autosquash", "--update-refs", "--no-fork-point",
            "--no-rebase-merges", oid,
        ]
        let result = try await execute(
            GitArguments.configOptions(settings) + args, timeout: .untilIdle, allowFailure: true, mutation: true)
        if let state = try await operationState() { return .stopped(state, Self.failure(result).localizedDescription) }
        guard result.exitCode == 0 else { throw Self.failure(result) }
        return .completed
    }
}
