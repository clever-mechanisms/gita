import AppKit
import GitaCore

final class CommitBucketLaneView: ThemedCardView, NSTextFieldDelegate, NSTextViewDelegate {
    private let presenter: CommitBucketsPresenter
    let bucketID: UUID
    private let title = NSTextField()
    private let body = NSTextView()
    private let chips = NSStackView()
    private let issue = Deck.wrapping("", font: Theme.caption, color: Theme.needsInputText)
    private let warning = Deck.icon("exclamationmark.triangle", size: 12, color: Theme.needsInputText)
    private lazy var order = control(String(localized: "Preview this commit"), "doc.text", "preview") { [weak self] in
        guard let self else { return }
        presenter.selectBucket(bucketID)
    }
    private var currentIndex = 0
    private var shownItems: [BucketHunkItem] = []
    private lazy var earlier = control(String(localized: "Move earlier"), "chevron.up", "earlier") { [weak self] in
        guard let self else { return }
        presenter.moveBucket(from: currentIndex, to: currentIndex - 1)
    }
    private lazy var later = control(String(localized: "Move later"), "chevron.down", "later") { [weak self] in
        guard let self else { return }
        presenter.moveBucket(from: currentIndex, to: currentIndex + 1)
    }

    private lazy var delete = control(String(localized: "Remove bucket"), "trash", "delete") { [weak self] in
        guard let self else { return }
        presenter.removeBucket(bucketID)
    }
    private var chipButtons: [PartsButton] = []

    init(bucketID: UUID, presenter: CommitBucketsPresenter) {
        self.bucketID = bucketID
        self.presenter = presenter
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        setAccessibilityElement(true)
        registerForDraggedTypes([SpeculativeList.itemType])
        configure()
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    private func control(_ label: String, _ symbol: String, _ id: String, action: @escaping () -> Void) -> PartsButton {
        SpeculativeViews.button(
            label, symbol: symbol, id: "lane.\(currentIndex).\(id)", style: .hover,
            iconOnly: true, action: action)
    }

    private func configure() {
        order.cornerRadius = Theme.rowHeight / 2
        order.background = .quiet
        let heading = Deck.hstack([order, Deck.spacer(), earlier, later, delete], spacing: 4)
        title.font = Theme.bodyEmphasis
        title.textColor = Theme.text
        title.isBezeled = false
        title.isBordered = false
        title.drawsBackground = true
        title.wantsLayer = true
        title.layer?.cornerRadius = 6
        title.layer?.masksToBounds = true
        title.backgroundColor = Theme.control
        title.placeholderString = String(localized: "Commit title")
        title.delegate = self
        title.focusRingType = .default
        title.setAccessibilityLabel(String(localized: "Commit title"))
        let bodyScroll = SpeculativeViews.preview(
            body, id: "lane.\(currentIndex).body", label: String(localized: "Commit body"))
        body.isEditable = true
        body.allowsUndo = true
        body.font = Theme.body
        body.isAutomaticQuoteSubstitutionEnabled = false
        body.isAutomaticDashSubstitutionEnabled = false
        body.isAutomaticTextReplacementEnabled = false
        body.delegate = self
        bodyScroll.heightAnchor.constraint(equalToConstant: 48).isActive = true
        chips.orientation = .vertical
        chips.alignment = .leading
        chips.spacing = 4
        let validation = Deck.hstack([warning, issue], spacing: 4)
        let content = SpeculativeViews.column([heading, title, bodyScroll, chips, validation], spacing: 4)
        Style.fill(content, in: self, inset: 8)
    }

    func display(_ bucket: CommitBucket, index: Int, issues: [BucketValidationIssue]) {
        currentIndex = index
        let caption = String(localized: "Commit \(index + 1)")
        order.parts = [
            .symbol("doc.text", color: Theme.secondaryText, size: 12),
            .text(caption, font: Theme.captionEmphasis, color: Theme.text),
        ]
        order.setAccessibilityLabel(String(localized: "Preview \(caption)"))
        setAccessibilityLabel(String(localized: "Commit \(index + 1), \(bucket.title)"))
        if title.stringValue != bucket.title { title.stringValue = bucket.title }
        if body.string != bucket.body {
            body.string = bucket.body
            if let storage = body.textStorage { body.undoManager?.removeAllActions(withTarget: storage) }
            body.undoManager?.removeAllActions(withTarget: body)
        }
        let items = CommitBucketPlanner.items(in: bucket, of: presenter.plan)
        if shownItems != items {
            shownItems = items
            chipButtons.removeAll()
            chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for item in items {
                let row = chip(item)
                chips.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: chips.widthAnchor).isActive = true
            }
        }
        updateControls()
        highlighted = presenter.selectedBucket == bucketID
        let paths = Set(items.map(\.path))
        let problem = issues.first {
            switch $0 {
            case .emptyTitle(let id), .emptyBucket(let id): id == bucketID
            case .duplicateAssignment(_, let ids): ids.contains(bucketID)
            case .hunkOrderOverlap(let path, _): paths.contains(path)
            }
        }
        issue.stringValue = problem?.message ?? ""
        issue.superview?.isHidden = problem == nil
    }

