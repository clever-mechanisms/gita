import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import GitaCore
@testable import GitaUI

@MainActor
@Suite("Image diff viewer and decoding", .serialized)
struct ImageDiffViewTests {
    private static func makeImageData(
        width: Int, height: Int, color: (UInt8, UInt8, UInt8, UInt8), type: UTType = .png, orientation: Int? = nil
    ) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = color.0
            pixels[index + 1] = color.1
            pixels[index + 2] = color.2
            pixels[index + 3] = color.3
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        let cgImage = try #require(
            CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        var props: [CFString: Any] = [:]
        if let orientation { props[kCGImagePropertyOrientation] = orientation }
        CGImageDestinationAddImage(destination, cgImage, props as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func imageFileFormatDetectsSupportedExtensionsAndLabels() {
        #expect(ImageFileFormat.isSupportedImagePath("assets/banner.png"))
        #expect(ImageFileFormat.isSupportedImagePath("photos/LIVE.JPG"))
        #expect(ImageFileFormat.isSupportedImagePath("icons/app.webp"))
        #expect(ImageFileFormat.isSupportedImagePath("icons/photo.heic"))
        #expect(ImageFileFormat.isSupportedImagePath("icons/icon.ico"))
        #expect(!ImageFileFormat.isSupportedImagePath("Sources/App.swift"))
        #expect(!ImageFileFormat.isSupportedImagePath("archive.bin"))
        #expect(!ImageFileFormat.isSupportedImagePath(nil))
        #expect(!ImageFileFormat.isSupportedImagePath(""))

        #expect(ImageFileFormat.displayLabel(for: "a/banner.png") == "PNG")
        #expect(ImageFileFormat.displayLabel(for: "a/photo.jpg") == "JPEG")
        #expect(ImageFileFormat.displayLabel(for: "a/scan.tif") == "TIFF")
        #expect(ImageFileFormat.displayLabel(for: "a/photo.jp2") == "JPEG 2000")
        #expect(ImageFileFormat.displayLabel(for: "noext") == String(localized: "Image"))
    }

    @Test func imageAssetDecodingZoomAndDocumentMetadata() throws {
        let pngData = try Self.makeImageData(width: 64, height: 32, color: (20, 140, 220, 200), type: .png)
        let jpegData = try Self.makeImageData(
            width: 80, height: 40, color: (220, 80, 40, 255), type: .jpeg, orientation: 6)

        let pngAsset = try #require(ImageDiffAsset.decode(data: pngData))
        #expect(pngAsset.pixelWidth == 64 && pngAsset.pixelHeight == 32)
        #expect(pngAsset.byteCount == Int64(pngData.count))
        #expect(pngAsset.dimensionsText == "64 × 32")

        // EXIF orientation 6 rotates 90 degrees, swapping width & height.
        let rotated = try #require(ImageDiffAsset.decode(data: jpegData))
        #expect(rotated.pixelWidth == 40 && rotated.pixelHeight == 80)

        #expect(ImageDiffAsset.decode(data: Data()) == nil)
        #expect(ImageDiffAsset.decode(data: Data([0x00, 0x01, 0x02, 0x03])) == nil)

        // Zoom logic: Fit never upscales small images and scales down large images.
        #expect(ImageDiffZoom.fit.label == String(localized: "Fit"))
        #expect(ImageDiffZoom.scale(1.5).label == "150%")
        #expect(
            ImageDiffZoom.fit.effectiveScale(
                contentSize: CGSize(width: 64, height: 64), viewportSize: CGSize(width: 400, height: 400)) == 1)
        #expect(
            ImageDiffZoom.fit.effectiveScale(
                contentSize: CGSize(width: 800, height: 400), viewportSize: CGSize(width: 400, height: 400)) == 0.5)
        #expect(ImageDiffZoom.fit.togglingFitAndActual() == .scale(1.0))
        #expect(ImageDiffZoom.scale(1.0).togglingFitAndActual() == .fit)
        #expect(ImageDiffZoom.fit.zoomingIn(currentScale: 1.0) == .scale(1.5))
        #expect(ImageDiffZoom.fit.zoomingOut(currentScale: 1.0) == .scale(0.75))
        #expect(ImageDiffZoom.scale(1.0).canZoomIn(currentScale: 1.0))
        #expect(!ImageDiffZoom.scale(4.0).canZoomIn(currentScale: 4.0))
        #expect(!ImageDiffZoom.scale(0.25).canZoomOut(currentScale: 0.25))

