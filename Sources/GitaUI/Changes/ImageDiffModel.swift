import CoreGraphics
import Foundation
import ImageIO

/// Supported raster image file extensions and display labels.
enum ImageFileFormat {
    static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "jpe", "gif", "webp", "heic", "heif", "avif",
        "bmp", "tif", "tiff", "ico", "icns", "jp2", "tga",
    ]

    static func isSupportedImagePath(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        let ext = RepositoryPathText.fileExtension(path).lowercased()
        return supportedExtensions.contains(ext)
    }

    static func displayLabel(for path: String) -> String {
        switch RepositoryPathText.fileExtension(path).lowercased() {
        case "jpg", "jpeg", "jpe": "JPEG"
        case "tif", "tiff": "TIFF"
        case "jp2": "JPEG 2000"
        case let ext where !ext.isEmpty: ext.uppercased()
        default: String(localized: "Image")
        }
    }
}

/// One decoded side of an image diff, safe to produce off the main thread.
struct ImageDiffAsset: Equatable, Sendable {
    static let maxPreviewBytes = 32 * 1_024 * 1_024
    static let maxPreviewPixelSide = 4_096

    var cgImage: CGImage
    var pixelWidth: Int
    var pixelHeight: Int
    var byteCount: Int64

    var dimensionsText: String { "\(pixelWidth) × \(pixelHeight)" }
    var byteSizeText: String { BinaryDiffSummary.formatBytes(byteCount) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.pixelWidth == rhs.pixelWidth && lhs.pixelHeight == rhs.pixelHeight
            && lhs.byteCount == rhs.byteCount && lhs.cgImage === rhs.cgImage
    }

    static func decode(data: Data) -> Self? {
        guard !data.isEmpty, data.count <= maxPreviewBytes,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPreviewPixelSide,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let size = orientedPixelDimensions(in: source) ?? (image.width, image.height)
        return Self(cgImage: image, pixelWidth: size.width, pixelHeight: size.height, byteCount: Int64(data.count))
    }

    private static func orientedPixelDimensions(in source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? (height, width) : (width, height)
    }
}

/// Comparison presentation when both Before and After versions of an image exist.
enum ImageDiffMode: String, CaseIterable, Sendable {
    case sideBySide
    case swipe
    case onion

    var title: String {
        switch self {
        case .sideBySide: String(localized: "Side by Side")
        case .swipe: String(localized: "Swipe")
        case .onion: String(localized: "Onion")
        }
    }
}

/// Zoom setting for `ImageDiffView`: automatic fit (never upscaling past 100%) or an explicit scale factor.
enum ImageDiffZoom: Equatable, Sendable {
    case fit
    case scale(CGFloat)

    static let presets: [CGFloat] = [0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0]

    var label: String {
        switch self {
        case .fit: String(localized: "Fit")
        case .scale(let factor): "\(Int((factor * 100).rounded()))%"
        }
    }

    func effectiveScale(contentSize: CGSize, viewportSize: CGSize) -> CGFloat {
        switch self {
        case .fit:
            Self.fitScale(contentSize: contentSize, viewportSize: viewportSize)
        case .scale(let factor):
            factor
        }
    }

    func zoomingIn(currentScale: CGFloat) -> Self {
        let next = Self.presets.first { $0 > currentScale + 0.01 } ?? Self.presets[Self.presets.count - 1]
        return .scale(next)
    }

    func zoomingOut(currentScale: CGFloat) -> Self {
        let previous = Self.presets.last { $0 < currentScale - 0.01 } ?? Self.presets[0]
        return .scale(previous)
    }

    func togglingFitAndActual() -> Self {
        switch self {
        case .fit: .scale(1.0)
        case .scale: .fit
        }
    }

    func canZoomIn(currentScale: CGFloat) -> Bool {
        currentScale < Self.presets[Self.presets.count - 1] - 0.01
    }

    func canZoomOut(currentScale: CGFloat) -> Bool {
        currentScale > Self.presets[0] + 0.01
    }

    static func fitScale(contentSize: CGSize, viewportSize: CGSize) -> CGFloat {
        guard contentSize.width > 0, contentSize.height > 0,
            viewportSize.width > 0, viewportSize.height > 0
        else { return 1 }
        return min(1, viewportSize.width / contentSize.width, viewportSize.height / contentSize.height)
    }
}

/// Pure presentation model for a loaded image diff or single-image blob preview.
struct ImageDiffDocument: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case added
        case removed
        case modified
        case blob
    }

    var summary: BinaryDiffSummary
    var old: ImageDiffAsset?
    var new: ImageDiffAsset?
    var isBlob: Bool

    var kind: Kind {
        if isBlob { return .blob }
        switch (old, new) {
        case (_?, _?): return .modified
        case (_?, nil): return .removed
        case (nil, _?): return .added
        case (nil, nil): return .blob
        }
    }

    var supportsComparison: Bool { old != nil && new != nil }
    var primaryAsset: ImageDiffAsset? { new ?? old }
    var formatLabel: String { ImageFileFormat.displayLabel(for: summary.path) }

    var statusBadgeTitle: String? {
        switch kind {
        case .added: String(localized: "Added")
        case .removed: String(localized: "Removed")
        case .modified, .blob: nil
        }
    }

    var metadataText: String {
        let format = formatLabel
        switch (old, new) {
        case (let before?, let after?):
            let dims =
                before.dimensionsText == after.dimensionsText
                ? after.dimensionsText
                : "\(before.dimensionsText) → \(after.dimensionsText)"
            return "\(format) · \(dims) · \(before.byteSizeText) → \(after.byteSizeText)"
        case (let before?, nil):
            return "\(format) · \(before.dimensionsText) · \(before.byteSizeText)"
        case (nil, let after?):
            return "\(format) · \(after.dimensionsText) · \(after.byteSizeText)"
        case (nil, nil):
            return format
        }
    }

    var oldCaption: String? {
        old.map { "\($0.dimensionsText) · \($0.byteSizeText)" }
    }

    var newCaption: String? {
        new.map { "\($0.dimensionsText) · \($0.byteSizeText)" }
    }

    var referenceCanvasSize: CGSize {
        let width = CGFloat(max(old?.pixelWidth ?? 0, new?.pixelWidth ?? 0))
        let height = CGFloat(max(old?.pixelHeight ?? 0, new?.pixelHeight ?? 0))
        return CGSize(width: max(1, width), height: max(1, height))
    }
}

/// Lifecycle of `ImageDiffView`: one enum instead of separate loading/document/fallback flags.
enum ImageDiffState: Equatable, Sendable {
    case hidden
    case loading(BinaryDiffSummary)
    case ready(ImageDiffDocument)

    var summary: BinaryDiffSummary? {
        switch self {
        case .hidden: nil
        case .loading(let summary): summary
        case .ready(let document): document.summary
        }
    }

    func isLoading(path: String) -> Bool {
        if case .loading(let summary) = self { return summary.path == path }
        return false
    }
}
