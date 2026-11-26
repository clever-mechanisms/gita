import AppKit
import GitaCore

@MainActor
final class ExternalToolsSettingsView: NSView {
    private let detector: ExternalToolDetector
    private let detectionTask = LatestTask()
    private let diff: ExternalToolSettingsGroup
    private let merge: ExternalToolSettingsGroup
    private let installed = SettingsGroup(String(localized: "Installed tools"), [])
    private(set) var detections: [ExternalToolPreset: ExternalToolDetection] = [:]
    var onLayoutChange: (() -> Void)?

    init(
        defaults: UserDefaults, detector: ExternalToolDetector = ExternalToolDetector(),
        runner: any CommandRunning = CommandRunner()
    ) {
        self.detector = detector
        let config = ExternalToolConfig.load(from: defaults)
        let launcher = ExternalToolLauncher(runner: runner, detector: detector)
        diff = ExternalToolSettingsGroup(kind: .diff, selection: config.diffTool, launcher: launcher) { selection in
            var config = ExternalToolConfig.load(from: defaults)
            config.diffTool = selection
            config.save(to: defaults)
        }
        merge = ExternalToolSettingsGroup(kind: .merge, selection: config.mergeTool, launcher: launcher) { selection in
            var config = ExternalToolConfig.load(from: defaults)
            config.mergeTool = selection
            config.save(to: defaults)
        }
        super.init(frame: .zero)
        let stack = NSStackView(views: [diff.group, merge.group, installed])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for view in stack.arrangedSubviews { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        installed.setRows([SettingsRow(String(localized: "Checking…"), [])])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ExternalToolsSettingsView is built in code") }

    func didAppear() {
        detectionTask.run(
            { [detector] in await detector.detectAll() },
            then: { [weak self] result in
                guard let self, case .success(let found) = result else { return }
                detections = found
                diff.updateDetections(detections)
                merge.updateDetections(detections)
                let badges = ExternalToolPreset.allCases.compactMap { preset -> ActionToolBadge? in
                    guard case .installed = detections[preset] else { return nil }
                    return ActionToolBadge(preset.displayName, color: Theme.success)
                }
                let rows = stride(from: 0, to: badges.count, by: 3).map { index in
                    SettingsRow("", Array(badges[index...].prefix(3)))
                }
                installed.setRows(
                    rows.isEmpty ? [SettingsRow(String(localized: "No installed tools found"), [])] : rows)
                onLayoutChange?()
            })
    }

    func didDisappear() {
        detectionTask.cancel()
        diff.cancel()
        merge.cancel()
    }
}

@MainActor
final class ExternalToolsSettingsPane: SettingsPaneContent {
    let tools: ExternalToolsSettingsView

    init(environment: SettingsEnvironment, detector: ExternalToolDetector = ExternalToolDetector()) {
        tools = ExternalToolsSettingsView(defaults: environment.defaults, detector: detector)
        super.init(environment: environment)
        tools.onLayoutChange = { [weak self] in self?.onLayoutChange?() }
        setGroups([tools])
    }

    override func didAppear() { tools.didAppear() }
    override func didDisappear() { tools.didDisappear() }
}
