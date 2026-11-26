import AppKit
import GitaCore

@MainActor
final class ExternalToolSettingsGroup {
    let group: SettingsGroup
    private let kind: ExternalToolKind
    private var selection: ExternalToolSelection
    private var detections: [ExternalToolPreset: ExternalToolDetection] = [:]
    private let presenter = ExternalToolsPresenter()
    private let launcher: ExternalToolLauncher
    private let work = LatestTask()
    private var launchState = ExternalToolLaunchState.idle
    private let save: (ExternalToolSelection) -> Void
    private let status = SettingsForm.note()
    private let executable = SettingsForm.note()
    private let arguments = SettingsForm.note()
    private var invalidArguments: String?
    private lazy var popup = SettingsForm.popup(accessibility: group.titleLabel?.stringValue ?? "") { [weak self] in
        guard let value = $0.selectedValue, let preset = ExternalToolPreset(rawValue: value) else { return }
        self?.changePreset(preset)
    }
    private lazy var test = ActionButton(title: String(localized: "Test launch")) { [weak self] in self?.launch() }

    init(
        kind: ExternalToolKind, selection: ExternalToolSelection, launcher: ExternalToolLauncher,
        save: @escaping (ExternalToolSelection) -> Void
    ) {
        self.kind = kind
        self.selection = selection
        self.launcher = launcher
        self.save = save
        group = SettingsGroup(kind == .diff ? String(localized: "Diff tool") : String(localized: "Merge tool"), [])
        executable.font = Theme.mono
        executable.isSelectable = true
        arguments.font = Theme.mono
        arguments.isSelectable = true
        buildRows()
        updateDetections([:])
    }

    func updateDetections(_ values: [ExternalToolPreset: ExternalToolDetection]) {
        detections = values
        popup.removeAllItems()
        for preset in presenter.presets(for: kind) {
            let title =
                preset == .custom
                ? preset.displayName
                : String(localized: "\(preset.displayName) · \(presenter.installedBadge(values[preset]))")
            popup.addItem(title, value: preset.rawValue)
        }
        popup.select(value: selection.preset.rawValue)
        updateStatus()
    }

    func cancel() {
        work.cancel()
        launchState = .idle
        updateStatus()
    }

    private func changePreset(_ preset: ExternalToolPreset) {
        cancel()
        selection.preset = preset
        if preset == .custom, selection.customArguments.isEmpty {
            selection.customArguments = kind == .diff ? preset.defaultDiffArguments : preset.defaultMergeArguments
        }
        invalidArguments = nil
        save(selection)
        buildRows()
        updateStatus()
    }

    private func buildRows() {
        var rows = [SettingsRow(String(localized: "Preset"), [popup])]
        if selection.preset == .custom {
            rows += customRows()
        } else {
            rows.append(SettingsRow(String(localized: "Executable"), [executable]))
            rows.append(SettingsRow(String(localized: "Arguments"), [arguments]))
        }
        rows.append(SettingsRow("", [status, test]))
        group.setRows(rows)
    }

    private func customRows() -> [SettingsRow] {
        let title = String(localized: "Executable")
        let path = ActionEditorField(selection.customExecutable, label: title) { [weak self] in self?.setPath($0) }
        path.font = Theme.mono
        let browse = ActionButton(title: String(localized: "Browse…")) { [weak self, weak path] in
            let panel = NSOpenPanel()
            panel.treatsFilePackagesAsDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            path?.stringValue = url.path
            self?.setPath(url.path)
        }
        let argumentTitle = String(localized: "Argument tokens")
        let field = ActionEditorField(presenter.arguments(selection, kind: kind), label: argumentTitle) {
            [weak self] in self?.setArguments($0)
        }
        field.font = Theme.mono
        return [
            SettingsRow(title, [path, browse]),
            SettingsRow(
                argumentTitle, [field], help: String(localized: "Enter a JSON array with one string per argument.")),
        ]
    }

    private func setPath(_ value: String) {
        cancel()
        selection.customExecutable = value
        save(selection)
        updateStatus()
    }

    private func setArguments(_ value: String) {
        cancel()
        if let arguments = try? JSONDecoder().decode([String].self, from: Data(value.utf8)) {
            selection.customArguments = arguments
            invalidArguments = nil
            save(selection)
        } else {
            invalidArguments = String(localized: "Enter a JSON array of strings.")
        }
        updateStatus()
    }

    private func updateStatus() {
        let detected = detections[selection.preset]
        executable.stringValue = presenter.executable(selection, detection: detected)
        executable.toolTip = executable.stringValue
        arguments.stringValue = presenter.arguments(selection, kind: kind)
        arguments.toolTip = arguments.stringValue
        let validation = invalidArguments ?? presenter.validation(selection, kind: kind, detection: detected)
        test.isEnabled = validation == nil && launchState != .launching
        status.stringValue = validation ?? presenter.banner(launchState)
        status.toolTip = status.stringValue
        status.textColor = statusColor(validation: validation)
    }

    private func statusColor(validation: String?) -> NSColor {
        if validation != nil { return invalidArguments != nil ? Theme.failure : Theme.secondaryText }
        return launchStateColor()
    }

    private func launchStateColor() -> NSColor {
        if case .failed = launchState { return Theme.failure }
        if case .launched = launchState { return Theme.success }
        return launchState == .launching ? Theme.running : Theme.secondaryText
    }

    private func launch() {
        guard test.isEnabled else { return }
        launchState = .launching
        updateStatus()
        work.run(
            { [launcher, selection, kind] in try await launcher.testLaunch(selection: selection, kind: kind) },
            then: { [weak self] result in self?.applyLaunchResult(result) })
    }

    private func applyLaunchResult(_ result: Result<Void, Error>) {
        switch result {
        case .success: launchState = .launched(toolName: selection.preset.displayName)
        case .failure(let error): launchState = .failed(error.localizedDescription)
        }
        updateStatus()
    }
}
