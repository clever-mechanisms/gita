import AppKit
import GitaCore

@MainActor
public final class ControlPlaneFacade {
    public static let shared = ControlPlaneFacade()
    private var sheets: [ObjectIdentifier: ControlPlaneSheet] = [:]
    private var commandCenter: WorkspaceCommandCenterWindowController?

    public init() {}

    // Keep the run, job and step invocation available directly to the workflow details view.
    // swiftlint:disable:next function_parameter_count
    @discardableResult public func presentCIFixSheet(
        from run: WorkflowRunDetail, job: WorkflowJob? = nil,
        step: WorkflowStep? = nil, root: URL, repository: String, account: GitHubAccountUse,
        on window: NSWindow?
    ) -> NSWindowController? {
        guard
            let target = CIFixTarget(
                run: run, job: job, step: step, root: root, repository: repository,
                account: account)
        else { return nil }
        let sheet = CIFixSheetController(presenter: CIFixPresenter(target: target, git: GitService(root: root)))
        present(sheet, on: window)
        return sheet
    }

    private func present(_ sheet: ControlPlaneSheet, on parent: NSWindow?) {
        let key = ObjectIdentifier(sheet)
        sheets[key] = sheet
        sheet.onDismiss = { [weak self] in self?.sheets[key] = nil }
        sheet.present(on: parent)
    }

    @discardableResult public func showWorkspaceCommandCenter(
        workspaceTitle: String, repositories: [WorkspaceRepository],
        providerReports: [URL: [ProviderReport]], onOpenRepository: @escaping @MainActor (URL) -> Void
    ) -> NSWindowController {
        let controller: WorkspaceCommandCenterWindowController
        if let commandCenter {
            controller = commandCenter
            controller.window?.subtitle = workspaceTitle
            controller.presenter.update(repositories: repositories, reports: providerReports, open: onOpenRepository)
        } else {
            let presenter = WorkspaceCommandCenterPresenter(
                repositories: repositories, reports: providerReports, open: onOpenRepository)
            controller = WorkspaceCommandCenterWindowController(title: workspaceTitle, presenter: presenter)
            commandCenter = controller
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    static func repositories(
        for workspace: Workspace, session: RepositoryTabSession? = nil,
        defaults: UserDefaults = Preference.store
    ) -> [WorkspaceRepository] {
        let tabs =
            session ?? RepositoryTabSession.restore(from: defaults, key: workspace.sessionKey) ?? RepositoryTabSession()
        let groups = tabs.tabGroups
        return tabs.repositories.enumerated().map { index, root in
            let group = groups.first { $0.members.contains(root) }?.group
            return WorkspaceRepository(
                root: root, colorIndex: index,
                tabColorRawValue: (tabs.color(for: root) ?? group?.color)?.rawValue, groupName: group?.name)
        }
    }
}
