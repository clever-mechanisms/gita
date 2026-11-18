import GitaCore

/// What the reference sheet shows about the reviewed reference, why it cannot be applied, and the action it applies.
extension ReferenceReviewState {
    private static let commitType = "commit"
    private static let tagType = "tag"
    private static let shortIDLength = 12

    var heading: String {
        let shown =
            sourceDetails?.reference.name
            ?? selectedSource.flatMap { selected in references.first { ReviewText.same($0.fullName, selected) }?.name }
            ?? selectedSource.map(ReviewText.shortReference)
        guard let shown, !needsSourcePicker else { return title }
        switch request {
        case .renameBranch: return String(localized: "Rename “\(shown)”")
        case .deleteBranch: return String(localized: "Delete “\(shown)”?")
        case .deleteTag: return String(localized: "Delete tag “\(shown)”?")
        case .setUpstream: return String(localized: "Upstream for “\(shown)”")
        case .createTag: return title
        }
    }

    /// One line under the heading; empty hides it.
    var summary: String {
        switch request {
        case .renameBranch: ""
        case .createTag(let commit): String(localized: "At \(commit.id.prefix(Self.shortIDLength)) · \(commit.subject)")
        case .deleteBranch: deleteBranchSummary
        case .deleteTag: sourceDetails.map(Self.tagSummary) ?? ""
        case .setUpstream: sourceDetails.map(Self.upstreamSummary) ?? ""
        }
    }
    private var deleteBranchSummary: String {
        guard let details = sourceDetails, details.mergeStatus == .merged, let target = details.deleteMergeTarget
        else { return "" }
        return String(localized: "Merged into \(ReviewText.shortReference(target))")
    }
    private static func tagSummary(_ details: GitReferenceDetails) -> String {
        if details.objectType == tagType {
            return details.commitID.map { String(localized: "Annotated tag · Commit \($0.prefix(shortIDLength))") }
                ?? String(localized: "Annotated tag")
        }
        if let commit = details.commitID { return String(localized: "Commit \(commit.prefix(shortIDLength))") }
        return String(localized: "\(details.objectType.capitalized) object · \(details.objectID.prefix(shortIDLength))")
    }
    private static func upstreamSummary(_ details: GitReferenceDetails) -> String {
        guard let upstream = details.upstream else { return String(localized: "No upstream is set") }
        let current =
            upstream.fullName.map(ReviewText.shortReference) ?? upstream.mergeRef
            ?? String(localized: "Configured upstream")
        return upstream.isMissing
            ? String(localized: "Current: \(current) (missing)") : String(localized: "Current: \(current)")
    }

    /// Every reviewed fact, as label and value, for the summary's tooltip.
    var factRows: [(String, String)] {
        if case .createTag(let commit) = request {
            return [
                (String(localized: "Commit"), commit.id), (String(localized: "Subject"), commit.subject),
                (String(localized: "Author"), commit.author),
                (String(localized: "Date"), commit.date.formatted(date: .abbreviated, time: .standard)),
            ]
        }
        guard let details = sourceDetails else { return [] }
        var rows = details.reference.kind == .tag ? Self.tagRows(details) : branchRows(details)
        if isTracking, let upstreamDetails {
            rows.append((String(localized: "Selected upstream"), upstreamDetails.reference.fullName))
            if let commit = upstreamDetails.commitID { rows.append((String(localized: "Selected commit"), commit)) }
        }
        return rows
    }
    var factsToolTip: String { factRows.map { String(localized: "\($0.0): \($0.1)") }.joined(separator: "\n") }

