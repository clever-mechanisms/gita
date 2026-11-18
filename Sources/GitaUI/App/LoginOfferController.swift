import AppKit

/// The Open at Login offer in the main window's corner: it appears once the window has been settled for a moment,
/// and goes away as soon as anything else needs the window (a sheet, a Git action, another app in front).
@MainActor
final class LoginOfferController {
    private static let margin: CGFloat = 20

    /// How long the window must stay settled before the offer appears.
    var delay = Duration.seconds(3)
    /// Whether the offer may show now.
    var canOffer: @MainActor () -> Bool = { false }
    /// The view the offer sits in.
    var container: @MainActor () -> NSView? = { nil }
    var onAccept: @MainActor () -> Void = {}
    var onDismiss: @MainActor () -> Void = {}

    /// Hidden, waiting out the delay in a settled window, or on screen. Hiding cancels the wait; the wait checks for
    /// that cancellation on the main actor, so a wait cancelled by `hide` never shows the offer.
    private enum Phase {
        case hidden
        case waiting(Task<Void, Never>)
        case shown(LoginOfferView)
    }

    private var phase = Phase.hidden

    var offer: LoginOfferView? {
        if case .shown(let offer) = phase { offer } else { nil }
    }

    var isShown: Bool { offer != nil }

    /// Shows the offer after the delay when it may show, else hides it.
    func update() {
        guard canOffer() else {
            hide()
            return
        }
        guard case .hidden = phase else { return }
        let task = Task { [weak self] in
            do { try await Task.sleep(for: self?.delay ?? .zero) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.phase = .hidden
            guard self.canOffer(), let content = self.container() else { return }
            self.show(in: content)
        }
        phase = .waiting(task)
    }

    func hide() {
        switch phase {
        case .hidden: break
        case .waiting(let task): task.cancel()
        case .shown(let offer): offer.removeFromSuperview()
        }
        phase = .hidden
    }

    private func show(in content: NSView) {
        let offer = LoginOfferView(
            onAccept: { [weak self] in self?.onAccept() }, onDismiss: { [weak self] in self?.onDismiss() })
        phase = .shown(offer)
        content.addSubview(offer)
        offer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            offer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.margin),
            offer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.margin),
            offer.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: Self.margin),
        ])
    }
}

/// The offer's answers: accepting turns Open at Login on; either answer is remembered so it is never offered again.
extension AppDelegate {
    func configureLoginOffer() {
        loginOffer.canOffer = { [weak self] in self?.canOfferLogin ?? false }
        loginOffer.container = { [weak self] in self?.mainWindow?.contentView }
        loginOffer.onAccept = { [weak self] in self?.acceptLoginOffer() }
        loginOffer.onDismiss = { [weak self] in
            guard let self else { return }
            LoginItem.answerOffer(defaults: self.defaults)
            self.loginOffer.hide()
        }
    }

    private var canOfferLogin: Bool { gate.canOfferLogin && environment.system.shouldOfferLogin(environment) }

    private func acceptLoginOffer() {
        guard loginOffer.isShown else { return }
        LoginItem.answerOffer(defaults: defaults)
        loginOffer.hide()
        do {
            switch try environment.system.enableLoginItem() {
            case .enabled: model.log(String(localized: "Opens at login"))
            case .requiresApproval:
                model.log(String(localized: "Login approval required"))
                environment.system.openLoginItemSettings()
            case .disabled, .unavailable:
                model.showError(
                    String(localized: "Login item unavailable"),
                    String(localized: "Open at Login could not be enabled. Try again in Settings."))
            }
        } catch { model.showError(String(localized: "Login item failed"), error.localizedDescription) }
        refreshSettings()
    }
}
