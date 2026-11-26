import AppKit

/// A restart for a new app language (Settings › General › Language › Restart Now), from the button to the quit.
@MainActor
enum LanguageRestart {
    case idle
    /// The replacement is starting: its ticket, the "Restarting…" sheet on the main window, and the timeout that
    /// gives up on it.
    case waiting(RelaunchTicket, sheet: NSWindow, timeout: Task<Void, Never>)
    /// The replacement opened and this process is quitting for it. Quitting can be refused (a Git action, a review
    /// sheet) or never come: the timeout, the refusal and an expired ticket all leave the hand-over.
    case handingOver(RelaunchTicket, timeout: Task<Void, Never>)
    /// The failure alert is showing; the shell stays closed to new work until it is answered.
    case failed

    /// How long the replacement may take to open, and then how long this process may take to quit (the replacement
    /// waits about as long for it).
    struct Timeouts {
        var replacement = Duration.seconds(10)
        var handover = Duration.seconds(15)
    }

    var isActive: Bool {
        if case .idle = self { false } else { true }
    }

    /// The hand-over to the replacement, while it is starting or taking over.
    var ticket: RelaunchTicket? {
        switch self {
        case .waiting(let ticket, _, _), .handingOver(let ticket, _): ticket
        case .idle, .failed: nil
        }
    }

    /// Moves to `next`, stopping the old state's timeout. The old sheet is returned for the caller to close once
    /// this mutation is over, so AppKit's callbacks (toolbar validation after a sheet) may read the new state.
    mutating func move(to next: Self) -> NSWindow? {
        defer { self = next }
        switch self {
        case .waiting(_, let sheet, let timeout):
            timeout.cancel()
            return sheet
        case .handingOver(_, let timeout):
            timeout.cancel()
            return nil
        case .idle, .failed:
            return nil
        }
    }

    /// Removes `sheet` from its window.
    static func close(_ sheet: NSWindow?) {
        guard let sheet else { return }
        sheet.sheetParent?.endSheet(sheet)
        sheet.orderOut(nil)
    }
}

/// Restarting for a new language: the shell saves its tabs, shows a sheet and opens a replacement, which waits for
/// this process to quit and opens the requests queued meanwhile.
extension AppDelegate {
    private static let sheetSize = NSSize(width: 320, height: 90)

    @objc func restartForLanguage() {
        guard environment.system.needsLanguageRestart(), gate.canRestartForLanguage, let window = mainWindow else {
            environment.system.beep()
            return
        }
        guard flushCommitDrafts() else { return }
        saveSessions()
        guard let ticket = tickets.begin() else {
            model.showError(
                String(localized: "Restart failed"), String(localized: "The language preference could not be saved."))
            return
        }
        loginOffer.hide()
        cancelAttentionNavigation()
        let sheet = Self.restartingSheet()
        let wait = languageRestartTimeouts.replacement
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: wait) } catch { return }
            self?.finishLanguageRestart(
                ticket, error: String(localized: "The replacement app did not open in time. Try restarting again."))
        }
        _ = languageRestart.move(to: .waiting(ticket, sheet: sheet, timeout: timeout))
        window.beginSheet(sheet)
        windows.validateToolbar()
        environment.system.openReplacement(
            environment.bundleURL, [RelaunchTicketStore.argument, ticket.token.uuidString]
        ) { [weak self] failure in self?.finishLanguageRestart(ticket, error: failure) }
    }

    /// Repository requests that arrive while restarting go to the replacement.
    func queueDuringLanguageRestart(_ urls: [URL]) {
        router.enqueue(urls)
        if let ticket = languageRestart.ticket, !tickets.queue(urls, for: ticket) {
            finishLanguageRestart(
                ticket,
                error: String(localized: "The pending repository requests could not be saved. Try restarting again."))
        }
    }

    /// The replacement opened (quit now, keeping the gate closed) or failed (tell the user, then reopen the shell).
    func finishLanguageRestart(_ ticket: RelaunchTicket, error: String?) {
        guard languageRestart.ticket?.token == ticket.token else { return }
        guard let error else {
            guard case .waiting = languageRestart else { return }
            beginLanguageHandover(ticket)
            return
        }
        tickets.cancel(ticket)
        LanguageRestart.close(languageRestart.move(to: .failed))
        windows.validateToolbar()
        DispatchQueue.main.async { [weak self] in self?.showLanguageRestartFailure(error) }
    }

    /// Quits for the replacement; the gate stays closed until termination, including didEndSheet callbacks.
    private func beginLanguageHandover(_ ticket: RelaunchTicket) {
        cancelAttentionNavigation()
        let wait = languageRestartTimeouts.handover
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: wait) } catch { return }
            self?.leaveLanguageHandover(ticket)
        }
        LanguageRestart.close(languageRestart.move(to: .handingOver(ticket, timeout: timeout)))
        DispatchQueue.main.async { [weak self] in
            guard let self, self.languageRestart.ticket?.token == ticket.token else { return }
            guard self.tickets.isPending(ticket) else {
                self.leaveLanguageHandover(ticket)
                return
            }
            self.environment.system.terminate()
        }
    }

    /// This process did not quit for the replacement (the quit was refused, the ticket expired or the wait timed out):
    /// the ticket is withdrawn, so the waiting replacement quits instead, and the shell opens again. The refusal has
    /// told the user why (a beep, the review sheet's question). `ticket` nil leaves any hand-over.
    func leaveLanguageHandover(_ ticket: RelaunchTicket? = nil) {
        guard case .handingOver(let current, _) = languageRestart, ticket.map({ $0.token == current.token }) ?? true
        else { return }
        tickets.cancel(current)
        _ = languageRestart.move(to: .idle)
        windows.validateToolbar()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isLanguageRestarting else { return }
            self.openPendingURLs()
            self.resumePendingAttention()
            self.loginOffer.update()
            self.refreshSettings()
        }
    }

    private func showLanguageRestartFailure(_ error: String) {
        let title = String(localized: "Restart failed")
        model.log(title, error, failed: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error
        if let window = mainWindow {
            environment.system.alerts.present(alert, on: window) { [weak self] _ in
                DispatchQueue.main.async { self?.resumeAfterLanguageRestartFailure() }
            }
        } else {
            resumeAfterLanguageRestartFailure()
        }
        refreshSettings()
    }

    private func resumeAfterLanguageRestartFailure() {
        guard case .failed = languageRestart else { return }
        _ = languageRestart.move(to: .idle)
        openPendingURLs()
        resumePendingAttention()
        loginOffer.update()
        windows.validateToolbar()
    }

    /// A notification's result was opened while the replacement waits: it takes precedence, so the restart stops.
    func deferLanguageRestartForNavigation() {
        guard let ticket = languageRestart.ticket else { return }
        tickets.cancel(ticket)
        LanguageRestart.close(languageRestart.move(to: .idle))
        openPendingURLs()
        refreshSettings()
        windows.validateToolbar()
    }

    private static func restartingSheet() -> NSWindow {
        let sheet = NSWindow(
            contentRect: NSRect(origin: .zero, size: sheetSize), styleMask: [.titled], backing: .buffered,
            defer: false)
        sheet.title = String(localized: "Restarting Gitā")
        let label = Style.label(String(localized: "Restarting…"), size: 13, weight: .medium)
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.usesThreadedAnimation = false
        progress.startAnimation(nil)
        let row = Style.stack([progress, label], spacing: 12)
        if let content = sheet.contentView {
            content.addSubview(row)
            row.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                row.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                row.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            ])
        }
        return sheet
    }
}
