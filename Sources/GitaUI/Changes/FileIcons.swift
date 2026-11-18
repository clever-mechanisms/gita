import AppKit
import UniformTypeIdentifiers

/// Finder's icon per file type, cached by extension.
@MainActor
enum FileIcons {
    private static let side: CGFloat = 16
    private static var cache: [String: NSImage] = [:]
    static let folder = sized(NSWorkspace.shared.icon(for: .folder))

    static func icon(for path: String) -> NSImage {
        let ext = RepositoryPathText.fileExtension(path)
        if let cached = cache[ext] { return cached }
        let image = sized(NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data))
        cache[ext] = image
        return image
    }
    private static func sized(_ image: NSImage) -> NSImage {
        image.size = NSSize(width: side, height: side)
        return image
    }
}
