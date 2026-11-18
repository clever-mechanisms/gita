import AppKit
import GitaCore

/// Something up a view's responder chain that shows a pull request's review: the repository window's controller,
/// which opens the Pull Requests page with the pull request expanded.
@MainActor
protocol PullRequestReviewOpening: AnyObject {
    func openPullRequestReview(_ item: ProviderItem)
}

extension NSResponder {
    /// The nearest responder, from this one up, that shows reviews.
    var pullRequestReviewOpener: (any PullRequestReviewOpening)? {
        sequence(first: self, next: \.nextResponder).lazy.compactMap { $0 as? any PullRequestReviewOpening }.first
    }
}

extension PartsButton {
    /// "Review Changes…" (or "View Changes…" once the pull request is closed or merged), showing the review in place
    /// on the Pull Requests page through the responder chain from `source`.
    static func review(_ item: ProviderItem, from source: NSView, small: Bool = false) -> PartsButton {
        let open = item.pullRequest.map { $0.lifecycle == .open } ?? true
        let title = open ? String(localized: "Review Changes…") : String(localized: "View Changes…")
        let button = Self.quiet(small ? "" : title, symbol: "text.magnifyingglass") { [weak source] in
            source?.pullRequestReviewOpener?.openPullRequestReview(item)
        }
        button.toolTip = title
        button.setAccessibilityLabel(title)
        if small { button.fixedHeight = 20 }
        return button
    }
}
