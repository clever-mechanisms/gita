import Foundation
import GitaCore

/// Detail reads (a run's jobs, a deployment's build) for recently selected items, for 30 seconds, at most eight.
/// An entry is only reused for the very item it was read for; `epoch` invalidates reads still in flight.
struct ProviderDetailsCache {
    static let lifetime: TimeInterval = 30
    static let capacity = 8

    private struct Entry {
        var item: ProviderItem
        var report: ProviderDetailReport
        var storedAt: Date
    }
    private var entries: [ProviderTarget: Entry] = [:]
    private(set) var epoch = 0

    func report(for target: ProviderTarget, item: ProviderItem, now: Date) -> ProviderDetailReport? {
        guard let entry = entries[target], entry.item == item else { return nil }
        let age = now.timeIntervalSince(entry.storedAt)
        return age >= 0 && age < Self.lifetime ? entry.report : nil
    }

    mutating func store(_ report: ProviderDetailReport, for target: ProviderTarget, item: ProviderItem, now: Date) {
        entries[target] = Entry(item: item, report: report, storedAt: now)
        if entries.count > Self.capacity, let oldest = entries.min(by: { $0.value.storedAt < $1.value.storedAt })?.key {
            entries[oldest] = nil
        }
    }

    /// Keeps only entries whose item `report` still lists unchanged (entries of other providers stay).
    mutating func retain(listedIn report: ProviderReport) {
        entries = entries.filter { target, entry in
            entry.item.provider != report.provider || report.items.contains { $0.target == target && $0 == entry.item }
        }
    }

    mutating func remove(provider: ProviderKind) {
        entries = entries.filter { $0.value.item.provider != provider }
        epoch += 1
    }

    mutating func removeAll() {
        epoch += 1
        entries.removeAll(keepingCapacity: false)
    }
}
