import AppKit
import GitaCore

/// Agent Air Traffic Control wiring: Collision Radar, Agent Flight Recorder, Fork & Race Arena, and hook routing.
extension AppDelegate {
    private static var agentControlByApp: [ObjectIdentifier: AgentControlFacade] = [:]

    var agentControl: AgentControlFacade {
        let key = ObjectIdentifier(self)
        if let existing = Self.agentControlByApp[key] { return existing }
        let facade = AgentControlFacade()
        Self.agentControlByApp[key] = facade
        RepositoryViewController.sharedAgentControlFacade = facade
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
        let items: [(id: String, title: String, action: Selector, symbol: String)] = [
            (
                "gita.menu.agentControl.collisionRadar", String(localized: "Collision Radar…"),
                #selector(showCollisionRadar), "dot.radiowaves.left.and.right"
            ),
            (
                "gita.menu.agentControl.flightRecorder", String(localized: "Agent Flight Recorder…"),
                #selector(showAgentFlightRecorder), "waveform.path.ecg"
            ),
            (
                "gita.menu.agentControl.arena", String(localized: "Fork & Race Arena…"),
                #selector(showAgentArena), "flag.checkered.2.crossed"
            ),
        ]
        var inserted = false
        for entry in items {
            let identifier = NSUserInterfaceItemIdentifier(entry.id)
            guard !repoMenu.items.contains(where: { $0.identifier == identifier }) else { continue }
            if !inserted {
                repoMenu.addItem(.separator())
                inserted = true
            }
            let menuItem = NSMenuItem(title: entry.title, action: entry.action, keyEquivalent: "")
            menuItem.target = self
            menuItem.identifier = identifier
            menuItem.image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil)
            repoMenu.addItem(menuItem)
        }
    }

    func wireAgentControlHooks() {
        RepositoryViewController.sharedAgentControlFacade = agentControl
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
        Self.agentControlByApp[ObjectIdentifier(self)]?.hasActiveRace == true
    }

    func cleanupAgentControlOnTerminate() {
        let key = ObjectIdentifier(self)
        Self.agentControlByApp.removeValue(forKey: key)?.cancelAll()
    }
}
