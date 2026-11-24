import AppKit

/// Indexes every Settings pane, group, row, help explanation, and card so sidebar live search highlights matching
/// panes and rows without maintaining a parallel manual table.
@MainActor
struct SettingsSearchIndex {
    struct Entry {
        var target: NSView?
        var searchableText: String
    }

    struct Result {
        var query: String
        var matchingPanes: [SettingsPane]
        var matchCounts: [SettingsPane: Int]
        var highlightedTargets: [SettingsPane: [NSView]]

        var isActive: Bool { !query.isEmpty }
    }

    private var entries: [SettingsPane: [Entry]] = [:]

    mutating func index(pane: SettingsPane, content: SettingsPaneContent) {
        var collected: [Entry] = []
        collectEntries(in: content.view, groupTitle: "", into: &collected)
        entries[pane] = collected
    }

    func search(_ rawQuery: String) -> Result {
        let tokens = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else {
            return Result(
                query: "", matchingPanes: SettingsPane.allCases, matchCounts: [:], highlightedTargets: [:])
        }
        var matchingPanes: [SettingsPane] = []
        var matchCounts: [SettingsPane: Int] = [:]
        var highlightedTargets: [SettingsPane: [NSView]] = [:]
        for pane in SettingsPane.allCases {
            let paneEntries = entries[pane] ?? []
            let directMatches = paneEntries.filter { entry in
                tokens.allSatisfy { entry.searchableText.localizedStandardContains($0) }
            }
            let paneMatches =
                directMatches.isEmpty
                ? paneEntries.filter { entry in
                    tokens.contains { entry.searchableText.localizedStandardContains($0) }
                        && tokens.allSatisfy {
                            entry.searchableText.localizedStandardContains($0)
                                || pane.title.localizedStandardContains($0)
                        }
                }
                : directMatches
            let targets = paneMatches.compactMap(\.target)
            let titleMatches = tokens.allSatisfy { pane.title.localizedStandardContains($0) }
            if !targets.isEmpty || titleMatches {
                matchingPanes.append(pane)
                matchCounts[pane] = targets.count
                highlightedTargets[pane] = targets
            }
        }
        return Result(
            query: rawQuery, matchingPanes: matchingPanes, matchCounts: matchCounts,
            highlightedTargets: highlightedTargets)
    }

    static func applyHighlights(_ targets: [NSView], in root: NSView) {
        let set = Set(targets.map(ObjectIdentifier.init))
        clearHighlights(in: root, keeping: set)
    }

    private static func clearHighlights(in view: NSView, keeping highlighted: Set<ObjectIdentifier>) {
        let id = ObjectIdentifier(view)
        if let row = view as? SettingsRow {
            row.isSearchHighlighted = highlighted.contains(id)
        } else if let card = view as? SettingsChoiceCard {
            card.isSearchHighlighted = highlighted.contains(id)
        } else if let card = view as? SettingsFeatureCard {
            card.isSearchHighlighted = highlighted.contains(id)
        }
        for subview in view.subviews {
            clearHighlights(in: subview, keeping: highlighted)
        }
    }

    private func collectEntries(in view: NSView, groupTitle: String, into list: inout [Entry]) {
        if let group = view as? SettingsGroup {
            let title = group.titleLabel?.stringValue ?? groupTitle
            for row in group.rows where !row.isHidden {
                list.append(entry(for: row, groupTitle: title))
            }
            return
        }
        if let card = view as? SettingsChoiceCard {
            let texts = [groupTitle, card.titleLabel.stringValue, card.help?.explanation].compactMap { $0 }
            list.append(Entry(target: card, searchableText: texts.joined(separator: " ")))
            return
        }
        if let card = view as? SettingsFeatureCard {
            let texts = [
                groupTitle, card.row.titleLabel.stringValue, card.row.subtitleLabel?.stringValue,
                card.row.help?.explanation,
            ].compactMap { $0 }
            list.append(Entry(target: card, searchableText: texts.joined(separator: " ")))
            return
        }
        if let row = view as? SettingsRow {
            list.append(entry(for: row, groupTitle: groupTitle))
            return
        }
        for subview in view.subviews {
            collectEntries(in: subview, groupTitle: groupTitle, into: &list)
        }
    }

    private func entry(for row: SettingsRow, groupTitle: String) -> Entry {
        let parts = [
            groupTitle, row.titleLabel.stringValue, row.subtitleLabel?.stringValue, row.help?.explanation,
        ].compactMap { $0 }
        return Entry(target: row, searchableText: parts.joined(separator: " "))
    }
}
