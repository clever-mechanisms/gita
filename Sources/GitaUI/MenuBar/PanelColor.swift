import AppKit
import GitaCore

/// A theme colour named by role, so panel rows stay plain comparable values and resolve the colour when drawn.
enum PanelColor: Hashable {
    case text, secondary, tertiary, accentText, needsInputText, success, failure, running, merged

    @MainActor var color: NSColor {
        switch self {
        case .text: Theme.text
        case .secondary: Theme.secondaryText
        case .tertiary: Theme.tertiaryText
        case .accentText: Theme.accentText
        case .needsInputText: Theme.needsInputText
        case .success: Theme.success
        case .failure: Theme.failure
        case .running: Theme.running
        case .merged: Theme.merged
        }
    }

    static func of(_ state: SignalState) -> Self {
        switch state {
        case .success: .success
        case .failure: .failure
        case .running, .pending: .running
        case .cancelled, .neutral: .tertiary
        }
    }
}
