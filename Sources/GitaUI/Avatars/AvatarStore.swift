import AppKit
import CryptoKit
import GitaCore

/// GitHub author pictures for the history, the commit header and merged-commit lists. Initials draw until a picture
/// arrives, and stay when there is none. Email → URL comes from `ProviderService.githubAvatars` (one read-only `gh`
/// GraphQL query per repository, at most every six hours) and from GitHub noreply addresses. Images are public CDN
/// files, fetched without cookies or credentials and kept in `~/Library/Caches/<bundle>/Avatars`. Decoded pictures
/// stay in a bounded memory cache; the disk is only read and written off the main thread.
@MainActor
final class AvatarStore {
    static let shared = AvatarStore(directory: defaultDirectory, defaults: Preference.store)
    static let changed = Notification.Name("dev.clevermechanisms.Gita.avatarsChanged")

    private static let memoryLimit = 400
    nonisolated private static let maximumImageBytes = 512 * 1_024
    nonisolated private static let diskLifetime: TimeInterval = 7 * 86_400
    private static let lookupInterval: TimeInterval = 6 * 3_600
    private static let maximumIndexEntries = 5_000
    private static let announceDelay: TimeInterval = 0.15

    /// A picture not in memory: being read (from disk or the CDN), or failed this session (initials stay). A
    /// lookup while it is read asks for it again should that read fail.
    enum Fetch: Equatable {
        case loading(retry: Bool)
        case missing
    }
    /// The saved email index: still being read from disk, or merged in. Saving before the merge would overwrite
    /// the file with this session's lookups alone, so a save asked for meanwhile waits for it.
    enum Index: Equatable {
        case restoring(saveAfter: Bool)
        case restored
    }

