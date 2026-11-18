import CryptoKit
import Darwin
import Foundation

/// One draft per worktree, shared across duplicate repository opens.
@MainActor
final class CommitMessageDraft {
    enum Change {
        case text
        case saveFailed(Error)
    }
    private static let maximumBytes = 1_048_576
    private static let readChunk = 65_536
    private struct WeakDraft { weak var value: CommitMessageDraft? }
    private static var drafts: [String: WeakDraft] = [:]

    let identity: String
    private let file: URL
    private(set) var text: String
    private(set) var revision = UUID()
    /// How long typing pauses before the draft is written.
    var saveDelay: Duration = .milliseconds(400)
    private var savedText: String
    private var saveTask: Task<Void, Never>?
    private var lastSaveError: String?
    private var observers: [UUID: (Change) -> Void] = [:]

    static func identity(root: URL, gitDirectory: URL) -> String {
        let root = root.standardizedFileURL.resolvingSymlinksInPath().path
        let gitDirectory = gitDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let data = Data(root.utf8) + Data([0]) + Data(gitDirectory.utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The folder that keeps the drafts: `CommitDrafts` in the app's Application Support folder.
    static func defaultDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        #if DEBUG
            let domain = "dev.clevermechanisms.Gita.development"
        #else
            let domain = "dev.clevermechanisms.Gita"
        #endif
        return support.appendingPathComponent(domain, isDirectory: true)
            .appendingPathComponent("CommitDrafts", isDirectory: true)
    }

    /// Where `open(root:gitDirectory:)` keeps drafts: `defaultDirectory()` in the app, a temporary folder in tests.
    static var storeDirectory: () throws -> URL = { try defaultDirectory() }

    static func open(root: URL, gitDirectory: URL) throws -> CommitMessageDraft {
        try open(root: root, gitDirectory: gitDirectory, in: storeDirectory())
    }

    /// The draft of this worktree, kept in `directory` as `<identity>.txt`.
    static func open(root: URL, gitDirectory: URL, in directory: URL) throws -> CommitMessageDraft {
        let identity = identity(root: root, gitDirectory: gitDirectory)
        if let existing = drafts[identity]?.value { return existing }
        drafts = drafts.filter { $0.value.value != nil }
        let draft = try CommitMessageDraft(
            identity: identity, file: directory.appendingPathComponent(identity + ".txt"))
        drafts[identity] = WeakDraft(value: draft)
        return draft
    }

    private init(identity: String, file: URL) throws {
        self.identity = identity
        self.file = file
        let value = try Self.read(file) ?? ""
        text = value
        savedText = value
    }

    /// The saved draft, or nil when there is none. Refuses links, non-regular files, oversized files and non-UTF-8.
    private static func read(_ file: URL) throws -> String? {
        let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            guard errno == ENOENT else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            return nil
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadUnsupportedScheme) }
        guard info.st_size <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(readChunk, maximumBytes + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return value
    }

    func observe(_ action: @escaping (Change) -> Void) -> UUID {
        let id = UUID()
        observers[id] = action
        return id
    }
    func removeObserver(_ id: UUID) { observers[id] = nil }

    func setText(_ value: String) {
        guard !text.utf8.elementsEqual(value.utf8) else { return }
        text = value
        revision = UUID()
        notify(.text)
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.saveTask = nil
            self.save()
        }
    }

    /// Writes the draft now; a failure is reported to observers once until a save succeeds again.
    private func save() {
        do { try flush() } catch {
            let errorIdentity = String(describing: error)
            guard lastSaveError != errorIdentity else { return }
            lastSaveError = errorIdentity
            notify(.saveFailed(error))
        }
    }

    private func notify(_ change: Change) {
        for observer in Array(observers.values) { observer(change) }
    }

    func flush() throws {
        saveTask?.cancel()
        saveTask = nil
        guard !text.utf8.elementsEqual(savedText.utf8) else { return }
        let files = FileManager.default
        if text.isEmpty {
            do { try files.removeItem(at: file) } catch CocoaError.fileNoSuchFile {}
        } else {
            let data = Data(text.utf8)
            guard data.count <= Self.maximumBytes else { throw DraftError.tooLong }
            let directory = file.deletingLastPathComponent()
            try files.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try data.write(to: file, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        savedText = text
        lastSaveError = nil
    }

    private enum DraftError: LocalizedError {
        case tooLong
        var errorDescription: String? { String(localized: "The commit message is too long to save.") }
    }
}
