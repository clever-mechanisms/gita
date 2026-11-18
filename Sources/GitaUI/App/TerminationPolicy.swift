/// How Quit (or logout) proceeds.
enum TerminationPolicy: Equatable {
    /// Save the commit drafts, then quit (or cancel when one cannot be saved).
    case now
    /// A review sheet decides first (it may ask about unsaved review work).
    case askReviewSheet
    /// A Git action is running: quitting now could leave the repository mid-operation. The user is told why.
    case refuseWhileMutating

    init(hasReviewSheet: Bool, isMutating: Bool) {
        if hasReviewSheet {
            self = .askReviewSheet
        } else {
            self = isMutating ? .refuseWhileMutating : .now
        }
    }
}
