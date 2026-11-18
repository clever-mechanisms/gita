import Foundation

/// Every theme's colours, one palette per theme.
extension Theme.Palette {
    /// Neutral graphite surfaces; accent from System Settings.
    static let system = Theme.Palette(
        light: [
            .window: 0xFFFFFF, .toolbar: 0xF6F6F6, .tabBar: 0xECECEC, .sidebar: 0xF3F3F3, .inset: 0xF8F8F8,
            .control: 0xEAEAEA, .separator: 0xDDDDDD, .rowSelection: 0xDCDCE0, .selection: 0, .text: 0x1D1D1F,
            .secondaryText: 0x5E5E63, .tertiaryText: 0x6E6E73, .accentText: 0, .accent: 0, .working: 0,
        ],
        dark: [
            .window: 0x1E1E1E, .toolbar: 0x282828, .tabBar: 0x1A1A1A, .sidebar: 0x232323, .inset: 0x1A1A1A,
            .control: 0x323232, .separator: 0x383838, .rowSelection: 0x414146, .selection: 0, .text: 0xE8E8E8,
            .secondaryText: 0xA4A4A8, .tertiaryText: 0x8A8A8F, .accentText: 0, .accent: 0, .working: 0,
        ],
        followsSystemAccent: true)

    static let midnight = Theme.Palette(
        light: [
            .window: 0xFFFFFF, .toolbar: 0xF3F5F9, .tabBar: 0xE8ECF3, .sidebar: 0xF0F3F8, .inset: 0xF6F8FB,
            .control: 0xE3EBF8, .separator: 0xDCE2EB, .rowSelection: 0xDDE1E8, .selection: 0xCFE0FB,
            .text: 0x1B2230, .secondaryText: 0x566173, .tertiaryText: 0x687385, .accentText: 0x1E4FBF,
            .accent: 0x2563EB, .working: 0x2563EB,
        ],
        dark: [
            .window: 0x11161F, .toolbar: 0x171E2B, .tabBar: 0x0D1219, .sidebar: 0x0F141C, .inset: 0x0D1219,
            .control: 0x1C2636, .separator: 0x243042, .rowSelection: 0x2C323C, .selection: 0x213A63,
            .text: 0xE3E8F0, .secondaryText: 0x9AA6B8, .tertiaryText: 0x7D8A9E, .accentText: 0x8DB6FF,
            .accent: 0x3B7BF0, .working: 0x5AA0FF,
        ],
        followsSystemAccent: false)

    static let nord = Theme.Palette(
        light: [
            .window: 0xF4F6F9, .toolbar: 0xE8ECF2, .tabBar: 0xDEE3EB, .sidebar: 0xEAEEF3, .inset: 0xF8F9FB,
            .control: 0xDCE5EF, .separator: 0xD3D9E2, .rowSelection: 0xD8DEE9, .selection: 0xCADCEB,
            .text: 0x2E3440, .secondaryText: 0x4C566A, .tertiaryText: 0x5E6779, .accentText: 0x3E5F8A,
            .accent: 0x5E81AC, .working: 0x5E81AC,
        ],
        dark: [
            .window: 0x2E3440, .toolbar: 0x353C4A, .tabBar: 0x292E39, .sidebar: 0x2B303B, .inset: 0x292E39,
            .control: 0x3B4252, .separator: 0x434C5E, .rowSelection: 0x434C5E, .selection: 0x4C566A,
            .text: 0xECEFF4, .secondaryText: 0xB4BCCB, .tertiaryText: 0x949EAF, .accentText: 0x88C0D0,
            .accent: 0x5E81AC, .working: 0x88C0D0,
        ],
        followsSystemAccent: false)

    /// Monochrome: System's graphite surfaces with a grey accent instead of the macOS accent colour.
    static let graphite = Theme.Palette(
        light: [
            .window: 0xFFFFFF, .toolbar: 0xF5F5F6, .tabBar: 0xEBEBED, .sidebar: 0xF2F2F3, .inset: 0xF8F8F9,
            .control: 0xE9E9EB, .separator: 0xDCDCDF, .rowSelection: 0xDCDCE0, .selection: 0xDDDDE1,
            .text: 0x1D1D1F, .secondaryText: 0x55555A, .tertiaryText: 0x636368, .accentText: 0x3A3A3F,
            .accent: 0x5A5A61, .working: 0x6E6E76,
        ],
        dark: [
            .window: 0x1C1C1E, .toolbar: 0x262628, .tabBar: 0x18181A, .sidebar: 0x212123, .inset: 0x18181A,
            .control: 0x303033, .separator: 0x363639, .rowSelection: 0x3E3E43, .selection: 0x3E3E43,
            .text: 0xE8E8EA, .secondaryText: 0xAEAEB3, .tertiaryText: 0x9A9AA0, .accentText: 0xD4D4D9,
            .accent: 0x6A6A72, .working: 0xB8B8BF,
        ],
        followsSystemAccent: false)

    /// Ethan Schoonover's Solarized base tones, with text one step darker/lighter for contrast.
    static let solarized = Theme.Palette(
        light: [
            .window: 0xFDF6E3, .toolbar: 0xF5EEDA, .tabBar: 0xEEE8D5, .sidebar: 0xF7F0DC, .inset: 0xFAF3E0,
            .control: 0xEEE8D5, .separator: 0xE0D9C4, .rowSelection: 0xE8E1CC, .selection: 0xD3E2E6,
            .text: 0x073642, .secondaryText: 0x4A5F66, .tertiaryText: 0x52676E, .accentText: 0x195F91,
            .accent: 0x1F6FA8, .working: 0x268BD2,
        ],
        dark: [
            .window: 0x002B36, .toolbar: 0x073642, .tabBar: 0x00222B, .sidebar: 0x00252F, .inset: 0x00222B,
            .control: 0x0B3F4C, .separator: 0x0E4351, .rowSelection: 0x1A4550, .selection: 0x134B5B,
            .text: 0xEEE8D5, .secondaryText: 0xB0BBBA, .tertiaryText: 0x9DABAC, .accentText: 0x7CC0EC,
            .accent: 0x1F6FA8, .working: 0x4AA3DF,
        ],
        followsSystemAccent: false)

