import Foundation
import GitaCore

/// Branch names with slashes sit in folders, as in Fork (build/a and build/b under "build"): a level's branches
/// first, in the list's order (pinned first), then its folders by name. A folder is open while filtering, as last
/// left, or, never touched, when it holds the current or selected branch.
@MainActor
struct SidebarFolders {
    typealias Row = RepositorySidebarView.Row
    private typealias Item = (ref: GitReference, parts: ArraySlice<String>)

    var selection: SidebarSelection
    var query: String
    /// `SidebarGroupID.persistedKey` → expanded.
    var expansion: [String: Bool]

    func rows(
        _ refs: [GitReference], group: SidebarGroupID, nested: Bool, name: (GitReference) -> String,
        row: @escaping (GitReference, Int, String?) -> Row
    ) -> [Row] {
        var rows: [Row] = []
        let items = refs.map {
            ($0, ArraySlice(name($0).split(separator: "/", omittingEmptySubsequences: false).map(String.init)))
        }
        walk(items, prefix: "", depth: 0, in: Place(group: group, nested: nested, row: row), into: &rows)
        return rows
    }

    /// The group the folders belong to and how its references become rows.
    private struct Place {
        var group: SidebarGroupID
        var nested: Bool
        var row: (GitReference, Int, String?) -> Row
    }

    private func walk(_ items: [Item], prefix: String, depth: Int, in place: Place, into rows: inout [Row]) {
        var folders: [String: [Item]] = [:]
        for item in items {
            if item.parts.count > 1, let head = item.parts.first {
                folders[head, default: []].append((item.ref, item.parts.dropFirst()))
            } else {
                rows.append(place.row(item.ref, depth, depth == 0 ? nil : item.parts.last))
            }
        }
        for (folder, children) in folders.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
            let path = prefix.isEmpty ? folder : prefix + "/" + folder
            let id = SidebarGroupID.folder(in: place.group, path: path)
            let holdsCurrent = children.contains {
                $0.ref.isCurrent || selection == .reference(fullName: $0.ref.fullName)
            }
            let open = !query.isEmpty || (expansion[id.persistedKey] ?? holdsCurrent)
            rows.append(
                .folder(
                    .init(
                        id: id, name: folder, depth: depth, nested: place.nested, count: children.count,
                        expanded: open)))
            if open { walk(children, prefix: path, depth: depth + 1, in: place, into: &rows) }
        }
    }
}
