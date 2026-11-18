import AppKit

/// The built-in terminal panel under the repository: the window's content and the panel share a split view, the
/// panel hidden until a terminal opens in it. It stays across repository tabs; closing the window closes its terminals
/// (`AppDelegate.mainWindowWillClose`).
extension RepositoryTabsController {
    /// Puts `body` and the terminal panel in a split view under the tab bar (drawn below it, so repository drawing
    /// stays under the tab controls even when a child invalidates beyond its bounds).
    func installTerminalPanel(body: NSView, below bar: NSView) {
        let split = DeckSplitView()
        view.addSubview(split, positioned: .below, relativeTo: bar)
        split.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.topAnchor.constraint(equalTo: bar.bottomAnchor),
            split.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(body)
        split.addArrangedSubview(terminalPanel)
        // A window resize goes to the repository; the panel keeps the height it was given.
        split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        split.setHoldingPriority(.defaultLow + 10, forSubviewAt: 1)
        terminalPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: TerminalPanelView.minimumHeight)
            .isActive = true
        split.delegate = terminalPanel
        terminalPanel.isHidden = true
        terminalPanel.currentDirectory = { [weak self] in self?.selectedRepository }
        terminalPanel.onVisibilityChange = { [weak self, weak split] shown in
            guard let self, let split else { return }
            self.setTerminalPanelShown(shown, in: split)
        }
    }

    var isTerminalPanelShown: Bool { !terminalPanel.isHidden }

    /// View ▸ Terminal: shows the panel (with a shell in the selected repository when it has no terminal yet) or
    /// hides it; its terminals keep running while hidden.
    func toggleTerminalPanel() {
        if isTerminalPanelShown {
            terminalPanel.onVisibilityChange?(false)
        } else if terminalPanel.entries.isEmpty {
            terminalPanel.openShell()
        } else {
            terminalPanel.onVisibilityChange?(true)
            terminalPanel.selected?.terminal.focus()
        }
    }

    private func setTerminalPanelShown(_ shown: Bool, in split: NSSplitView) {
        guard shown == terminalPanel.isHidden else { return }
        terminalPanel.isPlacing = true
        defer { terminalPanel.isPlacing = false }
        terminalPanel.isHidden = !shown
        split.adjustSubviews()
        if shown {
            split.layoutSubtreeIfNeeded()
            let height = TerminalPanelHeight.height(
                share: Preference.terminalPanelShare.double(terminalPanel.defaults), in: split.bounds.height)
            split.setPosition(split.bounds.height - height - split.dividerThickness, ofDividerAt: 0)
        } else if let window = view.window, terminalPanel.isAncestorOrSelf(of: window.firstResponder) {
            window.makeFirstResponder(nil)
        }
    }
}

extension NSView {
    /// True when `responder` is this view or inside it.
    fileprivate func isAncestorOrSelf(of responder: NSResponder?) -> Bool {
        guard let view = responder as? NSView else { return false }
        return view === self || view.isDescendant(of: self)
    }
}