    /// Gruvbox's warm retro palette, orange accent.
    static let gruvbox = Theme.Palette(
        light: [
            .window: 0xFBF1C7, .toolbar: 0xF2E5BC, .tabBar: 0xEBDBB2, .sidebar: 0xF4E8C0, .inset: 0xF9F5D7,
            .control: 0xEBDBB2, .separator: 0xDDCCA0, .rowSelection: 0xE2D0A2, .selection: 0xF0D2A8,
            .text: 0x282828, .secondaryText: 0x504945, .tertiaryText: 0x5F5650, .accentText: 0x9D3502,
            .accent: 0xAF3A03, .working: 0xD65D0E,
        ],
        dark: [
            .window: 0x282828, .toolbar: 0x32302F, .tabBar: 0x1D2021, .sidebar: 0x1D2021, .inset: 0x1D2021,
            .control: 0x3C3836, .separator: 0x45403D, .rowSelection: 0x4A4440, .selection: 0x4F3B2A,
            .text: 0xEBDBB2, .secondaryText: 0xC9B99A, .tertiaryText: 0xB3A48A, .accentText: 0xFE8019,
            .accent: 0xB8510C, .working: 0xFABD2F,
        ],
        followsSystemAccent: false)

    /// Dracula (dark) and its light counterpart Alucard, purple accent.
    static let dracula = Theme.Palette(
        light: [
            .window: 0xFFFBEB, .toolbar: 0xF4F0DE, .tabBar: 0xECE8D6, .sidebar: 0xF6F2E0, .inset: 0xFAF7E8,
            .control: 0xECE6F5, .separator: 0xE2DECC, .rowSelection: 0xE6E1CF, .selection: 0xE0D5F7,
            .text: 0x1F1F1F, .secondaryText: 0x55545D, .tertiaryText: 0x605F69, .accentText: 0x5A3FBF,
            .accent: 0x6F4FD1, .working: 0x7C5BD6,
        ],
        dark: [
            .window: 0x282A36, .toolbar: 0x2F3240, .tabBar: 0x21222C, .sidebar: 0x21222C, .inset: 0x1E1F29,
            .control: 0x383A4A, .separator: 0x3B3E50, .rowSelection: 0x44475A, .selection: 0x44475A,
            .text: 0xF8F8F2, .secondaryText: 0xC3C7DC, .tertiaryText: 0xAEB3CC, .accentText: 0xCFADFB,
            .accent: 0x7E57D6, .working: 0xBD93F9,
        ],
        followsSystemAccent: false)

    /// Warm paper for long reading sessions.
    static let sepia = Theme.Palette(
        light: [
            .window: 0xF8F1E3, .toolbar: 0xEFE6D3, .tabBar: 0xE7DDC8, .sidebar: 0xF1E8D6, .inset: 0xFBF6EC,
            .control: 0xE9DCC4, .separator: 0xDDD0B8, .rowSelection: 0xDCCDB1, .selection: 0xEBD8B8,
            .text: 0x3B2F23, .secondaryText: 0x5E4F3E, .tertiaryText: 0x6A5A48, .accentText: 0x7E4318,
            .accent: 0x8F5124, .working: 0xB5651D,
        ],
        dark: [
            .window: 0x2A241D, .toolbar: 0x332C23, .tabBar: 0x221D17, .sidebar: 0x251F19, .inset: 0x221D17,
            .control: 0x3D342A, .separator: 0x433A2F, .rowSelection: 0x40362B, .selection: 0x4E3D2C,
            .text: 0xEDE3D1, .secondaryText: 0xC6B8A2, .tertiaryText: 0xB0A28C, .accentText: 0xE8B077,
            .accent: 0x9A5A26, .working: 0xE3A869,
        ],
        followsSystemAccent: false)

    /// Teal, from the app icon's tile.
    static let teal = Theme.Palette(
        light: [
            .window: 0xFFFFFF, .toolbar: 0xF3F6F6, .tabBar: 0xE9EEEF, .sidebar: 0xF1F4F4, .inset: 0xF7F9F9,
            .control: 0xE4F5EF, .separator: 0xDDE3E5, .rowSelection: 0xE1E7E8, .selection: 0xBFE9DB,
            .text: 0x1C2427, .secondaryText: 0x5B6A70, .tertiaryText: 0x6B7A80, .accentText: 0x0A5C4B,
            .accent: 0x13806A, .working: 0x21A387,
        ],
        dark: [
            .window: 0x0F1A20, .toolbar: 0x13222A, .tabBar: 0x0B151B, .sidebar: 0x0A141A, .inset: 0x0C171D,
            .control: 0x16302E, .separator: 0x1E2E36, .rowSelection: 0x22303A, .selection: 0x1B4D44,
            .text: 0xE4EEF0, .secondaryText: 0x93A8B0, .tertiaryText: 0x74898F, .accentText: 0x91FAD1,
            .accent: 0x21A387, .working: 0x59DEB3,
        ],
        followsSystemAccent: false)
}
