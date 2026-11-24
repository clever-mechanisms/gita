import AppKit
import GitaCore

/// The Pull Requests list's columns: number, title, branch, status, author (avatar and login) and when it was last
/// updated. The rows and the header above them share these widths so every column lines up.
@MainActor
enum PullRequestColumns {
    static let number: CGFloat = 46
    static let branch: CGFloat = 210
    static let status: CGFloat = 170
    static let author: CGFloat = 140
    static let updated: CGFloat = 76
    static let actions: CGFloat = 86
    static let avatarSize: CGFloat = 16

    /// The title without the "#12 " the provider puts before it: the number has its own column.
    static func title(_ title: String, number: Int) -> String {
        let prefix = "#\(number) "
        return title.hasPrefix(prefix) ? String(title.dropFirst(prefix.count)) : title
    }

    /// "Open · Approved · Checks passed", "Draft", "Merged", "Closed".
    static func status(_ pr: PullRequestSummary) -> String {
        switch pr.lifecycle {
        case .merged: return PullRequestLifecycle.merged.localizedTitle
        case .closed: return PullRequestLifecycle.closed.localizedTitle
        case .open, .unknown:
            if pr.isDraft { return String(localized: "Draft") }
            return pr.status?.localizedTitle ?? PullRequestLifecycle.open.localizedTitle
        }
    }

    /// The pull request's author as a GitHub avatar beside the login (initials until the picture loads).
    static func author(_ login: String?) -> NSView {
        guard let login, !login.isEmpty else { return fixed(Deck.caption(""), author) }
        let avatar = AvatarView(name: login, email: login + "@users.noreply.github.com", size: avatarSize)
        let name = Deck.label(login, font: Theme.caption, color: Theme.secondaryText)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let view = Deck.hstack([avatar, name, Deck.spacer()], spacing: 6)
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel(login)
        return fixed(view, author)
    }

    /// The labels over the list, aligned with a row's cells (the chevron and icon slots stay empty).
    static func header() -> NSStackView {
        func title(_ text: String, _ width: CGFloat?) -> NSView {
            let label = Deck.label(text, font: Theme.captionEmphasis, color: Theme.secondaryText)
            return width.map { fixed(label, $0) } ?? label
        }
        let views: [NSView] = [
            fixed(NSView(), 10), fixed(NSView(), 16), title("#", number), title(String(localized: "Title"), nil),
            Deck.spacer(), title(String(localized: "Branch"), branch), title(String(localized: "Status"), status),
            title(String(localized: "Author"), author), title(String(localized: "Updated"), updated),
            fixed(NSView(), actions),
        ]
        let header = Deck.hstack(views, spacing: 10)
        header.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
        header.heightAnchor.constraint(equalToConstant: 26).isActive = true
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
