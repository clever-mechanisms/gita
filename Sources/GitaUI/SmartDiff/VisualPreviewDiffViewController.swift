import AppKit
import GitaCore

@MainActor
final class VisualPreviewDiffViewController: NSViewController {
    let pair: VisualPreviewPair
    let comparison: VisualPreviewDiffView
    var onBack: (() -> Void)? {
        didSet {
            if isViewLoaded { header.onBack = onBack }
        }
    }
    private lazy var header = AgentControlHeaderView(
        .init(
            symbol: "rectangle.split.2x1",
            title: pair.title,
            subtitle: Self.subtitle(for: pair),
            id: "preview",
            backTitle: String(localized: "Deployments"),
            accessibilityPrefix: "smartdiff."))

    init(pair: VisualPreviewPair, initialRoute: String = "/") {
        self.pair = pair
        let presenter = VisualPreviewDiffPresenter(
            productionURL: pair.productionURL, previewURL: pair.previewURL, initialRoute: initialRoute)
        comparison = VisualPreviewDiffView(presenter: presenter)
        super.init(nibName: nil, bundle: nil)
        title = pair.title
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(pair:initialRoute:)") }

    override func loadView() {
        header.onBack = onBack
        let root = ThemedBackgroundView()
        let column = AgentControlUI.column([header, comparison], spacing: 0)
        Deck.pin(column, in: root)
        root.smartDiffAccessibility(pair.title, "preview.controller")
        view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        if comparison.presenter.state == .idle { comparison.reload() }
    }

    func tearDown() {
        comparison.tearDown()
    }

    private static func subtitle(for pair: VisualPreviewPair) -> String {
        let production = pair.productionURL.host ?? pair.productionURL.absoluteString
        let preview = pair.previewURL.host ?? pair.previewURL.absoluteString
        if production == preview { return preview }
        return String(localized: "\(production) ↔ \(preview)")
    }
}
