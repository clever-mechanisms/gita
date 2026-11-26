import AppKit
import GitaCore

/// Validation and submission state for `BisectStartSheet`.
struct BisectStartState: Equatable, Sendable {
    var badRef: String
    var goodRef: String
    var errorMessage: String?

    init(badRef: String = "HEAD", goodRef: String = "") {
        self.badRef = badRef
        self.goodRef = goodRef
    }

    var trimmedBad: String { badRef.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedGood: String { goodRef.trimmingCharacters(in: .whitespacesAndNewlines) }

    var validationError: String? {
        if trimmedBad.isEmpty || trimmedGood.isEmpty {
            return String(localized: "Choose both a Bad commit and a Good commit.")
        }
        if trimmedBad == trimmedGood {
            return String(localized: "Bad and Good commits must be different.")
        }
        return nil
    }

    var canStart: Bool { validationError == nil }
}

/// Sheet for starting a visual `git bisect` session by selecting Bad and Good commits.
@MainActor
final class BisectStartSheet: ReviewSheetController, NSComboBoxDelegate {
    typealias StartAction = @MainActor (String, String) async throws -> Void

    private let recentCommits: [GitCommit]
    private let onStart: StartAction
    private let chrome: SheetChrome
    private let badCombo = NSComboBox()
    private let goodCombo = NSComboBox()
    private let cancelButton: NSButton
    private let startButton: NSButton
    private(set) var state: BisectStartState

    init(
        recentCommits: [GitCommit],
        initialBad: String = "HEAD",
        initialGood: String = "",
        onStart: @escaping StartAction
    ) {
        self.recentCommits = recentCommits
        self.onStart = onStart
        self.state = BisectStartState(badRef: initialBad, goodRef: initialGood)
        self.chrome = SheetChrome(
            title: String(localized: "Start Git Bisect"),
            layout: SheetChrome.Layout(width: 500, spacing: 10, minimumHeight: 220),
            identifier: "bisect.start"
        )
        self.cancelButton = SheetChrome.button(String(localized: "Cancel"), id: "bisect.start.cancel")
        self.startButton = SheetChrome.button(String(localized: "Start Bisect"), id: "bisect.start.confirm")
        super.init(sheet: chrome.window)
        buildInterface()
        updateControls()
    }

    private func buildInterface() {
        let heading = Style.label(
            String(localized: "Find the commit that introduced a regression"),
            size: 13,
            weight: .semibold
        )
        let explanation = SheetChrome.wrappingLabel(
            String(
                localized:
                    "Pick a Bad commit and an older Good commit. Git checks out the midpoint so you can mark steps."
            ),
            lines: 3
        )
        explanation.textColor = Theme.secondaryText
        chrome.add(heading, height: 20)
        chrome.add(explanation, height: 34)

        let badLabel = Style.label(String(localized: "Bad commit (contains the bug)"), size: 11, weight: .medium)
        configureCombo(badCombo, initialValue: state.badRef, placeholder: "HEAD", id: "bisect.start.bad")
        chrome.add(badLabel, height: 16)
        chrome.add(badCombo, height: 26)

        let goodLabel = Style.label(String(localized: "Good commit (before the bug)"), size: 11, weight: .medium)
        configureCombo(
            goodCombo,
            initialValue: state.goodRef,
            placeholder: String(localized: "Commit SHA, tag, or branch"),
            id: "bisect.start.good"
        )
        chrome.add(goodLabel, height: 16)
        chrome.add(goodCombo, height: 26)

        bind(cancelButton, #selector(cancelReview))
        cancelButton.keyEquivalent = "\u{1b}"
        bind(startButton, #selector(confirmStart))
        startButton.keyEquivalent = "\r"
        chrome.complete(footer: [SheetChrome.spacer(), cancelButton, startButton])
        window?.defaultButtonCell = startButton.cell as? NSButtonCell
        window?.initialFirstResponder = state.goodRef.isEmpty ? goodCombo : badCombo
    }

    private func configureCombo(_ combo: NSComboBox, initialValue: String, placeholder: String, id: String) {
        combo.isEditable = true
        combo.completes = true
        combo.usesDataSource = false
        combo.placeholderString = placeholder
        combo.font = Theme.body
        combo.delegate = self
        combo.target = self
        combo.action = #selector(comboChanged)
        combo.setAccessibilityIdentifier(id)
        for commit in recentCommits.prefix(50) {
            combo.addItem(withObjectValue: Self.displayItem(for: commit))
        }
        combo.stringValue = initialValue
    }

    static func displayItem(for commit: GitCommit) -> String {
        "\(String(commit.id.prefix(8))) · \(commit.subject)"
    }

    /// Extracts the commit SHA or raw ref from a combo box entry (`<sha> · <subject>` or user-typed ref).
    static func extractReference(from rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = trimmed.range(of: " · ") {
            return String(trimmed[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }

    override func updateControls() {
        let active = activity.isActive
        badCombo.isEnabled = active
        goodCombo.isEnabled = active
        cancelButton.isEnabled = active
        startButton.isEnabled = active && state.canStart
        window?.standardWindowButton(.closeButton)?.isEnabled = active

        if isApplying {
            chrome.show(SheetStatus(message: String(localized: "Starting bisect…"), isBusy: true))
        } else if let error = state.errorMessage {
            chrome.show(SheetStatus(message: error, isError: true))
        } else if let validation = state.validationError, !state.trimmedGood.isEmpty {
            chrome.show(SheetStatus(message: validation, isError: true))
        } else {
            chrome.show(SheetStatus(message: ""))
        }
    }

    func controlTextDidChange(_: Notification) { syncInputs() }

    func comboBoxSelectionDidChange(_: Notification) { syncInputs() }

    @objc private func comboChanged() { syncInputs() }

    private func syncInputs() {
        state.badRef = Self.extractReference(from: badCombo.stringValue)
        state.goodRef = Self.extractReference(from: goodCombo.stringValue)
        state.errorMessage = nil
        updateControls()
    }

    @objc private func confirmStart() {
        syncInputs()
        guard state.canStart else { return }
        let bad = state.trimmedBad
        let good = state.trimmedGood
        runApply { [onStart] in
            try await onStart(bad, good)
        } onFailure: { [weak self] error in
            self?.state.errorMessage = error.localizedDescription
            self?.updateControls()
        }
    }
}
