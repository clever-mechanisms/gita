import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@MainActor
@Suite struct SharedThemeTests {
    private func components(_ color: NSColor) -> [Int] {
        guard let rgb = color.usingColorSpace(.sRGB) else { return [] }
        return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
    }
    private func drawn(_ color: NSColor, dark: Bool) -> NSColor {
        var resolved = color
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    @Test func hexSplitsChannelsAndKeepsAlpha() {
        #expect(components(Theme.hex(0x123456)) == [0x12, 0x34, 0x56])
        #expect(Theme.hex(0xFFFFFF, alpha: 0.5).alphaComponent == 0.5)
    }

    @Test func dynamicColoursFollowTheDrawingAppearance() {
        let color = Theme.dynamic(0x000010, 0x0000F0)
        #expect(components(drawn(color, dark: false)) == [0, 0, 0x10])
        #expect(components(drawn(color, dark: true)) == [0, 0, 0xF0])
    }

    @Test(arguments: Theme.Choice.allCases)
    func everyPaletteResolvesEveryTokenInBothAppearances(choice: Theme.Choice) throws {
        let palette = try #require(Theme.palettes[choice])
        #expect(!choice.title.isEmpty)
        for token in Theme.Token.allCases {
            for dark in [false, true] {
                let color = Theme.resolve(token, dark: dark, choice: choice)
                let accentFamily: Set<Theme.Token> = [.accent, .working, .accentText, .selection]
                if palette.followsSystemAccent, accentFamily.contains(token) { continue }
                let hex = try #require((dark ? palette.dark : palette.light)[token])
                #expect(components(color) == components(Theme.hex(hex)), "\(choice) \(token) dark: \(dark)")
            }
        }
    }

    @Test func systemPaletteDerivesTheAccentFamilyFromMacOS() {
        let accent = Theme.resolve(.accent, dark: false, choice: .system)
        #expect(components(accent) == components(NSColor.controlAccentColor))
        #expect(Theme.resolve(.selection, dark: true, choice: .system).alphaComponent == 0.38)
        #expect(Theme.resolve(.selection, dark: false, choice: .system).alphaComponent == 0.22)
        #expect(components(Theme.resolve(.working, dark: false, choice: .system)) == components(accent))
        #expect(components(Theme.resolve(.working, dark: true, choice: .system)) != components(accent))
        #expect(
            components(Theme.resolve(.accentText, dark: true, choice: .system))
                != components(Theme.resolve(.accentText, dark: false, choice: .system)))
    }

    @Test func themedTokensResolveForTheCurrentTheme() {
        for dark in [false, true] {
            let expected = components(Theme.resolve(.text, dark: dark))
            #expect(components(drawn(Theme.text, dark: dark)) == expected)
            // A second resolution is served from the cache.
            #expect(components(drawn(Theme.text, dark: dark)) == expected)
        }
    }

    @Test func signalStatesMapToStatusColours() {
        #expect(Theme.color(for: .success) === Theme.success)
        #expect(Theme.color(for: .failure) === Theme.failure)
        #expect(Theme.color(for: .running) === Theme.running)
        #expect(Theme.color(for: .pending) === Theme.running)
        #expect(Theme.color(for: .cancelled) === Theme.tertiaryText)
        #expect(Theme.color(for: .neutral) === Theme.tertiaryText)
    }

    @Test func tabColoursAreDistinctPerColour() {
        let colors = [TabColor.red, .orange, .yellow, .green, .blue, .purple, .pink, .grey].map(Theme.tabColor)
        #expect(Set(colors.map { components(drawn($0, dark: false)) }).count == 8)
        #expect(Theme.authorColors.count == 9)
    }

    @Test func typeScaleUsesTheDocumentedSizes() {
        #expect(Theme.body.pointSize == 12)
        #expect(Theme.bodyEmphasis.pointSize == 12)
        #expect(Theme.title.pointSize == 13)
        #expect(Theme.caption.pointSize == 11)
        #expect(Theme.captionEmphasis.pointSize == 11)
        #expect(Theme.mono.pointSize == 11)
        #expect(Theme.rowHeight == 24 && Theme.sidebarWidth == 240 && Theme.tabHeight == 30 && Theme.panelWidth == 400)
        let surfaces = [
            Theme.toolbar, Theme.tabBar, Theme.sidebar, Theme.inset, Theme.control, Theme.selection,
            Theme.rowSelection, Theme.secondaryText, Theme.accentText, Theme.accent, Theme.working, Theme.needsInput,
            Theme.needsInputText, Theme.merged, Theme.idle, Theme.checkedOut,
        ]
        #expect(surfaces.allSatisfy { $0.usingColorSpace(.sRGB) != nil })
    }

