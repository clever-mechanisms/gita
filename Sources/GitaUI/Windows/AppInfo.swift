import Darwin
import Foundation

/// This copy's facts, read from the running bundle.
enum AppInfo {
    private static var info: [String: Any] { Bundle.main.infoDictionary ?? [:] }
    static var version: String { info["CFBundleShortVersionString"] as? String ?? "dev" }
    static var build: String { info["CFBundleVersion"] as? String ?? "dev" }
    static var revision: String? { (info["GitaSourceRevision"] as? String).map { String($0.prefix(7)) } }
    static var system: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : "")
    }
    static var architecture: String {
        #if arch(arm64)
            "Apple silicon"
        #else
            "Intel"
        #endif
    }
    /// The folder this copy runs from, for support. A quarantined download that was copied rather than moved runs
    /// from a temporary copy macOS makes (App Translocation).
    static var location: String { location(of: Bundle.main.bundleURL, home: realHome) }
    /// One line for a bug report: app, version, build, macOS, architecture, location.
    static var summary: String {
        "Gitā \(version) (\(build)\(revision.map { ", \($0)" } ?? "")) · \(system) · \(architecture) · \(location)"
    }

    static func location(of bundle: URL, home: String) -> String {
        let path = bundle.standardizedFileURL.path
        if path.contains("/AppTranslocation/") { return String(localized: "Temporary copy (App Translocation)") }
        let folder = bundle.standardizedFileURL.deletingLastPathComponent().path
        if !home.isEmpty, folder == home || folder.hasPrefix(home + "/") { return "~" + folder.dropFirst(home.count) }
        return folder
    }

    static func thirdPartyNoticesURL(in bundle: Bundle = .main) -> URL? {
        guard
            let url = bundle.url(
                forResource: "ThirdParty-Notices", withExtension: "txt", subdirectory: "ThirdParty"),
            FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    /// The user's real home folder; `NSHomeDirectory()` may return a sandbox container.
    private static var realHome: String {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return "" }
        return String(cString: dir)
    }
}
