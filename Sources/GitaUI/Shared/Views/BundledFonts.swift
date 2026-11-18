import AppKit
import CoreText

/// Faces shipped in `Resources/Fonts/<folder>` with their licences, registered for this process only, once per folder.
/// False when the files are missing (a copy built without resources): callers fall back to the system face instead of
/// whatever Core Text would substitute.
@MainActor
enum BundledFonts {
    /// Where the font folders live: the app bundle's `Fonts` resources. Tests point it at the repository's copy.
    static var directory: URL? = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true)
    private static var registered: Set<String> = []
    private static let fileExtensions: Set<String> = ["ttf", "otf"]
    /// CSS weights for the `wght` axis, by AppKit weight.
    private static let cssWeights: [(NSFont.Weight, Double)] = [
        (.ultraLight, 100), (.thin, 200), (.light, 300), (.regular, 400), (.medium, 500),
        (.semibold, 600), (.bold, 700), (.heavy, 800), (.black, 900),
    ]
    private static let regularCSSWeight: Double = 400
    private static let normalWidth: Double = 100
    private static let weightAxis = 0x7767_6874 // 'wght'
    private static let widthAxis = 0x7764_7468 // 'wdth'

    /// `family` at `weight`, or nil when the family is not available. A variable face gets its axes set explicitly:
    /// `wght` on the CSS scale (400 regular, 600 semibold…) and `wdth` at 100 (normal). Otherwise Core Text can keep
    /// the file's default instance, which for some families is not the regular weight (Lexend, Outfit) or width
    /// (Martian Mono).
    static func font(family: String, size: CGFloat, weight: NSFont.Weight) -> NSFont? {
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: family, .traits: [NSFontDescriptor.TraitKey.weight: weight],
        ])
        guard let font = NSFont(descriptor: descriptor, size: size), font.familyName == family else { return nil }
        guard let axes = CTFontCopyVariationAxes(font as CTFont) as? [[CFString: Any]], !axes.isEmpty else {
            return font
        }
        let variation = variation(axes: axes, wanted: [weightAxis: cssWeight(weight), widthAxis: normalWidth])
        guard !variation.isEmpty else { return font }
        let attribute = NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        return NSFont(descriptor: font.fontDescriptor.addingAttributes([attribute: variation]), size: size) ?? font
    }

    /// The CSS weight closest to `weight`.
    static func cssWeight(_ weight: NSFont.Weight) -> Double {
        cssWeights.min { abs($0.0.rawValue - weight.rawValue) < abs($1.0.rawValue - weight.rawValue) }?.1
            ?? regularCSSWeight
    }

    /// The wanted value of each axis the face has, clamped to the axis's range.
    static func variation(axes: [[CFString: Any]], wanted: [Int: Double]) -> [Int: Double] {
        var variation: [Int: Double] = [:]
        for axis in axes {
            guard let tag = axis[kCTFontVariationAxisIdentifierKey] as? Int, let value = wanted[tag],
                let low = axis[kCTFontVariationAxisMinimumValueKey] as? Double,
                let high = axis[kCTFontVariationAxisMaximumValueKey] as? Double
            else { continue }
            variation[tag] = min(high, max(low, value))
        }
        return variation
    }

    static func register(_ folder: String) -> Bool {
        if registered.contains(folder) { return true }
        let files = fontFiles(in: folder)
        guard !files.isEmpty, files.allSatisfy(registerFile) else { return false }
        registered.insert(folder)
        return true
    }

    private static func fontFiles(in folder: String) -> [URL] {
        guard let folderURL = directory?.appendingPathComponent(folder, isDirectory: true),
            let files = try? FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { fileExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// Registers one file for this process; a file another call already registered counts as done.
    private static func registerFile(_ file: URL) -> Bool {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error) { return true }
        let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
        return code == CTFontManagerError.alreadyRegistered.rawValue
    }
}
