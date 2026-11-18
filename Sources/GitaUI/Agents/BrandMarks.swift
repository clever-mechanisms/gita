import AppKit
import GitaCore

/// Service and app marks wherever Gita names one: GitHub (Octicons mark, `Resources/AgentMarks/github.svg`), GitLab
/// and Bitbucket (Simple Icons, `Resources/ProviderMarks`), Vercel (the solid triangle) and installed apps by their
/// own icon (Orca, Warp, Terminal, Cursor, Finder…).
/// Monochrome marks are redrawn on every display, so they follow appearance and theme like `AgentMarks`.
@MainActor
enum BrandMarks {
    enum Brand {
        case github, vercel, gitlab, bitbucket

        /// The mark's file below the resources, for the marks drawn from a file.
        var file: String? {
            switch self {
            case .github: "AgentMarks/github.svg"
            case .gitlab: "ProviderMarks/gitlab.svg"
            case .bitbucket: "ProviderMarks/bitbucket.svg"
            case .vercel: nil
            }
        }
        var name: String {
            switch self {
            case .github: "GitHub"
            case .vercel: "Vercel"
            case .gitlab: "GitLab"
            case .bitbucket: "Bitbucket"
            }
        }
    }
    static let orca = "com.stablyai.orca"
    static let finder = "com.apple.finder"

    private static var logos: [URL: NSImage] = [:]
    /// A mark drawn from a file in the resource folder, loaded once per file.
    private static func logo(_ brand: Brand) -> NSImage? {
        guard let file = brand.file, let url = BundledResources.url(file) else { return nil }
        if let image = logos[url] { return image }
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        logos[url] = image
        return image
    }

    /// The host of a remote URL (https or scp-like ssh) as a brand with a mark; nil for any other host.
    static func remote(_ url: String?) -> Brand? {
        guard let host = url.flatMap({ GitHubRemote.host(of: $0) }) else { return nil }
        if host.contains("github") { return .github }
        if host.contains("gitlab") { return .gitlab }
        if host.contains("bitbucket") { return .bitbucket }
        return nil
    }
    private static var images: [String: NSImage] = [:]
    private static let imageLimit = 128

    /// The mark `size` points square in `color` (a dynamic colour resolves when drawn).
    static func image(_ brand: Brand, size: CGFloat, color: NSColor = Theme.text) -> NSImage {
        let key = "\(brand)|\(size)|\(ObjectIdentifier(color).hashValue)"
        if let image = images[key] { return image }
        if images.count >= imageLimit { images.removeAll() }
        let logo = logo(brand)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let ink = MainActor.assumeIsolated { color.cgColor }
            switch brand {
            case .github, .gitlab, .bitbucket:
                guard let logo else { return false }
                context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
                logo.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                context.setBlendMode(.sourceIn)
                context.setFillColor(ink)
                context.fill(rect)
                context.endTransparencyLayer()
            case .vercel:
                // Vercel's mark: an equilateral triangle, sitting on the box's lower edge.
                let side = rect.width
                let height = side * sqrt(3) / 2
                let bottom = rect.minY + (rect.height - height) / 2
                context.move(to: CGPoint(x: rect.midX, y: bottom + height))
                context.addLine(to: CGPoint(x: rect.minX, y: bottom))
                context.addLine(to: CGPoint(x: rect.maxX, y: bottom))
                context.closePath()
                context.setFillColor(ink)
                context.fillPath()
            }
            return true
        }
        image.cacheMode = .never
        image.accessibilityDescription = brand.name
        images[key] = image
        return image
    }

    /// An installed app's own icon, or nil when it is not installed.
    static func app(_ bundleID: String, size: CGFloat = 16) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return app(at: url, size: size)
    }
    static func app(at url: URL, size: CGFloat = 16) -> NSImage {
        let original = NSWorkspace.shared.icon(forFile: url.path)
        let icon = (original.copy() as? NSImage) ?? original
        icon.size = NSSize(width: size, height: size)
        return icon
    }

    /// The mark for a web page: GitHub's on github.com, nil elsewhere.
    static func web(_ url: URL, size: CGFloat, color: NSColor = Theme.text) -> NSImage? {
        let host = url.host?.lowercased() ?? ""
        if host == "github.com" || host.hasSuffix(".github.com") { return image(.github, size: size, color: color) }
        if host == "vercel.com" || host.hasSuffix(".vercel.app") { return image(.vercel, size: size, color: color) }
        return nil
    }

    /// "<mark> Name" for labels and titles, the mark centred on the font's capitals.
    static func label(_ image: NSImage, _ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let side = (font.capHeight + 6).rounded()
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: ((font.capHeight - side) / 2).rounded(), width: side, height: side)
        let value = NSMutableAttributedString(attachment: attachment)
        value.append(NSAttributedString(string: " " + text, attributes: [.font: font, .foregroundColor: color]))
        return value
    }
}
