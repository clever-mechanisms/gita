import AppKit

/// Pure description of a binary file's diff empty state: sizes before/after and available actions.
struct BinaryDiffSummary: Equatable, Sendable {
    var path: String
    var oldByteCount: Int64?
    var newByteCount: Int64?
    var fileURL: URL?

    var canRevealOrOpen: Bool { fileURL != nil }

    var message: String {
        switch (oldByteCount, newByteCount) {
        case (let old?, let new?):
            let before = Self.formatBytes(old)
            let after = Self.formatBytes(new)
            return String(localized: "Binary file, \(before) → \(after)")
        case (nil, let new?):
            let after = Self.formatBytes(new)
            return String(localized: "Binary file, \(after)")
        case (let old?, nil):
            let before = Self.formatBytes(old)
            return String(localized: "Binary file, \(before) → removed")
        case (nil, nil):
            return String(localized: "Binary file")
        }
    }

    static func formatBytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, count), countStyle: .file)
    }

    static func isBinaryDiff(_ text: String) -> Bool {
        text.contains("GIT binary patch") || text.contains("Binary files ")
    }

    struct ResolutionInput: Sendable {
        var text: String
        var path: String?
        var isBlob: Bool
        var binaryBlobByteCount: Int64?
        var fileURL: URL?
        var oldByteCount: Int64?
        var newByteCount: Int64?
    }

    static func resolve(_ input: ResolutionInput) -> Self? {
        if input.isBlob {
            guard let count = input.binaryBlobByteCount else { return nil }
            return Self(path: input.path ?? "", oldByteCount: nil, newByteCount: count, fileURL: input.fileURL)
        }
        guard isBinaryDiff(input.text) else { return nil }
        let isDeleted =
            input.text.contains(" and /dev/null differ") || input.text.contains("\ndeleted file mode ")
        let effectiveNew: Int64? =
            if let explicit = input.newByteCount {
                explicit
            } else if !isDeleted, let url = input.fileURL,
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            {
                size
            } else {
                nil
            }
        return Self(
            path: input.path ?? "", oldByteCount: input.oldByteCount, newByteCount: effectiveNew,
            fileURL: input.fileURL)
    }
}

/// Actionable empty state for binary diffs (`"Binary file, X → Y [Open] [Reveal in Finder]"`).
/// Designed to be hosted inside `DiffView` when `BinaryDiffSummary.isBinaryDiff` holds.
@MainActor
final class BinaryDiffEmptyView: NSView {
    var onOpen: ((URL) -> Void)?
    var onRevealInFinder: ((URL) -> Void)?
    var openFile: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var revealFile: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    private let icon = NSImageView()
    private let messageLabel = Deck.wrapping("", font: Theme.body, color: Theme.secondaryText)
    private let openButton: PartsButton
    private let revealButton: PartsButton
    private(set) var summary: BinaryDiffSummary?

    override init(frame frameRect: NSRect) {
        openButton = PartsButton.quiet(String(localized: "Open"), symbol: "arrow.up.forward.app") {}
        revealButton = PartsButton.quiet(String(localized: "Reveal in Finder"), symbol: "folder") {}
        super.init(frame: frameRect)
        icon.setSymbol("doc.zipper", size: 22, color: Theme.secondaryText)
        messageLabel.alignment = .center
        openButton.fixedHeight = 26
        revealButton.fixedHeight = 26
        openButton.setAccessibilityIdentifier("binaryDiff.open")
        revealButton.setAccessibilityIdentifier("binaryDiff.reveal")
        openButton.onClick = { [weak self] in self?.triggerOpen() }
        revealButton.onClick = { [weak self] in self?.triggerReveal() }
        let buttons = Deck.hstack([openButton, revealButton], spacing: 8)
        let stack = Deck.vstack([icon, messageLabel, buttons], spacing: 10)
        stack.alignment = .centerX
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("BinaryDiffEmptyView is built in code") }

    func show(_ summary: BinaryDiffSummary?) {
        self.summary = summary
        guard let summary else {
            messageLabel.toolTip = nil
            isHidden = true
            return
        }
        isHidden = false
        messageLabel.stringValue = summary.message
        messageLabel.toolTip = summary.path.isEmpty ? nil : summary.path
        let hasFile = summary.canRevealOrOpen
        openButton.isEnabled = hasFile
        revealButton.isEnabled = hasFile
    }

    private func triggerOpen() {
        guard let url = summary?.fileURL else { return }
        if let onOpen { onOpen(url) } else { openFile(url) }
    }

    private func triggerReveal() {
        guard let url = summary?.fileURL else { return }
        if let onRevealInFinder { onRevealInFinder(url) } else { revealFile(url) }
    }
}
