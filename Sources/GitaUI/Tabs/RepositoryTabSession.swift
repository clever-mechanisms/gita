import Foundation

/// The open repository tabs as saved between launches: their paths in order, the selected one, and their colours and
/// groups. Older sessions have no colours or groups; empty ones are not written. Each workspace saves its own, under
/// its `Workspace.sessionKey`.
struct RepositoryTabSession: Codable, Equatable {
    /// Where the first workspace's tabs are saved (the only session before workspaces existed).
    static let defaultsKey = "repositoryTabSession"
    /// A tab group as saved: its members by repository path.
    struct SavedGroup: Codable, Equatable {
        var id: String
        var name: String
        var color: String
        var collapsed: Bool
        var paths: [String]
    }
    private enum CodingKeys: String, CodingKey {
        case paths, selectedPath, colors, groups
    }
    private var paths: [String]
    private var selectedPath: String?
    private var colors: [String: String]
    private var groups: [SavedGroup]

    var repositories: [URL] { paths.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    var selectedRepository: URL? {
        repositories.first { ReviewText.same($0.path, selectedPath ?? "") } ?? repositories.first
    }
    init(
        repositories: [URL] = [], selected: URL? = nil, colors: [(URL, TabColor)] = [], groups: [(TabGroup, [URL])] = []
    ) {
        var seen = Set<Data>()
        paths = repositories.map { Self.canonical($0).path }.filter { seen.insert(Data($0.utf8)).inserted }
        selectedPath = selected.map { Self.canonical($0).path }
        let open = Set(paths)
        let colorPairs = colors.map { (Self.canonical($0.0).path, $0.1.rawValue) }.filter { open.contains($0.0) }
        self.colors = Dictionary(colorPairs) { first, _ in first }
        self.groups = groups.compactMap { group, members -> SavedGroup? in
            let memberPaths = members.map { Self.canonical($0).path }.filter { open.contains($0) }
            guard !memberPaths.isEmpty else { return nil }
            return SavedGroup(
                id: group.id.uuidString, name: group.name, color: group.color.rawValue, collapsed: group.collapsed,
                paths: memberPaths)
        }
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paths = try container.decode([String].self, forKey: .paths)
        selectedPath = try container.decodeIfPresent(String.self, forKey: .selectedPath)
        colors = try container.decodeIfPresent([String: String].self, forKey: .colors) ?? [:]
        groups = try container.decodeIfPresent([SavedGroup].self, forKey: .groups) ?? []
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(paths, forKey: .paths)
        try container.encodeIfPresent(selectedPath, forKey: .selectedPath)
        if !colors.isEmpty { try container.encode(colors, forKey: .colors) }
        if !groups.isEmpty { try container.encode(groups, forKey: .groups) }
    }
    func color(for url: URL) -> TabColor? {
        colors[Self.canonical(url).path].flatMap(TabColor.init(rawValue:))
    }
    /// The saved groups with their members' repositories.
    var tabGroups: [(group: TabGroup, members: [URL])] {
        groups.map { saved in
            (
                TabGroup(
                    id: UUID(uuidString: saved.id) ?? UUID(), name: saved.name,
                    color: TabColor(rawValue: saved.color) ?? .grey, collapsed: saved.collapsed),
                saved.paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
            )
        }
    }
    mutating func focus(_ url: URL) {
        let path = Self.canonical(url).path
        if !paths.contains(where: { ReviewText.same($0, path) }) { paths.append(path) }
        selectedPath = path
    }
    /// The saved session, without repositories that are gone or unreadable (and their colours and groups).
    static func restore(
        from defaults: UserDefaults, key: String = Self.defaultsKey,
        isRepository: (URL) -> Bool = Self.isReadableRepository
    ) -> Self? {
        guard let data = defaults.data(forKey: key),
            let saved = try? JSONDecoder().decode(Self.self, from: data)
        else { return nil }
        let readable = saved.paths.compactMap { path -> URL? in
            guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
            let url = canonical(URL(fileURLWithPath: path, isDirectory: true))
            return isRepository(url) ? url : nil
        }
        // The initialiser keeps the colours and groups of open paths only.
        return Self(
            repositories: readable, selected: saved.selectedRepository,
            colors: readable.compactMap { url in saved.color(for: url).map { (url, $0) } }, groups: saved.tabGroups)
    }
    static func isReadableRepository(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let files = FileManager.default
        return files.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
            && files.isReadableFile(atPath: url.path)
            && files.isReadableFile(atPath: url.appendingPathComponent(".git").path)
    }
    func save(to defaults: UserDefaults, key: String = Self.defaultsKey) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self), data != defaults.data(forKey: key) else { return }
        defaults.set(data, forKey: key)
    }
    static func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
}
