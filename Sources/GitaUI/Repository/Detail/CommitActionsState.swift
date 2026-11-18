import Foundation

/// Local Changes' footer: Stage all, the commit message, Amend Last Commit and Commit staged.
struct CommitActionsState: Equatable {
    struct Input {
        var hasSnapshot: Bool
        var hasDraft: Bool
        var isDraftCurrent: Bool
        var hasOperation: Bool
        var hasConflicts: Bool
        var isMutating: Bool
        var hasStagedChanges: Bool
        var hasUnstagedFiles: Bool
        var hasHead: Bool
        /// Checked, including while HEAD's message is still loading.
        var amendChecked: Bool
        /// Armed at one commit: Commit rewrites it, including with nothing newly staged.
        var amends: Bool
        /// The checkbox is on but the message has not arrived: Commit waits.
        var amendLoading: Bool
        var amendIsPublished: Bool
        var amendIsDetached: Bool
        var message: String
    }

    var canCommit: Bool
    var commitTitle: String
    var commitToolTip: String?
    var canStageAll: Bool
    var stageAllTitle: String
    var canEditMessage: Bool
    var messageToolTip: String?
    var canAmend: Bool
    var amendChecked: Bool
    var amendToolTip: String?

    init(_ input: Input) {
        canCommit = Self.canCommit(input)
        commitTitle = Self.commitTitle(input)
        commitToolTip = Self.commitToolTip(input)
        canStageAll = Self.canStageAll(input)
        stageAllTitle = Self.stageAllTitle(input)
        canEditMessage = Self.canEditMessage(input)
        messageToolTip = Self.messageToolTip(input)
        canAmend = Self.canAmend(input)
        amendChecked = input.amendChecked
        amendToolTip = Self.amendToolTip(input)
    }

    private static func isBlocked(_ input: Input) -> Bool { input.hasOperation || input.hasConflicts }

    private static func canCommit(_ input: Input) -> Bool {
        let subject = CommitMessageText.split(input.message).subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBlocked(input), input.isDraftCurrent, !input.isMutating, !input.amendLoading, !subject.isEmpty
        else { return false }
        return input.amends || input.hasStagedChanges
    }

    private static func commitTitle(_ input: Input) -> String {
        input.amends ? String(localized: "Amend") : String(localized: "Commit staged")
    }

    private static func canStageAll(_ input: Input) -> Bool { !input.isMutating && input.hasUnstagedFiles }

    private static func stageAllTitle(_ input: Input) -> String {
        input.hasConflicts ? String(localized: "Stage other files") : String(localized: "Stage all")
    }

    private static func canEditMessage(_ input: Input) -> Bool { input.hasDraft && !isBlocked(input) }

    private static func messageToolTip(_ input: Input) -> String? {
        guard input.hasSnapshot, !input.hasDraft else { return nil }
        return String(localized: "Could not restore commit message")
    }

    private static func canAmend(_ input: Input) -> Bool {
        guard !input.isMutating, !isBlocked(input) else { return false }
        return input.hasHead || input.amendChecked
    }

    private static func commitToolTip(_ input: Input) -> String? {
        if input.hasOperation { return String(localized: "Use Continue to finish the operation") }
        return publishedWarning(input)
    }

    private static func amendToolTip(_ input: Input) -> String? {
        if input.hasOperation { return String(localized: "Continue or abort the current Git operation first.") }
        if let published = publishedWarning(input) { return published }
        if input.amends && input.amendIsDetached {
            return String(localized: "Repository is in detached HEAD state.")
        }
        if input.hasHead {
            return String(localized: "Replace the last commit with this message and the staged changes.")
        }
        return String(localized: "There is no commit to amend.")
    }

    private static func publishedWarning(_ input: Input) -> String? {
        guard input.amends && input.amendIsPublished else { return nil }
        return String(localized: "This commit is already on the upstream branch. Amending it needs a force push.")
    }
}
