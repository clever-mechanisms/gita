import AppKit
import GitaCore

/// A small, fictional history that plays what the chosen Pull mode or Merge default does, in both situations it can
/// meet (`SyncScenes`): the history before, the operation moving commits and branch labels into place, the history
/// after, then the other situation. The graph is drawn as the history list draws it (`SceneGraph`). With reduced
/// motion the pictures cross-fade instead of sliding. Drawing only; nothing is read.
@MainActor
final class SyncIllustrationView: NSView {
    enum Choice: Equatable {
        case pull(GitPullMode)
        case merge(GitMergeMode)

        var setting: String {
            switch self {
            case .pull: String(localized: "Pull")
            case .merge: String(localized: "Merge")
            }
        }
        var option: String {
            switch self {
            case .pull(let mode): mode.localizedTitle
            case .merge(let mode): mode.localizedTitle
            }
        }
    }

    static let height: CGFloat = 262
    /// How long a picture holds: the history before the operation, and after it (longer, to read the caption).
    private static let holdBefore: TimeInterval = 1.3
    private static let holdAfter: TimeInterval = 2.6
    /// The operation's own move, slower than a change of scene so it can be followed.
    private static let operation: TimeInterval = 0.75

    /// The picture drawn (or being moved into).
    private(set) var still: SyncScenes.Still
    var choice: Choice { still.choice }
    private var previous: SyncScenes.Still?
    /// The move into `still`, 0…1 (1 while it holds).
    var progress: CGFloat = 1 { didSet { needsDisplay = true } }
    /// Whether it plays by itself; off in tests.
    var plays = true
    /// Whether the operation slides commits and labels; off with reduced motion, where pictures cross-fade.
    var moves = !Deck.reduceMotion
    private let ticker = FrameTicker()
    private var phaseStart = Date()

    init(_ choice: Choice) {
        still = SyncScenes.Still(choice: choice, situation: .behind, after: false)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        updateAccessibility()
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("SyncIllustrationView is built in code") }

    override var isFlipped: Bool { true }

    /// The setting changed: its history in the situation shown now, before the operation.
    func show(_ new: Choice) {
        guard new != choice else { return }
        go(to: SyncScenes.Still(choice: new, situation: still.situation, after: false))
        updateAccessibility()
    }

    /// The next picture of the loop: the operation runs, then the other situation, before it.
    func advance() {
        go(
            to: still.after
                ? SyncScenes.Still(choice: choice, situation: still.situation.next, after: false)
                : SyncScenes.Still(choice: choice, situation: still.situation, after: true))
    }

    func start() {
        guard plays, !ticker.isRunning else { return }
        phaseStart = Date()
        ticker.start { [weak self] in self?.tick() }
    }
    func stop() {
        ticker.stop()
        progress = 1
    }

    /// Moves into `new`, eased while playing, at once otherwise.
    private func go(to new: SyncScenes.Still) {
        previous = still
        still = new
        phaseStart = Date()
        progress = ticker.isRunning ? 0 : 1
    }
    /// The operation itself takes longer than a change of scene.
    private var duration: TimeInterval {
        previous?.situation == still.situation && previous?.choice == still.choice && still.after
            ? Self.operation : SetupStageView.transition
    }
    private func tick() {
        let elapsed = Date().timeIntervalSince(phaseStart)
        if progress < 1 { progress = min(1, CGFloat(elapsed / duration)) }
        if elapsed > duration + (still.after ? Self.holdAfter : Self.holdBefore) { advance() }
    }

    private func updateAccessibility() {
        let situations = SyncScenes.Situation.allCases.map {
            "\(SyncScenes.title(choice, $0)): \(SyncScenes.caption(choice, $0))"
        }
        setAccessibilityLabel(
            String(
                localized: "Illustration: \(choice.setting), \(choice.option). \(situations.joined(separator: " "))"))
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
        SyncScenes.card(
            still, from: progress < 1 ? previous : nil, amount: SetupStageView.eased(progress), moves: moves,
            in: bounds)
    }
}
