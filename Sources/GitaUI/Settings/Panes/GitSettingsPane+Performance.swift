import AppKit
import GitaCore

/// Controls and async `~/.gitconfig` state for `Settings ▸ Git ▸ Performance & Global Defaults`.
@MainActor
final class GitPerformanceControls {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(GlobalGitPerformanceSnapshot)
        case saving(GlobalGitPerformanceSnapshot?)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .loading, .saving: true
            case .idle, .loaded, .failed: false
            }
        }

        var snapshot: GlobalGitPerformanceSnapshot? {
            switch self {
            case .loaded(let snapshot): snapshot
            case .saving(let snapshot): snapshot
            case .idle, .loading, .failed: nil
            }
        }
    }

    private let speedUp: AccentSwitch
    private let health: RepositoryHealthService
    private let onError: (Error) -> Void
    private var activeTask: Task<Void, Never>?
    private var pendingReload = false

    private(set) var state = LoadState.idle
    let globalFSMonitor: AccentSwitch
    let globalFSMonitorStatus: NSTextField
    let globalUntrackedCache: AccentSwitch
    let maintenanceCountLabel: NSTextField
    private(set) var fsMonitorRow: SettingsRow?

    init(
        speedUp: AccentSwitch,
        health: RepositoryHealthService,
        onError: @escaping (Error) -> Void = { _ in }
    ) {
        self.speedUp = speedUp
        self.health = health
        self.onError = onError
        var onFSMonitorToggle: (Bool) -> Void = { _ in }
        var onUntrackedCacheToggle: (Bool) -> Void = { _ in }
        globalFSMonitor = AccentSwitch(accessibility: String(localized: "Filesystem Monitor (Global)")) {
            onFSMonitorToggle($0)
        }
        globalFSMonitorStatus = SettingsForm.note()
        globalUntrackedCache = AccentSwitch(accessibility: String(localized: "Untracked Cache (Global)")) {
            onUntrackedCacheToggle($0)
        }
        maintenanceCountLabel = SettingsForm.note(String(localized: "Loading…"))
        configureControls()
        onFSMonitorToggle = { [weak self] enabled in self?.setGlobalFSMonitor(enabled) }
        onUntrackedCacheToggle = { [weak self] enabled in self?.setGlobalUntrackedCache(enabled) }
        applyState()
    }

    private func configureControls() {
        globalFSMonitor.setAccessibilityIdentifier("settings.git.globalFSMonitor")
        globalFSMonitorStatus.setAccessibilityIdentifier("settings.git.globalFSMonitorStatus")
        globalUntrackedCache.setAccessibilityIdentifier("settings.git.globalUntrackedCache")
        maintenanceCountLabel.setAccessibilityIdentifier("settings.git.globalMaintenanceCount")
    }

    func makeGroup() -> SettingsGroup {
        let monitorRow = SettingsRow(
            String(localized: "Filesystem Monitor (Global)"),
            [globalFSMonitorStatus, globalFSMonitor],
            subtitle: Self.defaultGlobalSubtitle,
            help: String(
                localized:
                    """
                    Sets core.fsmonitor in ~/.gitconfig so Git’s built-in filesystem monitor speeds up working tree \
                    checks across all repositories unless overridden per repository in Storage & Health.
                    """
            ))
        fsMonitorRow = monitorRow
        applyState()
        return SettingsGroup(
            String(localized: "Performance & Global Defaults"),
            [
                SettingsRow(
                    String(localized: "Speed up slow repositories"), [speedUp],
                    help: String(
                        localized:
                            """
                            When a large repository reads slowly, Gitā writes Git's commit-graph file and \
                            refreshes the index, as “git commit-graph write” and “git update-index \
                            --refresh” do. Your commits and files are not changed.
                            """
                    )),
                monitorRow,
                SettingsRow(
                    String(localized: "Untracked Cache (Global)"),
                    [globalUntrackedCache],
                    subtitle: Self.defaultGlobalSubtitle,
                    help: String(
                        localized:
                            """
                            Sets core.untrackedCache in ~/.gitconfig to cache untracked directory listings and speed \
                            up git status across all repositories unless overridden per repository in Storage & Health.
                            """
                    )),
                SettingsRow(
                    String(localized: "Scheduled Background Maintenance"),
                    [maintenanceCountLabel],
                    subtitle: String(
                        localized:
                            """
                            Repositories listed in ~/.gitconfig (maintenance.repo). Manage per-repository registration \
                            in each repository’s Storage & Health pane.
                            """
                    ),
                    help: String(
                        localized:
                            """
                            Git’s background scheduler periodically packs objects and updates indexes for \
                            repositories registered in maintenance.repo in ~/.gitconfig. Register or unregister \
                            individual repositories from their Storage & Health pane.
                            """
                    )),
            ])
    }

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        if case .saving = state {
            pendingReload = true
            return activeTask
        }
        activeTask?.cancel()
        pendingReload = false
        state = .loading
        applyState()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runLoad()
        }
        activeTask = task
        return task
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        pendingReload = false
        if case .loading = state {
            state = .idle
            applyState()
        }
    }

    private func runLoad() async {
        do {
            let snapshot = try await health.inspectGlobalDefaults()
            guard !Task.isCancelled else { return }
            state = .loaded(snapshot)
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
        activeTask = nil
        applyState()
    }

    private func setGlobalFSMonitor(_ enabled: Bool) {
        mutateGlobal { try await self.health.setGlobalFSMonitor(enabled) }
    }

    private func setGlobalUntrackedCache(_ enabled: Bool) {
        mutateGlobal { try await self.health.setGlobalUntrackedCache(enabled) }
    }

    private func mutateGlobal(_ operation: @escaping @Sendable () async throws -> Void) {
        let previous = state.snapshot
        activeTask?.cancel()
        state = .saving(previous)
        applyState()
        activeTask = Task { [weak self] in
            guard let self else { return }
            await self.runMutation(previous: previous, operation: operation)
        }
    }

    private func runMutation(
        previous: GlobalGitPerformanceSnapshot?, operation: @escaping @Sendable () async throws -> Void
    ) async {
        do {
            try await operation()
            let updated = try await health.inspectGlobalDefaults()
            guard !Task.isCancelled else { return }
            state = .loaded(updated)
        } catch {
            guard !Task.isCancelled else { return }
            state = previous.map(LoadState.loaded) ?? .failed(error.localizedDescription)
            onError(error)
        }
        activeTask = nil
        applyState()
        if pendingReload {
            pendingReload = false
            _ = refresh()
        }
    }

    private func applyState() {
        switch state {
        case .idle, .loading:
            globalFSMonitor.isEnabled = false
            globalUntrackedCache.isEnabled = false
            setFSMonitorNote(String(localized: "Loading…"), subtitle: Self.defaultGlobalSubtitle)
            maintenanceCountLabel.stringValue = String(localized: "Loading…")
        case .loaded(let snapshot):
            applySnapshot(snapshot, interactive: !state.isBusy)
        case .saving(let snapshot):
            if let snapshot {
                applySnapshot(snapshot, interactive: !state.isBusy)
            } else {
                globalFSMonitor.isEnabled = false
                globalUntrackedCache.isEnabled = false
            }
        case .failed(let message):
            globalFSMonitor.isEnabled = false
            globalUntrackedCache.isEnabled = false
            setFSMonitorNote(String(localized: "Unavailable"), subtitle: message)
            maintenanceCountLabel.stringValue = String(localized: "Unavailable")
            maintenanceCountLabel.toolTip = message
        }
    }

    private func applySnapshot(_ snapshot: GlobalGitPerformanceSnapshot, interactive: Bool) {
        switch snapshot.fsMonitor {
        case .customHook(let hook):
            globalFSMonitor.setOn(false)
            globalFSMonitor.isEnabled = false
            setFSMonitorNote(
                String(localized: "Custom hook"),
                subtitle: String(
                    localized: "Custom hook in ~/.gitconfig: \(hook). Gitā will not overwrite it."))
        case .enabled:
            globalFSMonitor.setOn(true)
            globalFSMonitor.isEnabled = interactive
            setFSMonitorNote("", subtitle: Self.defaultGlobalSubtitle)
        case .disabled, .unset:
            globalFSMonitor.setOn(false)
            globalFSMonitor.isEnabled = interactive
            setFSMonitorNote("", subtitle: Self.defaultGlobalSubtitle)
        }
        globalUntrackedCache.setOn(snapshot.untrackedCache == .enabled)
        globalUntrackedCache.isEnabled = interactive
        let summary = Self.formatMaintenanceCount(snapshot.registeredMaintenanceCount)
        maintenanceCountLabel.stringValue = summary
        maintenanceCountLabel.toolTip = summary
    }

    private func setFSMonitorNote(_ note: String, subtitle: String) {
        globalFSMonitorStatus.stringValue = note
        globalFSMonitorStatus.isHidden = note.isEmpty
        globalFSMonitorStatus.toolTip = note.isEmpty ? nil : subtitle
        fsMonitorRow?.subtitleLabel?.stringValue = subtitle
    }

    static func formatMaintenanceCount(_ count: Int) -> String {
        switch count {
        case 0: String(localized: "None registered")
        case 1: String(localized: "1 repository")
        default: String(localized: "\(count) repositories")
        }
    }

    private static var defaultGlobalSubtitle: String {
        String(localized: "Global default in ~/.gitconfig for all repositories unless overridden per repository.")
    }
}
