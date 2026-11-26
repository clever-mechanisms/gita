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
        guard let root = model.snapshot?.root else {
            environment.system.beep()
            return
        }
        statusItem?.closePanel()
        agentControl.presentCollisionRadar(for: root)
    }

    @objc func showAgentFlightRecorder() {
        guard let root = model.snapshot?.root else {
            environment.system.beep()
            return
        }
        statusItem?.closePanel()
        agentControl.presentFlightRecorder(for: root)
    }

    @objc func showAgentArena() {
        guard let root = model.snapshot?.root else {
            environment.system.beep()
            return
        }
        statusItem?.closePanel()
        agentControl.showArena(for: root, baseCommit: model.selectedCommit?.id ?? "HEAD")
    }

    func installAgentControlMenuItemsIfNeeded(in menu: NSMenu?) {
        guard let repoMenu = menu?.item(withTitle: String(localized: "Repository"))?.submenu else { return }
        installAgentControlMenuItems(in: repoMenu, addSeparator: true)
    }

    func installAgentControlMenuItems(in menu: NSMenu, addSeparator: Bool = false) {
        var needsSeparator = addSeparator
        func add(_ id: String, _ title: String, _ selector: Selector, _ symbol: String) {
            let identifier = NSUserInterfaceItemIdentifier("gita.menu.agentControl." + id)
            guard menu.items.allSatisfy({ $0.identifier != identifier }) else { return }
            if needsSeparator {
                menu.addItem(.separator())
                needsSeparator = false
            }
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self
            item.identifier = identifier
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        add(
            "collisionRadar", String(localized: "Collision Radar…"), #selector(showCollisionRadar),
            "dot.radiowaves.left.and.right")
        add(
            "flightRecorder", String(localized: "Agent Flight Recorder…"), #selector(showAgentFlightRecorder),
            "waveform.path.ecg")
        add("arena", String(localized: "Fork & Race Arena…"), #selector(showAgentArena), "flag.checkered.2.crossed")
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
