import AppKit

/// The scrolling list: reuses row views by id, keeps one selection and one hover, and is fully keyboard driven
/// (↑↓ select a row, ←→ a pill in a workspace's card or open and close a summary, ↩/Space act, ⌘C copy the row's
/// link).
@MainActor
final class PanelListView: NSView {
    private(set) var rows: [PanelRow] = []
    private var views: [String: PanelRowView] = [:]
    private(set) var selectedID: String?
    /// The pill chosen in the selected workspace card, if any.
    private(set) var selectedPill: Int?
    private weak var hovered: PanelRowView?
    var onAction: ((PanelAction) -> Void)?
    private(set) var contentHeight: CGFloat = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Theme.panelWidth, height: 44))
        setAccessibilityRole(.list)
        setAccessibilityLabel(String(localized: "Gitā"))
        setAccessibilityIdentifier("panel.list")
    }
    @available(*, unavailable, message: "The panel list is built in code")
    required init?(coder _: NSCoder) { fatalError("The panel list is built in code") }

    func set(_ next: [PanelRow], width: CGFloat) {
        let ids = Set(next.map(\.id))
        for (id, view) in views where !ids.contains(id) {
            view.removeFromSuperview()
            views[id] = nil
        }
        var y: CGFloat = 0
        for row in next {
            let view = views[row.id] ?? makeView(row, width: width)
            view.update(row)
            view.frame = NSRect(x: 0, y: y, width: width, height: row.height)
            view.isSelected = row.id == selectedID
            view.selectedPill = row.id == selectedID ? selectedPill : nil
            y += row.height
        }
        rows = next
        contentHeight = y
        if let selectedID, !ids.contains(selectedID) { resetSelection() }
        setFrameSize(NSSize(width: width, height: max(y, 1)))
        setAccessibilityChildren(next.compactMap { views[$0.id] })
        if let hovered, hovered.superview == nil { self.hovered = nil }
    }

    private func makeView(_ row: PanelRow, width: CGFloat) -> PanelRowView {
        let view = PanelRowView(row, width: width)
        view.onAction = { [weak self] action in self?.onAction?(action) }
        view.onClick = { [weak self] view in
            guard let self, let action = view.row.action else { return }
            self.select(id: view.row.id)
            self.onAction?(action)
        }
        view.onHover = { [weak self] view, inside in self?.hover(view, inside: inside) }
        addSubview(view)
        views[row.id] = view
        return view
    }

    private func hover(_ view: PanelRowView, inside: Bool) {
        if inside {
            hovered?.isHovered = false
            hovered = view
            view.isHovered = true
        } else if hovered === view {
            view.isHovered = false
            hovered = nil
        }
    }

    func resetSelection() {
        selectedID = nil
        selectedPill = nil
    }

    /// Selects a row, and in a workspace's card one of its pills.
    func select(id: String?, pill: Int? = nil) {
        selectedID = id
        selectedPill = pill
        for (key, view) in views {
            view.isSelected = key == id
            view.selectedPill = key == id ? pill : nil
        }
        if let id, let view = views[id] {
            scrollToVisible(view.frame.insetBy(dx: 0, dy: -4))
            NSAccessibility.post(element: view, notification: .focusedUIElementChanged)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let intent = PanelSelection.intent(keyCode: event.keyCode, modifiers: event.modifierFlags),
            perform(intent)
        else {
            super.keyDown(with: event)
            return
        }
    }

    /// Carries out a key's intent; false when it does not apply here (⌘C on a row without a link).
    private func perform(_ intent: PanelSelection.Intent) -> Bool {
        let current = rows.first { $0.id == selectedID }
        switch intent {
        case .move(let step):
            if let id = PanelSelection.moved(rows, from: selectedID, by: step) { select(id: id) }
        case .activate:
            if let action = PanelSelection.action(current, pill: selectedPill) { onAction?(action) }
        case .across(let step):
            if let action = PanelSelection.toggle(current, opening: step > 0) {
                onAction?(action)
            } else if let current {
                select(id: current.id, pill: PanelSelection.pill(current, from: selectedPill, by: step))
            }
        case .copyLink:
            guard let link = current?.link else { return false }
            onAction?(.copy(link))
        }
        return true
    }

    override func draw(_: NSRect) {}
}
