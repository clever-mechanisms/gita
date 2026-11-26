import Combine
import Foundation
import GitaCore

@MainActor
public final class NarrativeOrderPresenter {
    public private(set) var mode: FileOrderMode
    public private(set) var groups: [NarrativeFileGroup]
    public private(set) var collapsedLayers = Set(NarrativeLayer.allCases.filter(\.collapsedByDefault))
    let didToggle = PassthroughSubject<NarrativeLayer, Never>()
    private var entries: [NarrativeFileEntry]

    public init(entries: [NarrativeFileEntry] = [], mode: FileOrderMode = .narrative) {
        self.entries = entries
        self.mode = mode
        groups = NarrativeFileOrderer.group(entries, mode: mode)
    }

    public func setMode(_ mode: FileOrderMode) {
        self.mode = mode
        groups = NarrativeFileOrderer.group(entries, mode: mode)
    }

    public func update(_ entries: [NarrativeFileEntry]) {
        self.entries = entries
        groups = NarrativeFileOrderer.group(entries, mode: mode)
    }

    public func toggle(_ layer: NarrativeLayer) {
        if collapsedLayers.remove(layer) == nil { collapsedLayers.insert(layer) }
        didToggle.send(layer)
    }

    public func isCollapsed(_ layer: NarrativeLayer) -> Bool { collapsedLayers.contains(layer) }

    public static func summary(_ group: NarrativeFileGroup) -> String {
        let count = group.entries.count
        let files = count == 1 ? String(localized: "1 file") : String(localized: "\(count) files")
        return String(localized: "\(group.displayTitle), \(files), +\(group.totalAdditions) / −\(group.totalDeletions)")
    }
}