    private var urls: [String: URL] = [:] // lowercased email → avatar URL
    private let images = NSCache<AvatarCacheKey, NSImage>()
    /// The pictures not in memory that are being read or failed, by URL.
    private(set) var fetches: [URL: Fetch] = [:]
    private(set) var index = Index.restoring(saveAfter: false)
    private var lookedUp: [String: Date] = [:] // repository root → last GraphQL lookup
    private var pendingChange = false
    private let directory: URL?
    private let defaults: UserDefaults
    private let download: @Sendable (URL) async -> Data?
    private let now: () -> Date
    private static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(
                Bundle.main.bundleIdentifier ?? AppEnvironment.defaultBundleIdentifier, isDirectory: true
            )
            .appendingPathComponent("Avatars", isDirectory: true)
    }

    /// `download` fetches one picture (the CDN by default); `now` dates the repository lookups.
    init(
        directory: URL?, defaults: UserDefaults, download: @escaping @Sendable (URL) async -> Data? = cdnDownload,
        now: @escaping () -> Date = Date.init
    ) {
        self.directory = directory
        self.defaults = defaults
        self.download = download
        self.now = now
        images.countLimit = Self.memoryLimit
        loadIndex()
    }

    var isEnabled: Bool { Preference.showsAvatars.bool(defaults) }

    /// The picture for `email`, or nil while it loads / when there is none (callers draw initials).
    func image(email: String) -> NSImage? {
        guard isEnabled, !email.isEmpty else { return nil }
        let key = email.lowercased()
        guard let url = urls[key] ?? GitHubAvatars.noreplyURL(email: key) else { return nil }
        if let image = images.object(forKey: AvatarCacheKey(url)) { return image }
        if fetches[url] == nil { load(url) }
        return nil
    }

    /// Learns the repository's committers once per six hours (on open and on provider refresh).
    func lookUp(root: URL, remote: GitHubRemote?, service: ProviderService) {
        guard isEnabled, let remote else { return }
        let key = root.standardizedFileURL.path
        let time = now()
        if let last = lookedUp[key], time.timeIntervalSince(last) < Self.lookupInterval { return }
        lookedUp[key] = time
        // Retry pictures that failed earlier, and those being read should they fail.
        fetches = fetches.compactMapValues { $0 == .missing ? nil : .loading(retry: true) }
        Task { [weak self] in
            let account = GitHubAccountStore().use(for: remote.sourceID)
            let found = await service.githubAvatars(root: root, remote: remote, as: account)
            self?.learn(found)
        }
    }

    /// Takes the emails a lookup found (called by tests too, to answer before the saved index is read back).
    func learn(_ found: [String: URL]) {
        var learned = false
        for (email, url) in found where urls[email] != url {
            urls[email] = url
            learned = true
        }
        guard learned else { return }
        saveIndex()
        announce()
    }

    func preferenceChanged() { announce() }

    /// The disk copy when it is fresh, else the CDN; a failure leaves the initials for this session.
    private func load(_ url: URL) {
        fetches[url] = .loading(retry: false)
        let file = file(url)
        let download = download
        Task { [weak self] in
            let cached = await Task.detached(priority: .utility) { file.flatMap(Self.readFresh) }.value
            if let image = cached.flatMap(Self.decode) {
                self?.finishLoading(url, image: image)
                return
            }
            let body = await download(url)
            let image = body.flatMap(Self.decode)
            if image != nil, let body, let file { Task.detached(priority: .utility) { Self.write(body, to: file) } }
            self?.finishLoading(url, image: image)
        }
    }

    private func finishLoading(_ url: URL, image: NSImage?) {
        let retry = fetches[url] == .loading(retry: true)
        guard let image else {
            fetches[url] = retry ? nil : .missing
            return
        }
        fetches[url] = nil
        images.setObject(image, forKey: AvatarCacheKey(url))
        announce()
    }

    /// Public CDN files only: no cookies, no credentials, a few connections at most.
    nonisolated private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    nonisolated static func cdnDownload(_ url: URL) async -> Data? {
        guard let (body, response) = try? await session.data(from: url),
            (response as? HTTPURLResponse)?.statusCode == 200, body.count <= maximumImageBytes
        else { return nil }
        return body
    }

    private static func decode(_ data: Data) -> NSImage? {
        guard let image = NSImage(data: data), image.isValid else { return nil }
        return image
    }

    /// Coalesces bursts of arrivals into one repaint.
    private func announce() {
        guard !pendingChange else { return }
        pendingChange = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.announceDelay) { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingChange = false
                NotificationCenter.default.post(name: Self.changed, object: self)
            }
        }
    }

    // MARK: Disk cache

    private func file(_ url: URL) -> URL? {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent(digest + ".img")
    }
    private nonisolated static func readFresh(_ file: URL) -> Data? {
        guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
            let modified = values.contentModificationDate, Date().timeIntervalSince(modified) < diskLifetime
        else { return nil }
        return try? Data(contentsOf: file)
    }
    private nonisolated static func write(_ data: Data, to file: URL) {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
    private var indexFile: URL? { directory?.appendingPathComponent("index.json") }
    private func loadIndex() {
        guard let indexFile else {
            index = .restored
            return
        }
        Task { [weak self] in
            let stored = await Task.detached(priority: .utility) { () -> [String: String] in
                guard let data = try? Data(contentsOf: indexFile) else { return [:] }
                return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
            }.value
            self?.restore(stored)
        }
    }
    private func restore(_ stored: [String: String]) {
        var restored: [String: URL] = [:]
        for (email, string) in stored.prefix(Self.maximumIndexEntries) {
            if let url = GitHubAvatars.validated(string) { restored[email] = url }
        }
        let saveAfter = index == .restoring(saveAfter: true)
        index = .restored
        // Lookups that finished meanwhile are newer than the saved index.
        urls.merge(restored) { current, _ in current }
        if saveAfter { saveIndex() }
        if !restored.isEmpty { announce() }
    }
    private func saveIndex() {
        guard index == .restored else {
            index = .restoring(saveAfter: true)
            return
        }
        guard let indexFile, let data = try? JSONEncoder().encode(urls.mapValues(\.absoluteString)) else { return }
        Task.detached(priority: .utility) { Self.write(data, to: indexFile) }
    }
}

/// An avatar URL as an `NSCache` key (the cache needs an object key; this keeps the URL a Swift value).
private final class AvatarCacheKey: NSObject {
    let url: URL
    init(_ url: URL) { self.url = url }
    override var hash: Int { url.hashValue }
    override func isEqual(_ object: Any?) -> Bool { (object as? AvatarCacheKey)?.url == url }
}
