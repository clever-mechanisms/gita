import AppKit
import GitaCore

/// GitHub's green Merge button beside Refresh: the left part merges with the chosen method (after a confirmation),
/// the chevron opens the methods the repository allows, each with what it does to the branch's commits.
@MainActor
final class ReviewMergeControl: NSView {
    let mergeButton = PartsButton([], background: .tinted, accessibility: String(localized: "Merge pull request"))
    let menuButton = PartsButton(
        [.symbol("chevron.down", color: .white, size: 10)], background: .tinted,
        accessibility: String(localized: "Merge method"))
    var onMerge: (() -> Void)?
    var onPick: ((PullRequestMergeMethod) -> Void)?
    private var methods: [PullRequestMergeMethod] = []
    private var chosen: PullRequestMergeMethod?
    private var commits = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for button in [mergeButton, menuButton] {
            button.fixedHeight = 26
            button.cornerRadius = 7
            button.tintFill = Theme.success
            button.tintBorder = Theme.success
        }
        mergeButton.horizontalPadding = 11
        mergeButton.spacing = 5
        menuButton.horizontalPadding = 7
        mergeButton.onClick = { [weak self] in self?.onMerge?() }
        menuButton.onClick = { [weak self] in self?.showMenu() }
        Deck.pin(Deck.hstack([mergeButton, menuButton], spacing: 1), in: self)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ReviewMergeControl is built in code") }

    func apply(_ state: PullRequestReviewState) {
        isHidden = !state.showsMerge
        methods = state.mergeOptions.methods
        chosen = state.mergeMethod
        commits = state.mergeOptions.commitCount
        let title = Self.buttonTitle(chosen)
        mergeButton.parts = [
            .symbol("arrow.triangle.merge", color: .white, size: 12),
            .text(title, font: Theme.bodyEmphasis, color: .white),
        ]
        mergeButton.setAccessibilityLabel(title)
        mergeButton.isEnabled = state.canMerge
        menuButton.isEnabled = !state.isSending && !state.isLoading && methods.count > 1
        mergeButton.toolTip = state.mergeProblem ?? state.mergeExplanation
        menuButton.toolTip = state.mergeProblem
    }

    /// "Merge pull request", "Squash and merge" or "Rebase and merge", as GitHub labels its button.
    static func buttonTitle(_ method: PullRequestMergeMethod?) -> String {
        switch method {
        case .squash, .rebase: method?.localizedTitle ?? ""
        case .merge, nil: String(localized: "Merge pull request")
        }
    }

    /// The methods, the chosen one ticked, each title over its explanation.
    func menu() -> NSMenu {
        let menu = NSMenu()
        for method in methods {
            let item = MenuAction(method.localizedTitle) { [weak self] in self?.onPick?(method) }
            item.attributedTitle = Self.menuTitle(method, commits: commits)
            item.state = method == chosen ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func showMenu() {
        menu().popUp(positioning: nil, at: NSPoint(x: 0, y: mergeButton.bounds.height + 3), in: mergeButton)
    }

    private static func menuTitle(_ method: PullRequestMergeMethod, commits: Int) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: method.localizedTitle + "\n", attributes: [.font: Theme.bodyEmphasis, .foregroundColor: Theme.text])
        text.append(
            NSAttributedString(
                string: method.explanation(commits: commits),
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.secondaryText]))
        return text
    }
}
