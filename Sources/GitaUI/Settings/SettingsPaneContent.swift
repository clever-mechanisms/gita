import AppKit

/// One Settings pane: a vertical stack of groups, refreshed from live state whenever it is shown or a setting changes.
@MainActor
class SettingsPaneContent: NSObject {
    let view = FlippedView()
    let environment: SettingsEnvironment
    private let stack = NSStackView()
    /// Called when rows appear or disappear so the window can animate to the new height.
    var onLayoutChange: (() -> Void)?
    weak var window: NSWindow?

    init(environment: SettingsEnvironment) {
        self.environment = environment
        super.init()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 22, bottom: 22, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    var defaults: UserDefaults { environment.defaults }

    func setGroups(_ groups: [NSView]) {
        for group in groups {
            stack.addArrangedSubview(group)
            group.widthAnchor.constraint(
                equalTo: stack.widthAnchor, constant: -(stack.edgeInsets.left + stack.edgeInsets.right)
            ).isActive = true
        }
    }

    /// Re-reads every control from the settings and live state.
    func refresh() {}
    /// The pane was selected or its window opened.
    func didAppear() {}
    /// The pane was replaced or its window closed.
    func didDisappear() {}
    /// Gita came back to the front while this pane was showing.
    func applicationDidBecomeActive() {}
    /// Returns a view inside the pane to scroll to for a deep link.
    func view(for _: SettingsAnchor) -> NSView? { nil }

    /// A switch for a Boolean setting, written to this pane's defaults.
    func toggle(_ preference: Preference, accessibility: String, identifier: String? = nil) -> AccentSwitch {
        let toggle = AccentSwitch(accessibility: accessibility) { [weak self] on in
            guard let self else { return }
            preference.set(on, self.defaults)
        }
        if let identifier { toggle.setAccessibilityIdentifier(identifier) }
        return toggle
    }
    func present(_ error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }
}
