import AppKit
import GitaCore

/// Safe drop menu and confirmation builders for §6d drag-and-drop. Nothing mutates on drop; every action opens
/// a review or confirmation sheet.
@MainActor
enum SidebarDropMenuBuilder {
    struct BranchDropPlan: Equatable {
        var repositoryRoot: URL
        var sourceName: String
        var targetName: String
        var sourceFullName: String
        var targetFullName: String
        var targetIsCurrent: Bool
        var sourceIsCurrent: Bool
    }

    static func branchDropMenu(
        _ plan: BranchDropPlan,
        onMerge: @escaping @MainActor () -> Void,
        onRebase: @escaping @MainActor () -> Void
    ) -> NSMenu {
        let menu = NSMenu()
        let mergeTitle = String(localized: "Merge \(plan.sourceName) into \(plan.targetName)…")
        let mergeItem = MenuAction(mergeTitle, symbol: "arrow.triangle.merge", handler: onMerge)
        mergeItem.setAccessibilityIdentifier("sidebar.drop.merge")
        menu.addItem(mergeItem)

        let rebaseTitle =
            plan.targetIsCurrent && !plan.sourceIsCurrent
            ? String(localized: "Rebase \(plan.targetName) onto \(plan.sourceName)…")
            : String(localized: "Rebase \(plan.sourceName) onto \(plan.targetName)…")
        let rebaseItem = MenuAction(rebaseTitle, symbol: "arrow.triangle.branch", handler: onRebase)
        rebaseItem.setAccessibilityIdentifier("sidebar.drop.rebase")
        menu.addItem(rebaseItem)
        return menu
    }

    static func cherryPickConfirmation(commits: [GitCommit], target: GitReference) -> NSAlert {
        let count = commits.count
        let alert = NSAlert()
        alert.messageText =
            count == 1
            ? String(localized: "Cherry-pick 1 commit onto \(target.name)?")
            : String(localized: "Cherry-pick \(count) commits onto \(target.name)?")
        let lines = commits.prefix(8).map { "\(String($0.id.prefix(7)))  \($0.subject)" }
        let suffix = count > 8 ? ["…"] : []
        let switchNote =
            target.isCurrent
            ? []
            : [String(localized: "Gitā will check out \(target.name) first, then replay the commits.")]
        alert.informativeText = (switchNote + lines + suffix).joined(separator: "\n")
        alert.addButton(
            withTitle: count == 1
                ? String(localized: "Cherry-pick") : String(localized: "Cherry-pick \(count)"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert
    }

    static func multiCommitConfirmation(title: String, commits: [GitCommit], actionTitle: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        let lines = commits.prefix(8).map { "\(String($0.id.prefix(7)))  \($0.subject)" }
        let suffix = commits.count > 8 ? ["…"] : []
        alert.informativeText = (lines + suffix).joined(separator: "\n")
        alert.addButton(withTitle: actionTitle)
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert
    }
}