        // Document metadata across added / removed / modified / blob kinds.
        let summary = BinaryDiffSummary(
            path: "banner.png", oldByteCount: nil, newByteCount: pngAsset.byteCount, fileURL: nil)
        let added = ImageDiffDocument(summary: summary, old: nil, new: pngAsset, isBlob: false)
        #expect(added.kind == .added && !added.supportsComparison)
        #expect(added.statusBadgeTitle == String(localized: "Added"))
        #expect(added.metadataText.contains("PNG") && added.metadataText.contains("64 × 32"))

        let removed = ImageDiffDocument(summary: summary, old: pngAsset, new: nil, isBlob: false)
        #expect(removed.kind == .removed && removed.statusBadgeTitle == String(localized: "Removed"))

        let blob = ImageDiffDocument(summary: summary, old: nil, new: pngAsset, isBlob: true)
        #expect(blob.kind == .blob && blob.statusBadgeTitle == nil)

        let modified = ImageDiffDocument(summary: summary, old: pngAsset, new: rotated, isBlob: false)
        #expect(modified.kind == .modified && modified.supportsComparison)
        #expect(modified.metadataText.contains("64 × 32 → 40 × 80"))
        #expect(modified.referenceCanvasSize == CGSize(width: 64, height: 80))
    }

    @Test func imageDiffViewRendersModesZoomAndTopBarActions() throws {
        UITestSupport.bootstrap()
        let oldAsset = try #require(
            ImageDiffAsset.decode(data: Self.makeImageData(width: 120, height: 80, color: (20, 120, 220, 255))))
        let newAsset = try #require(
            ImageDiffAsset.decode(data: Self.makeImageData(width: 160, height: 80, color: (30, 190, 90, 255))))
        let fileURL = URL(fileURLWithPath: "/tmp/banner.png")
        let summary = BinaryDiffSummary(
            path: "output/banner.png", oldByteCount: oldAsset.byteCount, newByteCount: newAsset.byteCount,
            fileURL: fileURL)

        let view = ImageDiffView(frame: NSRect(x: 0, y: 0, width: 720, height: 420))
        var opened: URL?
        var revealed: URL?
        view.onOpen = { opened = $0 }
        view.onRevealInFinder = { revealed = $0 }

        // Loading state keeps Open & Reveal in Finder available on top bar.
        view.apply(.loading(summary))
        #expect(!view.isHidden)
        #expect(view.openButton.isEnabled && view.revealButton.isEnabled)
        #expect(view.modeControl.isHidden)
        view.openButton.onClick?()
        view.revealButton.onClick?()
        #expect(opened == fileURL && revealed == fileURL)
        UITestSupport.render(view)

        // Modified image supports Side by Side, Swipe, and Onion modes + zoom controls.
        let modified = ImageDiffDocument(summary: summary, old: oldAsset, new: newAsset, isBlob: false)
        view.apply(.ready(modified))
        #expect(!view.modeControl.isHidden)
        #expect(view.mode == .sideBySide)
        UITestSupport.render(view)

        view.setMode(.swipe)
        #expect(view.mode == .swipe && !view.swipeSurface.isHidden)
        view.swipeSurface.splitFraction = 0.25
        #expect(view.swipeSurface.accessibilityValue() as? Int == 25)
        UITestSupport.render(view)

        view.setMode(.onion)
        #expect(view.mode == .onion && !view.onionSurface.isHidden)
        view.onionSlider.doubleValue = 0.75
        view.onionSlider.sendAction(view.onionSlider.action, to: view.onionSlider.target)
        #expect(abs(view.onionOpacity - 0.75) < 0.01)
        UITestSupport.render(view)

        // Zoom in / out / reset toggle.
        view.stepZoomIn()
        #expect(view.zoom != .fit)
        view.stepZoomOut()
        view.toggleFitAndActual()
        #expect(view.zoom == .fit)

        // Added & Removed single-image states render cleanly and disable actions when fileURL is nil.
        let removedSummary = BinaryDiffSummary(
            path: "output/banner.png", oldByteCount: oldAsset.byteCount, newByteCount: nil, fileURL: nil)
        view.apply(.ready(ImageDiffDocument(summary: removedSummary, old: oldAsset, new: nil, isBlob: false)))
        #expect(!view.singleSurface.isHidden)
        #expect(view.modeControl.isHidden)
        #expect(!view.openButton.isEnabled && !view.revealButton.isEnabled)
        UITestSupport.render(view)

        view.apply(.hidden)
        #expect(view.isHidden)
    }

    @Test func repositoryWindowDisplaysImagesInLocalChangesTreeCompareAndFallsBackWhenCorrupt() async throws {
        let pngV1 = try Self.makeImageData(width: 96, height: 48, color: (30, 100, 220, 255), type: .png)
        let pngV2 = try Self.makeImageData(width: 120, height: 60, color: (220, 60, 40, 255), type: .png)
        let jpgData = try Self.makeImageData(width: 64, height: 64, color: (40, 180, 90, 255), type: .jpeg)
        let corruptPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0xFE, 0x00])

        let fixture = try await RepositoryWindowFixture { repo in
            let assets = repo.url.appendingPathComponent("assets", isDirectory: true)
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            try pngV1.write(to: assets.appendingPathComponent("banner.png"))
            try repo.git("add", "assets/banner.png")
            try repo.git("commit", "-q", "-m", "Add banner v1")
            // Modify tracked PNG, add untracked JPG, and add a corrupt PNG.
            try pngV2.write(to: assets.appendingPathComponent("banner.png"))
            try jpgData.write(to: assets.appendingPathComponent("preview.jpg"))
            try corruptPNG.write(to: assets.appendingPathComponent("broken.png"))
        }
        defer { fixture.close() }

        fixture.model.section = .changes
        // 1. Modified PNG renders both Before and After in ImageDiffView and hides text-diff header controls.
        fixture.controller.chooseChange(
            FileChange(path: "assets/banner.png", indexStatus: " ", worktreeStatus: "M"), staged: false)
        try await fixture.wait("modified PNG image diff ready") {
            if case .ready(let doc) = fixture.controller.codePane.diffView.imageDiffView.state {
                return doc.summary.path == "assets/banner.png" && doc.supportsComparison
                    && doc.old?.pixelWidth == 96 && doc.new?.pixelWidth == 120
            }
            return false
        }
        let imageView = fixture.controller.codePane.diffView.imageDiffView
        #expect(!imageView.isHidden)
        #expect(fixture.controller.codePane.diffView.binaryEmptyView.isHidden)
        #expect(fixture.controller.codePane.layoutControl.isHidden)
        #expect(fixture.controller.codePane.optionsButton.isHidden)
        #expect(fixture.controller.codePane.findButton.isHidden)
        #expect(imageView.openButton.isEnabled && imageView.revealButton.isEnabled)

        // 2. Untracked JPEG renders single Added image preview.
        fixture.controller.chooseChange(
            FileChange(path: "assets/preview.jpg", indexStatus: "?", worktreeStatus: "?"), staged: false)
        try await fixture.wait("untracked JPEG image diff ready") {
            if case .ready(let doc) = fixture.controller.codePane.diffView.imageDiffView.state {
                return doc.summary.path == "assets/preview.jpg" && doc.kind == .added && doc.new?.pixelWidth == 64
            }
            return false
        }

        // 3. Corrupt PNG falls back to BinaryDiffEmptyView cleanly.
        fixture.controller.chooseChange(
            FileChange(path: "assets/broken.png", indexStatus: "?", worktreeStatus: "?"), staged: false)
        try await fixture.wait("corrupt PNG falls back to binary empty state") {
            !fixture.controller.codePane.diffView.binaryEmptyView.isHidden
                && fixture.controller.codePane.diffView.imageDiffView.isHidden
        }

        // 4. Commit File Tree blob mode renders the committed PNG.
        fixture.model.section = .history
        try await fixture.selectCommit("Add banner v1")
        fixture.controller.selectDetailTab(.tree)
        try await fixture.wait("tree review active") { fixture.model.isTreeReview }
        fixture.model.selectTreeEntry(TreeEntry(path: "assets/banner.png", kind: "blob", objectID: ""))
        try await fixture.wait("tree blob PNG ready") {
            if case .ready(let doc) = fixture.controller.codePane.diffView.imageDiffView.state {
                return doc.kind == .blob && doc.new?.pixelWidth == 96
            }
            return false
        }

        // 5. CommitCompareView renders modified image across two commits.
        try fixture.repository.git("add", "assets/banner.png")
        try fixture.repository.git("commit", "-q", "-m", "Update banner v2")
        try await fixture.refresh()
        let commits = fixture.controller.historyCommits
        #expect(commits.count >= 2)
        fixture.historyTable.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        try await fixture.wait("compare image diff ready") {
            if case .ready(let doc) = fixture.controller.commitDetail.compareView.diffView.imageDiffView.state {
                return doc.supportsComparison && doc.old?.pixelWidth == 96 && doc.new?.pixelWidth == 120
            }
            return false
        }
    }
}
