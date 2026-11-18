import GitaCore

/// The Vercel alert groups already told about. The first successful alerts read only seeds them, so opening a
/// repository never announces alerts that were already active.
struct VercelAlertTracker {
    private var seen: Set<String> = []
    private var isSeeded = false

    /// The active alerts not seen before in a successful read; empty for a failed or the first read.
    mutating func newAlerts(in signals: VercelSignals?) -> [VercelSignals.Alert] {
        guard let signals, let read = signals.reads[.alerts], read.outcome != .failed else { return [] }
        let active = signals.activeAlerts
        let known = seen
        let seeded = isSeeded
        seen.formUnion(active.map(\.id))
        isSeeded = true
        guard seeded else { return [] }
        return active.filter { !known.contains($0.id) }
    }
}
