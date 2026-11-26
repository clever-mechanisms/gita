import Foundation
import GitaCore

struct StackTreeRow: Equatable, Sendable {
    let stackID: String
    let title: String
    let depth: Int
    let isCurrent: Bool
    let needsRestack: Bool
    let counts: String
    let summary: String
    var connectorSymbol: String? { depth == 0 ? nil : "arrow.turn.down.right" }
}

struct BranchStackPresenter {
    private(set) var state = StackRestackState.idle
    private(set) var stacks: [BranchStack] = []
    var selectedStackID: String?
    var selected: BranchStack? { stacks.first { $0.id == selectedStackID } }
    var isRestacking: Bool {
        if case .restacking = state { return true }
        return false
    }
    var isBusy: Bool {
        switch state {
        case .loading, .previewing, .restacking: true
        default: false
        }
    }
    var hasError: Bool {
        switch state {
        case .failed, .stopped: true
        default: false
        }
    }
    var canRestack: Bool {
        if case .stopped = state { return false }
        return !isBusy && selected != nil
    }
    var status: String {
        switch state {
        case .idle, .loaded: ""
        case .loading: String(localized: "Reading branch history…")
        case .previewing: String(localized: "Review the proposed restack.")
        case .restacking: String(localized: "Restacking branches…")
        case .stopped(_, let message): String(localized: "Rebase stopped. \(message)")
        case .completed(let result):
            String(localized: "Branches updated by restack: \(result.updatedBranches.count)")
        case .failed(let message): message
        }
    }

    mutating func startLoading() -> UUID {
        let id = UUID()
        state = .loading(id: id)
        return id
    }
    mutating func loaded(_ values: [BranchStack], id: UUID) {
        guard state == .loading(id: id) else { return }
        replaceStacks(values)
        state = .loaded(values)
    }
    private mutating func replaceStacks(_ values: [BranchStack]) {
        stacks = values
        if !values.contains(where: { $0.id == selectedStackID }) { selectedStackID = values.first?.id }
    }
    mutating func preview(_ value: BranchStackRestackPreview) { state = .previewing(value) }
    mutating func cancelPreview() { state = .loaded(stacks) }
    mutating func startRestack(_ stack: BranchStack) { state = .restacking(stackID: stack.id) }
    mutating func finish(_ result: BranchStackRestackResult, stacks: [BranchStack]) {
        replaceStacks(stacks)
        switch result.outcome {
        case .completed: state = .completed(result)
        case .stopped(let operation, let message): state = .stopped(operation, message)
        }
    }
    mutating func fail(_ message: String) { state = .failed(message) }

    func rows() -> [StackTreeRow] {
        stacks.flatMap { stack in
            let header = StackTreeRow(
                stackID: stack.id, title: stack.baseBranch, depth: 0, isCurrent: stack.isBaseCurrent,
                needsRestack: stack.needsRestack, counts: String(localized: "\(stack.totalCommits) commits"),
                summary: String(localized: "Stack ending at \(stack.topBranch)"))
            return [header]
                + stack.layers.map { layer in
                    StackTreeRow(
                        stackID: stack.id, title: layer.branchName, depth: layer.depth, isCurrent: layer.isCurrent,
                        needsRestack: false, counts: String(localized: "↑\(layer.aheadOfBase) ↓\(layer.behindBase)"),
                        summary: String(
                            localized: "\(layer.commitsFromParent) commits · \(layer.commitSubjects.first ?? "")"))
                }
        }
    }

    static func reviewText(_ value: BranchStackRestackPreview) -> String {
        var sections = [String(localized: "Rebase \(value.stack.topBranch) onto \(value.ontoRef).")]
        if let current = value.currentBranch, current != value.stack.topBranch {
            sections.append(
                String(
                    localized:
                        "Checkout will switch from \(current) to \(value.stack.topBranch) during rebase and return afterward."
                ))
        } else if value.currentBranch == nil {
            sections.append(
                String(localized: "Checkout will switch to \(value.stack.topBranch) during rebase."))
        }
        let refs = String(localized: "Branches affected by --update-refs")
        sections.append(([refs] + value.branchesToUpdate).joined(separator: "\n"))
        if !value.forkedSiblingBranches.isEmpty {
            let warning = String(localized: "Forked sibling branches will not move with --update-refs")
            sections.append(([warning] + value.forkedSiblingBranches).joined(separator: "\n"))
        }
        let commits = String(localized: "Commits to replay: \(value.commitsToReplay.count)")
        sections.append(
            ([commits] + value.commitsToReplay.map { "\($0.id.prefix(8))  \($0.subject)" }).joined(separator: "\n"))
        if !value.blockedByWorktreePaths.isEmpty {
            let blocked = String(localized: "Switch branches in these worktrees before restacking.")
            sections.append(([blocked] + value.blockedByWorktreePaths).joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }
}
