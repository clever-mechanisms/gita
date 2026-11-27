import AppKit
import GitaCore

@MainActor
protocol ArenaQuitHandling: AnyObject {
    var hasActiveRace: Bool { get }
    func cancelAll()
}

extension AgentControlFacade: ArenaQuitHandling {}

/// Agent Air Traffic Control wiring: Collision Radar, Agent Flight Recorder, Fork & Race Arena, and hook routing.
extension AppDelegate {
    var agentControl: AgentControlFacade {
        if let activeAgentControl { return activeAgentControl }
        let facade = AgentControlFacade()
        activeAgentControl = facade
        return facade
    }

    @objc func showCollisionRadar() {
        openInlineAgentTool(.collisionRadar)
    }

    @objc func showAgentFlightRecorder() {
        openInlineAgentTool(.flightRecorder)
    }

    @objc func showAgentArena() {
        openInlineAgentTool(.agentArena(baseCommit: model.selectedCommit?.id ?? "HEAD"))
    }

    private func openInlineAgentTool(_ request: ToolPageRequest) {
        guard model.snapshot?.root != nil else {
            environment.system.beep()
            return
        }
        statusItem?.closePanel()
        showWindow()
        repositoryController?.openToolPage(request)
    }

    func wireAgentControlHooks() {
        RepositoryViewController.sharedReviewedHunksProvider = { [weak self] in self?.reviewedHunks }
        AgentMonitor.shared.onHookEvent = { [weak self] event in
            self?.routeAgentHookEvent(event)
        }
    }

    func routeAgentHookEvent(_ event: AgentHookEvent) {
        let roots = openRepositoryRoots
        let matched: URL? =
            if let cwd = event.cwd {
                roots.first { cwd == $0.path || cwd.hasPrefix($0.path + "/") }
            } else {
                nil
            }
        guard let root = matched ?? model.snapshot?.root else { return }
        agentControl.handleHookEvent(event, repositoryRoot: root)
    }

    var hasActiveAgentArenaRace: Bool {
        activeAgentControl?.hasActiveRace == true
    }

    func confirmQuitDuringActiveArenaRace(_ done: @escaping @MainActor (Bool) -> Void) {
        confirmQuitDuringActiveArenaRace(activeAgentControl, completion: done)
    }

    func confirmQuitDuringActiveArenaRace(
        _ arena: (any ArenaQuitHandling)?, completion done: @escaping @MainActor (Bool) -> Void
    ) {
        guard let arena, arena.hasActiveRace else {
            done(true)
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "An Arena race is still running.")
        alert.informativeText = String(
            localized: "Quitting now will cancel the active race and clean up its temporary worktrees.")
        alert.alertStyle = .warning
        let quitButton = alert.addButton(withTitle: String(localized: "Cancel Race & Quit"))
        quitButton.hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Keep Racing"))
        environment.system.alerts.present(alert, on: mainWindow) { response in
            guard response == .alertFirstButtonReturn else {
                done(false)
                return
            }
            arena.cancelAll()
            done(true)
        }
    }

    func cleanupAgentControlOnTerminate() {
        activeAgentControl?.cancelAll()
        activeAgentControl = nil
    }
}
