import AppKit

/// A small, fictional history that shows what a merge setting does by playing it: every few seconds it eases between
/// the setting off and on, with an Off/On tag naming the state drawn. With reduced motion it holds still on the
/// state the setting has now. Drawing only; nothing is read.
@MainActor
final class MergeIllustrationView: NSView {
    enum Kind: CaseIterable {
        /// Collapse merged commits: the merge's row stands for the commits it brought in.
        case collapse
        /// Show squash merges as merges: the squashed branch joins its squash commit.
        case squash

        var title: String {
            switch self {
            case .collapse: String(localized: "Collapse merged commits")
            case .squash: String(localized: "Show squash merges as merges")
            }
        }
    }

    static let height: CGFloat = 156
    private static let hold: TimeInterval = 1.4

    let kind: Kind
    /// The state drawn (or being eased into).
    private(set) var isOn: Bool
    /// The eased move into `isOn`, 0…1 (1 while still).
    private(set) var progress: CGFloat = 1
    /// Whether it plays by itself; off with reduced motion and in tests.
    var plays = !Deck.reduceMotion
    private let ticker = FrameTicker()
    private var phaseStart = Date()

    init(_ kind: Kind, isOn: Bool) {
        self.kind = kind
        self.isOn = isOn
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Illustration: \(kind.title)"))
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("MergeIllustrationView is built in code") }

    override var isFlipped: Bool { true }

    /// The setting changed: show its new state at once, eased in.
    func show(_ on: Bool) {
        guard on != isOn else { return }
        move(to: on)
    }
    /// The next state of the loop, eased in.
    func advance() { move(to: !isOn) }

    func start() {
        guard plays, !ticker.isRunning else { return }
        phaseStart = Date()
        ticker.start { [weak self] in self?.tick() }
    }
    func stop() {
        ticker.stop()
        progress = 1
        needsDisplay = true
    }

    private func move(to on: Bool) {
        isOn = on
        phaseStart = Date()
        // Eased in only while the ticker runs; stopped, the new state draws at once (as SyncIllustrationView does).
        progress = ticker.isRunning ? 0 : 1
        needsDisplay = true
    }
    private func tick() {
        let elapsed = Date().timeIntervalSince(phaseStart)
        progress = min(1, CGFloat(elapsed / SetupStageView.transition))
        if elapsed > SetupStageView.transition + Self.hold { advance() }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_: NSRect) {
        let amount = SetupStageView.eased(progress)
        MergeIllustrationScenes.card(kind, isOn: isOn, amount: isOn ? amount : 1 - amount, in: bounds)
    }
}

/// The two scenes `MergeIllustrationView` and the Setup Guide's History step play, from how far the setting is on
/// (0…1).
@MainActor
enum MergeIllustrationScenes {
    static let rowHeight: CGFloat = 22
    /// The rows the taller of the two scenes needs.
    static let rows = 6
    private static var textX: CGFloat { SetupScenes.laneX(2, in: .zero) + 8 }

    /// The setting's scene on its panel, with an Off/On tag naming the state drawn (or being moved into); the rows
    /// are as tall as fit (at most `rowHeight`). The card around it names the setting.
    static func card(_ kind: MergeIllustrationView.Kind, isOn: Bool, amount on: CGFloat, in bounds: NSRect) {
        SetupScenes.panel(bounds)
        scene(kind, isOn: isOn, amount: on, in: bounds.insetBy(dx: 14, dy: 12))
    }

    /// The scene alone: the tag at the top right, the history beside it.
    static func scene(_ kind: MergeIllustrationView.Kind, isOn: Bool, amount on: CGFloat, in rect: NSRect) {
        SetupScenes.stateTag(isOn, in: rect)
        let height = min(rowHeight, rect.height / CGFloat(rows))
        switch kind {
        case .collapse: collapse(folded: on, in: rect, rowHeight: height)
        case .squash: squash(joined: on, in: rect, rowHeight: height)
        }
    }

    @discardableResult
    private static func row(
        _ subject: String, at y: CGFloat, in rect: NSRect, font: NSFont = Theme.body,
        color: NSColor = Theme.text, alpha: CGFloat = 1
    ) -> CGFloat {
        SetupScenes.text(
            subject, at: NSPoint(x: rect.minX + textX, y: y - 8), font: font, color: color, alpha: alpha,
            width: rect.width - textX)
    }

