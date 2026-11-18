import AppKit
import GitaCore

/// The commit menu's author item: Highlight (fade everyone else's commits) and Filter (a tab with only theirs).
@MainActor
struct AuthorMenuBuilder {
    private static let avatarSize = NSSize(width: 16, height: 16)

    var highlighted: CommitAuthor?
    /// The author this tab shows alone, if it is an author tab.
    var lens: CommitAuthor?
    var highlight: (CommitAuthor?) -> Void
    /// Opens an author tab (only theirs).
    var filter: (CommitAuthor) -> Void

    func item(for commit: GitCommit) -> NSMenuItem? {
        guard !commit.author.isEmpty else { return nil }
        let author = CommitAuthor(commit)
        let item = NSMenuItem(title: commit.author, action: nil, keyEquivalent: "")
        item.image = NSImage(size: Self.avatarSize, flipped: false) { rect in
            Deck.drawAvatar(commit.author, email: commit.email, in: rect)
            return true
        }
        item.setAccessibilityLabel(String(localized: "Author \(commit.author)"))
        let submenu = NSMenu()
        let highlighting = highlighted == author
        let highlight = highlight
        let highlightItem = MenuAction(String(localized: "Highlight"), symbol: "highlighter") {
            highlight(highlighting ? nil : author)
        }
        highlightItem.state = highlighting ? .on : .off
        highlightItem.toolTip = String(localized: "Fade every other author's commits")
        // Filter: a tab with only their commits, as a graph of their own ("project [Author]").
        let filtering = lens == author
        let filter = filter
        let filterItem = MenuAction(String(localized: "Filter"), symbol: "line.3.horizontal.decrease") {
            if !filtering { filter(author) }
        }
        filterItem.state = filtering ? .on : .off
        filterItem.toolTip = String(localized: "Show only this author's commits, in a new tab")
        submenu.addItem(highlightItem)
        submenu.addItem(filterItem)
        if let other = highlighted, other != author {
            submenu.addItem(.separator())
            submenu.addItem(
                MenuAction(String(localized: "Stop Highlighting \(other.name)"), symbol: nil) { highlight(nil) })
        }
        item.submenu = submenu
        return item
    }
}
