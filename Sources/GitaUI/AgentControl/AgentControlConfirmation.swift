import AppKit

typealias AgentControlConfirmation =
    @MainActor (
        DestructiveConfirmation, NSWindow?, @escaping @MainActor () -> Void
    ) -> Void

extension DestructiveConfirmation {
    static func present(_ confirmation: Self, on window: NSWindow?, confirmed: @escaping @MainActor () -> Void) {
        guard let window else { return }
        confirmation.present(on: window, confirmed: confirmed)
    }
}
