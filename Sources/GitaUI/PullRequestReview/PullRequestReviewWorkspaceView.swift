import AppKit

/// Pure layout decisions for the full-height PR list-detail workspace.
struct PullRequestReviewWorkspaceLayout: Equatable, Sendable {
    var presentation: ReviewPresentation
    var collapsesListToIcons: Bool
    var showsDetail: Bool

    static func evaluate(width: CGFloat, hasSelection: Bool, isPoppedOut: Bool) -> Self {
        let presentation = ReviewPresentation.preferred(forWidth: width)
        let collapses = presentation != .inline && width < ReviewPresentation.sidebarCollapseWidth
        return Self(
            presentation: presentation,
            collapsesListToIcons: collapses,
            showsDetail: hasSelection && !isPoppedOut && presentation != .inline)
    }
}

/// Full-height list-detail host for Pull Request reviews: keeps the PR list on the left (collapsing to compact
/// icon rows when `< 1,100 pt`) and hosts the selected `PullRequestReviewView` at full height on the right, falling
/// back to inline cards on narrow windows (`< 900 pt`).
@MainActor
final class PullRequestReviewWorkspaceView: NSView {
    private static let listFullWidth: CGFloat = 280
    private static let listCompactWidth: CGFloat = 68

    let listHost = NSView()
    let detailHost = NSView()
    private let split = DeckSplitView()
    private var listWidthConstraint: NSLayoutConstraint?
    private(set) var layoutState = PullRequestReviewWorkspaceLayout(
        presentation: .page, collapsesListToIcons: false, showsDetail: false)
    private(set) weak var activeReview: PullRequestReviewView?
    var onCollapseChanged: ((Bool) -> Void)?
    var onLayoutChanged: ((PullRequestReviewWorkspaceLayout) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(listHost)
        split.addArrangedSubview(detailHost)
        let widthConstraint = listHost.widthAnchor.constraint(equalToConstant: Self.listFullWidth)
        widthConstraint.priority = .defaultLow + 20
        listWidthConstraint = widthConstraint
        listHost.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.listCompactWidth).isActive = true
        split.setHoldingPriority(.defaultLow + 10, forSubviewAt: 0)
        Style.fill(split, in: self)
        detailHost.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("PullRequestReviewWorkspaceView is built in code") }

    func showReview(_ reviewView: PullRequestReviewView?, isPoppedOut: Bool = false) {
        if activeReview !== reviewView {
            activeReview?.removeFromSuperview()
            activeReview = reviewView
        }
        applyLayout(width: bounds.width, isPoppedOut: isPoppedOut)
    }

    func clearReview() {
        if activeReview?.superview === detailHost {
            activeReview?.removeFromSuperview()
        }
        activeReview = nil
        applyLayout(width: bounds.width, isPoppedOut: false)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyLayout(width: newSize.width, isPoppedOut: activeReview?.presentation == .window)
    }

    func applyLayout(width: CGFloat, isPoppedOut: Bool) {
        let effectiveWidth = width > 0 ? width : 1_120
        let next = PullRequestReviewWorkspaceLayout.evaluate(
            width: effectiveWidth, hasSelection: activeReview != nil, isPoppedOut: isPoppedOut)
        let collapseChanged = next.collapsesListToIcons != layoutState.collapsesListToIcons
        let changed = next != layoutState
        let needsAttach = next.showsDetail && activeReview?.superview !== detailHost
        guard changed || needsAttach else { return }
        layoutState = next
        detailHost.isHidden = !next.showsDetail
        if next.showsDetail, let activeReview {
            if activeReview.superview !== detailHost {
                activeReview.removeFromSuperview()
                Style.fill(activeReview, in: detailHost)
            }
            activeReview.setPresentation(next.presentation)
            listWidthConstraint?.constant =
                next.collapsesListToIcons ? Self.listCompactWidth : Self.listFullWidth
            listWidthConstraint?.isActive = true
        } else {
            if !isPoppedOut, let activeReview {
                if activeReview.superview === detailHost {
                    activeReview.removeFromSuperview()
                }
                activeReview.setPresentation(next.presentation)
            }
            listWidthConstraint?.isActive = false
            listWidthConstraint?.constant = Self.listFullWidth
        }
        split.adjustSubviews()
        if collapseChanged { onCollapseChanged?(next.collapsesListToIcons) }
        if changed { onLayoutChanged?(next) }
    }
}
