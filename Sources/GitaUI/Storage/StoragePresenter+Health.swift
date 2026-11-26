import Foundation
import GitaCore

struct StorageHealthSummaryModel: Equatable {
    enum Status: Equatable {
        case optimized
        case recommend(StorageHealthAction)
        case updating
    }

    let enabledCount: Int
    let totalCount: Int
    let headline: String
    let subtitle: String
    let status: Status
}

struct StorageHealthCardModel: Equatable {
    enum Control: Equatable {
        case toggle(Bool)
        case button
    }
    enum Section: Equatable {
        case performance, maintenance
    }
    enum IconTone: Equatable {
        case blue, green, purple, orange, indigo
    }
    enum StatusTone: Equatable {
        case positive, neutral, warning
    }
    struct SecondaryToggle: Equatable {
        let isOn: Bool
        let action: StorageHealthAction
        let accessibilityLabel: String
    }

    let section: Section
    let symbol: String
    let iconTone: IconTone
    let title: String
    let statusText: String
    let statusTone: StatusTone
    let detail: String
    var statPills: [String] = []
    let action: StorageHealthAction
    let control: Control
    var buttonSymbol: String?
    var secondaryToggle: SecondaryToggle?
    let enabled: Bool
}

extension StoragePresenter {
    func healthSummary(
        for snapshot: RepositoryHealthSnapshot, actionState: HealthActionState
    ) -> StorageHealthSummaryModel {
        let fsMonitorReady = snapshot.fsMonitor != .disabled && snapshot.fsMonitor != .unset
        let needsFSMonitor = !fsMonitorReady
        let cacheReady = snapshot.untrackedCache == .enabled
        let graphReady = snapshot.commitGraph.isPresent
        let maintenanceReady = snapshot.maintenance.isRegistered
        let enabledCount = [fsMonitorReady, cacheReady, graphReady, maintenanceReady].count { $0 }
        let totalCount = 4
        let headline =
            enabledCount == totalCount
            ? String(localized: "All \(totalCount) optimizations enabled")
            : String(localized: "\(enabledCount) of \(totalCount) optimizations enabled")
        let subtitle =
            enabledCount == totalCount
            ? String(localized: "Git is configured for fast status, log, and background upkeep.")
            : String(localized: "Enable recommended Git optimizations for faster status and graph operations.")
        let status: StorageHealthSummaryModel.Status =
            if actionState.isRunning {
                .updating
            } else if needsFSMonitor || !cacheReady || !graphReady || !maintenanceReady {
                .recommend(
                    .enableRecommended(
                        fsMonitor: needsFSMonitor, untrackedCache: !cacheReady,
                        commitGraph: !graphReady, registerMaintenance: !maintenanceReady))
            } else {
                .optimized
            }
        return StorageHealthSummaryModel(
            enabledCount: enabledCount, totalCount: totalCount, headline: headline,
            subtitle: subtitle, status: status)
    }

    func healthCards(
        for snapshot: RepositoryHealthSnapshot, actionState: HealthActionState, hasActiveAgent: Bool = false
    ) -> [StorageHealthCardModel] {
        let enabled = !actionState.isRunning
        return [
            fsMonitorCard(snapshot.fsMonitor, enabled: enabled),
            untrackedCacheCard(snapshot.untrackedCache, enabled: enabled),
            commitGraphCard(snapshot.commitGraph, enabled: enabled),
            gcCard(snapshot.maintenance, hasActiveAgent: hasActiveAgent, enabled: enabled),
            maintenanceCard(snapshot.maintenance, enabled: enabled),
        ]
    }

    private func fsMonitorCard(_ setting: FSMonitorSetting, enabled: Bool) -> StorageHealthCardModel {
        let title = String(localized: "Filesystem Monitor")
        if case .customHook(let hook) = setting {
            return StorageHealthCardModel(
                section: .performance, symbol: "bolt.horizontal.circle.fill", iconTone: .blue,
                title: title, statusText: String(localized: "Custom hook"), statusTone: .warning,
                detail: String(
                    localized: "Custom hook active: \(hook). Gitā will not overwrite it without confirmation."),
                action: .replaceCustomFSMonitor(hook), control: .button, buttonSymbol: "arrow.triangle.2.circlepath",
                enabled: enabled)
        }
        let on = setting == .enabled
        return StorageHealthCardModel(
            section: .performance, symbol: "bolt.horizontal.circle.fill", iconTone: .blue,
            title: title, statusText: on ? String(localized: "Enabled") : String(localized: "Off"),
            statusTone: on ? .positive : .neutral,
            detail: String(localized: "Use Git’s built-in filesystem monitor to speed up working tree checks."),
            action: .fsMonitor(!on), control: .toggle(on), enabled: enabled)
    }

