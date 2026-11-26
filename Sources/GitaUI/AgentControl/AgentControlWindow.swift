import AppKit

@MainActor
final class AgentControlWindow: NSWindow, NSWindowDelegate {
    var onClose: (() -> Void)?
    init(content: NSViewController, repositoryRoot: URL, autosave: String, minimum: NSSize) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        title = content.title ?? ""
        subtitle = repositoryRoot.lastPathComponent
        contentViewController = content
        isReleasedWhenClosed = false
        minSize = minimum
        delegate = self
        center()
        setFrameAutosaveName(autosave + "." + repositoryRoot.path)
    }

    func present() { AuxiliaryWindowActivation.show(self) }

    func windowWillClose(_: Notification) {
        onClose?()
        AuxiliaryWindowActivation.closing(self)
    }
}
