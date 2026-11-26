import Foundation
import GitaCore

struct StorageHealthCardModel: Equatable {
    enum Control: Equatable {
        case toggle(Bool)
        case button
    }
    let title: String
    let detail: String
    let action: StorageHealthAction
    let control: Control
    let enabled: Bool
}

extension StoragePresenter {
    func healthCards(
        for snapshot: RepositoryHealthSnapshot, actionState: HealthActionState, hasActiveAgent: Bool = false
    ) -> [StorageHealthCardModel] {
        let enabled = !actionState.isRunning
        let cache = snapshot.untrackedCache == .enabled
        let stats = snapshot.maintenance
        let registration = stats.isRegistered ? String(localized: "Registered") : String(localized: "Unregistered")
        let auto = describe(stats.automatic)
        return [
            fsMonitorCard(snapshot.fsMonitor, enabled: enabled),
            StorageHealthCardModel(
                title: String(localized: "Untracked cache"),
                detail: String(localized: "Cache untracked directory listings to speed up git status."),
                action: .untrackedCache(!cache), control: .toggle(cache), enabled: enabled),
            StorageHealthCardModel(
                title: String(localized: "Commit Graph"), detail: graphStatus(snapshot.commitGraph),
                action: .commitGraph, control: .button, enabled: enabled),
            gcCard(stats, hasActiveAgent: hasActiveAgent, enabled: enabled),
            StorageHealthCardModel(
                title: String(localized: "Git Maintenance"),
                detail: String(localized: "\(registration) · Automatic maintenance: \(auto)"),
                action: .maintenance, control: .button, enabled: enabled),
        ]
    }

    private func fsMonitorCard(_ setting: FSMonitorSetting, enabled: Bool) -> StorageHealthCardModel {
        let title = String(localized: "Filesystem monitor")
        if case .customHook(let hook) = setting {
            return StorageHealthCardModel(
                title: title,
                detail: String(
                    localized:
                        "Custom hook active: \(hook). Gitā will not overwrite it without confirmation."
                ),
                action: .replaceCustomFSMonitor(hook), control: .button, enabled: enabled)
        }
        let on = setting == .enabled
        return StorageHealthCardModel(
            title: title,
            detail: String(localized: "Use Git’s filesystem monitor to speed up working tree changes."),
            action: .fsMonitor(!on), control: .toggle(on), enabled: enabled)
    }

    private func gcCard(_ stats: GitMaintenanceInfo, hasActiveAgent: Bool, enabled: Bool) -> StorageHealthCardModel {
        let loose = stats.looseObjects
        let packed = stats.packedObjects
        let totalBytes = UInt64(max(0, stats.looseKiB + stats.packedKiB)) * 1_024
        let size = formatBytes(totalBytes)
        var detail = String(
            localized: "\(loose) loose objects · \(packed) packed objects · \(stats.packs) packs (\(size))")
        if hasActiveAgent {
            detail += " " + String(localized: "Active agent detected; immediate pruning is deferred.")
        }
        return StorageHealthCardModel(
            title: String(localized: "Garbage Collection"), detail: detail,
            action: .garbageCollection(pruneNow: !hasActiveAgent), control: .button, enabled: enabled)
    }

    private func graphStatus(_ graph: CommitGraphInfo) -> String {
        if let date = graph.modifiedAt { return String(localized: "Last rebuilt \(date.formatted()).") }
        return graph.isPresent
            ? String(localized: "Commit graph present.") : String(localized: "No commit graph found.")
    }

    private func describe(_ setting: GitConfigSwitch) -> String {
        switch setting {
        case .enabled: String(localized: "Enabled")
        case .disabled: String(localized: "Disabled")
        case .unset: String(localized: "Git default")
        case .other(let value): value
        }
    }
}
