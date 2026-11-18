import AppKit
import GitaCore

/// The strip between a side and the result: a band joins each change on the side to its place in the result, with
/// » (or «) to apply it and × to ignore it. The left strip also offers ↺ (revert) and the simple merge, level with
/// the result.
@MainActor
final class MergeGutterView: NSView {
    static let width: CGFloat = 44
    private static let button: CGFloat = 16

    private struct Hit {
        var rect: NSRect
        var action: MergeAction
        var symbol: String
        var tint: MergeTint
        var help: String
    }

    private let side: MergeSide
    private weak var sidePane: MergeTextView?
    private weak var resultPane: MergeTextView?
    private var chunks: [MergeGutterChunk] = []
    private var marks: [MergeGutterMark] = []
    private var wording = MergeWording(operation: nil)
    private var isEnabled = true
    private var hits: [Hit] = []
    var onAction: ((MergeAction) -> Void)?

    init(side: MergeSide, sidePane: MergeTextView, resultPane: MergeTextView) {
        self.side = side
        self.sidePane = sidePane
        self.resultPane = resultPane
        super.init(frame: .zero)
        clipsToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    override var isFlipped: Bool { true }

    func show(chunks: [MergeGutterChunk], marks: [MergeGutterMark], wording: MergeWording, enabled: Bool) {
        self.chunks = chunks
        self.marks = marks
        self.wording = wording
        isEnabled = enabled
        setAccessibilityLabel(String(localized: "Changes from \(wording.title(side))"))
        refresh()
    }

    /// Redraws after a scroll or a change.
    func refresh() {
        hits = layoutHits()
        removeAllToolTips()
        for hit in hits { addToolTip(hit.rect, owner: self, userData: nil) }
        // Each button is an accessibility button, so VoiceOver can find and press it.
        setAccessibilityChildren(
            hits.map { MergeGutterButton(gutter: self, action: $0.action, label: $0.help, frame: $0.rect) })
        needsDisplay = true
    }

    /// The top of `line` of `pane` in this view's coordinates (scrolling included).
    private func y(_ pane: MergeTextView?, line: Int) -> CGFloat {
        guard let pane else { return 0 }
        return convert(NSPoint(x: 0, y: pane.y(line: line)), from: pane).y
    }

    private func layoutHits() -> [Hit] {
        guard isEnabled else { return [] }
        var hits: [Hit] = []
        let size = Self.button
        let name = wording.title(side)
        for chunk in chunks where chunk.isPending {
            let top = y(sidePane, line: chunk.side.lowerBound) + 1
            let applyX = side == .ours ? 3 : bounds.width - size - 3
            let ignoreX = side == .ours ? applyX + size + 3 : applyX - size - 3
            hits.append(
                Hit(
                    rect: NSRect(x: applyX, y: top, width: size, height: size),
                    action: .apply(side, chunk: chunk.chunk),
                    symbol: side == .ours ? "chevron.right.2" : "chevron.left.2", tint: chunk.tint,
                    help: String(localized: "Apply the \(name) change")))
            hits.append(
                Hit(
                    rect: NSRect(x: ignoreX, y: top, width: size, height: size),
                    action: .ignore(side, chunk: chunk.chunk), symbol: "xmark", tint: chunk.tint,
                    help: String(localized: "Ignore the \(name) change")))
        }
        for mark in marks {
            let rect = NSRect(
                x: bounds.width - size - 2, y: y(resultPane, line: mark.line) + 1, width: size, height: size)
            switch mark.kind {
            case .revert:
                hits.append(
                    Hit(
                        rect: rect, action: .revert(chunk: mark.chunk), symbol: "arrow.uturn.backward",
                        tint: mark.tint, help: String(localized: "Revert this change in the result")))
            case .simple:
                hits.append(
                    Hit(
                        rect: rect, action: .simple(chunk: mark.chunk), symbol: "wand.and.stars", tint: mark.tint,
                        help: String(localized: "Both sides change different parts: merge them")))
            }
        }
        return hits
    }

    override func draw(_ dirtyRect: NSRect) {
        Theme.inset.setFill()
        bounds.intersection(dirtyRect).fill()
        for chunk in chunks {
            let sideTop = y(sidePane, line: chunk.side.lowerBound)
            let sideBottom = max(y(sidePane, line: chunk.side.upperBound), sideTop + 1)
            let resultTop = y(resultPane, line: chunk.result.lowerBound)
            let resultBottom = max(y(resultPane, line: chunk.result.upperBound), resultTop + 1)
            let (left, right) =
                side == .ours
                ? ((sideTop, sideBottom), (resultTop, resultBottom))
                : ((resultTop, resultBottom), (sideTop, sideBottom))
            let path = NSBezierPath()
            let middle = bounds.width / 2
            path.move(to: NSPoint(x: 0, y: left.0))
            path.curve(
                to: NSPoint(x: bounds.width, y: right.0), controlPoint1: NSPoint(x: middle, y: left.0),
                controlPoint2: NSPoint(x: middle, y: right.0))
            path.line(to: NSPoint(x: bounds.width, y: right.1))
            path.curve(
                to: NSPoint(x: 0, y: left.1), controlPoint1: NSPoint(x: middle, y: right.1),
                controlPoint2: NSPoint(x: middle, y: left.1))
            path.close()
            MergeColors.fill(chunk.tint, done: !chunk.isPending).setFill()
            path.fill()
        }
        for hit in hits { drawButton(hit) }
    }

    private func drawButton(_ hit: Hit) {
        let shape = NSBezierPath(roundedRect: hit.rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        Theme.window.setFill()
        shape.fill()
        MergeColors.line(hit.tint).setStroke()
        shape.stroke()
        let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [MergeColors.line(hit.tint)]))
        guard
            let image = NSImage(systemSymbolName: hit.symbol, accessibilityDescription: hit.help)?
                .withSymbolConfiguration(configuration)
        else { return }
        let origin = NSPoint(x: hit.rect.midX - image.size.width / 2, y: hit.rect.midY - image.size.height / 2)
        image.draw(in: NSRect(origin: origin, size: image.size))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = hits.first(where: { $0.rect.contains(point) }) else {
            super.mouseDown(with: event)
            return
        }
        onAction?(hit.action)
    }

    fileprivate func press(_ action: MergeAction) { onAction?(action) }
}

extension MergeGutterView: NSViewToolTipOwner {
    nonisolated func view(
        _ view: NSView, stringForToolTip _: NSView.ToolTipTag, point: NSPoint, userData _: UnsafeMutableRawPointer?
    ) -> String {
        MainActor.assumeIsolated { (view as? MergeGutterView)?.hits.first { $0.rect.contains(point) }?.help ?? "" }
    }
}

/// A gutter button for accessibility: its label, its place, and Press.
@MainActor
final class MergeGutterButton: NSAccessibilityElement {
    private nonisolated(unsafe) weak var gutter: MergeGutterView?
    nonisolated let action: MergeAction

    init(gutter: MergeGutterView, action: MergeAction, label: String, frame: NSRect) {
        self.gutter = gutter
        self.action = action
        super.init()
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityParent(gutter)
        setAccessibilityFrameInParentSpace(frame)
    }

    nonisolated override func accessibilityPerformPress() -> Bool {
        let gutter = gutter
        let action = action
        return MainActor.assumeIsolated {
            guard let gutter else { return false }
            gutter.press(action)
            return true
        }
    }
}
