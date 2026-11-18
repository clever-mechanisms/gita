import AppKit

/// The Setup Guide sheet: a rail of steps on the left; on the right each step's heading, then its options, each with
/// an animated scene of what it does, or a scene across the page (the tools checklist on the Tools step). The choices
/// are a draft until Finish; Skip or Cancel drops them.
@MainActor
final class SetupGuideController: NSWindowController, NSWindowDelegate {
    static let preferredSize = NSSize(width: 920, height: 680)

    /// The guide's lifecycle: built, shown as a sheet, ended by Finish or by Skip or Cancel (the sheet stays until
    /// it is dismissed), then dismissed. Only a built guide is presented; only a built or shown one takes input.
    enum Phase: Equatable {
        case built, presented, finished, cancelled, dismissed
    }

    var draft: SetupChoices
    let firstRun: Bool
    private let onFinish: @MainActor (SetupChoices) -> Void
    private let onCancel: @MainActor () -> Void
    let checklistEnvironment: SetupChecklistEnvironment
    let heading = Style.label("", size: 24, weight: .bold, color: Theme.text)
    let subtitle = NSTextField(wrappingLabelWithString: "")
    let position = Style.label("", size: 12, color: Theme.secondaryText)
    let bodyScroll = NSScrollView()
    let body = NSStackView()
    lazy var zoomOut = button("", id: "zoomOut", symbol: "minus", action: #selector(reduceZoom))
    lazy var zoomIn = button("", id: "zoomIn", symbol: "plus", action: #selector(increaseZoom))
    lazy var zoomValue = button(String(localized: "100%"), id: "zoomReset", action: #selector(resetZoom))
    lazy var backButton = button(String(localized: "Back"), id: "back", action: #selector(back))
    lazy var nextButton = button(String(localized: "Continue"), id: "continue", action: #selector(continueGuide))
    lazy var cancelButton = button(
        firstRun ? String(localized: "Skip") : String(localized: "Cancel"), id: "cancel",
        action: #selector(cancelGuide))
    var cardButtons: [SetupCardButton] = []
    /// The page's scenes; they move on together.
    private(set) var stages: [SetupStageView] = []
    private(set) var options: SetupOptionsView?
    private(set) var checklist: SetupChecklistView?
    private(set) var card: SetupGuideCard = .welcome
    private weak var parentWindow: NSWindow?
    private(set) var phase = Phase.built
    private var loopTask: Task<Void, Never>?
    var lastInteraction = Date.distantPast
    private let observations = SetupObservationBag()
    /// Whether the scene may move on its own; tests, with no window on screen, answer it.
    var showsMotion: (NSWindow?, NSWindow?) -> Bool = { SetupGuideController.isMotionVisible(window: $0, parent: $1) }
    /// How long each scene step stays before the next.
    var demoStep = Duration.seconds(1.6)
    /// The guide still takes input: not finished, skipped or dismissed.
    var isOpen: Bool { phase == .built || phase == .presented }
    private var isPresented: Bool { phase == .presented }

    init(
        choices: SetupChoices, firstRun: Bool,
        onFinish: @escaping @MainActor (SetupChoices) -> Void,
        onCancel: @escaping @MainActor () -> Void,
        checklist: SetupChecklistEnvironment = SetupChecklistEnvironment()
    ) {
        draft = choices
        draft.historyZoomPercent = HistoryZoom.bounded(choices.historyZoomPercent)
        self.firstRun = firstRun
        self.onFinish = onFinish
        self.onCancel = onCancel
        checklistEnvironment = checklist
        let window = SetupGuideWindow(
            contentRect: NSRect(origin: .zero, size: Self.preferredSize), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = String(localized: "Setup Guide")
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = true
        super.init(window: window)
        window.delegate = self
        window.onHistoryShortcut = { [weak self] key in self?.handleHistoryShortcut(key) ?? false }
        buildInterface()
        show(.welcome, focusSelector: false)
    }
    @available(*, unavailable, message: "The Setup Guide is built in code")
    required init?(coder _: NSCoder) { fatalError("The Setup Guide is built in code") }
    isolated deinit { loopTask?.cancel() }

    func present(on parent: NSWindow) {
        guard phase == .built, let window else { return }
        phase = .presented
        parentWindow = parent
        fitWindow()
        observeActivity(parent: parent, window: window)
        parent.beginSheet(window) { [weak self] _ in self?.stopActivity() }
        checklist?.start()
        focus(card, selector: true)
        refreshDemoActivity()
    }
    func dismiss() {
        guard phase != .dismissed else { return }
        phase = .dismissed
        stopActivity()
        releasePage()
        guard let window else { return }
        window.delegate = nil
        if let parent = window.sheetParent { parent.endSheet(window) }
        window.orderOut(nil)
        parentWindow = nil
    }

    // MARK: Steps

    func show(_ next: SetupGuideCard, focusSelector: Bool) {
        guard isOpen else { return }
        stopLoop()
        releasePage()
        card = next
        heading.stringValue = next.heading
        subtitle.stringValue = next.subtitle
        position.stringValue = String(localized: "\(next.rawValue + 1) of \(SetupGuideCard.allCases.count)")
        if next == .tools {
            addPage(makeChecklist())
        } else {
            if let scene = next.pageScene {
                let stage = SetupStageView(scene: scene, choices: draft, title: next.heading)
                stages.append(stage)
                addPage(stage, height: scene.pageHeight)
            }
            addPage(next == .ready ? SetupShortcutsView() : makeOptions(next))
        }
        updateRail()
        backButton.isEnabled = next != .welcome
        nextButton.title = next == .ready ? String(localized: "Finish") : String(localized: "Continue")
        nextButton.setAccessibilityIdentifier(next == .ready ? "setup.finish" : "setup.continue")
        syncChoices()
        bodyScroll.contentView.scroll(to: .zero)
        bodyScroll.reflectScrolledClipView(bodyScroll.contentView)
        if isPresented { focus(next, selector: focusSelector) }
        lastInteraction = Date.distantPast
        refreshDemoActivity()
    }
    private func addPage(_ page: NSView, height: CGFloat? = nil) {
        body.addArrangedSubview(page)
        page.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        if let height { page.heightAnchor.constraint(equalToConstant: height).isActive = true }
    }
    private func makeChecklist() -> NSView {
        var environment = checklistEnvironment
        environment.useOrca = { [weak self] in self?.draft[.useOrca] ?? false }
        let tools = SetupChecklistView(environment: environment)
        checklist = tools
        if isPresented { tools.start() }
        return tools
    }
    private func makeOptions(_ next: SetupGuideCard) -> NSView {
        let view = SetupOptionsView(card: next, choices: draft, zoom: next == .history ? zoomControl() : nil)
        view.onChange = { [weak self] preference, on in self?.setChoice(preference, on) }
        options = view
        stages += view.stages
        return view
    }
    private func focus(_ next: SetupGuideCard, selector: Bool) {
        window?.recalculateKeyViewLoop()
        if selector || checklist != nil {
            window?.makeFirstResponder(cardButtons[next.rawValue])
        } else {
            window?.makeFirstResponder(nextButton)
        }
    }
    private func releasePage() {
        checklist?.stop()
        checklist = nil
        for stage in stages { stage.stop() }
        stages = []
        options?.onChange = nil
        options = nil
        for view in body.arrangedSubviews {
            body.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
    func syncChoices() {
        zoomValue.title = String(localized: "\(draft.historyZoomPercent)%")
        zoomOut.isEnabled = HistoryZoom.canZoomOut(draft.historyZoomPercent)
        zoomIn.isEnabled = HistoryZoom.canZoomIn(draft.historyZoomPercent)
        for stage in stages { stage.choices = draft }
        options?.update(draft)
    }
    func fitWindow() {
        guard let window, phase != .dismissed else { return }
        let parent = parentWindow ?? NSApp.mainWindow
        let visible =
            (parent?.screen ?? window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_400, height: 900)
        let parentSize = parent?.contentLayoutRect.size ?? visible.size
        let desired = NSSize(
            width: min(Self.preferredSize.width, visible.width - 40, max(parentSize.width - 24, 720)),
            height: min(Self.preferredSize.height, visible.height - 50, max(parentSize.height - 24, 520)))
        guard window.contentView?.frame.size != desired else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: desired))
        frame.origin = NSPoint(x: (parent?.frame.midX ?? window.frame.midX) - frame.width / 2, y: window.frame.maxY)
        frame.origin.y -= frame.height
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: isPresented, animate: false)
    }

    // MARK: Scene activity

    private func observeActivity(parent: NSWindow, window: NSWindow) {
        let normal = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observe(normal, name: name, object: nil)
        }
        for observedWindow in [parent, window] {
            for name in [
                NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification, NSWindow.didChangeScreenNotification,
            ] {
                observe(normal, name: name, object: observedWindow)
            }
        }
        observe(
            NSWorkspace.shared.notificationCenter, name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
    }
    private func observe(_ center: NotificationCenter, name: Notification.Name, object: Any?) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fitWindow()
                self?.refreshDemoActivity()
            }
        }
        observations.add(center, token: token)
    }
    /// Gita is in front, the guide is key and visible over a visible parent, and motion is not reduced.
    static func isMotionVisible(window: NSWindow?, parent: NSWindow?) -> Bool {
        guard NSApp.isActive, let window, window.isVisible, window.isKeyWindow,
            window.occlusionState.contains(.visible), parent?.isVisible == true
        else { return false }
        return !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    private var canProgress: Bool {
        guard isPresented, showsMotion(window, parentWindow), let stage = stages.first,
            stage.superview != nil, !stage.isHiddenOrHasHiddenAncestor
        else { return false }
        return true
    }
    func refreshDemoActivity() {
        guard canProgress else {
            stopLoop()
            return
        }
        guard loopTask == nil else { return }
        let step = demoStep
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: step) } catch { return }
                // `stopLoop` cancels on the main actor, so a step woken after it sees the cancellation here.
                guard !Task.isCancelled, let self else { return }
                guard self.canProgress else {
                    self.stopLoop()
                    return
                }
                if Date().timeIntervalSince(self.lastInteraction) >= 2 { self.stages.forEach { $0.advance() } }
            }
        }
    }
    private func stopLoop() {
        loopTask?.cancel()
        loopTask = nil
    }
    func stopActivity() {
        stopLoop()
        observations.removeAll()
        for stage in stages { stage.stop() }
        checklist?.stop()
        (window as? SetupGuideWindow)?.onHistoryShortcut = nil
    }
    func windowDidBecomeKey(_: Notification) { refreshDemoActivity() }
    func windowDidResignKey(_: Notification) { refreshDemoActivity() }
    func windowDidChangeOcclusionState(_: Notification) { refreshDemoActivity() }