    /// A merge with its three commits below it; folded, they slide up into the merge's row and its chip.
    static func collapse(folded: CGFloat, in rect: NSRect, rowHeight: CGFloat = rowHeight) {
        let open = 1 - folded
        let subjects = [
            String(localized: "Search field"), String(localized: "Index results"), String(localized: "Search tests"),
        ]
        let mainX = SetupScenes.laneX(0, in: rect)
        let branchX = SetupScenes.laneX(1, in: rect)
        let mergeY = rect.minY + rowHeight / 2
        let afterY = mergeY + rowHeight * (1 + CGFloat(subjects.count) * open)
        SetupScenes.edge(
            from: NSPoint(x: mainX, y: mergeY), to: NSPoint(x: mainX, y: afterY + rowHeight), color: SetupScenes.lane(0)
        )
        if open > 0.01 {
            let lastY = mergeY + rowHeight * CGFloat(subjects.count) * open
            let branch = SetupScenes.lane(1)
            SetupScenes.edge(
                from: NSPoint(x: mainX, y: mergeY), to: NSPoint(x: branchX, y: mergeY + rowHeight * open),
                color: branch, alpha: open)
            SetupScenes.edge(
                from: NSPoint(x: branchX, y: mergeY + rowHeight * open), to: NSPoint(x: branchX, y: lastY),
                color: branch, alpha: open)
            SetupScenes.edge(
                from: NSPoint(x: branchX, y: lastY), to: NSPoint(x: mainX, y: afterY), color: branch, alpha: open)
            for (index, subject) in subjects.enumerated() {
                let y = mergeY + rowHeight * CGFloat(index + 1) * open
                SetupScenes.node(NSPoint(x: branchX, y: y), color: branch, alpha: open)
                row(subject, at: y, in: rect, alpha: open)
            }
        }
        SetupScenes.node(NSPoint(x: mainX, y: mergeY), color: SetupScenes.lane(0))
        let width = row(String(localized: "Merge search"), at: mergeY, in: rect, font: Theme.bodyEmphasis)
        let chevron = Deck.symbol(open > 0.5 ? "chevron.down" : "chevron.right", size: 8, color: Theme.accentText)
        SetupScenes.pill(
            String(localized: "\(subjects.count) commits"),
            at: NSPoint(x: rect.minX + textX + width + 8, y: mergeY - 9),
            color: Theme.accentText, image: chevron)
        SetupScenes.node(NSPoint(x: mainX, y: afterY), color: SetupScenes.lane(0))
        row(String(localized: "Update README"), at: afterY, in: rect)
        SetupScenes.node(NSPoint(x: mainX, y: afterY + rowHeight), color: SetupScenes.lane(0), hollow: true)
        row(String(localized: "Release 0.9"), at: afterY + rowHeight, in: rect, color: Theme.secondaryText)
    }

    /// A squash commit on main and the branch it squashed; joined, the branch's line runs into the squash commit.
    static func squash(joined: CGFloat, in rect: NSRect, rowHeight: CGFloat = rowHeight) {
        let mainX = SetupScenes.laneX(0, in: rect)
        let branchX = SetupScenes.laneX(1, in: rect)
        let y = (0..<6).map { rect.minY + rowHeight * (CGFloat($0) + 0.5) }
        let main = SetupScenes.lane(0)
        let branch = SetupScenes.lane(1)
        SetupScenes.edge(from: NSPoint(x: mainX, y: y[0]), to: NSPoint(x: mainX, y: y[5]), color: main)
        SetupScenes.edge(from: NSPoint(x: branchX, y: y[1]), to: NSPoint(x: branchX, y: y[3]), color: branch)
        SetupScenes.edge(from: NSPoint(x: branchX, y: y[3]), to: NSPoint(x: mainX, y: y[4]), color: branch)
        if joined > 0.01 {
            SetupScenes.edge(
                from: NSPoint(x: mainX, y: y[0]), to: NSPoint(x: branchX, y: y[1]), color: branch, alpha: joined)
        }
        let rows: [(lane: Int, subject: String, label: String?)] = [
            (0, String(localized: "Add search (#42)"), "main"),
            (1, String(localized: "Search tests"), "search"),
            (1, String(localized: "Index results"), nil),
            (1, String(localized: "Search field"), nil),
            (0, String(localized: "Update README"), nil),
            (0, String(localized: "Release 0.9"), nil),
        ]
        for (index, item) in rows.enumerated() {
            let x = item.lane == 0 ? mainX : branchX
            SetupScenes.node(NSPoint(x: x, y: y[index]), color: SetupScenes.lane(item.lane), hollow: index == 5)
            var textStart = rect.minX + textX
            if let label = item.label {
                textStart +=
                    SetupScenes.pill(
                        label, at: NSPoint(x: textStart, y: y[index] - 9), color: SetupScenes.lane(item.lane)) + 6
            }
            SetupScenes.text(
                item.subject, at: NSPoint(x: textStart, y: y[index] - 8),
                font: index == 0 ? Theme.bodyEmphasis : Theme.body,
                color: index == 5 ? Theme.secondaryText : Theme.text, width: rect.maxX - textStart)
        }
    }
}
