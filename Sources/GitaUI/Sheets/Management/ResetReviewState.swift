import GitaCore

/// The reset review: the reviewed preview of the target commit, the chosen mode and the hard-reset confirmation.
struct ResetReviewState {
    /// The preview read, and an apply failure on a loaded preview. A failed read needs Reload; changing the mode
    /// clears only an apply failure.
    enum Load {
        /// Not read yet, or the read was stopped.
        case idle
        case loading
        case loaded(GitResetPreview, applyError: String?)
        case failed(String)
    }
    let commitID: String
    var mode: GitResetMode = .mixed
    /// The "Replace tracked files and discard changes" box, required for a hard reset.
    var confirmsDiscard = false
    private(set) var load = Load.idle

    init(commitID: String) { self.commitID = commitID }

    var preview: GitResetPreview? { if case .loaded(let preview, _) = load { preview } else { nil } }
    var isLoading: Bool { if case .loading = load { true } else { false } }
    var errorMessage: String? {
        switch load {
        case .loaded(_, let applyError): applyError
        case .failed(let message): message
        case .idle, .loading: nil
        }
    }
    var isDestructive: Bool { mode == .hard }
    var applyTitle: String { isDestructive ? String(localized: "Hard Reset") : String(localized: "Reset") }
    var effect: String {
        switch mode {
        case .soft: String(localized: "Keep staged and working changes.")
        case .mixed: String(localized: "Unstage changes; keep working files.")
        case .hard: String(localized: "Discard staged and working changes in tracked files.")
        }
    }
    /// The branch and change count of the reviewed checkout; nil until the preview loads.
    var facts: (text: String, toolTip: String)? {
        guard let preview else { return nil }
        let branch = preview.currentBranch ?? String(localized: "Detached HEAD")
        return (
            String(localized: "\(branch) · \(preview.trackedChangeCount) tracked changes"),
            String(localized: "HEAD: \(preview.currentHeadID)\n\(preview.untrackedFileCount) untracked files")
        )
    }
    func canApply(_ activity: SheetActivity) -> Bool {
        guard case .loaded(_, applyError: nil) = load else { return false }
        return activity.isActive && (!isDestructive || confirmsDiscard)
    }
    func status(_ activity: SheetActivity) -> SheetStatus {
        let message =
            activity.isApplying
            ? (activity.refusedClose
                ? String(localized: "Wait for the reset to finish.") : String(localized: "Resetting…"))
            : errorMessage ?? (isLoading ? String(localized: "Loading reset preview…") : "")
        return SheetStatus(
            message: message, isBusy: isLoading || activity.isApplying,
            isError: errorMessage != nil && !activity.isApplying)
    }

    mutating func beginLoad() {
        confirmsDiscard = false
        load = .loading
    }
    mutating func cancelLoad() {
        if isLoading { load = .idle }
    }
    mutating func finishLoad(_ result: Result<GitResetPreview, any Error>) {
        switch result {
        case .success(let next) where ReviewText.same(next.target.id, commitID): load = .loaded(next, applyError: nil)
        case .success: load = .failed(String(localized: "The selected commit is unavailable."))
        case .failure(let error): load = .failed(ReviewText.message(error))
        }
    }
    mutating func select(_ mode: GitResetMode) {
        self.mode = mode
        clearApplyError()
    }
    mutating func beginApply() { clearApplyError() }
    mutating func applyFailed(_ error: any Error) {
        guard let preview else { return }
        load = .loaded(preview, applyError: ReviewText.message(error))
    }
    private mutating func clearApplyError() {
        if let preview { load = .loaded(preview, applyError: nil) }
    }
}
