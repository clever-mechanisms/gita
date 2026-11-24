import AppKit

/// Private pasteboard payload (`app.gita.reference`) for §6d drag-and-drop across files, branches, and commits.
enum GitaDragReference: Codable, Equatable, Sendable {
    static let pasteboardType = NSPasteboard.PasteboardType("app.gita.reference")

    case files(paths: [String], staged: Bool)
    case branch(fullName: String, name: String, isRemote: Bool)
    case commits(ids: [String])

    private struct Payload: Codable {
        let repositoryRoot: String
        let reference: GitaDragReference
    }

    func pasteboardItem(repositoryRoot: String, fileURL: URL? = nil) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if let data = try? JSONEncoder().encode(Payload(repositoryRoot: repositoryRoot, reference: self)) {
            item.setData(data, forType: Self.pasteboardType)
        }
        if let fileURL {
            item.setString(fileURL.absoluteString, forType: .fileURL)
        }
        return item
    }

    static func readAll(from items: [NSPasteboardItem], repositoryRoot: String?) -> [Self] {
        guard let repositoryRoot else { return [] }
        var references: [Self] = []
        for item in items {
            guard let data = item.data(forType: pasteboardType),
                let payload = try? JSONDecoder().decode(Payload.self, from: data),
                payload.repositoryRoot == repositoryRoot
            else { return [] }
            references.append(payload.reference)
        }
        return references
    }

    static func mergedFiles(from items: [NSPasteboardItem], repositoryRoot: String?) -> (paths: [String], staged: Bool)?
    {
        let sides = readAll(from: items, repositoryRoot: repositoryRoot).compactMap {
            entry -> (paths: [String], staged: Bool)? in
            guard case .files(let paths, let staged) = entry else { return nil }
            return (paths, staged)
        }
        guard let first = sides.first, sides.allSatisfy({ $0.staged == first.staged }) else { return nil }
        let allPaths = sides.flatMap(\.paths)
        guard !allPaths.isEmpty else { return nil }
        var seen = Set<String>()
        return (allPaths.filter { seen.insert($0).inserted }, first.staged)
    }

    static func firstBranch(
        from items: [NSPasteboardItem], repositoryRoot: String?
    ) -> (fullName: String, name: String, isRemote: Bool)? {
        for entry in readAll(from: items, repositoryRoot: repositoryRoot) {
            if case .branch(let fullName, let name, let isRemote) = entry {
                return (fullName, name, isRemote)
            }
        }
        return nil
    }

    static func commitIDs(from items: [NSPasteboardItem], repositoryRoot: String?) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        for entry in readAll(from: items, repositoryRoot: repositoryRoot) {
            if case .commits(let list) = entry {
                for id in list where seen.insert(id).inserted { ids.append(id) }
            }
        }
        return ids
    }
}
