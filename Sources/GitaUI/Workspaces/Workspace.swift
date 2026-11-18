import Foundation

/// A named set of repositories: its own tabs (`RepositoryTabSession`) and its own recently opened list. The app
/// starts with one; the user adds, names and deletes others, and opens one in the window or in a window of its own
/// (Settings ▸ General ▸ Workspaces).
struct Workspace: Codable, Equatable, Identifiable {
    /// The workspace every installation starts with. It keeps the settings keys used before workspaces existed, so
    /// the tabs and recent repositories of an earlier version are its own.
    static let firstID = "default"

    let id: String
    /// nil for the first workspace until it is given a name.
    var name: String?

    var title: String { name ?? String(localized: "Default") }
    /// Where its tabs are saved.
    var sessionKey: String { Self.key(RepositoryTabSession.defaultsKey, id) }
    /// Where its recently opened repositories are saved.
    var recentKey: String { Self.key(Preference.recentRepositories.rawValue, id) }

    private static func key(_ base: String, _ id: String) -> String { id == firstID ? base : "\(base).\(id)" }

    /// Its recently opened repositories, newest first.
    func recent(in defaults: UserDefaults) -> [String] { defaults.stringArray(forKey: recentKey) ?? [] }

    /// Forgets its tabs and its recent repositories (the repositories themselves are untouched).
    func forget(in defaults: UserDefaults) {
        defaults.removeObject(forKey: sessionKey)
        defaults.removeObject(forKey: recentKey)
    }
}

/// The workspaces in the order they were made, and the one last in front. There is always at least one.
struct WorkspaceList: Codable, Equatable {
    static let defaultsKey = "workspaces"
    static let nameLimit = 40

    private(set) var workspaces: [Workspace]
    private(set) var activeID: String

    init() {
        workspaces = [Workspace(id: Workspace.firstID, name: nil)]
        activeID = Workspace.firstID
    }

    var active: Workspace { self[activeID] ?? workspaces[0] }
    var canRemove: Bool { workspaces.count > 1 }
    subscript(id: String) -> Workspace? { workspaces.first { $0.id == id } }

    /// A name as typed: trimmed and cut to `nameLimit`; nil when nothing is left.
    static func cleaned(_ input: String) -> String? {
        let typed = input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(nameLimit)
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The name offered for a new workspace: "Workspace 2", or the first number no workspace is called yet.
    var suggestedName: String {
        let taken = Set(workspaces.map(\.title))
        var number = workspaces.count + 1
        while taken.contains(Self.numbered(number)) { number += 1 }
        return Self.numbered(number)
    }
    private static func numbered(_ number: Int) -> String { String(localized: "Workspace \(number)") }

    /// A new workspace after the others; nil when `name` is empty.
    mutating func add(named name: String) -> Workspace? {
        guard let name = Self.cleaned(name) else { return nil }
        let workspace = Workspace(id: UUID().uuidString, name: name)
        workspaces.append(workspace)
        return workspace
    }

    /// The renamed workspace; nil when it is unknown or `name` is empty.
    mutating func rename(_ id: String, to name: String) -> Workspace? {
        guard let index = workspaces.firstIndex(where: { $0.id == id }), let name = Self.cleaned(name) else {
            return nil
        }
        workspaces[index].name = name
        return workspaces[index]
    }

    /// The workspace to show once `id` is gone: the one before it, else the one after. nil for the only workspace.
    func neighbor(of id: String) -> Workspace? {
        guard canRemove, let index = workspaces.firstIndex(where: { $0.id == id }) else { return nil }
        return workspaces[index > 0 ? index - 1 : 1]
    }

    /// Removes a workspace, never the last one; the active one moves to its neighbour.
    @discardableResult mutating func remove(_ id: String) -> Bool {
        guard let next = neighbor(of: id) else { return false }
        workspaces.removeAll { $0.id == id }
        if activeID == id { activeID = next.id }
        return true
    }

    mutating func activate(_ id: String) {
        if self[id] != nil { activeID = id }
    }

    /// The saved list; a first launch, or a list that cannot be read, starts with the first workspace alone.
    static func restore(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
            var saved = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        var seen = Set<String>()
        saved.workspaces = saved.workspaces.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
        guard let first = saved.workspaces.first else { return Self() }
        if saved[saved.activeID] == nil { saved.activeID = first.id }
        return saved
    }

    func save(to defaults: UserDefaults) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(self), data != defaults.data(forKey: Self.defaultsKey) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
