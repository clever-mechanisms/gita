import AppKit
import GitaCore

@MainActor
final class CreateStashSheet: NSObject, NSTextFieldDelegate {
    typealias Execute = @MainActor (StashCreateRequest) async throws -> Void
    private var presenter: CreateStashPresenter
    private let execute: Execute
    private var onEnd: ((NSApplication.ModalResponse) -> Void)?
    private let chrome = SheetChrome(
        title: String(localized: "Create Stash"), layout: .init(width: 580, spacing: 10, minimumHeight: 280),
        identifier: "stash.create", styleMask: [.titled])
    private let message = NSTextField()
    private let fileList = ChangedFilesView(side: .commit)
    private let fileCountLabel = Deck.label(
        "", font: .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium), color: Theme.secondaryText)
    private lazy var treeToggle = PartsButton(
        [.symbol("list.bullet.indent", color: Theme.secondaryText, size: 11)], background: .hover,
        accessibility: String(localized: "Toggle tree view")
    ) { [weak self] in
        self?.toggleTreeMode()
    }
    private lazy var picker: ActionSegmentedControl = {
        let control = ActionSegmentedControl(labels: presenter.scopeTitles) { [weak self] index in
            guard let self, presenter.scopes.indices.contains(index) else { return }
            presenter.selectScope(presenter.scopes[index])
            render()
        }
        for (index, symbol) in presenter.scopeSymbols.enumerated() {
            control.setImage(Deck.template(symbol, size: 11, weight: .medium), forSegment: index)
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
        }
        control.segmentDistribution = .fit
        return control
    }()
    private lazy var keep = NSButton(
        checkboxWithTitle: String(localized: "Keep staged changes in index (--keep-index)"), target: self,
        action: #selector(changeKeep))
    private lazy var submit = SheetChrome.button(
        String(localized: "Create Stash"), id: "stash.create.submit", symbol: "archivebox")
    private lazy var cancel = SheetChrome.button(
        String(localized: "Cancel"), id: "stash.create.cancel", symbol: "xmark")

    private init(presenter: CreateStashPresenter, execute: @escaping Execute) {
        self.presenter = presenter
        self.execute = execute
        super.init()
        buildInterface()
        render()
    }

    static func present(
        on parent: NSWindow, alerts: AlertPresenter = .standard, changes: [FileChange], selectedPaths: [String],
        execute: @escaping Execute, completion: @escaping @MainActor (Bool) -> Void
    ) {
        let sheet = Self(presenter: .init(changes: changes, selectedPaths: selectedPaths), execute: execute)
        var finished = false
        let finish: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard !finished else { return }
            finished = true
            sheet.onEnd = nil
            sheet.chrome.window.orderOut(nil)
            completion(response == .OK)
        }
        sheet.onEnd = finish
        alerts.beginSheet(sheet.chrome.window, parent) { response in finish(response) }
        sheet.chrome.fit()
        sheet.chrome.window.makeFirstResponder(sheet.message)
    }

    private func buildInterface() {
        chrome.add(makeHeader(), height: 36)
        chrome.add(makeMessageField(), height: 44)
        chrome.add(picker, height: 28)
        keep.font = Theme.body
        chrome.add(keep, height: 20)
        let preview = makeFileTreeCard()
        chrome.add(preview, height: 210)
        chrome.setFlexibleRow(preview, preferred: 210, minimum: 110)
        cancel.target = self
        cancel.action = #selector(cancelSheet)
        cancel.keyEquivalent = "\u{1b}"
        submit.target = self
        submit.action = #selector(submitSheet)
        submit.keyEquivalent = "\r"
        chrome.complete(footer: [SheetChrome.spacer(), cancel, submit])
        chrome.window.defaultButtonCell = submit.cell as? NSButtonCell
    }

    private func makeHeader() -> NSView {
        let badge = StorageStyle.iconBadge(
            "archivebox", tint: Theme.accent, boxSize: 32, symbolSize: 15, cornerRadius: 8)
        let title = Deck.label(
            String(localized: "Stash Changes"), font: TextLines.system(14, weight: .semibold), color: Theme.text)
        let subtitle = Deck.caption(
            String(localized: "Save local modifications to a stash entry and clean your working tree."))
        return Deck.hstack([badge, Deck.vstack([title, subtitle], spacing: 2), Deck.spacer()], spacing: 10)
    }

    private func makeMessageField() -> NSView {
        let label = Deck.label(String(localized: "Message"), font: Theme.captionEmphasis, color: Theme.secondaryText)
        message.placeholderString = String(localized: "Optional stash message")
        message.font = Theme.body
        message.delegate = self
        message.setAccessibilityLabel(String(localized: "Stash message"))
        message.setAccessibilityIdentifier("stash.create.message")
        let stack = Deck.vstack([label, message], spacing: 4)
        message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func makeFileTreeCard() -> NSView {
        let card = FillView(color: Theme.window)
        card.borderColor = Theme.separator
        card.cornerRadius = 10
        let clip = NSView()
        clip.wantsLayer = true
        clip.layer?.cornerRadius = 9
        clip.layer?.masksToBounds = true
        let headerIcon = Deck.icon("doc.on.doc", size: 11, weight: .medium, color: Theme.secondaryText)
        headerIcon.setAccessibilityElement(false)
        let title = Deck.sectionTitle(String(localized: "Files to Stash"))
        let countPill = FillView(color: Theme.control)
        countPill.cornerRadius = 6
        Deck.pin(fileCountLabel, in: countPill, insets: NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6))
        treeToggle.fixedHeight = 20
        treeToggle.horizontalPadding = 5
        treeToggle.cornerRadius = 4
        let headerRow = Deck.hstack([headerIcon, title, countPill, Deck.spacer(), treeToggle], spacing: 6)
        let headerBar = FillView(color: Theme.toolbar)
        Deck.pin(headerRow, in: headerBar, insets: NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8))
        headerBar.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let divider = Deck.separator()
        fileList.emptyText = String(localized: "No files match this scope.")
        fileList.setContentHuggingPriority(.defaultLow, for: .vertical)
        let stack = Deck.vstack([headerBar, divider, fileList], spacing: 0)
        Deck.pin(stack, in: clip)
        for view in [headerBar, divider, fileList] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        Deck.pin(clip, in: card, insets: NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
        return card
    }

    func controlTextDidChange(_: Notification) {
        presenter.message = message.stringValue
        submit.isEnabled = presenter.canSubmit
    }

    @objc private func changeKeep() { presenter.setKeepIndex(keep.state == .on) }
    @objc private func cancelSheet() { end(.cancel) }
    @objc private func submitSheet() { create() }

    private func toggleTreeMode() {
        fileList.showsTree.toggle()
        syncTreeToggle()
    }

    private func syncTreeToggle() {
        let symbol = fileList.showsTree ? "list.bullet.indent" : "list.bullet"
        let tip =
            fileList.showsTree
            ? String(localized: "Showing folder tree (click for flat list)")
            : String(localized: "Showing flat list (click for folder tree)")
        treeToggle.parts = [.symbol(symbol, color: Theme.secondaryText, size: 11)]
        treeToggle.toolTip = tip
        treeToggle.setAccessibilityLabel(tip)
    }

    private func create() {
        presenter.message = message.stringValue
        guard let request = presenter.begin() else { return }
        render()
        Task {
            do {
                try await execute(request)
                presenter.finish()
                end(.OK)
            } catch {
                presenter.fail(error.localizedDescription)
                render()
            }
        }
    }

    private func end(_ response: NSApplication.ModalResponse) {
        if let parent = chrome.window.sheetParent {
            parent.endSheet(chrome.window, returnCode: response)
        } else {
            onEnd?(response)
        }
    }

    private func render() {
        picker.selectedSegment = presenter.scopes.firstIndex(of: presenter.scope) ?? 0
        picker.isEnabled = !presenter.isRunning
        picker.setEnabled(!presenter.selectedPaths.isEmpty, forSegment: 3)
        keep.isEnabled = presenter.canKeepIndex
        keep.state = presenter.keepIndex ? .on : .off
        message.isEnabled = !presenter.isRunning
        cancel.isEnabled = !presenter.isRunning
        submit.isEnabled = presenter.canSubmit
        fileList.update(presenter.affectedChanges)
        fileCountLabel.stringValue = presenter.fileCountText
        syncTreeToggle()
        chrome.show(presenter.status)
    }
}
