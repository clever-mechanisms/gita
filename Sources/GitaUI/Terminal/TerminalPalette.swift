/// The sixteen ANSI colours of the built-in terminal, per theme, in xterm.js's names. Nord, Solarized, Gruvbox and
/// Dracula use their published terminal palettes; the other themes a neutral pair tuned for a white or a near-black
/// background.
enum TerminalPalette {
    static let names = [
        "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
        "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue", "brightMagenta", "brightCyan",
        "brightWhite",
    ]

    static func ansi(_ theme: Theme.Choice, dark: Bool) -> [String: String] {
        let colors = dark ? darkColors(theme) : lightColors(theme)
        return Dictionary(uniqueKeysWithValues: zip(names, colors.map(TerminalAppearance.hex)))
    }

    private static func darkColors(_ theme: Theme.Choice) -> [UInt32] {
        switch theme {
        case .nord: nordDark
        case .solarized: solarized
        case .gruvbox: gruvboxDark
        case .dracula: draculaDark
        default: neutralDark
        }
    }

    private static func lightColors(_ theme: Theme.Choice) -> [UInt32] {
        switch theme {
        case .solarized: solarized
        case .gruvbox: gruvboxLight
        default: neutralLight
        }
    }

    static let neutralDark: [UInt32] = [
        0x000000, 0xF14C4C, 0x23D18B, 0xE5E510, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xCCCCCC,
        0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xFFFFFF,
    ]
    static let neutralLight: [UInt32] = [
        0x000000, 0xCD3131, 0x00A651, 0x949800, 0x0451A5, 0xBC05BC, 0x0598BC, 0x555555,
        0x666666, 0xCD3131, 0x14A44D, 0xB5BA00, 0x0451A5, 0xBC05BC, 0x0598BC, 0xA5A5A5,
    ]
    static let nordDark: [UInt32] = [
        0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
        0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4,
    ]
    static let solarized: [UInt32] = [
        0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
        0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
    ]
    static let gruvboxDark: [UInt32] = [
        0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
        0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
    ]
    static let gruvboxLight: [UInt32] = [
        0xFBF1C7, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0x7C6F64,
        0x928374, 0x9D0006, 0x79740E, 0xB57614, 0x076678, 0x8F3F71, 0x427B58, 0x3C3836,
    ]
    static let draculaDark: [UInt32] = [
        0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
        0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
    ]
}
