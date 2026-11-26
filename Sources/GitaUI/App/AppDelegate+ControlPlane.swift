import AppKit
import GitaCore

/// Closed-Loop Control Plane wiring: Workspace Command Center.
extension AppDelegate {
    @objc func showWorkspaceCommandCenter() {
        statusItem?.closePanel()
        let workspace = place.workspace
        let repositories = ControlPlaneFacade.repositories(
            for: workspace, session: tabsController?.session ?? place.session, defaults: defaults)
        var reportsByRoot: [URL: [ProviderReport]] = [:]
        for openModel in place.models {
            if let root = openModel.snapshot?.root ?? openModel.root {
                reportsByRoot[root] = openModel.reports
            }
        }
        ControlPlaneFacade.shared.showWorkspaceCommandCenter(
            workspaceTitle: workspace.title, repositories: repositories, providerReports: reportsByRoot
        ) { [weak self] url in
            self?.openRepositoryTab(url)
        }
    }
}
