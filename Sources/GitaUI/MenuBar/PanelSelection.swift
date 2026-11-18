import AppKit

/// The panel list's keyboard: which key means what, and where a step lands. Pure, so it is checked without a window.
enum PanelSelection {
    enum Intent: Equatable {
        /// ↓ (1) or ↑ (-1).
        case move(Int)
        /// ↩, ⌤ or Space.
        case activate
        /// → (1) or ← (-1): through a workspace's pills; on a summary, → opens it and ← closes it.
        case across(Int)
        /// ⌘C copies the row's link.
        case copyLink
    }

    private enum Key {
        static let down: UInt16 = 125, up: UInt16 = 126, right: UInt16 = 124, left: UInt16 = 123
        static let returnKey: UInt16 = 36, enter: UInt16 = 76, space: UInt16 = 49, c: UInt16 = 8
    }

    /// What a key press means in the list; nil leaves it to the responder chain.
    static func intent(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Intent? {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        switch keyCode {
        case Key.down: return .move(1)
        case Key.up: return .move(-1)
        case Key.returnKey, Key.enter, Key.space: return .activate
        case Key.right: return .across(1)
        case Key.left: return .across(-1)
        case Key.c where flags == .command: return .copyLink
        default: return nil
        }
    }

    /// The selectable row a step from `selected` lands on: the first (or last, stepping up) when nothing is selected,
    /// held at either end.
    static func moved(_ rows: [PanelRow], from selected: String?, by step: Int) -> String? {
        let candidates = rows.filter(\.isSelectable)
        guard !candidates.isEmpty else { return nil }
        let index =
            candidates.firstIndex { $0.id == selected }.map { $0 + step } ?? (step > 0 ? 0 : candidates.count - 1)
        return candidates[max(0, min(candidates.count - 1, index))].id
    }

    /// The toggle → or ← performs on `row`: only a summary that is collapsed (→) or open (←).
    static func toggle(_ row: PanelRow?, opening: Bool) -> PanelAction? {
        guard let row, row.disclosure == .init(isOpen: !opening), let action = row.action, case .toggle = action
        else { return nil }
        return action
    }

    /// The pill a step from `selected` lands on in a workspace's card: the first one from the card itself, held at
    /// the last, and back on the card (nil) before the first. A closed workspace's pills are labels: never chosen.
    static func pill(_ row: PanelRow?, from selected: Int?, by step: Int) -> Int? {
        guard let row, row.pills.contains(where: { $0.action != nil }) else { return nil }
        let index = (selected ?? -1) + step
        return index < 0 ? nil : min(index, row.pills.count - 1)
    }

    /// What ↩ does on `row`: its chosen pill's action, else its own.
    static func action(_ row: PanelRow?, pill: Int?) -> PanelAction? {
        guard let row else { return nil }
        if let pill, row.pills.indices.contains(pill) { return row.pills[pill].action }
        return row.action
    }
}
