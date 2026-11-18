// Builds Resources/AppIcon.icns from the Gitá icon kit's full-bleed Apple icon (gita-media-kit/icon-kit/apple).
// Every size is drawn on the standard macOS icon grid: the artwork clipped to the system's rounded square
// (824 of 1024 points, centred) with a transparent margin. macOS 26 and later frame an icon in grey when it does not
// follow that shape; a full-bleed square passed at large sizes but was framed at 16 and 32 points (Notifications,
// list rows), so the shape is drawn into the icon itself rather than left to the system.
// Usage: swift scripts/artwork.swift [icon.png] [output.icns]
//   (defaults: ../gita-media-kit/icon-kit/apple/AppStore-1024.png, Resources/AppIcon.icns)
import AppKit
import Foundation

let arguments = CommandLine.arguments
let source = arguments.count > 1 ? arguments[1] : "../gita-media-kit/icon-kit/apple/AppStore-1024.png"
let output = arguments.count > 2 ? arguments[2] : "Resources/AppIcon.icns"
guard let data = FileManager.default.contents(atPath: source), let artwork = NSBitmapImageRep(data: data)?.cgImage,
    artwork.width == artwork.height, artwork.width >= 1024
else {
    FileHandle.standardError.write(Data("artwork: \(source) is not a square image of at least 1024 pixels\n".utf8))
    exit(1)
}

/// The macOS rounded square with continuous corners, in a 1024-point canvas: 824 points wide with a 185.4-point
/// radius, the curve's control points those of Apple's continuous-corner rounded rectangle.
func iconShape(scale: CGFloat) -> CGPath {
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let r: CGFloat = 185.4
    let path = CGMutablePath()
    // One corner described from its top-left-relative offsets, mirrored onto the four corners.
    func point(_ corner: Int, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        switch corner {
        case 0: return CGPoint(x: rect.maxX - x * r, y: rect.maxY - y * r)  // top right, along the top edge first
        case 1: return CGPoint(x: rect.maxX - y * r, y: rect.minY + x * r)  // bottom right
        case 2: return CGPoint(x: rect.minX + x * r, y: rect.minY + y * r)  // bottom left
        default: return CGPoint(x: rect.minX + y * r, y: rect.maxY - x * r)  // top left
        }
    }
    path.move(to: point(3, 0, 1.52866483))
    for corner in 0..<4 {
        path.addLine(to: point(corner, 1.52866483, 0))
        path.addCurve(
            to: point(corner, 0.66993427, 0.06549600),
            control1: point(corner, 1.08849323, 0), control2: point(corner, 0.86840689, 0))
        path.addLine(to: point(corner, 0.63149399, 0.07491100))
        path.addCurve(
            to: point(corner, 0.07491100, 0.63149399),
            control1: point(corner, 0.37282392, 0.16905899), control2: point(corner, 0.16905899, 0.37282392))
        path.addLine(to: point(corner, 0.06549600, 0.66993427))
        path.addCurve(
            to: point(corner, 0, 1.52866483),
            control1: point(corner, 0, 0.86840689), control2: point(corner, 0, 1.08849323))
    }
    path.closeSubpath()
    var transform = CGAffineTransform(scaleX: scale, y: scale)
    return path.copy(using: &transform)!
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Gita-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let canvas = CGContext(
            data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        canvas.interpolationQuality = .high
        let factor = CGFloat(pixels) / 1024
        canvas.addPath(iconShape(scale: factor))
        canvas.clip()
        canvas.draw(artwork, in: CGRect(x: 100, y: 100, width: 824, height: 824).applying(.init(scaleX: factor, y: factor)))
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try NSBitmapImageRep(cgImage: canvas.makeImage()!).representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(name))
    }
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output]
try process.run()
process.waitUntilExit()
try? fm.removeItem(at: iconset)
if process.terminationStatus != 0 { exit(process.terminationStatus) }
print("Wrote \(output) from \(source)")
