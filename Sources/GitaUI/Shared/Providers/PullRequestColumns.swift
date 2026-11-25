import AppKit
import GitaCore

/// The Pull Requests list's columns: number, title, branch, status pill, author (avatar and login), updated time and
/// actions. Rows and the header above them share these widths (scaled with zoom) so every column lines up.
@MainActor
enum PullRequestColumns {
    static let number: CGFloat = 48
    static let branch: CGFloat = 190
    static let status: CGFloat = 180
    static let author: CGFloat = 136
    static let updated: CGFloat = 74
    static let actions: CGFloat = 86
    static let avatarSize: CGFloat = 16

    /// Wide metadata columns grow gentler than text so the title keeps breathing room when zoomed in.
    static func gentleScale(_ scale: CGFloat) -> CGFloat { 1 + (scale - 1) * 0.55 }
    static func numberWidth(_ scale: CGFloat = 1) -> CGFloat { (number * scale).rounded() }
    static func branchWidth(_ scale: CGFloat = 1) -> CGFloat { (branch * gentleScale(scale)).rounded() }
    static func statusWidth(_ scale: CGFloat = 1) -> CGFloat { (status * gentleScale(scale)).rounded() }
    static func authorWidth(_ scale: CGFloat = 1) -> CGFloat { (author * gentleScale(scale)).rounded() }
    static func updatedWidth(_ scale: CGFloat = 1) -> CGFloat { (updated * scale).rounded() }
    static func actionsWidth(_ scale: CGFloat = 1) -> CGFloat { (actions * gentleScale(scale)).rounded() }
    static func iconWidth(_ scale: CGFloat = 1) -> CGFloat { (16 * scale).rounded() }
    static func chevronWidth(_ scale: CGFloat = 1) -> CGFloat { (10 * scale).rounded() }
    static func headerHeight(_ scale: CGFloat = 1) -> CGFloat { (26 * scale).rounded() }

    /// The title without the "#12 " the provider puts before it: the number has its own column.
    static func title(_ title: String, number: Int) -> String {
        let prefix = "#\(number) "
        return title.hasPrefix(prefix) ? String(title.dropFirst(prefix.count)) : title
    }

    /// "Review requested", "Approved · Checks passed", "Draft", "Merged", "Closed".
    static func status(_ pr: PullRequestSummary) -> String {
        switch pr.lifecycle {
        case .merged: return PullRequestLifecycle.merged.localizedTitle
        case .closed: return PullRequestLifecycle.closed.localizedTitle
        case .open, .unknown:
            if pr.isDraft { return String(localized: "Draft") }
            if pr.reviewRequestedFromViewer { return reviewRequestedStatus(pr.checksState) }
            return pr.status?.localizedTitle ?? PullRequestLifecycle.open.localizedTitle
        }
    }

    private static func reviewRequestedStatus(_ checks: PullRequestStatusLabel.Checks?) -> String {
        let label = String(localized: "Review requested")
        switch checks {
        case .failing: return String(localized: "\(label) · Checks failing")
        case .pending: return String(localized: "\(label) · Checks pending")
        default: return label
        }
    }

    /// Status pill colour: reflects failing checks, requested changes and viewer review requests on open PRs.
    static func statusColor(_ pr: PullRequestSummary) -> NSColor {
        switch pr.lifecycle {
        case .merged: return Theme.merged
        case .closed: return Theme.secondaryText
        case .open, .unknown:
            if pr.isDraft { return Theme.secondaryText }
            if pr.checksState == .failing || pr.status?.review == .changesRequested { return Theme.failure }
            if pr.reviewRequestedFromViewer { return Theme.needsInputText }
            if pr.status?.review == .approved { return Theme.success }
            if pr.checksState == .pending { return Theme.running }
            return Theme.success
        }
    }

    /// The pull request's status as a tinted pill inside the Status column.
    static func statusBadge(_ pr: PullRequestSummary, toolTip: String?, scale: CGFloat = 1) -> NSView {
        let pill = PullRequestStatusPill(text: status(pr), color: statusColor(pr), scale: scale)
        pill.toolTip = toolTip
        let box = Deck.hstack([pill, Deck.spacer()], spacing: 0)
        return fixed(box, statusWidth(scale))
    }

