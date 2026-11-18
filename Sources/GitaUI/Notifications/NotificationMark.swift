import AppKit
import GitaCore
import UserNotifications

/// Who a notification is about, shown as its mark: the coding agent (Claude, Codex…) or the service (GitHub, Vercel).
/// macOS has no inline images in a notification's title or body, so the mark goes in as an attachment, which
/// Notification Center shows as a thumbnail beside the text.
enum NotificationMark: Hashable {
    case agent(AgentTool)
    case brand(BrandMarks.Brand)

    /// Deployments come from Vercel; pull requests and workflow runs from GitHub.
    static func provider(_ destination: ProviderNotificationDestination) -> Self {
        if case .deployment = destination.target { return .brand(.vercel) }
        return .brand(.github)
    }

    /// Side of the rendered PNG in pixels.
    static let pixels = 128
    /// Monochrome marks are drawn in this ink on a white tile, so they read on light and dark banners alike.
    private static let ink = NSColor(srgbRed: 0.09, green: 0.09, blue: 0.1, alpha: 1)

    /// A brand drawn from a file needs that file; agent marks fall back to a drawing.
    private var isAvailable: Bool {
        guard case .brand(let brand) = self, let file = brand.file else { return true }
        return BundledResources.url(file).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// The mark on a white rounded tile as PNG data; nil when its logo is missing or drawing fails.
    @MainActor
    func png() -> Data? {
        let side = CGFloat(Self.pixels)
        guard isAvailable,
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Self.pixels, pixelsHigh: Self.pixels, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                bitsPerPixel: 0),
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let tile = NSRect(x: 0, y: 0, width: side, height: side)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: tile, xRadius: side * 0.22, yRadius: side * 0.22).fill()
        draw(in: tile.insetBy(dx: side * 0.2, dy: side * 0.2), context: graphics.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    @MainActor
    private func draw(in rect: NSRect, context: CGContext) {
        switch self {
        case .agent(let tool):
            AgentMarkPainter.draw(AgentMarks.kind(tool), in: rect, context: context, ink: Self.ink.cgColor)
        case .brand(let brand):
            BrandMarks.image(brand, size: rect.width, color: Self.ink).draw(in: rect)
        }
    }

    /// The mark as a notification attachment, written to a fresh file that macOS moves into its own store.
    /// Nil when it can't be made: the notification is still sent, without the mark.
    @MainActor
    func attachment(directory: URL = FileManager.default.temporaryDirectory) -> UNNotificationAttachment? {
        guard let data = png() else { return nil }
        let folder = directory.appendingPathComponent("gita-notification-marks", isDirectory: true)
        let file = folder.appendingPathComponent(UUID().uuidString + ".png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file)
            return try UNNotificationAttachment(identifier: "gita.mark", url: file, options: nil)
        } catch {
            try? FileManager.default.removeItem(at: file)
            return nil
        }
    }
}
