import Foundation
import GitaCore

/// What the panel can ask the app to do. Every row's obvious action is one of these, one click away.
struct MenuPanelActions {
    var openApp: @MainActor () -> Void = {}
    var refresh: @MainActor () -> Void = {}
    var settings: @MainActor () -> Void = {}
    var quit: @MainActor () -> Void = {}
    var openRepository: @MainActor () -> Void = {}
    var showRepository: @MainActor (URL) -> Bool = { _ in false }
    var showProviderPage: @MainActor (URL, ProviderKind) -> Void = { _, _ in }
    /// A repository's tab, in the window of the workspace with this id.
    var showTab: @MainActor (URL, String) -> Void = { _, _ in }
    var push: @MainActor (URL) -> Void = { _ in }
    var reveal: @MainActor (AgentSession) -> Void = { _ in }
    /// A workspace, by id.
    var openWorkspace: @MainActor (String) -> Void = { _ in }
    var newWorkspace: @MainActor () -> Void = {}
}
