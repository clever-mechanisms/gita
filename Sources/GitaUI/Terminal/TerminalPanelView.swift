import AppKit

/// The built-in terminal along the bottom of the main window: a row of tabs (one per terminal, titled by its
/// program), "+" for a new shell in the current repository and a button that hides the panel. Closing a tab hangs
/// its program up; the panel hides itself when its last tab closes.
@MainActor
final class TerminalPanelView: NSView {
    nonisolated static let barHeight: CGFloat = 30
    /// The tab row and a few lines of terminal.
    nonisolated static let minimumHeight: CGFloat = barHeight + 60

    struct Entry {
        let id: UUID
        let terminal: TerminalView
        var title: String
    }

    private(set) var entries: [Entry] = []
    private(set) var selectedID: UUID?
    /// The panel wants to be shown (true) or hidden (false); the window's split view does it.
    var onVisibilityChange: ((Bool) -> Void)?
    /// The folder "+" starts a shell in: the selected repository.
    var currentDirectory: () -> URL? = { nil }
    /// Where the height the user drags the panel to is remembered.
    var defaults = Preference.store
    /// True while the app itself shows, hides or places the panel: those resizes are not the user's.
    var isPlacing = false
    /// Builds a terminal; tests replace it so nothing runs.
    var makeTerminal: (URL, TerminalSession.Launch) -> TerminalView = { directory, launch in
        TerminalView(session: TerminalSession(directory: directory, launch: launch))
    }

    private let tabRow = Deck.hstack([], spacing: 2)
    private let host = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let add = PartsButton(
            [.symbol("plus", color: Theme.secondaryText, size: 12)], accessibility: String(localized: "New Terminal")
        ) { [weak self] in self?.openShell() }
        add.toolTip = String(localized: "New Terminal")
        let hide = PartsButton(
            [.symbol("chevron.down", color: Theme.secondaryText, size: 11)],
            accessibility: String(localized: "Hide Terminal")
        ) { [weak self] in self?.onVisibilityChange?(false) }
        hide.toolTip = String(localized: "Hide Terminal")
        let bar = Deck.hstack([tabRow, add, Deck.spacer(), hide], spacing: 4)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        // The repository tab strip's colour, so the panel's tabs read as part of the window.
        let barBackground = FillView(color: Theme.tabBar)
        Deck.pin(bar, in: barBackground)
        barBackground.heightAnchor.constraint(equalToConstant: Self.barHeight).isActive = true
        let column = Deck.vstack([barBackground, Deck.separator(), host], spacing: 0)
        column.distribution = .fill
        Deck.pin(column, in: self)
        for view in column.arrangedSubviews { view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Terminal"))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("TerminalPanelView is built in code") }

    var selected: Entry? { entries.first { $0.id == selectedID } }
    /// The terminals whose program would end if the panel closed now.
    var openCount: Int { entries.filter { $0.terminal.session.isOpen }.count }

    /// A new terminal in `directory` running `launch`, selected, with the panel shown.
    @discardableResult
    func open(_ directory: URL, launch: TerminalSession.Launch = .shell) -> Entry {
        let terminal = makeTerminal(directory, launch)
        let entry = Entry(id: UUID(), terminal: terminal, title: Self.title(directory, launch: launch))
        entries.append(entry)
        terminal.session.onTitle = { [weak self] title in self?.retitle(entry.id, title) }
        Deck.pin(terminal, in: host)
        onVisibilityChange?(true)
        select(entry.id)
        return entry
    }

    /// "+": a shell in the selected repository.
    func openShell() {
        guard let directory = currentDirectory() else {
            NSSound.beep()
            return
        }
        open(directory)
    }

    func select(_ id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        selectedID = id
        for entry in entries { entry.terminal.isHidden = entry.id != id }
        rebuildTabs()
        selected?.terminal.focus()
    }

    /// Closes a terminal and hangs its program up; the next one is selected, or the panel hides.
    func close(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let entry = entries.remove(at: index)
        entry.terminal.session.terminate()
        entry.terminal.removeFromSuperview()
        if entries.isEmpty {
            selectedID = nil
            rebuildTabs()
            onVisibilityChange?(false)
        } else if selectedID == id {
            select(entries[min(index, entries.count - 1)].id)
        } else {
            rebuildTabs()
        }
    }

    /// Every terminal closes (the window is closing).
    func closeAll() {
        for entry in entries { close(entry.id) }
    }

    /// The tab's name until the program sets a title: the folder, or "Review · folder" for a review.
    static func title(_ directory: URL, launch: TerminalSession.Launch) -> String {
        let folder = directory.lastPathComponent
        return launch == .shell ? folder : String(localized: "Review · \(folder)")
    }

    private func retitle(_ id: UUID, _ title: String) {
        guard !title.isEmpty, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].title = title
        rebuildTabs()
    }

    private func rebuildTabs() {
        tabRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for entry in entries { tabRow.addArrangedSubview(tab(entry)) }
    }

    /// One tab: its title (choosing it) and a close button.
    private func tab(_ entry: Entry) -> NSView {
        let isSelected = entry.id == selectedID
        let title = PartsButton(
            [
                .symbol("apple.terminal", color: Theme.secondaryText, size: 11),
                .text(entry.title, font: Theme.caption, color: isSelected ? Theme.text : Theme.secondaryText),
            ], background: isSelected ? .selected : .hover, accessibility: entry.title
        ) { [weak self] in self?.select(entry.id) }
        title.toolTip = entry.terminal.session.directory.path
        title.widthAnchor.constraint(lessThanOrEqualToConstant: 240).isActive = true
        let close = PartsButton(
            [.symbol("xmark", color: Theme.secondaryText, size: 9)],
            accessibility: String(localized: "Close \(entry.title)")
        ) { [weak self] in self?.close(entry.id) }
        close.horizontalPadding = 4
        close.toolTip = String(localized: "Close Terminal")
        return Deck.hstack([title, close], spacing: 0)
    }
}

/// The split view the panel sits in tells it when the user drags the divider: that height, as a share of the
/// window's, is the one it opens at next time.
extension TerminalPanelView: NSSplitViewDelegate {
    func splitViewDidResizeSubviews(_ notification: Notification) {
        // AppKit names the divider when it moved (a window resize names none); the app's own moves are skipped.
        guard notification.userInfo?["NSSplitViewDividerIndex"] != nil, !isHidden, !isPlacing,
            let split = notification.object as? NSSplitView, split.bounds.height > 0
        else { return }
        Preference.terminalPanelShare.set(Double(frame.height / split.bounds.height), defaults)
    }
}

/// The terminal panel's height: a share of the window's content height, 30% until the user drags it elsewhere.
enum TerminalPanelHeight {
    static let defaultShare = 0.3
    /// The repository keeps at least this much above the panel.
    static let repositoryMinimum: CGFloat = 200

    /// The panel's height in `total` points for a remembered `share` (kept between 10% and 90%), never below the
    /// panel's minimum nor above what leaves the repository its own.
    static func height(share: Double, in total: CGFloat) -> CGFloat {
        let fraction = share.isFinite ? min(max(share, 0.1), 0.9) : defaultShare
        let minimum = TerminalPanelView.minimumHeight
        return min(max(total * CGFloat(fraction), minimum), max(total - repositoryMinimum, minimum))
    }
}

/// Where "Open in Terminal" and "Review with …" send the built-in terminal: the main window's panel. The app delegate
/// sets `open` at launch (it shows the window first); until then nothing opens.
@MainActor
enum BuiltInTerminal {
    static var open: (_ directory: URL, _ launch: TerminalSession.Launch) -> Void = { _, _ in }
}
