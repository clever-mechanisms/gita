import AppKit

/// One Gita per session: a second launch hands its repositories to the earlier one and quits.
@MainActor
enum SingleInstance {
    nonisolated static let showWindow = Notification.Name("dev.clevermechanisms.Gita.showWindow")
    nonisolated static let pathsKey = "repositoryPaths"

    struct Instance: Equatable {
        var processIdentifier: Int32
        var launchDate: Date?
    }

    /// The instance `current` hands over to: the earliest other launch, and only when it started before `current`
    /// (the process ID breaks a tie), so two simultaneous launches never both quit.
    static func handOverTarget(_ current: Instance, others: [Instance]) -> Instance? {
        func order(_ instance: Instance) -> (Date, Int32) {
            (instance.launchDate ?? .distantPast, instance.processIdentifier)
        }
        guard let earliest = others.min(by: { order($0) < order($1) }), order(earliest) < order(current) else {
            return nil
        }
        return earliest
    }

    /// The earlier running copy of this app, if this launch should hand over to it.
    static func earlierInstance(bundleIdentifier: String) -> NSRunningApplication? {
        let current = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).filter {
            $0 != current && !$0.isTerminated
        }
        guard
            let target = handOverTarget(
                Instance(processIdentifier: current.processIdentifier, launchDate: current.launchDate),
                others: others.map { Instance(processIdentifier: $0.processIdentifier, launchDate: $0.launchDate) })
        else { return nil }
        return others.first { $0.processIdentifier == target.processIdentifier }
    }

    /// Asks `other` to show its window, or to open `paths`; a background launch with nothing to open stays quiet.
    static func handOver(paths: [String], to other: NSRunningApplication, background: Bool) {
        guard !background || !paths.isEmpty else { return }
        DistributedNotificationCenter.default().postNotificationName(
            showWindow, object: nil, userInfo: [pathsKey: paths], deliverImmediately: true)
        other.activate()
    }

    /// Repository requests from a later launch. Any process can post this notification, so only absolute paths of
    /// existing folders are taken.
    static func observe(_ handler: @escaping @MainActor ([URL]) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: showWindow, object: nil, queue: .main) {
            notification in
            let paths = notification.userInfo?[pathsKey]
            let folders = repositoryFolders(paths)
            MainActor.assumeIsolated { handler(folders) }
        }
    }

    nonisolated static func repositoryFolders(_ value: Any?) -> [URL] {
        guard let paths = value as? [String] else { return [] }
        return paths.prefix(32).compactMap { path in
            var isDirectory: ObjCBool = false
            guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
    }
}
