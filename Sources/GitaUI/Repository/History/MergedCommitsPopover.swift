import AppKit

/// The list of commits a merge brought in, in a popover on the merge's chip. Opened by a click it stays until a click
/// elsewhere or Escape; opened by hover (Settings › Git) it closes once the pointer leaves the chip and the list.
/// While it is open the pointer is checked against both directly: cell enter/exit pairs are lost whenever rows are
/// reconfigured under the pointer (reloads, scrolling).
@MainActor
final class MergedCommitsPopover: NSObject {
    /// How often the pointer is checked while the list is open.
    static let hoverInterval: TimeInterval = 0.1
    /// The pointer may leave for this long before a hover-opened list closes.
    static let closeDelay: TimeInterval = 0.4
    /// A click this soon after the list closed is the click that closed it.
    static let reopenGuard: TimeInterval = 0.3
    /// The chip's hit area grows by this much while the pointer moves to the list.
    private static let anchorSlack: CGFloat = 3

    /// Whether lists open on hover (Settings › Git › Merged commits open on hover).
    var opensOnHover: () -> Bool = { Preference.mergedCommitsOn.string() == "hover" }
    /// The system uptime (injected by tests).
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var pointer: () -> NSPoint = { NSEvent.mouseLocation }
    /// The commit ID a chip's view shows now (nil for a view that shows none).
    var representedCommit: (NSView) -> String? = { ($0 as? HistoryCommitCell)?.representedCommitID }

    private var popover: NSPopover?
    private(set) var shownID: String?
    private var followsHover = false
    private var closed: (id: String, uptime: TimeInterval)?
    private var closeWork: DispatchWorkItem?
    private var hoverWatch: Timer?
    private weak var anchorView: NSView?
    private var anchorRect = NSRect.zero
    private var anchorScreenRect = NSRect.zero

    var isShown: Bool { popover?.isShown == true }

    /// The chip was clicked: toggles a click-opened list, ignores the click that just closed it.
    func chipClicked(_ id: String, rect: NSRect, in view: NSView, list: () -> MergedCommitsView?) {
        if isShown, shownID == id {
            if !followsHover {
                closeWork?.cancel()
                popover?.close()
            }
            return
        }
        if let closed, closed.id == id, now() - closed.uptime < Self.reopenGuard { return }
        show(id, rect: rect, in: view, list: list)
    }

    /// The pointer entered a chip (lists open on hover).
    func chipHovered(_ id: String, rect: NSRect, in view: NSView, list: () -> MergedCommitsView?) {
        guard opensOnHover() else { return }
        show(id, rect: rect, in: view, list: list)
    }

    /// The pointer left a chip.
    func chipHoverEnded() {
        if opensOnHover() { scheduleClose() }
    }

    func show(_ id: String, rect: NSRect, in view: NSView, list make: () -> MergedCommitsView?) {
        closeWork?.cancel()
        if isShown, shownID == id { return }
        popover?.close()
        guard let list = make() else { return }
        let hover = opensOnHover()
        if hover {
            list.onHover = { [weak self] inside in
                if inside { self?.closeWork?.cancel() } else { self?.scheduleClose() }
            }
        }
        // One popover for the window's lifetime: moving from merge to merge swaps its content instead of creating a
        // popover and its window each time.
        let popover = popover ?? makePopover()
        popover.behavior = hover ? .semitransient : .transient
        followsHover = hover
        popover.animates = !Deck.reduceMotion
        popover.contentViewController?.view = list
        popover.contentSize = list.fittingSize
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
        self.popover = popover
        shownID = id
        anchorView = view
        anchorRect = rect
        anchorScreenRect = Self.screenRect(rect, in: view) ?? .zero
        watchHover()
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.contentViewController = NSViewController()
        NotificationCenter.default.addObserver(
            self, selector: #selector(popoverDidClose), name: NSPopover.didCloseNotification, object: popover)
        return popover
    }

    @objc private func popoverDidClose(_: Notification) {
        if let shownID { closed = (shownID, now()) }
    }

    func close() {
        closeWork?.cancel()
        popover?.close()
    }

    /// The tab is going away: no timer, scheduled close or observer outlives it.
    func invalidate() {
        close()
        stopWatching()
        closeWork = nil
        if let popover {
            NotificationCenter.default.removeObserver(self, name: NSPopover.didCloseNotification, object: popover)
        }
        popover = nil
    }

    private static func screenRect(_ rect: NSRect, in view: NSView) -> NSRect? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(view.convert(rect, to: nil))
    }

    private func watchHover() {
        guard hoverWatch == nil else { return }
        let timer = Timer(timeInterval: Self.hoverInterval, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated { self.checkHover() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverWatch = timer
    }

    private func stopWatching() {
        hoverWatch?.invalidate()
        hoverWatch = nil
    }

    /// Closes the list when its chip moved or shows another commit, and (hover) once the pointer left both.
    func checkHover() {
        guard let popover, popover.isShown else {
            stopWatching()
            return
        }
        guard let anchor = currentAnchor() else {
            closeWork?.cancel()
            popover.close()
            return
        }
        guard followsHover else { return }
        if isPointerInside(anchor, popover: popover) {
            closeWork?.cancel()
            closeWork = nil
        } else if closeWork?.isCancelled ?? true {
            scheduleClose()
        }
    }

    /// The chip's place on screen while it is where the list opened and still shows the merge (else nil).
    private func currentAnchor() -> NSRect? {
        guard let view = anchorView, let anchor = Self.screenRect(anchorRect, in: view), anchor == anchorScreenRect
        else { return nil }
        return representedCommit(view).map { $0 == shownID } ?? true ? anchor : nil
    }

    private func isPointerInside(_ anchor: NSRect, popover: NSPopover) -> Bool {
        let pointer = pointer()
        if anchor.insetBy(dx: -Self.anchorSlack, dy: -Self.anchorSlack).contains(pointer) { return true }
        return popover.contentViewController?.view.window?.frame.contains(pointer) ?? false
    }

    private func scheduleClose() {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.closeWork = nil
            self?.popover?.close()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDelay, execute: work)
    }
}
