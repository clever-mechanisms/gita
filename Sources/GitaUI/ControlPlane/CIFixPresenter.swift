import AppKit
import GitaCore

@MainActor
final class CIFixPresenter {
    enum Destination: Int { case builtIn, external }
    typealias Load = @Sendable () async throws -> CIFixContext
    typealias Launch = @MainActor (ReviewAgent, Destination, String) throws -> Void

    let target: CIFixTarget
    private(set) var state = CIFixState.idle { didSet { changed?() } }
    private(set) var agents: [ReviewAgent]
    private var launcher: ReviewAgentLauncher?
    private var loadedContext: CIFixContext?
    var selectedAgent: ReviewAgent?
    var destination: Destination
    var prompt = ""
    var changed: (() -> Void)?
    private let fetch: Load
    private let launchAgent: Launch
    private var task: Task<Void, Never>?

    init(
        target: CIFixTarget, agents: [ReviewAgent], preferred: ReviewAgent? = nil,
        destination: Destination = .builtIn, fetch: @escaping Load, launch: @escaping Launch
    ) {
        self.target = target
        self.agents = agents
        self.selectedAgent = preferred.flatMap { agents.contains($0) ? $0 : nil } ?? agents.first
        self.destination = destination
        self.fetch = fetch
        self.launchAgent = launch
    }

    convenience init(target: CIFixTarget, git: GitService, launcher: ReviewAgentLauncher = .shared) {
        self.init(
            target: target, agents: launcher.installedAgents, preferred: launcher.agent,
            destination: OpenIn.usesBuiltInTerminal() ? .builtIn : .external,
            fetch: { try await CIFixOrchestrator().load(target: target, gitService: git) },
            launch: { agent, destination, prompt in
                guard let executable = launcher.installed[agent] else { throw CocoaError(.fileNoSuchFile) }
                let script = CIFixOrchestrator.launchScript(
                    agent: agent, executable: executable, target: target,
                    prompt: prompt, path: launcher.searchPath)
                if destination == .builtIn {
                    let file = try TerminalScriptLauncher.writeScript(script, in: ReviewScripts.folder)
                    AppOpener.system.openBuiltInTerminal(target.root, file)
                } else {
                    let defaults = UserDefaults(suiteName: "Gita.ControlPlane.Terminal") ?? UserDefaults()
                    let terminal = OpenIn.terminalApp(.system, defaults: Preference.store)
                    let id = terminal.flatMap { Bundle(url: $0)?.bundleIdentifier } ?? OpenIn.defaultTerminal
                    defaults.setVolatileDomain(
                        [Preference.terminalBundleID.rawValue: id], forName: UserDefaults.argumentDomain)
                    try TerminalScriptLauncher(defaults: defaults, folder: ReviewScripts.folder, opener: .system)
                        .launch(script, in: target.root)
                }
            })
        self.launcher = launcher
    }

    func discoverAgents() { launcher?.refresh() }

    func updateAgents() {
        guard let launcher else { return }
        agents = launcher.installedAgents
        if selectedAgent.map({ agents.contains($0) }) != true { selectedAgent = launcher.agent }
        changed?()
    }

    deinit { task?.cancel() }

    @discardableResult func load() -> Task<Void, Never> {
        task?.cancel()
        loadedContext = nil
        state = .loading
        let work = Task { [weak self, fetch] in
            do {
                let context = try await fetch()
                try Task.checkCancellation()
                self?.loadedContext = context
                self?.prompt = context.prompt
                self?.state = .ready(context)
            } catch {
                if !Task.isCancelled { self?.state = .failed(error.localizedDescription) }
            }
        }
        task = work
        return work
    }

    func launch() {
        guard case .ready(let context) = state, let agent = selectedAgent, agents.contains(agent),
            !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        state = .launching(agent, context)
        do {
            try launchAgent(agent, destination, prompt)
            state = .launched(agent)
        } catch { state = .failed(error.localizedDescription) }
    }

    func retry() {
        if let loadedContext {
            state = .ready(loadedContext)
            launch()
        } else {
            load()
        }
    }

    func cancel() {
        task?.cancel()
        state = .idle
    }
}