    private static func tagRows(_ details: GitReferenceDetails) -> [(String, String)] {
        if let commit = details.commitID, ReviewText.same(details.objectID, commit) {
            return [(String(localized: "Commit"), commit), (String(localized: "Type"), details.objectType)]
        }
        var rows = [(String(localized: "Object"), details.objectID), (String(localized: "Type"), details.objectType)]
        if let commit = details.commitID { rows.append((String(localized: "Commit"), commit)) }
        return rows
    }
    private func branchRows(_ details: GitReferenceDetails) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let commit = details.commitID { rows.append((String(localized: "Commit"), commit)) }
        rows += Self.upstreamRows(details.upstream)
        rows += details.worktreePaths.enumerated().map {
            ($0.offset == 0 ? String(localized: "Worktree") : "", $0.element)
        }
        if case .deleteBranch = request { rows += Self.mergeRows(details) }
        return rows
    }
    private static func upstreamRows(_ upstream: GitReferenceUpstream?) -> [(String, String)] {
        guard let upstream else { return [(String(localized: "Current upstream"), String(localized: "No upstream"))] }
        let name =
            upstream.fullName ?? [upstream.remoteName, upstream.mergeRef].compactMap { $0 }.joined(separator: " · ")
        var rows = [(String(localized: "Current upstream"), name.isEmpty ? String(localized: "Configured") : name)]
        if upstream.isMissing { rows.append((String(localized: "Upstream status"), String(localized: "Missing"))) }
        if let object = upstream.objectID { rows.append((String(localized: "Upstream commit"), object)) }
        return rows
    }
    private static func mergeRows(_ details: GitReferenceDetails) -> [(String, String)] {
        var rows: [(String, String)] = []
        if let target = details.deleteMergeTarget { rows.append((String(localized: "Merge target"), target)) }
        if let commit = details.deleteMergeCommitID { rows.append((String(localized: "Target commit"), commit)) }
        if details.mergeStatus != .unknown {
            rows.append(
                (
                    String(localized: "Merge status"),
                    details.mergeStatus == .merged ? String(localized: "Merged") : String(localized: "Not merged")
                ))
        }
        return rows
    }

    // MARK: Validation

    /// Why the reviewed reference cannot take this action; nil when it can.
    var restriction: String? {
        if case .createTag(let commit) = request, !ReviewText.isFullObjectID(commit.id) {
            return String(localized: "Selected commit is unavailable.")
        }
        if (isRenaming || isTracking) && selectedSource == nil {
            return String(localized: "No current branch is selected.")
        }
        guard let details = sourceDetails else { return nil }
        if details.reference.kind == .branch && (details.commitID == nil || details.objectType != Self.commitType) {
            return String(localized: "Branch does not point to a commit.")
        }
        switch request {
        case .renameBranch: return Self.renameRestriction(details)
        case .deleteBranch: return Self.deleteRestriction(details)
        case .setUpstream: return upstreamRestriction(details)
        case .createTag, .deleteTag: return nil
        }
    }
    private static func renameRestriction(_ details: GitReferenceDetails) -> String? {
        let inUse = details.worktreePaths.count > 1 || (!details.reference.isCurrent && !details.worktreePaths.isEmpty)
        return inUse ? String(localized: "Branch is in use by a worktree.") : nil
    }
    private static func deleteRestriction(_ details: GitReferenceDetails) -> String? {
        if details.reference.isCurrent || !details.worktreePaths.isEmpty {
            return String(localized: "Branch is checked out or reserved by a worktree.")
        }
        if details.upstream?.isMissing == true { return String(localized: "Configured upstream is missing.") }
        switch details.mergeStatus {
        case .notMerged: return String(localized: "Branch is not merged into the reviewed target.")
        case .unknown: return String(localized: "Merge status unavailable.")
        case .merged: return nil
        }
    }
    private func upstreamRestriction(_ details: GitReferenceDetails) -> String? {
        guard let upstreamDetails else { return nil }
        if ReviewText.same(upstreamDetails.reference.fullName, details.reference.fullName) {
            return String(localized: "Choose a different upstream branch.")
        }
        if upstreamDetails.commitID == nil || upstreamDetails.objectType != Self.commitType {
            return String(localized: "Upstream does not point to a commit.")
        }
        return nil
    }

    func pendingAction(_ activity: SheetActivity) -> ReferenceReviewAction? {
        guard activity.isActive, !sourceLoading, !upstreamLoading, errorMessage == nil, restriction == nil
        else { return nil }
        switch request {
        case .createTag(let commit): return tagAction(commit)
        case .renameBranch:
            guard let details = sourceDetails, !Self.isBlank(name), !ReviewText.same(name, details.reference.name)
            else { return nil }
            return .renameBranch(details, name)
        case .deleteBranch: return sourceDetails.map(ReferenceReviewAction.deleteBranch)
        case .deleteTag:
            return sourceDetails.map { .deleteTag($0, deleteFromAllRemotes: hasRemotes && deleteFromAllRemotes) }
        case .setUpstream: return sourceDetails.flatMap(upstreamAction)
        }
    }
    private func tagAction(_ commit: GitCommit) -> ReferenceReviewAction? {
        guard !Self.isBlank(name), ReviewText.isFullObjectID(commit.id) else { return nil }
        return .createTag(
            name: name, commitID: commit.id, annotation: Self.isBlank(annotation) ? nil : annotation,
            pushToAllRemotes: hasRemotes && pushToAllRemotes)
    }
    private func upstreamAction(_ details: GitReferenceDetails) -> ReferenceReviewAction? {
        switch upstreamChoice {
        case .none: return details.upstream == nil ? nil : .setUpstream(details, nil)
        case .unavailable: return nil
        case .reference:
            guard let upstreamDetails else { return nil }
            if let current = details.upstream, !current.isMissing, let fullName = current.fullName,
                ReviewText.same(fullName, upstreamDetails.reference.fullName)
            {
                return nil
            }
            return .setUpstream(details, upstreamDetails)
        }
    }
    private static func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func status(_ activity: SheetActivity) -> SheetStatus {
        let message: String
        if activity.isApplying {
            message =
                activity.refusedClose
                ? String(localized: "Wait for this action to finish.") : String(localized: "Applying…")
        } else if let errorMessage {
            message = errorMessage
        } else if sourceLoading {
            message = String(localized: "Loading reference…")
        } else if upstreamLoading {
            message = String(localized: "Loading upstream…")
        } else {
            message = restriction ?? ""
        }
        return SheetStatus(
            message: message, isBusy: activity.isApplying || sourceLoading || upstreamLoading,
            isError: errorMessage != nil || restriction != nil)
    }
}
