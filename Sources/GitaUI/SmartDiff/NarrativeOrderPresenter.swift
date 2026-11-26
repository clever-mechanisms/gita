import Combine
import Foundation
import GitaCore

@MainActor
final class NarrativeOrderPresenter {
    private(set) var mode: FileOrderMode
    private(set) var groups: [NarrativeFileGroup]
    private(set) var collapsedLayers = Set(NarrativeLayer.allCases.filter(\.collapsedByDefault))
    let didToggle = PassthroughSubject<NarrativeLayer, Never>()
    private var entries: [NarrativeFileEntry]

    init(entries: [NarrativeFileEntry] = [], mode: FileOrderMode = .narrative) {
        self.entries = entries
        self.mode = mode
        groups = NarrativeFileOrderer.group(entries, mode: mode)
    }

    func setMode(_ mode: FileOrderMode) {
        self.mode = mode
        groups = NarrativeFileOrderer.group(entries, mode: mode)
    }

    func update(_ entries: [NarrativeFileEntry]) {
        self.entries = entries
        groups = NarrativeFileOrderer.group(entries, mode: mode)
    }

    func toggle(_ layer: NarrativeLayer) {
        if collapsedLayers.remove(layer) == nil { collapsedLayers.insert(layer) }
        didToggle.send(layer)
    }

    func isCollapsed(_ layer: NarrativeLayer) -> Bool { collapsedLayers.contains(layer) }

    static func summary(_ group: NarrativeFileGroup) -> String {
        let count = group.entries.count
        let files = count == 1 ? String(localized: "1 file") : String(localized: "\(count) files")
        return String(localized: "\(group.displayTitle), \(files), +\(group.totalAdditions) / −\(group.totalDeletions)")
    }
}
