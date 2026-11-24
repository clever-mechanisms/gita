import AppKit
import GitaCore

/// Detail view for §6b 2-commit comparison (`git diff <base> <head>`): header with `[Swap]`, changed file list, and
/// `DiffView`.
@MainActor
final class CommitCompareView: NSView {
    private enum Metrics {
        static let headerHeight: CGFloat = 34
        static let filePaneWidth: CGFloat = 250
        static let shortLength = 7
    }

    var onSwap: (() -> Void)?
    var onSelectFile: ((FileChange) -> Void)?

    private let summaryLabel = Deck.label("", font: Theme.bodyEmphasis, color: Theme.text)
    private let distanceLabel = Deck.label("", font: Theme.caption, color: Theme.secondaryText)
    private let swapButton = PartsButton(
        [
            .symbol("arrow.left.arrow.right", color: Theme.secondaryText, size: 10.5),
            .text(String(localized: "Swap"), font: Theme.caption, color: Theme.text),
        ],
        background: .hover, accessibility: String(localized: "Swap comparison order"))
    let filesView = ChangedFilesView(side: .commit)
    private let diffView = DiffView()
    private let split = DeckSplitView()
    private var state: CompareState?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureHeader()
        configureSplit()
        setAccessibilityIdentifier("history.compareView")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("CommitCompareView is built in code") }

    private func configureHeader() {
        swapButton.fixedHeight = 22
        swapButton.horizontalPadding = 8
        swapButton.cornerRadius = 5
        swapButton.onClick = { [weak self] in self?.onSwap?() }
        swapButton.setAccessibilityIdentifier("history.compare.swap")
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        distanceLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        swapButton.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func configureSplit() {
        let headerRow = Deck.hstack([summaryLabel, distanceLabel, Deck.spacer(), swapButton], spacing: 8)
        headerRow.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        let header = RowView()
        header.hoverEnabled = false
        header.bottomSeparator = Theme.separator
        Deck.pin(headerRow, in: header, insets: NSEdgeInsets(top: 0, left: 0, bottom: 1, right: 0))

        filesView.emptyText = String(localized: "No differences between these commits")
        filesView.onSelect = { [weak self] file in self?.onSelectFile?(file) }
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(filesView)
        split.addArrangedSubview(diffView)
        split.setHoldingPriority(.init(260), forSubviewAt: 0)
        filesView.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        for view in [header, split] as [NSView] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            header.heightAnchor.constraint(equalToConstant: Metrics.headerHeight),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.topAnchor.constraint(equalTo: header.bottomAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        split.setPosition(Metrics.filePaneWidth, ofDividerAt: 0)
    }

    func update(_ next: CompareState) {
        guard next != state else { return }
        state = next
        let baseShort = String(next.base.prefix(Metrics.shortLength))
        let headShort = String(next.head.prefix(Metrics.shortLength))
        summaryLabel.stringValue = String(localized: "Comparing \(baseShort) → \(headShort)")
        distanceLabel.stringValue = Self.distanceText(next.distance)
        distanceLabel.isHidden = distanceLabel.stringValue.isEmpty
        filesView.update(next.files)
        filesView.select(path: next.selectedFile?.path)
        let empty =
            next.files.isEmpty && !next.isLoadingFiles
            ? String(localized: "No differences between these commits")
            : String(localized: "Select a file")
        diffView.update(
            next.diff, loading: next.isLoadingFiles || next.isLoadingDiff, blob: false,
            emptyMessage: empty, path: next.selectedFile?.path)
    }

    static func distanceText(_ distance: CommitDistance?) -> String {
        guard let distance, distance.total > 0 else { return "" }
        if distance.isLinear {
            let count = distance.total
            return count == 1
                ? String(localized: "(1 commit apart)")
                : String(localized: "(\(count) commits apart)")
        }
        return String(localized: "(−\(distance.behind) / +\(distance.ahead) commits)")
    }
}
