import Foundation

/// Tabs gathered under a named, coloured chip in the tab strip; a collapsed group shows only its chip.
struct TabGroup: Equatable {
    let id: UUID
    var name: String
    var color: TabColor
    var collapsed = false
    /// The chip's name, or the accessibility name of an unnamed group.
    var displayName: String { name.isEmpty ? String(localized: "Unnamed group") : name }
}
