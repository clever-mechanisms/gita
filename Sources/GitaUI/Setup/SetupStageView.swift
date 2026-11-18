import AppKit

/// One animated scene of the Setup Guide (`SetupScene`): a small, fictional picture of what an option or a step is
/// about (the history searched and zoomed, a merge folding its commits away, a commit gaining its pull request,
/// checks and preview, agents changing state, the menu bar panel). It reads nothing: `SetupScenes` draws it from the
/// step and the drafted choices, so a switch turned off shows at once (Vercel's preview leaves the picture). Each
/// `advance` moves to the next step and eases into it; with reduced motion, or `animates` off, the step shows at once.
@MainActor
final class SetupStageView: NSView {
    static let transition: TimeInterval = 0.4
    private static let frameInterval: TimeInterval = 1.0 / 60

    let scene: SetupScene
    var choices: SetupChoices { didSet { needsDisplay = true } }
    /// Whether moves ease in over `transition`; off in tests and with reduced motion.
    var animates = !Deck.reduceMotion
    private(set) var step = 0
    /// How far the move to `step` has come, 0…1 (1 while still).
    private(set) var progress: CGFloat = 1
    private var timer: Timer?
    private var transitionStart = Date()

    /// `title` names what the scene shows, for VoiceOver.
    init(scene: SetupScene, choices: SetupChoices, title: String) {
        self.scene = scene
        self.choices = choices
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "Illustration: \(title)"))
        setAccessibilityIdentifier("setup.stage." + scene.rawValue)
    }
    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }
    isolated deinit { timer?.invalidate() }

    override var isFlipped: Bool { true }

    /// The next step of the scene, eased in.
    func advance() {
        step = (step + 1) % scene.steps
        guard animates else {
            progress = 1
            needsDisplay = true
            return
        }
        progress = 0
        transitionStart = Date()
        startTimer()
        needsDisplay = true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        progress = 1
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        progress = min(1, CGFloat(Date().timeIntervalSince(transitionStart) / Self.transition))
        needsDisplay = true
        if progress >= 1 { stop() }
    }

    /// Ease in and out: slow at both ends.
    static func eased(_ value: CGFloat) -> CGFloat {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    override func draw(_: NSRect) {
        SetupScenes.panel(bounds)
        // A scene across the page has more room around it than one in a card.
        let inset: CGFloat = bounds.height > 180 ? 18 : 12
        SetupScenes.draw(
            SetupScenes.Frame(
                scene: scene, step: step, progress: Self.eased(progress), choices: choices,
                rect: bounds.insetBy(dx: inset, dy: inset)))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