    /// The head branch in monospaced type with a quiet branch icon.
    static func branchView(_ name: String?, scale: CGFloat = 1) -> NSView {
        guard let name, !name.isEmpty else { return fixed(Deck.caption(""), branchWidth(scale)) }
        let icon = Deck.icon("arrow.triangle.branch", size: (9.5 * scale).rounded(), color: Theme.tertiaryText)
        let label = Deck.label(name, font: TextLines.monospaced(11 * scale), color: Theme.secondaryText)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let view = Deck.hstack([icon, label, Deck.spacer()], spacing: 4)
        view.toolTip = name
        return fixed(view, branchWidth(scale))
    }

    /// The pull request's author as a GitHub avatar beside the login (initials until the picture loads).
    static func author(_ login: String?, scale: CGFloat = 1) -> NSView {
        let width = authorWidth(scale)
        guard let login, !login.isEmpty else { return fixed(Deck.caption(""), width) }
        let side = (avatarSize * scale).rounded()
        let avatar = AvatarView(name: login, email: login + "@users.noreply.github.com", size: side)
        let name = Deck.label(login, font: TextLines.system(11 * scale), color: Theme.secondaryText)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let view = Deck.hstack([avatar, name, Deck.spacer()], spacing: 6)
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel(login)
        return fixed(view, width)
    }

    /// The labels over the list, aligned with a row's cells (the chevron and icon slots stay empty).
    static func header(scale: CGFloat = 1, showsChevron: Bool = true) -> NSStackView {
        let font = TextLines.system(11 * scale, weight: .medium)
        func title(_ text: String, _ width: CGFloat?) -> NSView {
            let label = Deck.label(text, font: font, color: Theme.secondaryText)
            return width.map { fixed(label, $0) } ?? label
        }
        var views: [NSView] = []
        if showsChevron { views.append(fixed(NSView(), chevronWidth(scale))) }
        views += [
            fixed(NSView(), iconWidth(scale)),
            title("#", numberWidth(scale)),
            title(String(localized: "Title"), nil),
            Deck.spacer(),
            title(String(localized: "Branch"), branchWidth(scale)),
            title(String(localized: "Status"), statusWidth(scale)),
            title(String(localized: "Author"), authorWidth(scale)),
            title(String(localized: "Updated"), updatedWidth(scale)),
            fixed(NSView(), actionsWidth(scale)),
        ]
        let header = Deck.hstack(views, spacing: 10)
        header.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        header.heightAnchor.constraint(equalToConstant: headerHeight(scale)).isActive = true
        return header
    }

    static func fixed(_ view: NSView, _ width: CGFloat) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        let constraint = view.widthAnchor.constraint(equalToConstant: width)
        constraint.priority = NSLayoutConstraint.Priority(450)
        constraint.isActive = true
        return view
    }
}

/// A subtle tinted status badge matching Gita's history chips (14% fill, 38% border).
@MainActor
private final class PullRequestStatusPill: NSView {
    private let tint: NSColor
    private let label: NSTextField

    init(text: String, color: NSColor, scale: CGFloat) {
        tint = color
        label = Deck.label(text, font: TextLines.system(10.5 * scale, weight: .medium), color: color)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = (5 * scale).rounded()
        layer?.borderWidth = 1
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let padX = (6 * scale).rounded()
        let padY = max(1, (2 * scale).rounded())
        Deck.pin(label, in: self, insets: NSEdgeInsets(top: padY, left: padX, bottom: padY, right: padX))
        updateColors()
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = tint.withAlphaComponent(0.12).cgColor
            layer?.borderColor = tint.withAlphaComponent(0.35).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
}

/// Section header inside a grouped provider list ("OPEN · 3", "MERGED · 24").
@MainActor
final class ProviderGroupHeader: RowView {
    init(title: String, count: Int, symbol: String, color: NSColor, scale: CGFloat = 1) {
        super.init(frame: .zero)
        fill = Deck.groupHeaderFill
        bottomSeparator = Theme.separator.withAlphaComponent(0.7)
        hoverEnabled = false
        let icon = Deck.icon(symbol, size: (10.5 * scale).rounded(), weight: .semibold, color: color)
        let label = Deck.label(
            title.localizedUppercase, font: TextLines.system(10.5 * scale, weight: .semibold),
            color: Theme.secondaryText)
        let digits = Deck.label(
            "\(count)", font: NSFont.monospacedDigitSystemFont(ofSize: 10.5 * scale, weight: .medium),
            color: Theme.tertiaryText)
        digits.setContentCompressionResistancePriority(.required, for: .horizontal)
        let stack = Deck.hstack([icon, label, digits, Deck.spacer()], spacing: 6)
        Deck.pin(stack, in: self, insets: NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14))
        heightAnchor.constraint(equalToConstant: (26 * scale).rounded()).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(title), \(count)")
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }
}
