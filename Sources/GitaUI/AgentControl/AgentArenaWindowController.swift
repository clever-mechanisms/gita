import AppKit
import GitaCore

@MainActor
final class AgentArenaWindowController: NSWindowController {
    let arena: AgentArenaViewController

    init(presenter: AgentArenaPresenter) {
        arena = AgentArenaViewController(presenter)
        let window = AgentControlWindow(
            content: arena, repositoryRoot: presenter.root, autosave: "Gita.AgentArenaWindow",
            minimum: NSSize(width: 780, height: 520))
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Programmatic controller") }

    override func showWindow(_: Any?) {
        (window as? AgentControlWindow)?.present()
    }
}
