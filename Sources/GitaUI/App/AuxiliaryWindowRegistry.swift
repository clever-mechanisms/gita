import AppKit
import GitaCore

/// Tracks open per-repository utility windows, releases entries when closed, and rebuilds when
/// a repository's `GitService` instance changes (e.g. after closing and reopening a tab).
@MainActor
final class AuxiliaryWindowRegistry {
    enum Kind: Hashable {
        case submodulesLFS
        case cleanup
        case stackedBranches(String)
        case reflog
        case codeSearch
        case lineHistory
    }

    struct Key: Hashable {
        let rootPath: String
        let kind: Kind

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.rootPath == rhs.rootPath && lhs.kind == rhs.kind
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(rootPath)
            hasher.combine(kind)
        }
    }

    private struct Entry {
        let controller: NSWindowController
        weak var service: GitService?
        var closeObserver: NSObjectProtocol?
    }

    private var entries: [Key: Entry] = [:]

    isolated deinit {
        for entry in entries.values {
            if let observer = entry.closeObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    func controller<Controller: NSWindowController>(
        for root: URL, kind: Kind, service: GitService, make: () -> Controller
    ) -> Controller {
        let key = Key(rootPath: root.standardizedFileURL.path, kind: kind)
        if let existing = entries[key], existing.service === service, let typed = existing.controller as? Controller {
            return typed
        }
        removeEntry(for: key, closingWindow: true)
        let created = make()
        entries[key] = Entry(controller: created, service: service, closeObserver: nil)
        return created
    }

    func observeClose(for root: URL, kind: Kind) {
        let key = Key(rootPath: root.standardizedFileURL.path, kind: kind)
        guard var entry = entries[key], entry.closeObserver == nil, let window = entry.controller.window else {
            return
        }
        entry.closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.removeEntry(for: key, closingWindow: false)
            }
        }
        entries[key] = entry
    }

    private func removeEntry(for key: Key, closingWindow: Bool) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        if let observer = removed.closeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if closingWindow {
            removed.controller.close()
        }
    }
}