    @Test(arguments: Theme.Choice.allCases)
    func checkedOutLabelUsesAHueNoOtherLabelUses(choice: Theme.Choice) {
        let labels = [
            Theme.running, Theme.needsInput, Theme.needsInputText, Theme.success, Theme.failure, Theme.merged,
            Theme.idle,
        ]
        for dark in [false, true] {
            let accent = Theme.resolve(.accent, dark: dark, choice: choice)
            let here = Theme.checkedOutColor(dark: dark, accent: accent)
            #expect(!Theme.huesNear(here, accent))
            #expect(!Theme.huesNear(here, Theme.resolve(.working, dark: dark, choice: choice)))
            #expect(!Theme.huesNear(here, Theme.resolve(.accentText, dark: dark, choice: choice)))
            for label in labels {
                #expect(!Theme.huesNear(here, drawn(label, dark: dark)), "\(choice) dark: \(dark)")
            }
        }
    }

    @Test func automaticCheckedOutIsLimeUnlessThatMatchesTheAccent() {
        let blue = Theme.hex(0x2563EB)
        let onBlue = Theme.checkedOutColor(dark: false, accent: blue)
        #expect(Theme.huesNear(onBlue, Theme.hex(0x4D7C0F)))
        let lime = Theme.hex(0x4D7C0F)
        let onLime = Theme.checkedOutColor(dark: false, accent: lime)
        #expect(!Theme.huesNear(onLime, lime))
        let chosen = Theme.checkedOutColor(dark: false, accent: blue, tint: .pink)
        #expect(Theme.huesNear(chosen, Theme.hex(0xC81EAA)))
    }

    @Test func aChosenCommitColourReplacesTheLanePalette() throws {
        #expect(HistoryTint.laneColors(dark: false, tint: .automatic).count == Style.graphColors.count)
        let lanes = HistoryTint.laneColors(dark: true, tint: .blue)
        #expect(lanes.count == 1)
        #expect(Theme.huesNear(lanes[0], Theme.hex(0x4C9AFF)))
        let suite = try #require(UserDefaults(suiteName: "GitaUITests.historyTint.\(UUID().uuidString)"))
        #expect(HistoryTint.stored(.commits, defaults: suite) == .automatic)
        suite.set("nope", forKey: Preference.commitColor.rawValue)
        #expect(HistoryTint.stored(.commits, defaults: suite) == .automatic)
        #expect(HistoryTint.dynamic(.automatic) == nil)
        #expect(HistoryTint.dynamic(.lime) != nil)
        #expect(HistoryTint.mergeLabel(tint: .automatic) === Theme.merged)
        let merge = HistoryTint.mergeLabel(tint: .blue)
        #expect(merge !== Theme.merged)
        #expect(Theme.huesNear(drawn(merge, dark: true), Theme.hex(0x4C9AFF)))
    }

    @Test func interfaceFontStoredValuesRoundTrip() {
        #expect(InterfaceFont(stored: "system") == .system)
        #expect(InterfaceFont(stored: "sf-pro-rounded") == .system)
        #expect(InterfaceFont(stored: "mono:menlo").face == .menlo)
        #expect(InterfaceFont(stored: "mono:unknown") == .system)
        #expect(InterfaceFont(face: .menlo).id == "mono:menlo")
        #expect(InterfaceFont.system.id == "system")
        #expect(InterfaceFont.system.title.contains("SF Pro"))
        #expect(InterfaceFont(face: .system).title == "SF Mono")
        #expect(InterfaceFont(face: .menlo).title == "Menlo")
        #expect(InterfaceFont.groups.count == 2)
        #expect(InterfaceFont.groups[1].count == CodeFont.allCases.count)
        #expect(InterfaceFont.system.make(12, weight: .bold).pointSize == 12)
        #expect(InterfaceFont(face: .menlo).make(14).familyName == "Menlo")
    }
}
