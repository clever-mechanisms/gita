import AppKit
import GitaCore

@MainActor
final class FlightDiffPane: NSView {
    private let presenter: FlightRecorderPresenter
    let files = AgentControlList(title: String(localized: "Changed files"), id: "flight.files")
    let diff = DiffView()
    private let banner = AgentControlUI.truncationCaption()
    private lazy var hunks = AgentControlUI.popup(
        String(localized: "Hunk"), "flight.hunks", target: self,
        action: #selector(selectHunk))
    private lazy var restore = AgentControlUI.button(String(localized: "Restore Hunk"), "flight.restoreHunk") {
        [weak self] in self?.restoreHunk()
    }

    init(_ presenter: FlightRecorderPresenter) {
        self.presenter = presenter
        super.init(frame: .zero)
        let right = AgentControlUI.column([Deck.hstack([hunks, Deck.spacer(), restore]), banner, diff])
        Style.fill(AgentControlUI.split(files.scroll, right), in: self)
        AgentControlUI.identify(diff, "flight.diff")
        files.table.nextKeyView = hunks
        hunks.nextKeyView = restore
        restore.nextKeyView = diff.table
        files.onSelect = { [weak self] index in
            guard let self, let paths = self.presenter.diff?.files, paths.indices.contains(index) else { return }
            self.presenter.selectFile(paths[index])
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Programmatic view") }

    func render() {
        let paths = presenter.diff?.files ?? []
        let items = paths.enumerated().map { index, path in
            AgentControlList.Item(
                title: path,
                makeAction: { [weak self] in
                    let button = AgentControlUI.button(
                        String(localized: "Restore File"), "flight.restoreFile.\(index)", style: .hover
                    ) {
                        [weak self] in self?.presenter.restoreFile(path, on: self?.window)
                    }
                    button.setAccessibilityLabel(String(localized: "Restore \(path)"))
                    return button
                })
        }
        files.update(items, selected: paths.firstIndex { $0 == presenter.selectedFile })
        let patch = presenter.patch
        hunks.removeAllItems()
        for hunk in patch?.document.hunks ?? [] {
            hunks.addItem(withTitle: String(localized: "Hunk \(hunk.index + 1)"))
        }
        if let index = presenter.selectedHunkIndex { hunks.selectItem(at: index) }
        hunks.isEnabled = hunks.numberOfItems > 0
        restore.isEnabled =
            hunks.isEnabled && presenter.effectiveComparison == .workingTree && presenter.diff?.isTruncated == false
            && patch?.document.canApplyHunks == true
        let fallback =
            paths.isEmpty
            ? String(localized: "No changes between these versions.")
            : String(localized: "The file patch is outside the preview.")
        let selected = presenter.selectedHunkIndex.flatMap { index -> String? in
            guard let hunks = patch?.document.hunks, hunks.indices.contains(index) else { return nil }
            return hunks[index].patch
        }
        banner.isHidden = presenter.diff?.isTruncated != true
        diff.update(selected ?? patch?.text ?? "", loading: false, emptyMessage: fallback, path: presenter.selectedFile)
    }

    @objc private func selectHunk() { presenter.selectHunk(hunks.indexOfSelectedItem) }

    private func restoreHunk() {
        guard let path = presenter.selectedFile, let index = presenter.selectedHunkIndex,
            let expected = presenter.patch?.text
        else { return }
        presenter.restoreHunk(path: path, hunkIndex: index, expectedDiff: expected, on: window)
    }
}
