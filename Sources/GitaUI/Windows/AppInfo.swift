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
    /// One line for a bug report: app, version, build, macOS, architecture.
    static var summary: String {
        "Gitā \(version) (\(build)\(revision.map { ", \($0)" } ?? "")) · \(system) · \(architecture)"
    }
}
