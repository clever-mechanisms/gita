import AppKit
import Foundation
import GitaCore
import Testing
import UserNotifications

@testable import GitaUI

/// The agent or service mark each notification carries as its thumbnail.
@MainActor
struct NotificationsMarkTests {
    typealias NF = NotificationsFixtures

    @Test func providerNotificationsShowTheServiceThatReportedThem() {
        #expect(NotificationMark.provider(NF.destination()) == .brand(.github))
        #expect(
            NotificationMark.provider(NF.destination(NF.pullRequest(), event: .pullRequestOpened)) == .brand(.github))
        #expect(
            NotificationMark.provider(NF.destination(NF.deployment(), event: .previewReady)) == .brand(.vercel))
    }

    @Test func everyMarkRendersAsASquarePNGOnAWhiteTile() throws {
        let marks = AgentTool.allCases.map(NotificationMark.agent) + [.brand(.github), .brand(.vercel)]
        let resources = BundledResources.root
        BundledResources.root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources", isDirectory: true)
        defer { BundledResources.root = resources }
        for mark in marks {
            let data = try #require(mark.png(), "\(mark)")
            let bitmap = try #require(NSBitmapImageRep(data: data))
            #expect(bitmap.pixelsWide == NotificationMark.pixels)
            #expect(bitmap.pixelsHigh == NotificationMark.pixels)
            let middle = NotificationMark.pixels / 2
            #expect(bitmap.colorAt(x: middle, y: 4)?.usingColorSpace(.deviceRGB)?.redComponent ?? 0 > 0.9)
            #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0, "the tile's corners are rounded")
        }
    }

    @Test func aBrandWhoseLogoIsMissingHasNoMark() {
        let resources = BundledResources.root
        BundledResources.root = FileManager.default.temporaryDirectory.appendingPathComponent("GitaUITests.\(UUID())")
        defer { BundledResources.root = resources }
        #expect(NotificationMark.brand(.github).png() == nil)
        #expect(NotificationMark.brand(.vercel).png() != nil)
        #expect(NotificationMark.agent(.claudeCode).png() != nil)
    }

    @Test func theAttachmentIsAFreshPNGFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitaUITests.Marks.\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try #require(NotificationMark.agent(.codex).attachment(directory: directory))
        let second = try #require(NotificationMark.agent(.codex).attachment(directory: directory))
        #expect(first.identifier == "gita.mark")
        #expect(first.url != second.url)
        #expect(first.url.pathExtension == "png")

        let blocked = directory.appendingPathComponent("file")
        try Data().write(to: blocked)
        #expect(NotificationMark.brand(.vercel).attachment(directory: blocked) == nil)
    }
}
