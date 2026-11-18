import AppKit
import Foundation
import Testing

@testable import GitaCore
@testable import GitaUI

@MainActor
@Suite struct SharedDeckTests {
    @Test func adaptiveColoursPickByAppearance() {
        let color = Deck.adaptive(light: .white, dark: .black)
        var light: NSColor?
        var dark: NSColor?
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance { light = color.usingColorSpace(.sRGB) }
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { dark = color.usingColorSpace(.sRGB) }
        #expect(light?.redComponent == 1)
        #expect(dark?.redComponent == 0)
        #expect([Deck.link, Deck.quietFill, Deck.segmentFill, Deck.groupHeaderFill].count == 4)
        _ = Deck.reduceMotion
    }

    @Test func agentStatesHaveSymbols() {
        #expect(Deck.agentStateSymbol(.needsInput) == Deck.needsInputSymbol)
        #expect(Deck.agentStateSymbol(.working) == "play.fill")
        #expect(Deck.agentStateSymbol(.done) == "checkmark")
        #expect(Deck.agentStateSymbol(.idle) == "moon.zzz")
    }

    @Test func symbolsAreCachedPerColourAndAppearance() {
        let first = Deck.symbol("star.fill", size: 12, color: Theme.text)
        #expect(first != nil)
        #expect(Deck.symbol("star.fill", size: 12, color: Theme.text) === first)
        #expect(Deck.symbol("checkmark.circle.fill", size: 12, color: Theme.success, inner: .white) != nil)
        #expect(Deck.symbol("no-such-symbol-anywhere", size: 12, color: Theme.text) == nil)
        // Past the cache limit the cache starts over and still answers.
        for size in 0..<405 { _ = Deck.symbol("circle", size: 8 + CGFloat(size) / 100, color: Theme.text) }
        #expect(Deck.symbol("star.fill", size: 12, color: Theme.text) != nil)
    }

    @Test func templatesAreTemplateImagesAndCached() throws {
        let image = try #require(Deck.template("gearshape", size: 11))
        #expect(image.isTemplate)
        #expect(Deck.template("gearshape", size: 11) === image)
        let view = Deck.icon("gearshape", size: 11, color: Theme.accent)
        #expect(view.image === image)
        #expect(view.contentTintColor === Theme.accent)
        view.setSymbol(nil, size: 11, color: Theme.text)
        #expect(view.image == nil)
    }

