import AppKit
import GitaCore

/// A step's options, two to a row: switches for the settings the step is about (with each provider's and agent's
/// own mark), or tiles that only explain. An option with a scene is a card that shows it under its words
/// (`SetupFeatureCard`). The values are the guide's draft (`SetupChoices`).
@MainActor
final class SetupOptionsView: NSView {
    /// One tile: its picture, words and, for a switch, the setting it drafts; `scene` shows it under the words, and
    /// `isZoom` puts the history zoom's control on it.
    struct Spec {
        var image: NSImage?
        var title: String
        var detail: String
        var preference: Preference?
        var scene: SetupScene?
        var isZoom = false
    }

    var onChange: ((Preference, Bool) -> Void)?
    private(set) var tiles: [Preference: SetupOptionTile] = [:]
    /// The cards' scenes, in order.
    private(set) var stages: [SetupStageView] = []
    private let grid = NSStackView()

    /// `zoom` is the history zoom's control, for the tile that asks for it.
    init(card: SetupGuideCard, choices: SetupChoices, zoom: NSView? = nil) {
        super.init(frame: .zero)
        setAccessibilityIdentifier("setup.options." + card.identifier)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 10
        Style.fill(grid, in: self)
        let made = Self.specs(card).map { view(for: $0, choices: choices, zoom: zoom) }
        for start in stride(from: 0, to: made.count, by: 2) {
            let pair = Array(made[start..<min(start + 2, made.count)])
            let row = NSStackView(views: pair.count == 1 ? pair + [NSView()] : pair)
            row.distribution = .fillEqually
            row.spacing = 10
            row.alignment = .top
            grid.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        }
        update(choices)
    }
    @available(*, unavailable, message: "Built in code")
    required init?(coder _: NSCoder) { fatalError("Built in code") }

    private func view(for spec: Spec, choices: SetupChoices, zoom: NSView?) -> NSView {
        let tile = SetupOptionTile(
            image: spec.image, title: spec.title, detail: spec.detail, preference: spec.preference,
            accessory: spec.isZoom ? zoom : nil
        ) { [weak self] preference, on in self?.onChange?(preference, on) }
        if let preference = spec.preference { tiles[preference] = tile }
        guard let scene = spec.scene else { return tile }
        let stage = SetupStageView(scene: scene, choices: choices, title: spec.title)
        stages.append(stage)
        return SetupFeatureCard(tile: tile, stage: stage)
    }

    /// Shows the draft: every switch and scene, and each agent dimmed while detection as a whole is off.
    func update(_ choices: SetupChoices) {
        let detecting = choices[.useAgents]
        for (preference, tile) in tiles {
            let isAgent = preference.rawValue.hasPrefix("detect")
            tile.show(choices[preference], enabled: !isAgent || detecting)
        }
        for stage in stages { stage.choices = choices }
    }

    // MARK: Content

    static func specs(_ card: SetupGuideCard) -> [Spec] {
        switch card {
        case .welcome: welcomeSpecs
        case .history: historySpecs
        case .integrations: integrationSpecs
        case .agents: agentSpecs
        case .ready, .tools: []
        }
    }

    static func symbol(_ name: String) -> NSImage? {
        Deck.symbol(name, size: 20, weight: .medium, color: Theme.accentText)
    }

    private static var welcomeSpecs: [Spec] {
        [
            Spec(
                image: symbol("point.3.connected.trianglepath.dotted"),
                title: String(localized: "Every branch at once"),
                detail: String(localized: "Dense, zoomable history with search, filters and lazy commit trees."),
                scene: .history),
            Spec(
                image: BrandMarks.image(.github, size: 26), title: String(localized: "Pull requests and checks"),
                detail: String(localized: "Next to the commits they belong to, with Vercel previews."),
                scene: .pullRequests),
            Spec(
                image: AgentMarks.image(.claudeCode, size: 26), title: String(localized: "Coding agents"),
                detail: String(localized: "Claude Code, Codex and others, by branch and by state."), scene: .agents),
            Spec(
                image: symbol("menubar.rectangle"), title: String(localized: "Menu bar and notifications"),
                detail: String(localized: "Know when a check fails or an agent waits for you."), scene: .menuBar),
        ]
    }

    /// The commit details and the zoom first, then the merge settings.
    private static var historySpecs: [Spec] {
        [
            Spec(
                image: symbol("sidebar.squares.right"), title: String(localized: "Commit details"),
                detail: String(localized: "The message, files and checks under the history. ⌘D"),
                preference: .showsHistoryDetails, scene: .details),
            Spec(
                image: symbol("plus.magnifyingglass"), title: String(localized: "History zoom"),
                detail: String(localized: "Row height and text size."), scene: .zoom, isZoom: true),
            Spec(
                image: symbol("rectangle.compress.vertical"), title: String(localized: "Collapse merged commits"),
                detail: String(localized: "A merge stands for the commits it brought in; open it to see them."),
                preference: .collapsesMergedCommits, scene: .collapse),
            Spec(
                image: symbol("arrow.triangle.merge"), title: String(localized: "Squash merges as merges"),
                detail: String(localized: "Draw a squash-merged branch joining its squash commit."),
                preference: .squashMergesAsMerges, scene: .squash),
        ]
    }

    private static var integrationSpecs: [Spec] {
        [
            Spec(
                image: BrandMarks.image(.github, size: 26), title: "GitHub",
                detail: String(localized: "Pull requests, workflows and checks, through the gh CLI."),
                preference: .useGitHub),
            Spec(
                image: BrandMarks.image(.vercel, size: 24), title: "Vercel",
                detail: String(localized: "Deployments and previews, through the vercel CLI."), preference: .useVercel),
            Spec(
                image: BrandMarks.app(BrandMarks.orca, size: 28) ?? symbol("square.grid.3x1.below.line.grid.1x2"),
                title: "Orca", detail: String(localized: "Task titles and terminals of Orca’s worktrees."),
                preference: .useOrca),
            Spec(
                image: symbol("arrow.clockwise"), title: String(localized: "Refresh automatically"),
                detail: String(localized: "Read the providers again while a window is open."),
                preference: .providerRefresh),
        ]
    }

    private static var agentSpecs: [Spec] {
        [
            Spec(
                image: symbol("sparkles"), title: String(localized: "Detect coding agents"),
                detail: String(localized: "Watch for agent sessions in your repositories."), preference: .useAgents)
        ]
            + AgentTool.allCases.map { tool in
                Spec(
                    image: AgentMarks.image(tool, size: 26), title: tool.displayName,
                    detail: String(localized: "Show \(tool.displayName) sessions."),
                    preference: tool.detectionPreference)
            }
    }
}
