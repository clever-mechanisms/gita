import AppKit
import GitaCore

/// The opened row: the session's facts, then what to do with it.
@MainActor
final class PaneDetail: NSView {
    init(row: AgentsPaneView.Row, owner: @escaping () -> AgentsPaneView?, now: Date = Date()) {
        super.init(frame: .zero)
        let views: [NSView] = [Self.grid(PaneFacts.make(row, now: now)), WrapRow(Self.actions(row, owner: owner))]
        let stack = Deck.vstack(views, spacing: 10)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 12, right: 12)
        for view in views {
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -26).isActive = true
        }
        Deck.pin(stack, in: self)
    }
    @available(*, unavailable, message: "Pane details are built in code")
    required init?(coder _: NSCoder) { fatalError("Pane details are built in code") }

    /// Show in the agent's app (only when it is known: naming it beats a vague "terminal"), Show in History, open in
    /// the terminal and editor, and open in a new tab unless this window already shows the checkout.
    private static func actions(_ row: AgentsPaneView.Row, owner: @escaping () -> AgentsPaneView?) -> [NSView] {
        let folder = URL(fileURLWithPath: row.checkoutPath, isDirectory: true)
        var actions: [NSView] = []
        if let session = row.session, let host = WindowAgents.shared.hostApp(session) {
            let reveal = PartsButton.app(String(localized: "Show in \(host.name)"), icon: host.icon, filled: true) {
                owner()?.onReveal?(session)
            }
            reveal.toolTip = String(localized: "Switches to the \(host.name) tab where this agent runs.")
            actions.append(reveal)
        }
        actions.append(
            PartsButton.app(
                String(localized: "Show in History"),
                icon: Deck.symbol(Section.history.symbol, size: 13, color: Theme.secondaryText)
            ) { owner()?.onShowInHistory?(row) })
        if let terminal = OpenIn.terminalChoice() {
            let name = terminal.name
            let button = PartsButton.app(String(localized: "Open in \(name)"), icon: terminal.icon) {
                OpenIn.terminal(folder)
            }
            button.toolTip = String(localized: "Opens a new \(name) window in this folder.")
            actions.append(button)
        }
        if let editor = OpenIn.editorApp {
            let name = OpenIn.name(editor)
            let button = PartsButton.app(
                String(localized: "Open in \(name)"), icon: NSWorkspace.shared.icon(forFile: editor.path)
            ) { OpenIn.editor(folder) }
            button.toolTip = String(localized: "Opens this folder in \(name).")
            actions.append(button)
        }
        if !row.isOpenHere {
            let button = PartsButton.app(
                String(localized: "Open in New Tab"),
                icon: Deck.symbol("plus.square.on.square", size: 13, color: Theme.secondaryText)
            ) { owner()?.onOpenCheckout?(folder) }
            button.toolTip = String(localized: "Opens this checkout in a new Gitā tab.")
            actions.append(button)
        }
        return actions
    }

    /// Paths stay on one line, middle-truncated with the full path as tooltip (wrapping split names mid-word).
    private static func grid(_ facts: [PaneFacts.Fact]) -> NSView {
        let grid = NSGridView(
            views: facts.map { fact -> [NSView] in
                let value: NSTextField
                if fact.isPath {
                    value = Deck.label(fact.value, font: Theme.mono)
                    value.lineBreakMode = .byTruncatingMiddle
                    value.toolTip = fact.value
                } else {
                    value = Deck.wrapping(fact.value, font: Theme.body, characterWrap: false)
                }
                value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let name = Deck.label(fact.name, color: Theme.secondaryText)
                name.setContentCompressionResistancePriority(.required, for: .horizontal)
                return [name, value]
            })
        grid.rowSpacing = 3
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .leading
        return grid
    }
}
