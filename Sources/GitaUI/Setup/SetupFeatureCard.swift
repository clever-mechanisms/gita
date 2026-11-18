import AppKit

/// One card that says what something is and shows it: the option's tile (its mark, words and switch or control) on
/// top, and its animated scene under it.
@MainActor
final class SetupFeatureCard: NSView {
    static let sceneHeight: CGFloat = 160

    init(tile: SetupOptionTile, stage: SetupStageView) {
        super.init(frame: .zero)
        tile.drawsBackground = false
        for view in [tile, stage] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            tile.topAnchor.constraint(equalTo: topAnchor),
            tile.leadingAnchor.constraint(equalTo: leadingAnchor),
            tile.trailingAnchor.constraint(equalTo: trailingAnchor),
            stage.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: -2),
            stage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stage.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stage.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            stage.heightAnchor.constraint(equalToConstant: Self.sceneHeight),
        ])
    }
    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    override func draw(_: NSRect) { SetupOptionTile.drawCard(bounds) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