    private func updateControls() {
        let prefix = "speculative.lane.\(currentIndex)"
        setAccessibilityIdentifier(prefix)
        let controls: [(NSView, String)] = [
            (order, "preview"), (earlier, "earlier"), (later, "later"), (delete, "delete"),
            (title, "title"), (body, "body"),
        ]
        for (view, suffix) in controls { view.setAccessibilityIdentifier(prefix + "." + suffix) }
        let editing = presenter.canEdit
        title.isEnabled = editing
        body.isEditable = editing
        earlier.isEnabled = editing && currentIndex > 0
        later.isEnabled = editing && currentIndex + 1 < presenter.plan.buckets.count
        order.isEnabled = editing
        delete.isEnabled = editing
        for (index, button) in chipButtons.enumerated() {
            button.setAccessibilityIdentifier(prefix + ".actions.\(index)")
            button.isEnabled = editing
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        title.backgroundColor = Theme.control
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertTab(_:)): window?.selectNextKeyView(textView)
        case #selector(NSResponder.insertBacktab(_:)): window?.selectPreviousKeyView(textView)
        default: return false
        }
        return true
    }

    private func chip(_ item: BucketHunkItem) -> NSView {
        let label = Deck.label(item.hunkIndex.map { String(localized: "\(item.path) · Hunk \($0 + 1)") } ?? item.path)
        label.font = Theme.mono
        label.toolTip = item.header
        let menu = control(String(localized: "Move or remove change"), "ellipsis", "actions.\(item.id)") {}
        chipButtons.append(menu)
        menu.menuProvider = { [weak self] in
            guard let self else { return nil }
            let menu = NSMenu()
            menu.addItem(
                MenuAction(String(localized: "Unassign change")) { [weak self] in self?.presenter.unassign(item.id) })
            for bucket in presenter.plan.buckets where bucket.id != bucketID {
                menu.addItem(
                    MenuAction(String(localized: "Move to \(bucket.title)")) { [weak self] in
                        self?.presenter.assign(itemID: item.id, to: bucket.id)
                    })
            }
            return menu
        }
        let row = Deck.hstack([Deck.icon("doc.text", size: 12, color: Theme.secondaryText), label, Deck.spacer(), menu])
        row.heightAnchor.constraint(equalToConstant: Theme.rowHeight).isActive = true
        return row
    }

    func controlTextDidBeginEditing(_: Notification) { presenter.selectBucket(bucketID) }
    func textDidBeginEditing(_: Notification) { presenter.selectBucket(bucketID) }
    func controlTextDidChange(_: Notification) { updateMessage() }
    func textDidChange(_: Notification) { updateMessage() }
    private func updateMessage() { presenter.updateMessage(bucketID, title: title.stringValue, body: body.string) }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard presenter.canEdit, let id = sender.draggingPasteboard.string(forType: SpeculativeList.itemType),
            presenter.plan.items.contains(where: { $0.id == id })
        else { return [] }
        highlighted = true
        return .move
    }
    override func draggingExited(_: (any NSDraggingInfo)?) { highlighted = presenter.selectedBucket == bucketID }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard presenter.canEdit, let id = sender.draggingPasteboard.string(forType: SpeculativeList.itemType) else {
            return false
        }
        presenter.assign(itemID: id, to: bucketID)
        return true
    }
}
