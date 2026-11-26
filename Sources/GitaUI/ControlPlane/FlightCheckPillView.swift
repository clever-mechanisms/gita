import AppKit
import GitaCore

@MainActor
struct FlightCheckDisplay {
    let title: String
    let state: SignalState
    private var customSymbol: String?
    var symbol: String { customSymbol ?? Style.stateSymbol(state) }
    var color: NSColor { Theme.color(for: state) }
    var sha: String?
    var duration: String?
    var output = FlightCheckOutput()
    var detail: String?

    static func make(_ state: FlightCheckState) -> Self {
        switch state {
        case .unconfigured:
            return Self(
                title: String(localized: "Configure check"), state: .neutral, customSymbol: "slider.horizontal.3")
        case .idle(let last):
            if let last { return result(last) }
            return Self(title: String(localized: "Ready to check"), state: .neutral)
        case .preparing(let sha):
            return Self(title: String(localized: "Preparing"), state: .pending, sha: sha)
        case .running(let sha, _, let tail):
            return Self(
                title: String(localized: "Checking"), state: .running, sha: sha,
                output: tail)
        case .passed(let value), .failed(let value): return result(value)
        case .cancelled: return Self(title: String(localized: "Stopped"), state: .cancelled)
        case .error(let message):
            return Self(
                title: String(localized: "Check unavailable"), state: .failure,
                detail: message)
        }
    }

    private static func result(_ value: FlightCheckResult) -> Self {
        let state: SignalState = value.succeeded ? .success : .failure
        return Self(
            title: value.succeeded ? String(localized: "Passed") : String(localized: "Failed"),
            state: state, sha: value.commitSHA,
            duration: DeckFormat.duration(value.duration), output: value.output,
            detail: value.succeeded ? nil : String(localized: "Command exited with status \(value.exitCode)."))
    }
}

@MainActor
public final class FlightCheckPillView: NSView {
    private let presenter: FlightCheckPresenter
    private let button = PartsButton(frame: .zero)

    init(presenter: FlightCheckPresenter, present: @escaping @MainActor () -> Void) {
        self.presenter = presenter
        super.init(frame: .zero)
        button.onClick = present
        button.cornerRadius = button.fixedHeight / 2
        button.background = .quiet
        button.spacing = 4
        Deck.pin(button, in: self)
        button.setAccessibilityIdentifier("controlPlane.flightCheck.pill")
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(render), name: FlightCheckPresenter.didChange, object: presenter)
        center.addObserver(self, selector: #selector(render), name: .gitaThemeChanged, object: nil)
        render()
    }
    required init?(coder _: NSCoder) { nil }
    public override var intrinsicContentSize: NSSize { button.intrinsicContentSize }
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }

    @objc private func render() {
        let display = FlightCheckDisplay.make(presenter.state)
        button.parts = [
            .symbol(display.symbol, color: display.color, size: 12),
            .text(display.title, font: Theme.captionEmphasis, color: Theme.text),
        ]
        if let duration = display.duration {
            button.parts.append(.badge(duration, fill: Deck.segmentFill, color: Theme.secondaryText))
        }
        let label = String(localized: "Pre-push flight check, \(display.title)")
        button.setAccessibilityLabel(label)
        button.toolTip = display.detail ?? label
        invalidateIntrinsicContentSize()
    }
}

/// Hosts the active tab's `FlightCheckPillView` inside the shared main toolbar without starting timers or subprocesses.
@MainActor
final class FlightCheckToolbarSlot: NSView {
    private var currentRoot: URL?
    private var pill: FlightCheckPillView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
    }

    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    override var intrinsicContentSize: NSSize { pill?.intrinsicContentSize ?? .zero }

    func update(root: URL?, gitService: GitService?) {
        let normalized = root?.standardizedFileURL.resolvingSymlinksInPath()
        guard normalized != currentRoot || (normalized != nil && pill == nil) else { return }
        currentRoot = normalized
        pill?.removeFromSuperview()
        pill = nil
        if let root, let gitService {
            let view = ControlPlaneFacade.shared.makeFlightCheckPill(for: root, gitService: gitService) { [weak self] in
                ControlPlaneFacade.shared.presentFlightCheckSheet(
                    for: root, gitService: gitService, on: self?.window ?? NSApp.keyWindow)
            }
            Deck.pin(view, in: self)
            pill = view
            isHidden = false
        } else {
            isHidden = true
        }
        invalidateIntrinsicContentSize()
    }
}
