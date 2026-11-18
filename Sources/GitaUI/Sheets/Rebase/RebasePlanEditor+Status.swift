/// The status line of the interactive rebase sheet.
extension RebasePlanEditor {
    /// Whether the plan on screen was read fresh enough to replay: only a `current` review can be applied.
    enum Review: Equatable {
        /// Nothing read yet, or the read was stopped.
        case unread
        /// The range is being read.
        case loading
        /// The range was read and the plan can be replayed.
        case current
        /// The read failed or the rebase was refused: Reload reviews the range again.
        case stale(String)

        var isLoading: Bool { self == .loading }
        var error: String? { if case .stale(let message) = self { message } else { nil } }
    }
    struct Progress {
        var review = Review.unread
        var inputError: String?
        var messagesPending = false
    }

    func status(_ activity: SheetActivity, _ progress: Progress) -> SheetStatus {
        let busy = activity.isApplying || progress.review.isLoading || progress.messagesPending
        if activity.isApplying {
            let message =
                activity.refusedClose
                ? String(localized: "Wait for the rebase to finish or pause.") : String(localized: "Rebasing…")
            return SheetStatus(message: message, isBusy: busy)
        }
        if progress.review.isLoading {
            return SheetStatus(message: String(localized: "Loading commits…"), isBusy: busy)
        }
        if let reviewError = progress.review.error {
            let message =
                plan == nil ? reviewError : String(localized: "\(reviewError)\nReload to review this range again.")
            return SheetStatus(message: message, isBusy: busy, isError: true)
        }
        if let inputError = progress.inputError { return SheetStatus(message: inputError, isBusy: busy, isError: true) }
        if let validation { return SheetStatus(message: validation, isBusy: busy, isError: !progress.messagesPending) }
        let drops = dropCount
        guard drops > 0 else { return SheetStatus(message: "", isBusy: busy) }
        let message =
            drops == steps.count
            ? String(localized: "All \(drops) commits will be dropped.")
            : String(localized: "\(drops) commits will be dropped.")
        return SheetStatus(message: message, isBusy: busy)
    }
}
