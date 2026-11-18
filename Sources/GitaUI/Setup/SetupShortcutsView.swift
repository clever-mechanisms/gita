import AppKit
import GitaCore

/// The Ready step's keyboard card: the shortcuts worth knowing on day one, two columns of a name and its keys, with
/// the shortcuts Settings ▸ Shortcuts can change read as they are set now.
@MainActor
final class SetupShortcutsView: NSView {
    struct Item: Equatable {
        var title: String
        var keys: [String]
    }

    private static let rowHeight: CGFloat = 32
    private static let headerHeight: CGFloat = 34
    private static let padding: CGFloat = 14
    private static let keyFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
    private static let keyHeight: CGFloat = 24
    private static let keyInset: CGFloat = 8

    let items: [Item]

    init(defaults: UserDefaults = Preference.store) {
        items = Self.items(defaults)
        super.init(frame: .zero)
        let rows = CGFloat((items.count + 1) / 2)
        heightAnchor.constraint(equalToConstant: Self.headerHeight + rows * Self.rowHeight + Self.padding).isActive =
            true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("setup.shortcuts")
        setAccessibilityLabel(
            ([String(localized: "Keyboard shortcuts")] + items.map { "\($0.title): \($0.keys.joined(separator: ", "))" })
                .joined(separator: ". "))
    }
    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    override var isFlipped: Bool { true }

    /// The shortcuts, in reading order (down the first column, then the second).
    static func items(_ defaults: UserDefaults) -> [Item] {
        let keys = { (commands: [ShortcutCommand]) in
            commands.compactMap { ShortcutStore.shortcut($0, defaults)?.display }
        }
        return [
            Item(title: String(localized: "Open a repository"), keys: ["⌘O"]),
            Item(title: String(localized: "Open another in a new tab"), keys: ["⌘T"]),
            Item(
                title: String(localized: "History · Changes · Worktrees"),
                keys: keys([.allCommits, .localChanges, .worktrees])),
            Item(
                title: PaletteItems.commandTitle(ShortcutCommand.commandPalette.title), keys: keys([.commandPalette])),
            Item(title: String(localized: "Fetch · Pull · Push"), keys: keys([.fetch, .pull, .push])),
            Item(title: String(localized: "Find in history"), keys: ["⌘F"]),
            Item(title: String(localized: "Commit details"), keys: ["⌘D"]),
            Item(title: String(localized: "Zoom"), keys: ["⌘+", "⌘−", "⌘0"]),
            Item(title: String(localized: "Menu bar panel"), keys: ["⇧⌘M"]),
            Item(title: String(localized: "Settings"), keys: ["⌘,"]),
        ]
    }

    override func draw(_: NSRect) {
        SetupOptionTile.drawCard(bounds)
        let inner = bounds.insetBy(dx: Self.padding, dy: 0)
        Deck.symbol("keyboard", size: 13, weight: .medium, color: Theme.accentText)?.draw(
            in: NSRect(x: inner.minX, y: 11, width: 18, height: 13), from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: true, hints: nil)
        SetupScenes.text(
            String(localized: "Keyboard"), at: NSPoint(x: inner.minX + 24, y: 9), font: Theme.bodyEmphasis,
            color: Theme.text)
        let again = String(localized: "Gitā ▸ Setup Guide… opens this guide again.")
        let againWidth = SetupScenes.textWidth(again, font: Theme.caption)
        SetupScenes.text(
            again, at: NSPoint(x: max(inner.minX + 100, inner.maxX - againWidth), y: 10), font: Theme.caption,
            color: Theme.secondaryText, width: min(againWidth, inner.width - 100))
        let perColumn = (items.count + 1) / 2
        let gap: CGFloat = 24
        let columnWidth = (inner.width - gap) / 2
        for (index, item) in items.enumerated() {
            let column = CGFloat(index / perColumn)
            let row = CGFloat(index % perColumn)
            draw(
                item,
                in: NSRect(
                    x: inner.minX + column * (columnWidth + gap), y: Self.headerHeight + row * Self.rowHeight,
                    width: columnWidth, height: Self.rowHeight))
        }
    }

    /// The name on the left, its keys as keycaps on the right.
    private func draw(_ item: Item, in rect: NSRect) {
        var x = rect.maxX
        for key in item.keys.reversed() {
            let width = max(Self.keyHeight, SetupScenes.textWidth(key, font: Self.keyFont) + Self.keyInset * 2)
            x -= width
            let cap = NSRect(
                x: x, y: rect.minY + (rect.height - Self.keyHeight) / 2, width: width, height: Self.keyHeight)
            let shape = NSBezierPath(roundedRect: cap, xRadius: 6, yRadius: 6)
            Theme.window.setFill()
            shape.fill()
            Theme.separator.setStroke()
            shape.stroke()
            SetupScenes.text(
                key, at: NSPoint(x: cap.minX + Self.keyInset, y: cap.minY + 4), font: Self.keyFont, color: Theme.text)
            x -= 5
        }
        SetupScenes.text(
            item.title, at: NSPoint(x: rect.minX, y: rect.minY + 7), font: Theme.body, color: Theme.text,
            width: max(0, x - rect.minX - 6))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
