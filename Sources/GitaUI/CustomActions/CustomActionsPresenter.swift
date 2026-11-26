import Foundation
import GitaCore

struct CustomActionsPresenter: Sendable {
    func sampleContext(for scope: CustomActionScope) -> CustomActionContext {
        let root = URL(filePath: "/Projects/Example")
        let remote = "https://github.com/example/project.git"
        switch scope {
        case .repository:
            return CustomActionContext(repositoryRoot: root, remoteURL: remote)
        case .commit:
            return CustomActionContext(repositoryRoot: root, commitSHA: "a1b2c3d4", remoteURL: remote)
        case .branch:
            return CustomActionContext(repositoryRoot: root, branch: "feature/review", remoteURL: remote)
        case .file:
            return CustomActionContext(repositoryRoot: root, filePath: "Sources/Example.swift", remoteURL: remote)
        case .worktree:
            return CustomActionContext(
                repositoryRoot: root, worktreePath: URL(filePath: "/Projects/Example-review"), remoteURL: remote)
        }
    }

    func summary(_ action: CustomAction) -> String { action.executable }
    func scopeBadge(_ action: CustomAction) -> String { action.scope.localizedTitle }
    func placeholders(for scope: CustomActionScope) -> [String] { scope.supportedPlaceholders }

    func isValid(_ action: CustomAction) -> Bool {
        (try? CustomActionStore.validate(action)) != nil
    }

    func description(for placeholder: String) -> String {
        switch placeholder {
        case "$SHA": String(localized: "Selected commit ID")
        case "$BRANCH": String(localized: "Selected branch name")
        case "$FILE": String(localized: "Selected file path")
        case "$WORKTREE": String(localized: "Selected worktree directory")
        case "$REPO_ROOT": String(localized: "Repository root directory")
        case "$REMOTE_URL": String(localized: "Repository remote URL")
        default: placeholder
        }
    }

    func preview(_ action: CustomAction) throws -> String {
        let command = try CustomActionRunner().resolve(action, context: sampleContext(for: action.scope))
        let argv = command.displayArguments.enumerated().map { "[\($0)] \($1.debugDescription)" }
        return ([String(localized: "Directory: \(command.directory.path)")] + argv).joined(separator: "\n")
    }

    func importSummary(_ actions: [CustomAction]) -> String {
        let lines = actions.map { action in
            let argv = ([action.executable] + action.arguments).map(\.debugDescription).joined(separator: " ")
            return "• \(action.name) (\(action.scope.localizedTitle)): \(argv)"
        }
        let header = String(localized: "Imported actions always ask for confirmation before running.")
        return ([header, ""] + lines).joined(separator: "\n")
    }

    func export(_ actions: [CustomAction], store: CustomActionStore) throws -> Data { try store.exportJSON(actions) }
    func previewImport(_ data: Data, store: CustomActionStore) throws -> [CustomAction] {
        try store.previewImport(data)
    }
    func commitImport(_ data: Data, store: CustomActionStore) throws -> [CustomAction] { try store.importJSON(data) }
}
