import AppKit
import GitaCore

/// The merge editor's layout: the toolbar, the five columns (three panes, two gutters) under their headers, the
/// versions and message views in the same place, and the footer.
extension MergeEditorView {
    func buildInterface() {
        let toolbar = buildToolbar()
        let footer = buildFooter()
        buildPanes()
        for view in [toolbar, panes, versions, message, footer] as [NSView] {
            addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        var constraints = [
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: Metrics.toolbarHeight),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Metrics.footerHeight),
            message.centerXAnchor.constraint(equalTo: centerXAnchor),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
        ]
        for view in [toolbar, panes, versions, footer] as [NSView] {
            constraints += [
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
            ]
        }
        for view in [panes, versions] as [NSView] {
            constraints += [
                view.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
                view.bottomAnchor.constraint(equalTo: footer.topAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        message.alignment = .centerX
        messageDetail.lineBreakMode = .byWordWrapping
        messageDetail.maximumNumberOfLines = 4
        messageDetail.alignment = .center
    }

    private func buildToolbar() -> NSView {
        applyAllButton.toolTip = String(localized: "Apply every change that conflicts with nothing, from both sides")
        simpleButton.toolTip = String(localized: "Merge every conflict whose sides change different lines or words")
        wordsButton.controlSize = .small
        wordsButton.font = TextLines.system(12)
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = Style.stack(
            [pathLabel, statusLabel, spacer, previousButton, nextButton, applyAllButton, simpleButton, wordsButton],
            spacing: 8)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        let background = ThemedBackgroundView()
        background.color = Theme.toolbar
        Style.fill(bar, in: background)
        return background
    }

    private func buildFooter() -> NSView {
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        errorLabel.setAccessibilityIdentifier("merge.error")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bar = Style.stack([progress, errorLabel, spacer, reloadButton, saveButton])
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        let background = ThemedBackgroundView()
        background.color = Theme.toolbar
        Style.fill(bar, in: background)
        return background
    }

    private func buildPanes() {
        let resultTitle = Style.label(String(localized: "Result"), size: 12, weight: .semibold)
        workingButton.toolTip = String(
            localized: "Put the file as it is in the working tree into the result, as resolved in another editor")
        resetButton.toolTip = String(localized: "Start this file again from the common base")
        let columns: [NSView] = [
            column(header(oursTitle, oursDetail, [oursApplyButton, useOursButton]), oursPane.embedded()),
            column(header(nil, nil, []), leftGutter),
            column(header(resultTitle, resultDetail, [workingButton, resetButton]), resultPane.embedded()),
            column(header(nil, nil, []), rightGutter),
            column(header(theirsTitle, theirsDetail, [useTheirsButton, theirsApplyButton]), theirsPane.embedded()),
        ]
        var constraints: [NSLayoutConstraint] = []
        var leading = panes.leadingAnchor
        for column in columns {
            panes.addSubview(column)
            column.translatesAutoresizingMaskIntoConstraints = false
            constraints += [
                column.leadingAnchor.constraint(equalTo: leading),
                column.topAnchor.constraint(equalTo: panes.topAnchor),
                column.bottomAnchor.constraint(equalTo: panes.bottomAnchor),
            ]
            leading = column.trailingAnchor
        }
        constraints += [
            columns[4].trailingAnchor.constraint(equalTo: panes.trailingAnchor),
            columns[1].widthAnchor.constraint(equalToConstant: MergeGutterView.width),
            columns[3].widthAnchor.constraint(equalToConstant: MergeGutterView.width),
            columns[2].widthAnchor.constraint(equalTo: columns[0].widthAnchor),
            columns[4].widthAnchor.constraint(equalTo: columns[0].widthAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        resultDetail.stringValue = String(localized: "Starts from the common base · editable")
    }

    /// A column's header: its name and what it is, then its buttons.
    private func header(_ title: NSTextField?, _ detail: NSTextField?, _ buttons: [NSButton]) -> NSView {
        let background = ThemedBackgroundView()
        background.color = Theme.toolbar
        guard let title, let detail else { return background }
        detail.lineBreakMode = .byTruncatingTail
        title.lineBreakMode = .byTruncatingTail
        let labels = Style.stack([title, detail], vertical: true, spacing: 1)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = Style.stack([labels, spacer] + buttons, spacing: 6)
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 8)
        Style.fill(stack, in: background)
        return background
    }

    private func column(_ header: NSView, _ content: NSView) -> NSView {
        let column = NSView()
        for view in [header, content] {
            column.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            header.topAnchor.constraint(equalTo: column.topAnchor),
            header.heightAnchor.constraint(equalToConstant: Metrics.headerHeight),
            content.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            content.topAnchor.constraint(equalTo: header.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])
        return column
    }
}