    private func untrackedCacheCard(_ setting: GitConfigSwitch, enabled: Bool) -> StorageHealthCardModel {
        let on = setting == .enabled
        return StorageHealthCardModel(
            section: .performance, symbol: "hare.fill", iconTone: .green,
            title: String(localized: "Untracked Cache"),
            statusText: on ? String(localized: "Enabled") : String(localized: "Off"),
            statusTone: on ? .positive : .neutral,
            detail: String(localized: "Cache untracked directory listings to speed up git status."),
            action: .untrackedCache(!on), control: .toggle(on), enabled: enabled)
    }

    private func commitGraphCard(_ graph: CommitGraphInfo, enabled: Bool) -> StorageHealthCardModel {
        let status: String
        let tone: StorageHealthCardModel.StatusTone
        if let date = graph.modifiedAt {
            let formatted = date.formatted(date: .abbreviated, time: .shortened)
            status = String(localized: "Rebuilt \(formatted)")
            tone = .positive
        } else if graph.isPresent {
            status = String(localized: "Present")
            tone = .positive
        } else {
            status = String(localized: "Not built")
            tone = .neutral
        }
        return StorageHealthCardModel(
            section: .performance, symbol: "point.3.connected.trianglepath.dotted", iconTone: .purple,
            title: String(localized: "Commit Graph"), statusText: status, statusTone: tone,
            detail: String(localized: "Accelerates commit history traversal and graph rendering."),
            action: .commitGraph, control: .button, buttonSymbol: "arrow.clockwise", enabled: enabled)
    }

    private func gcCard(_ stats: GitMaintenanceInfo, hasActiveAgent: Bool, enabled: Bool) -> StorageHealthCardModel {
        let totalBytes = UInt64(max(0, stats.looseKiB + stats.packedKiB)) * 1_024
        let size = formatBytes(totalBytes)
        let loosePill = String(localized: "\(stats.looseObjects) loose")
        let packedPill = String(localized: "\(stats.packedObjects) packed")
        let packsPill = String(localized: "\(stats.packs) packs (\(size))")
        let detail =
            hasActiveAgent
            ? String(localized: "Active agent detected; immediate pruning is deferred for safety.")
            : String(localized: "Compact loose objects and packfiles to reclaim space in .git.")
        let needsGC = stats.looseObjects >= 6_700
        return StorageHealthCardModel(
            section: .maintenance, symbol: "sparkles", iconTone: .orange,
            title: String(localized: "Garbage Collection"),
            statusText: needsGC ? String(localized: "Recommended") : String(localized: "Healthy"),
            statusTone: needsGC ? .warning : .positive,
            detail: detail, statPills: [loosePill, packedPill, packsPill],
            action: .garbageCollection(pruneNow: !hasActiveAgent), control: .button,
            buttonSymbol: "wand.and.stars", enabled: enabled)
    }

    private func maintenanceCard(_ stats: GitMaintenanceInfo, enabled: Bool) -> StorageHealthCardModel {
        let registered = stats.isRegistered
        let auto = describe(stats.automatic)
        return StorageHealthCardModel(
            section: .maintenance, symbol: "clock.arrow.2.circlepath", iconTone: .indigo,
            title: String(localized: "Git Maintenance"),
            statusText: registered ? String(localized: "Registered") : String(localized: "Unregistered"),
            statusTone: registered ? .positive : .neutral,
            detail: String(localized: "Automatic maintenance: \(auto). Runs periodic background packing and prefetch."),
            action: .maintenance, control: .button, buttonSymbol: "play.fill",
            secondaryToggle: .init(
                isOn: registered,
                action: .maintenanceRegistration(!registered),
                accessibilityLabel: String(localized: "Register for scheduled maintenance")),
            enabled: enabled)
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
