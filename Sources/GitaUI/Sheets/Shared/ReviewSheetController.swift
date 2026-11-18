import AppKit

/// The lifecycle every review sheet shares: the first read starts when the sheet is shown, a running mutation keeps
/// it open (close and quit are refused and the status says why), unsaved edits ask before they are discarded, and
/// closing ends the sheet on its parent window. Subclasses supply their form, their reads and their state.
@MainActor
class ReviewSheetController: NSWindowController, NSWindowDelegate {
    /// What a discard confirmation says, and which button is the safe one.
    struct DiscardPrompt {
        var message: String
        var information: String
        var closeTitle: String
        var quitTitle: String
        /// Keep Editing comes first; otherwise the discard button leads, without the Return key.
        var keepEditingFirst: Bool
    }
    /// Shows an alert on the sheet; replaced in tests to answer it without a run loop.
    typealias AlertPresenter = (NSAlert, NSWindow, @escaping @MainActor (NSApplication.ModalResponse) -> Void) -> Void
    var presentAlert: AlertPresenter = { alert, window, handler in
        alert.beginSheetModal(for: window) { response in MainActor.assumeIsolated { handler(response) } }
    }
    private(set) var activity = SheetActivity.built

    var isApplying: Bool { activity.isApplying }

    init(sheet: NSWindow) {
        super.init(window: sheet)
        sheet.delegate = self
    }
    @available(*, unavailable, message: "Review sheets are built in code")
    required init?(coder _: NSCoder) { fatalError("Review sheets are built in code") }

    // MARK: Subclass hooks

    /// The sheet is on screen for the first time: start its reads.
    func sheetDidPresent() {}
    /// Cancels reads in flight; called when the sheet closes.
    func cancelLoads() {}
    /// Applies the current state to the controls.
    func updateControls() {}
    /// The sheet is about to end.
    func sheetWillFinish() {}
    /// True while closing must wait (a mutation is running).
    var blocksClose: Bool { activity.isApplying }
    /// Closing would lose edits; `discardPrompt` asks first.
    var hasUnsavedChanges: Bool { false }
    var discardPrompt: DiscardPrompt? { nil }
    /// A close or quit was refused: the status explains it.
    func closeRefused() {
        activity.refuseClose()
        updateControls()
    }

    // MARK: Presentation

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        presented()
    }
    func windowDidBecomeKey(_: Notification) { presented() }
    private func presented() {
        if activity.present() { sheetDidPresent() }
    }

    func bind(_ control: NSControl, _ action: Selector) {
        control.target = self
        control.action = action
    }

    /// Starts a read once the sheet is active: cancels the reads in flight, lets `begin` mark the state as loading,
    /// and hands the result to `deliver` (then refreshes the controls) unless the sheet is finishing by then.
    func startLoad<Value>(
        _ loads: LatestTask, _ work: @escaping @MainActor () async throws -> Value, begin: () -> Void,
        then deliver: @escaping @MainActor (Result<Value, any Error>) -> Void
    ) {
        guard activity.isActive else { return }
        cancelLoads()
        begin()
        updateControls()
        loads.run(work) { [weak self] result in
            guard let self, !self.activity.isFinishing else { return }
            deliver(result)
            self.updateControls()
        }
    }

    // MARK: Applying

    /// Runs the reviewed mutation unless the sheet is busy, asking or closing. The controller stays alive until it
    /// finishes; closing never cancels it, but a sheet that closed meanwhile hears nothing of the result.
    func runApply(
        _ operation: @escaping @MainActor () async throws -> Void, onSuccess: (@MainActor () -> Void)? = nil,
        onFailure: @escaping @MainActor (any Error) -> Void
    ) {
        guard activity.beginApply() else { return }
        updateControls()
        Task { [self] in
            do {
                try await operation()
                guard activity.endApply() else { return }
                if let onSuccess { onSuccess() } else { finish(.OK) }
            } catch {
                guard activity.endApply() else { return }
                onFailure(error)
            }
        }
    }

    // MARK: Closing

    /// App termination does not pass through `windowShouldClose` for attached sheets.
    func requestApplicationTermination(_ reply: @escaping (Bool) -> Void) {
        if blocksClose {
            closeRefused()
            reply(false)
        } else if activity.isPrompting {
            reply(false)
        } else if hasUnsavedChanges, !activity.isFinishing, let prompt = discardPrompt {
            confirmDiscard(prompt, action: prompt.quitTitle, onCancel: { reply(false) }, then: { reply(true) })
        } else {
            reply(true)
        }
    }
    /// Call only after `requestApplicationTermination` approved discarding edits.
    func dismissForApprovedTermination() {
        if blocksClose { closeRefused() } else { finish(.cancel) }
    }
    func requestClose() {
        if blocksClose {
            closeRefused()
            return
        }
        guard !activity.isPrompting, !activity.isFinishing else { return }
        if hasUnsavedChanges, let prompt = discardPrompt {
            confirmDiscard(prompt, action: prompt.closeTitle) { [weak self] in self?.finish(.cancel) }
        } else {
            finish(.cancel)
        }
    }
    override func close() { requestClose() }
    override func cancelOperation(_: Any?) { requestClose() }
    @objc func cancelReview() { requestClose() }
    func windowShouldClose(_: NSWindow) -> Bool {
        if activity.isFinishing { return true }
        requestClose()
        return false
    }
    func windowWillClose(_: Notification) {
        activity.finish()
        cancelLoads()
    }
    func finish(_ response: NSApplication.ModalResponse) {
        guard !activity.isFinishing, !blocksClose, !activity.isPrompting, let window else { return }
        activity.finish()
        cancelLoads()
        sheetWillFinish()
        if let parent = window.sheetParent {
            parent.endSheet(window, returnCode: response)
            window.orderOut(nil)
        } else {
            window.close()
        }
    }

    /// Asks before discarding edits. The discard button never answers Return.
    func confirmDiscard(
        _ prompt: DiscardPrompt, action: String, onCancel: @escaping @MainActor () -> Void = {},
        then completion: @escaping @MainActor () -> Void
    ) {
        guard let window, activity.beginPrompt() else {
            onCancel()
            return
        }
        updateControls()
        let alert = NSAlert()
        alert.messageText = prompt.message
        alert.informativeText = prompt.information
        alert.alertStyle = .warning
        let keep = String(localized: "Keep Editing")
        let titles = prompt.keepEditingFirst ? [keep, action] : [action, keep]
        for title in titles { alert.addButton(withTitle: title) }
        let discardIndex = prompt.keepEditingFirst ? 1 : 0
        for (index, button) in alert.buttons.enumerated() {
            button.keyEquivalent = index == discardIndex ? "" : "\u{1b}"
        }
        alert.window.defaultButtonCell = nil
        let discard: NSApplication.ModalResponse =
            prompt.keepEditingFirst ? .alertSecondButtonReturn : .alertFirstButtonReturn
        presentAlert(alert, window) { [weak self] response in
            guard let self, !self.activity.isFinishing else {
                onCancel()
                return
            }
            self.activity.endPrompt()
            self.updateControls()
            if response == discard { completion() } else { onCancel() }
        }
    }
}
