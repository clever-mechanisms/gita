import AppKit

/// The code pane: the shown path with Stage / Unstage hunk over the diff. The merge editor covers it for a conflict.
@MainActor
final class CodePaneView: NSView {
    private static let headerHeight: CGFloat = 28

    let diffView = DiffView()
    private let pathLabel = Style.label("", size: 11, color: Theme.secondaryText)
    let hunkButton = Style.button(String(localized: "Stage hunk"), symbol: "plus", target: nil, action: nil)
    var onApplyHunk: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hunkButton.target = self
        hunkButton.action = #selector(hunkPressed)
        hunkButton.setAccessibilityIdentifier("applyHunk")
        let header = Style.stack([pathLabel, hunkButton])
        header.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [header, diffView] as [NSView] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: Self.headerHeight),
            diffView.leadingAnchor.constraint(equalTo: leadingAnchor),
            diffView.trailingAnchor.constraint(equalTo: trailingAnchor),
            diffView.topAnchor.constraint(equalTo: header.bottomAnchor),
            diffView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    @objc private func hunkPressed() { onApplyHunk?() }

    func apply(_ state: CodePaneState) {
        pathLabel.stringValue = state.path
        pathLabel.toolTip = state.path
        hunkButton.isHidden = !state.showsHunk
        hunkButton.title = state.hunkTitle
        hunkButton.setAccessibilityLabel(state.hunkTitle)
        hunkButton.isEnabled = state.canApplyHunk
        hunkButton.toolTip = state.hunkToolTip
    }
}
