import AppKit
import GitaCore

/// The last lines of a failed build, under its deployment.
@MainActor
enum BuildLogView {
    enum State: Equatable {
        case loading
        /// No lines: why, in words.
        case message(String)
        case lines([String])

        /// What a loaded log shows; a log that connected but has no output stopped before building.
        init(_ log: VercelBuildLog) {
            guard log.lines.isEmpty else {
                self = .lines(log.lines)
                return
            }
            self = .message(
                log.status == .connected
                    ? String(localized: "No build output. The deployment stopped before building.")
                    : (log.diagnostic ?? log.status.localizedTitle))
        }
    }
    private enum Metrics {
        static let fontSize: CGFloat = 10.5
        static let cornerRadius: CGFloat = 5
        static let insets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        static let spacing: CGFloat = 3
    }
    /// What a log shows when the read failed.
    static let unavailable = VercelBuildLog(lines: [], status: .unavailable)

    static func make(_ state: State) -> NSView {
        let title = Deck.caption(String(localized: "Build log · last lines"))
        switch state {
        case .loading:
            return Deck.vstack(
                [title, Deck.label(String(localized: "Loading…"), font: Theme.caption, color: Theme.tertiaryText)],
                spacing: Metrics.spacing)
        case .message(let text):
            return Deck.vstack(
                [title, Deck.label(text, font: Theme.caption, color: Theme.secondaryText)], spacing: Metrics.spacing)
        case .lines(let lines):
            let box = output(lines)
            let stack = Deck.vstack([title, box], spacing: Metrics.spacing)
            box.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return stack
        }
    }

    private static func output(_ lines: [String]) -> NSView {
        let body = NSTextField(wrappingLabelWithString: lines.joined(separator: "\n"))
        body.font = TextLines.monospaced(Metrics.fontSize)
        body.textColor = Theme.text
        body.isSelectable = true
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        body.preferredMaxLayoutWidth = 0
        body.lineBreakMode = .byCharWrapping
        body.setAccessibilityLabel(String(localized: "Build log"))
        let box = FillView(color: Theme.control)
        box.cornerRadius = Metrics.cornerRadius
        Deck.pin(body, in: box, insets: Metrics.insets)
        return box
    }
}
