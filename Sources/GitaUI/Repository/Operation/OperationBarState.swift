import GitaCore

/// The bar over the history while a merge, rebase, cherry-pick or revert is paused or files conflict.
struct OperationBarState: Equatable {
    struct Button: Equatable {
        var isHidden: Bool
        var isEnabled: Bool
        var toolTip: String?
    }

    var isHidden: Bool
    var title: String
    var toolTip: String?
    var continueButton: Button
    /// Resolve Simple: shown only while some conflicted file can be merged on its own.
    var resolveSimple: Button
    var resolveSimpleTitle: String
    var skip: Button
    var abort: Button

    /// `currentBranch`: the snapshot's branch (the operation's branch is named only when it is another one).
    /// `simpleConflicts`: the conflicted files Resolve Simple can merge on its own.
    init(
        operation: GitOperationState?, currentBranch: String?, conflicts: Int, simpleConflicts: Int = 0, isBusy: Bool
    ) {
        isHidden = operation == nil && conflicts == 0
        let editing = operation?.isEditingCommit == true
        var name = operation?.kind.localizedTitle ?? String(localized: "Conflicts")
        if let branch = operation?.branch, branch != currentBranch {
            name = String(localized: "\(name) · \(branch.replacingOccurrences(of: "refs/heads/", with: ""))")
        }
        if let step = operation?.step, let total = operation?.total {
            name = String(localized: "\(name) \(step)/\(total)")
        }
        let status =
            if conflicts > 0 {
                String(localized: "\(conflicts) unresolved")
            } else if editing {
                String(localized: "Paused for edits")
            } else {
                String(localized: "Ready to continue")
            }
        title = String(localized: "\(name) · \(status)")
        toolTip = editing ? String(localized: "Stage changes, then Continue to amend this commit.") : nil
        continueButton = Button(
            isHidden: operation == nil, isEnabled: operation != nil && conflicts == 0 && !isBusy,
            toolTip: editing ? String(localized: "Amend this commit with staged changes and continue rebasing") : nil)
        resolveSimple = Button(
            isHidden: simpleConflicts == 0, isEnabled: !isBusy,
            toolTip: String(
                localized: "Merge and stage the conflicted files whose changes do not overlap; the rest stay for you"))
        resolveSimpleTitle = String(localized: "Resolve Simple (\(simpleConflicts))")
        skip = Button(isHidden: operation?.canSkip != true, isEnabled: !isBusy)
        abort = Button(isHidden: operation == nil, isEnabled: !isBusy)
    }
}