    // MARK: Finishing

    func moveCard(_ amount: Int, focusSelector: Bool) {
        guard let next = SetupGuideCard(rawValue: card.rawValue + amount) else { return }
        show(next, focusSelector: focusSelector)
    }
    @objc func continueGuide() {
        guard isOpen else { return }
        if card != .ready {
            moveCard(1, focusSelector: false)
            return
        }
        phase = .finished
        stopActivity()
        disableCompletionControls()
        onFinish(draft)
    }
    @objc func cancelGuide() {
        guard isOpen else { return }
        phase = .cancelled
        stopActivity()
        disableCompletionControls()
        onCancel()
    }
    private func disableCompletionControls() {
        for control in [backButton, nextButton, cancelButton, zoomOut, zoomIn, zoomValue] { control.isEnabled = false }
        for button in cardButtons { button.isEnabled = false }
        for tile in options?.tiles.values.map({ $0 }) ?? [] { tile.toggle?.isEnabled = false }
    }
    override func close() { cancelGuide() }
    override func cancelOperation(_: Any?) { cancelGuide() }
    func windowShouldClose(_: NSWindow) -> Bool {
        if phase == .dismissed { return true }
        cancelGuide()
        return false
    }
    func windowWillClose(_: Notification) {
        if phase != .dismissed { cancelGuide() }
        stopActivity()
    }
}
