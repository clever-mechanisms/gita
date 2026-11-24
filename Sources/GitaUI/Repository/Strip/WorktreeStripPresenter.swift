import Foundation
import GitaCore

/// Adaptive worktree strip mode: hidden when nothing actionable exists beyond the toolbar, compact single-line chips
/// when active, or attention-tinted when an agent needs input, checks fail, or production is behind.
@MainActor
enum StripMode: @MainActor Equatable {
    case hidden
    case compact([StripCellContent])
    case attention([StripCellContent])

    var chips: [StripCellContent] {
        switch self {
        case .hidden: []
        case .compact(let chips), .attention(let chips): chips
        }
    }

    var height: CGFloat {
        switch self {
        case .hidden: 0
        case .compact, .attention: WorktreeStripView.compactHeight
        }
    }

    var isAttention: Bool {
        if case .attention = self { true } else { false }
    }
}

/// Pure presenter deciding the worktree strip's mode and chips from its input.
@MainActor
enum StripPresenter {
    static func mode(_ input: WorktreeStripView.Input, now: Date = Date(), narrow: Bool = false) -> StripMode {
        let chips = WorktreeStripCells.cells(input, now: now, narrow: narrow)
        guard !chips.isEmpty else { return .hidden }
        return chips.contains(where: \.isAttention) ? .attention(chips) : .compact(chips)
    }
}

/// The worktree strip's input for the open checkout, read from the snapshot (never from display strings).
@MainActor
struct WorktreeStripPresenter {
    var snapshot: RepositorySnapshot
    /// The agents working in this checkout.
    var sessions: [AgentSession]
    var signals: ProviderSignalQuery
    var checks: [ProviderItem]
    var vercel: VercelContext?
    var productionBehind: Int?
    var productionBranch: String?
    var remoteDelta: RemoteDelta?
    var remoteCheckStatusSummary: String?

    /// The checked-out branch: nil while HEAD is detached or unborn.
    static func branch(of snapshot: RepositorySnapshot) -> String? {
        snapshot.head == nil || snapshot.branch?.isEmpty != false ? nil : snapshot.branch
    }

    var input: WorktreeStripView.Input {
        let branch = Self.branch(of: snapshot)
        var input = WorktreeStripView.Input()
        input.head = snapshot.head
        if let remoteDelta, remoteDelta.currentUpstreamMoved {
            input.remoteUpdate = Self.remoteUpdateHint(
                delta: remoteDelta, branch: branch, summary: remoteCheckStatusSummary)
        }
        if let crowd = WindowAgents.crowd(sessions) {
            input.session = crowd.lead
            input.otherAgents = crowd.others
            input.subagents = crowd.subagents
        }
        input.pullRequest = signals.pullRequest(branch: branch)
        input.canCreatePullRequest = branch != nil && snapshot.github?.webURL != nil
        input.checks = checks
        input.deployment =
            signals.latestDeployment(branch: branch, head: snapshot.head)
            ?? signals.latestDeployment(branch: branch, head: snapshot.head, environment: nil)
        if let vercel {
            input.production = vercel.production
            input.productionBehind = productionBehind
            input.isProductionBranch = branch != nil && branch == productionBranch
            if let branch {
                input.branchURL = vercel.branchPreviews[branch]
                input.comments = vercel.comments?.byBranch[branch] ?? 0
            }
        }
        return input
    }

    /// Create PR…: GitHub's compare page for `branch`, used when `gh pr create --web` fails.
    static func compareURL(github: URL, branch: String) -> URL? {
        let encoded = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        return URL(string: github.absoluteString + "/compare/" + encoded + "?expand=1")
    }

    private static func remoteUpdateHint(
        delta: RemoteDelta, branch: String?, summary: String?
    ) -> WorktreeStripView.RemoteHint {
        let matched =
            delta.currentUpstreamKey.flatMap { delta.moved[$0] != nil ? $0 : nil }
            ?? branch.flatMap { current in delta.moved.keys.first { $0.branch == current } }
            ?? (delta.moved.count == 1 ? delta.moved.keys.first : nil)
        let upstreamName = matched.map { "\($0.remote)/\($0.branch)" } ?? String(localized: "Upstream")
        let age = DeckFormat.relative(delta.checkedAt)
        let text = String(localized: "\(upstreamName) moved \(age)")
        let tip = (summary?.isEmpty == false ? summary : nil) ?? text
        return WorktreeStripView.RemoteHint(summary: text, toolTip: tip)
    }
}
