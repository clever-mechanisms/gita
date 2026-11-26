import AppKit
import GitaCore

@MainActor
final class ControlPlaneFacade {
    static let shared = ControlPlaneFacade()
    private let service = PrePushFlightCheckService()
    private let settings: FlightCheckSettingsStore
    private let presenters = NSHashTable<FlightCheckPresenter>.weakObjects()
    private var sheets: [ObjectIdentifier: ControlPlaneSheet] = [:]
    private var commandCenter: WorkspaceCommandCenterWindowController?

    init(defaults: UserDefaults = .standard) { settings = FlightCheckSettingsStore(defaults: defaults) }

    // Keep the run, job and step invocation available directly to the workflow details view.
    // swiftlint:disable:next function_parameter_count
    @discardableResult func presentCIFixSheet(
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

    func makeFlightCheckPill(
        for root: URL, gitService: GitService,
        onPresentSheet: (@MainActor () -> Void)? = nil
    ) -> FlightCheckPillView {
        let presenter = flightPresenter(root, git: gitService)
        return FlightCheckPillView(presenter: presenter) { [weak self] in
            if let onPresentSheet {
                onPresentSheet()
            } else {
                self?.presentFlightCheckSheet(for: root, gitService: gitService, on: NSApp.keyWindow)
            }
        }
    }

    @discardableResult func presentFlightCheckSheet(
        for root: URL, gitService: GitService,
        on window: NSWindow?
    ) -> NSWindowController {
        let sheet = FlightCheckSheetController(presenter: flightPresenter(root, git: gitService))
        present(sheet, on: window)
        return sheet
    }

    private func flightPresenter(_ root: URL, git: GitService) -> FlightCheckPresenter {
        let key = root.standardizedFileURL.resolvingSymlinksInPath().path
        if let existing = presenters.allObjects.first(where: { $0.root.path == key }) { return existing }
        let presenter = FlightCheckPresenter(root: root, git: git, service: service, store: settings)
        presenters.add(presenter)
        return presenter
    }

    private func present(_ sheet: ControlPlaneSheet, on parent: NSWindow?) {
        let key = ObjectIdentifier(sheet)
        sheets[key] = sheet
        sheet.onDismiss = { [weak self] in self?.sheets[key] = nil }
        sheet.present(on: parent)
    }

    @discardableResult func showWorkspaceCommandCenter(
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
