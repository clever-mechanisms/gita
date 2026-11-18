import AppKit

/// The workspace these tabs belong to: its name at the leading end of the tab bar, with the menu that switches,
/// adds, renames and deletes workspaces, and in the window's title.
extension RepositoryTabsController {
    /// A long name is cut short rather than pushing the tabs away.
    static let workspaceButtonLimit: CGFloat = 200
    private static let workspaceTitleLimit = 22

    /// The name as the button shows it: whole in its tooltip, cut here so the chevron after it stays in view.
    static func buttonTitle(_ title: String) -> String {
        title.count > workspaceTitleLimit ? title.prefix(workspaceTitleLimit - 1) + "…" : title
    }

    func configureWorkspaceButton() {
        workspaceButton.horizontalPadding = 7
        workspaceButton.spacing = 5
        workspaceButton.fixedHeight = 24
        workspaceButton.contentAlignment = .left
        workspaceButton.menuProvider = { [weak self] in self?.workspaceMenu?() }
        workspaceButton.setAccessibilityIdentifier("workspaces.switcher")
        workspaceButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateWorkspaceButton()
    }

    private func updateWorkspaceButton() {
        workspaceButton.parts = [
            .symbol(Deck.workspaceSymbol, color: Theme.secondaryText, size: 12),
            .text(Self.buttonTitle(workspace.title), font: Theme.body, color: Theme.secondaryText),
            .symbol("chevron.down", color: Theme.secondaryText, size: 8),
        ]
        workspaceButton.toolTip = String(localized: "Workspace: \(workspace.title)")
        workspaceButton.setAccessibilityValue(workspace.title)
    }

    /// The workspace's name changed (a rename, or a new interface font to draw it in): the button, the tabs beside
    /// it and the window's title follow.
    func refreshWorkspace() {
        guard isViewLoaded, !isDetached else { return }
        updateWorkspaceButton()
        view.layoutSubtreeIfNeeded()
        strip.relayout()
        refreshTabs()
    }

    /// "repository — Gitā"; a workspace with a name of its own is named too, which tells its window from the others
    /// in the Window menu and Mission Control.
    func windowTitle(repository: String?) -> String {
        switch (repository, workspace.name) {
        case (let repository?, let name?): String(localized: "\(repository) — \(name) — Gitā")
        case (let repository?, nil): String(localized: "\(repository) — Gitā")
        case (nil, let name?): String(localized: "\(name) — Gitā")
        case (nil, nil): "Gitā"
        }
    }
}