    @Test func copyWritesThePasteboardItIsGiven() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("GitaUITests-" + UUID().uuidString))
        defer { pasteboard.releaseGlobally() }
        Deck.copy("https://example.com", to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "https://example.com")
    }

    @Test(arguments: [
        ("https://example.com/path", true), ("http://example.com", false), ("https://user:pw@example.com", false),
        ("https://user@example.com", false), ("file:///etc/hosts", false), ("HTTPS://example.com", true),
        ("https:///nohost", false),
    ])
    func onlyCredentialFreeHTTPSAddressesAreSafe(text: String, safe: Bool) {
        #expect((Deck.safeWebURL(URL(string: text)) != nil) == safe)
    }

    @Test func openingAnUnsafeAddressDoesNothing() {
        #expect(Deck.safeWebURL(nil) == nil)
        Deck.open(nil)
        Deck.open(URL(string: "http://example.invalid"))
    }

    @Test func applicationNamesDropTheExtension() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaUITests-\(UUID().uuidString)", isDirectory: true)
        let app = folder.appendingPathComponent("Example Tool.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(Deck.applicationName(at: app) == "Example Tool")
    }

    @Test func pillsHaveColoursPerKind() {
        for kind in [Deck.PillKind.head, .branch, .remote, .tag] {
            let colors = Deck.pillColors(kind)
            #expect(colors.fill !== colors.text)
            #expect(colors.border.alphaComponent <= 1)
        }
        #expect(Deck.pillColors(.head).text === Theme.checkedOut)
        #expect(Deck.pillColors(.branch).text !== Theme.checkedOut)
        #expect(Deck.pillColors(.remote).text !== Theme.checkedOut)
        #expect(Deck.pillColors(.tag).text !== Theme.checkedOut)
    }

    @Test(arguments: [
        ("Ada Lovelace", "AL"), ("grace", "GR"), ("jean-luc picard", "JP"), ("x", "X"), ("", ""), ("42 7", "4"),
        ("john_ronald.tolkien", "JT"),
    ])
    func initialsTakeTheFirstAndLastWord(name: String, expected: String) {
        #expect(Deck.computeInitials(name) == expected)
        #expect(Deck.initials(name) == expected)
        #expect(Deck.initials(name) == expected)
    }

    @Test func avatarsDrawInitialsAndLaneColoursInBothAppearances() throws {
        let (defaults, name) = SharedFixtures.scratchDefaults()
        let previous = Theme.authorStore
        Theme.authorStore = defaults
        defer {
            Theme.authorStore = previous
            SharedFixtures.remove(name)
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let bitmap = try #require(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                Deck.drawAvatar("Ada Lovelace", in: NSRect(x: 0, y: 0, width: 24, height: 24))
                Deck.drawAvatar("Ada Lovelace", in: NSRect(x: 0, y: 0, width: 24, height: 24))
                Deck.drawAvatar("Grace", in: NSRect(x: 30, y: 0, width: 16, height: 16), lane: 3)
            }
            NSGraphicsContext.restoreGraphicsState()
            #expect((bitmap.colorAt(x: 12, y: 20)?.alphaComponent ?? 0) > 0)
            #expect((bitmap.colorAt(x: 38, y: 24)?.alphaComponent ?? 0) > 0)
        }
        Deck.themeChanged()
    }

    @Test func labelsStacksAndLayoutHelpers() {
        let label = Deck.label("Title", font: Theme.title, color: Theme.accent)
        #expect(label.maximumNumberOfLines == 1)
        #expect(label.font == Theme.title)
        #expect(Deck.caption("c").font == Theme.caption)
        let section = Deck.sectionTitle("deployments")
        #expect(section.stringValue == "DEPLOYMENTS")
        let hstack = Deck.hstack([NSView(), Deck.spacer()], spacing: 3)
        #expect(hstack.orientation == .horizontal && hstack.spacing == 3)
        let vstack = Deck.vstack([NSView()])
        #expect(vstack.orientation == .vertical && vstack.alignment == .leading)
        #expect(Deck.separator().constraints.first?.firstAttribute == .height)
        #expect(Deck.separator(vertical: true).constraints.first?.firstAttribute == .width)
        let scroll = NSScrollView()
        let document = Deck.document(in: scroll)
        #expect(scroll.documentView === document)
        let parent = NSView()
        let child = NSView()
        Deck.pin(child, in: parent, insets: NSEdgeInsets(top: 1, left: 2, bottom: 3, right: 4))
        #expect(child.superview === parent)
        #expect(parent.constraints.count == 4)
        #expect(Deck.truncatingTail.lineBreakMode == .byTruncatingTail)
    }

    @Test func relativeDatesReadNowThenRelativeThenADate() {
        let now = SharedFixtures.now
        #expect(DeckFormat.relative(now.addingTimeInterval(-30), now: now) == String(localized: "now"))
        #expect(DeckFormat.relative(now.addingTimeInterval(30), now: now) == String(localized: "now"))
        let hours = DeckFormat.relative(now.addingTimeInterval(-7_200), now: now)
        #expect(hours != String(localized: "now"))
        let old = now.addingTimeInterval(-30 * 86_400)
        let first = DeckFormat.relative(old, now: now)
        #expect(DeckFormat.relative(old, now: now) == first)
        #expect(first.contains(Calendar.current.component(.year, from: old).description))
    }

    @Test func durationsRoundAndDropZeroUnits() {
        #expect(DeckFormat.duration(-1).isEmpty)
        #expect(DeckFormat.duration(.infinity).isEmpty)
        #expect(DeckFormat.duration(0) == DeckFormat.duration(1))
        #expect(DeckFormat.duration(65) != DeckFormat.duration(3_600))
        #expect(DeckFormat.duration(3_629) == DeckFormat.duration(3_600))
    }
}
