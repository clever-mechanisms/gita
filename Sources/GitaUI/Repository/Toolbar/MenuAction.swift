import AppKit

/// A menu item that runs a closure.
@MainActor
final class MenuAction: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String? = nil, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }

    @available(*, unavailable, message: "Built in code")
    required init(coder _: NSCoder) { fatalError("Built in code") }

    @objc private func run() { handler() }
}
