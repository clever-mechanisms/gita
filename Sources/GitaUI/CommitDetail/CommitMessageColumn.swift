import AppKit
import GitaCore

/// The Commit tab's left column: author header, message, trailers and a merge's parents; for a stash, its name and
/// subject.
@MainActor
enum CommitMessageColumn {
    private enum Metrics {
        static let avatar: CGFloat = 28
        static let subjectSize: CGFloat = 14
        static let shortSHA = 7
    }

    static func views(_ input: CommitDetailView.Input, selectCommit: ((String) -> Void)?) -> [NSView] {
        if let stash = input.stash, input.commit == nil {
            return [
                Deck.label(stash.ref, font: Theme.mono, color: Theme.secondaryText),
                wrapping(stash.subject, font: subjectFont, color: Theme.text),
            ]
        }
        guard let commit = input.commit else { return [] }
        let message = ParsedCommitMessage(
            (input.message ?? commit.subject).trimmingCharacters(in: .whitespacesAndNewlines))
        var views: [NSView] = [header(commit, committer: input.committer, signature: input.signature)]
        views.append(wrapping(message.subject, font: subjectFont, color: Theme.text))
        if !message.body.isEmpty { views.append(wrapping(message.body, font: Theme.body, color: Theme.text)) }
        views += message.trailers.map { Deck.label($0, font: Theme.body, color: Theme.secondaryText) }
        if commit.parents.count > 1 { views.append(parents(commit.parents, selectCommit: selectCommit)) }
        return views
    }
    private static var subjectFont: NSFont { TextLines.system(Metrics.subjectSize, weight: .semibold) }

    /// Reference names as the header shows them: without `HEAD -> ` and `tag: `, and without a detached `HEAD`.
    static func references(_ decorations: [String]) -> [String] {
        decorations.map {
            $0.replacingOccurrences(of: "HEAD -> ", with: "").replacingOccurrences(of: "tag: ", with: "")
        }.filter { $0 != "HEAD" }
    }

    /// When, the first reference (+N more) and who committed it when that is not the author.
    static func subtitle(_ commit: GitCommit, committer: String?) -> String {
        var meta = [DeckFormat.relative(commit.date)]
        let refs = references(commit.decorations)
        if let first = refs.first { meta.append(refs.count > 1 ? "\(first) +\(refs.count - 1)" : first) }
        if let committer, committer != commit.author { meta.append(String(localized: "committed by \(committer)")) }
        return meta.joined(separator: " · ")
    }

    private static func header(_ commit: GitCommit, committer: String?, signature: CommitSignatureInfo?) -> NSView {
        let avatar = AvatarView(name: commit.author, email: commit.email, size: Metrics.avatar)
        let name = Deck.label(commit.author, font: Theme.bodyEmphasis)
        name.toolTip = commit.email.isEmpty ? nil : commit.email
        let subtitle = Deck.caption(subtitle(commit, committer: committer))
        subtitle.toolTip = references(commit.decorations).joined(separator: "\n")
        // The author's email beside the name (selectable, so it can be copied); truncates in the middle if narrow.
        var nameItems: [NSView] = [name]
        if !commit.email.isEmpty {
            let email = Deck.label(commit.email, font: Theme.body, color: Theme.secondaryText)
            email.isSelectable = true
            email.lineBreakMode = .byTruncatingMiddle
            email.toolTip = commit.email
            email.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            name.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            nameItems.append(email)
        }
        if let signature, signature.isSigned {
            let badge = SignatureBadgeView()
            badge.update(signature)
            badge.setContentHuggingPriority(.required, for: .horizontal)
            badge.setContentCompressionResistancePriority(.required, for: .horizontal)
            nameItems.append(badge)
        }
        let nameLine: NSView = nameItems.count > 1 ? Deck.hstack(nameItems, spacing: 6) : name
        return Deck.hstack([avatar, Deck.vstack([nameLine, subtitle], spacing: 1)], spacing: 10)
    }

    /// "Merge of" and a link per parent.
    private static func parents(_ parents: [String], selectCommit: ((String) -> Void)?) -> NSView {
        var parts: [NSView] = [Deck.caption(String(localized: "Merge of"))]
        for parent in parents {
            parts.append(PartsButton.link(String(parent.prefix(Metrics.shortSHA))) { selectCommit?(parent) })
        }
        return Deck.hstack(parts, spacing: 6)
    }

    /// A selectable label that wraps onto as many lines as the column needs.
    private static func wrapping(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.preferredMaxLayoutWidth = 0
        return label
    }
}
