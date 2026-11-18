import AppKit
import GitaCore
import Testing

@testable import GitaUI

@MainActor
@Suite("Palette branches and remote marks")
struct PaletteBranchEntriesTests {
    private static func reference(_ name: String, _ kind: GitReference.Kind, current: Bool = false) -> GitReference {
        let prefix = kind == .branch ? "refs/heads/" : "refs/remotes/"
        return GitReference(name: name, fullName: prefix + name, commit: "c", kind: kind, isCurrent: current)
    }

    private static let snapshot = RepositorySnapshot(
        root: URL(fileURLWithPath: "/r"), branch: "main", head: "c", changes: [], commits: [],
        references: [
            reference("main", .branch, current: true), reference("feature/login", .branch),
            reference("old", .branch), reference("origin/main", .remote), reference("origin/HEAD", .remote),
            reference("origin/release", .remote), reference("wip", .branch),
        ],
        worktrees: [
            GitWorktree(path: "/r", branch: "main", head: "c"), GitWorktree(path: "/r-wip", branch: "wip", head: "c"),
        ],
        stashes: [], remoteURL: nil, gitDirectory: URL(fileURLWithPath: "/r/.git"))

    @Test func branchesAreNewestFirstWithRemoteOnlyOnesAndWorktrees() {
        let dates = [
            "refs/heads/main": Date(timeIntervalSince1970: 10),
            "refs/heads/feature/login": Date(timeIntervalSince1970: 30),
            "refs/remotes/origin/release": Date(timeIntervalSince1970: 20),
        ]
        let entries = BranchPaletteEntries.make(Self.snapshot, dates: dates)
        #expect(entries.map(\.name) == ["feature/login", "origin/release", "main", "old", "wip"])
        #expect(entries.first { $0.name == "origin/release" }?.isRemote == true)
        #expect(entries.first { $0.name == "wip" }?.worktree == "/r-wip")
        #expect(entries.first { $0.name == "main" }?.isCurrent == true)
    }

    @Test func remoteHostsHaveMarks() {
        #expect(BrandMarks.remote("git@github.com:o/r.git") == .github)
        #expect(BrandMarks.remote("git@github-sqligrp:o/r.git") == .github)
        #expect(BrandMarks.remote("https://github.sqligrp.com/o/r") == .github)
        #expect(BrandMarks.remote("https://gitlab.example.com/o/r") == .gitlab)
        #expect(BrandMarks.remote("https://bitbucket.org/o/r") == .bitbucket)
        #expect(BrandMarks.remote("https://example.com/github/r") == nil)
        #expect(BrandMarks.remote("https://example.com/o/r") == nil && BrandMarks.remote(nil) == nil)
        for brand in [BrandMarks.Brand.github, .gitlab, .bitbucket, .vercel] {
            #expect(!brand.name.isEmpty)
            let image = BrandMarks.image(brand, size: 14)
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 14, pixelsHigh: 14, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            if let bitmap, let context = NSGraphicsContext(bitmapImageRep: bitmap) {
                NSGraphicsContext.current = context
                image.draw(in: NSRect(x: 0, y: 0, width: 14, height: 14))
                NSGraphicsContext.current = nil
            }
        }
    }

    @Test func workflowCountsMatchThePage() {
        let vercelRun = ProviderItem(
            id: "run", provider: .vercel, category: "CI", title: "CI", state: .running, kind: .workflowRun)
        let query = ProviderSignalQuery(signals: [vercelRun])
        #expect(query.activeWorkflows == 1)
        #expect(ProviderPageState.lists(vercelRun, on: .workflows))
    }
}
