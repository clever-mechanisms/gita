import AppKit
import GitaCore

/// An agent's mark that moves while the agent works: the radial marks (Claude's spark, OpenAI's knot, Gemini's star)
/// turn, the others breathe. Still while it waits, is done or idle (dimmed), while the window is hidden or occluded,
/// and with Reduce Motion. The animation runs in Core Animation, not in a timer.
/// Motion is the only state sign on a mark: moving means working. There is no state dot and no state colour on the
/// mark; the words beside it say the rest.
@MainActor
final class AgentMarkView: NSView {
    var tool: AgentTool? {
        didSet {
            if oldValue != tool {
                needsDisplay = true
                restartMotion()
            }
        }
    }
    var state: AgentState? {
        didSet {
            if oldValue != state {
                needsDisplay = true
                updateMotion()
            }
        }
    }
    var agent: AgentMarkState? {
        get { tool.flatMap { tool in state.map { AgentMarkState(tool: tool, state: $0) } } }
        set {
            tool = newValue?.tool
            state = newValue?.state
        }
    }
    var side: CGFloat {
        didSet {
            if oldValue != side {
                invalidateIntrinsicContentSize()
                needsDisplay = true
            }
        }
    }
    private let mark = CALayer()
    private(set) var moving = false
    var reduceMotion: () -> Bool = { Deck.reduceMotion }
    var isWindowVisible: (NSWindow?) -> Bool = {
        $0.map { $0.occlusionState.contains(.visible) && $0.isVisible } ?? false
    }
    private var occlusionObserver: NSObjectProtocol?
    private var motionObserver: NSObjectProtocol?

    init(side: CGFloat = 14) {
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        mark.contentsGravity = .resizeAspect
        layer?.addSublayer(mark)
        setAccessibilityElement(false)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        motionObserver = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMotion() }
        }
    }
    @available(*, unavailable, message: "Agent marks are built in code")
    required init?(coder _: NSCoder) { fatalError("Agent marks are built in code") }
    isolated deinit {
        if let motionObserver { NotificationCenter.default.removeObserver(motionObserver) }
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
    }
    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }
    override var wantsUpdateLayer: Bool { true }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mark.frame = bounds
        CATransaction.commit()
    }
    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let tool else {
            mark.contents = nil
            return
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let image = AgentMarks.image(tool, size: side)
        // Rendered under this view's appearance: the monochrome marks take the theme's text colour.
        var rendered: CGImage?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            var rect = NSRect(x: 0, y: 0, width: side, height: side)
            rendered = image.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: AffineTransform(scale: scale)])
        }
        mark.contents = rendered
        mark.contentsScale = scale
        mark.opacity = state == .idle ? 0.55 : 1
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMotion() }
            }
        }
        updateMotion()
    }
    override func viewDidHide() {
        super.viewDidHide()
        updateMotion()
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateMotion()
    }
    private func restartMotion() {
        mark.removeAllAnimations()
        moving = false
        updateMotion()
    }
    static func shouldAnimate(
        hasTool: Bool, state: AgentState?, visible: Bool, hidden: Bool, reduceMotion: Bool
    ) -> Bool {
        hasTool && state == .working && visible && !hidden && !reduceMotion
    }

    func updateMotion() {
        let visible = isWindowVisible(window)
        let shouldMove = Self.shouldAnimate(
            hasTool: tool != nil, state: state, visible: visible, hidden: isHiddenOrHasHiddenAncestor,
            reduceMotion: reduceMotion())
        guard shouldMove != moving else { return }
        moving = shouldMove
        guard shouldMove, let tool else {
            mark.removeAllAnimations()
            return
        }
        mark.add(Self.motion(AgentMarks.kind(tool)), forKey: "motion")
    }

    /// Radial marks turn; the others breathe.
    static func motion(_ kind: AgentMarkPainter.Kind) -> CABasicAnimation {
        let animation: CABasicAnimation
        switch kind {
        case .claude, .openAI, .gemini:
            animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = 0
            animation.toValue = -2 * CGFloat.pi
            animation.duration = 2.4
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
        case .cursor, .opencode, .aider, .antigravity:
            animation = CABasicAnimation(keyPath: "transform.scale")
            animation.fromValue = 1
            animation.toValue = 0.78
            animation.duration = 0.8
            animation.autoreverses = true
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        }
        animation.repeatCount = .infinity
        return animation
    }
}
