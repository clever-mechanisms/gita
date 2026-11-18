import AppKit

/// Virtual key codes the custom controls handle, and the shared reading of a key press.
enum KeyPress {
    static let returnKey: UInt16 = 36
    static let space: UInt16 = 49
    static let keypadEnter: UInt16 = 76
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
    static let escape: UInt16 = 53
    static let tab: UInt16 = 48
    static let delete: UInt16 = 51
    static let forwardDelete: UInt16 = 117

    /// Space or Return: what presses a focused button.
    static func isActivation(_ event: NSEvent) -> Bool {
        event.charactersIgnoringModifiers == " " || event.keyCode == returnKey
    }
    /// No Command, Control, Option or Shift held.
    static func isPlain(_ event: NSEvent) -> Bool {
        event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift])
    }
    /// −1 for Left or Up, +1 for Right or Down, nil for any other key.
    static func arrowStep(_ event: NSEvent) -> Int? {
        switch event.keyCode {
        case leftArrow, upArrow: -1
        case rightArrow, downArrow: 1
        default: nil
        }
    }
}
