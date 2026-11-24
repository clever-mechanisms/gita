import Foundation

/// Local Changes' composer state: Commit, Commit & Push, Amend Last Commit, and the inline published-amend banner.
struct CommitActionsState: Equatable {
    struct Input {
        var hasSnapshot: Bool
        var hasDraft: Bool
        var isDraftCurrent: Bool
        var hasOperation: Bool
        var hasConflicts: Bool
        var isMutating: Bool
        var stagedCount: Int
        var hasHead: Bool
        var mode: CommitMode
        var amendCommitID: String?
        var upstreamName: String?
        var message: String
    }

    private static let shortSHALength = 7

    var mode: CommitMode
    var canCommit: Bool
    var canCommitAndPush: Bool
    var canOpenCommitMenu: Bool
    var commitTitle: String
    var commitToolTip: String?
    var pushDisabledToolTip: String?
    var canEditMessage: Bool
    var messageToolTip: String?
    var canAmend: Bool
    var amendToolTip: String?
    var amendBanner: String?

    init(_ input: Input) {
        mode = input.mode
        let commitAllowed = Self.canCommit(input)
        canCommit = commitAllowed
        canCommitAndPush = commitAllowed && !input.mode.isPublished
        canOpenCommitMenu = Self.canOpenCommitMenu(input)
        commitTitle = Self.commitTitle(input)
        commitToolTip = Self.commitToolTip(input)
        pushDisabledToolTip = input.mode.isPublished ? Self.publishedWarning(input) : nil
        canEditMessage = Self.canEditMessage(input)
        messageToolTip = Self.messageToolTip(input)
        canAmend = Self.canAmend(input)
        amendToolTip = Self.amendToolTip(input)
        amendBanner = Self.amendBanner(input)
    }

    private static func isBlocked(_ input: Input) -> Bool { input.hasOperation || input.hasConflicts }

    private static func canCommit(_ input: Input) -> Bool {
        let subject = CommitMessageText.split(input.message).subject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isBlocked(input), input.isDraftCurrent, !input.isMutating, !input.mode.isLoading, !subject.isEmpty
        else { return false }
        return input.mode.isArmed || input.stagedCount > 0
    }

    private static func canOpenCommitMenu(_ input: Input) -> Bool {
        guard input.hasSnapshot, !input.isMutating, !isBlocked(input) else { return false }
        return input.hasHead || input.mode.isAmend || input.stagedCount > 0
    }

    private static func commitTitle(_ input: Input) -> String {
        if input.mode.isAmend {
            if let sha = shortSHA(input.amendCommitID) { return String(localized: "Amend \(sha)") }
            return String(localized: "Amend")
        }
        switch input.stagedCount {
        case 0: return String(localized: "Commit")
        case 1: return String(localized: "Commit 1 file")
        default: return String(localized: "Commit \(input.stagedCount) files")
        }
    }

    private static func shortSHA(_ id: String?) -> String? {
        guard let id, !id.isEmpty else { return nil }
        return String(id.prefix(shortSHALength))
    }

    private static func canEditMessage(_ input: Input) -> Bool { input.hasDraft && !isBlocked(input) }

    private static func messageToolTip(_ input: Input) -> String? {
        guard input.hasSnapshot, !input.hasDraft else { return nil }
        return String(localized: "Could not restore commit message")
    }

    private static func canAmend(_ input: Input) -> Bool {
        guard !input.isMutating, !isBlocked(input) else { return false }
        return input.hasHead || input.mode.isAmend
    }

    private static func commitToolTip(_ input: Input) -> String? {
        if input.hasOperation { return String(localized: "Use Continue to finish the operation") }
        return publishedWarning(input)
    }

    private static func amendToolTip(_ input: Input) -> String? {
        if input.hasOperation { return String(localized: "Continue or abort the current Git operation first.") }
        if let published = publishedWarning(input) { return published }
        if input.mode.isArmed && input.mode.isDetached {
            return String(localized: "Repository is in detached HEAD state.")
        }
        if input.hasHead {
            return String(localized: "Replace the last commit with this message and the staged changes.")
        }
        return String(localized: "There is no commit to amend.")
    }

    private static func publishedWarning(_ input: Input) -> String? {
        guard input.mode.isPublished else { return nil }
        return String(localized: "This commit is already on the upstream branch. Amending it needs a force push.")
    }

    private static func amendBanner(_ input: Input) -> String? {
        guard input.mode.isPublished else { return nil }
        if let sha = shortSHA(input.amendCommitID), let upstream = input.upstreamName, !upstream.isEmpty {
            return String(localized: "⚠ \(sha) is on \(upstream). Amending needs a force push.")
        }
        if let sha = shortSHA(input.amendCommitID) {
            return String(localized: "⚠ \(sha) is on the upstream branch. Amending needs a force push.")
        }
        return String(localized: "⚠ This commit is already on the upstream branch. Amending needs a force push.")
    }
}
