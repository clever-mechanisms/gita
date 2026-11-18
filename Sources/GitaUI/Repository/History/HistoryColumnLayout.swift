import CoreGraphics

/// How the history columns share the list's width: the subject absorbs what the metadata columns leave; narrow
/// windows drop the SHA column (it is in the detail bar) and squeeze Status before scrolling sideways.
struct HistoryColumnLayout: Equatable {
    /// The status column never gets narrower than this (times the zoom) while it shows.
    static let minimumStatusWidth: CGFloat = 120
    /// The narrowest a status column may be dragged (times the zoom).
    static let draggableStatusWidth: CGFloat = 48

    struct Input: Equatable {
        var total: CGFloat
        var subjectMinimum: CGFloat
        var author: CGFloat
        var date: CGFloat
        var sha: CGFloat
        var statusShown: Bool
        var statusPreferred: CGFloat
        var scale: CGFloat
    }

    var showsSHA: Bool
    /// The status column's width, nil while it is hidden.
    var status: CGFloat?
    var subject: CGFloat

    init(_ input: Input) {
        let fixed = input.author + input.date
        let preferred = input.statusShown ? input.statusPreferred : 0
        showsSHA = input.total >= input.subjectMinimum + fixed + HistoryColumn.sha.baseWidth * input.scale + preferred
        let sha = showsSHA ? input.sha : 0
        if input.statusShown {
            let room = input.total - input.subjectMinimum - fixed - sha
            status = max(Self.minimumStatusWidth * input.scale, min(input.statusPreferred, room))
        } else {
            status = nil
        }
        subject = max(input.subjectMinimum, input.total - (fixed + sha + (status ?? 0)))
    }
}
