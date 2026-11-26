import AppKit
import GitaCore

extension FilePaneView {
    func applyOrderMode(_ mode: FileOrderMode) {
        guard orderMode != mode else { return }
        orderMode = mode
        narrativePresenter.setMode(mode)
        let useTree = mode == .pathTree && Preference.filesAsTree.bool(defaults)
        for list in allLists { list.showsTree = useTree }
        showChanges(rawChanges, amendStaging: rawAmendStaging)
        showCommitFiles(rawCommitFiles)
    }

    func ordered(_ files: [FileChange]) -> [FileChange] {
        guard orderMode != .pathTree else { return files }
        if orderMode == .narrative {
            narrativePresenter.update(files.map { NarrativeFileEntry($0) })
            return narrativePresenter.groups
                .filter { !narrativePresenter.isCollapsed($0.layer) }
                .flatMap(\.entries)
                .compactMap(\.fileChange)
        }
        return SmartDiffFacade.shared.orderFiles(files, mode: orderMode)
            .flatMap(\.entries)
            .compactMap(\.fileChange)
    }

    func refreshNarrativeHeaders() {
        narrativeHeaders.arrangedSubviews.forEach {
            narrativeHeaders.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        guard orderMode == .narrative, content != .tree else {
            narrativeHeaders.isHidden = true
            return
        }
        let source = content == .localChanges ? rawChanges : rawCommitFiles
        narrativePresenter.update(source.map { NarrativeFileEntry($0) })
        let groups = narrativePresenter.groups
        guard groups.count > 1 else {
            narrativeHeaders.isHidden = true
            return
        }
        for group in groups {
            let header = SmartDiffFacade.shared.makeNarrativeHeaderView(group: group, presenter: narrativePresenter) {
                [weak self] in
                guard let self else { return }
                self.showChanges(self.rawChanges, amendStaging: self.rawAmendStaging)
                self.showCommitFiles(self.rawCommitFiles)
            }
            narrativeHeaders.addArrangedSubview(header)
            header.widthAnchor.constraint(equalTo: narrativeHeaders.widthAnchor).isActive = true
        }
        narrativeHeaders.isHidden = false
    }
}
