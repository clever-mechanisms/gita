import AppKit
import GitaCore

/// Loads one provider item's details for an in-place disclosure (`force` bypasses the 30 s cache).
typealias ProviderDetailLoader = @MainActor (ProviderItem, Bool) async -> ProviderDetailReport?

/// Read-only provider details shown in place (no modal windows): the PR card (opened by, merged by, reviews, checks,
/// Open on GitHub), a workflow run's jobs, or a deployment's addresses. Loads when it first appears in a window and
/// cancels when removed, so a collapsed row never keeps a request alive.
@MainActor
final class ProviderDetailView: NSView {
    /// The details' read: none yet (or the first one stopped), the first read, a forced refresh (which gives way
    /// to what was shown before it if it stops), the report shown, or a failed read with the report it left on
    /// screen and what the footer says.
    enum Phase {
        case idle
        case loading
        indirect case refreshing(previous: Self)
        case loaded(ProviderDetailReport)
        case failed(ProviderDetailReport?, message: String)

        /// The report whose sections are on screen.
        var report: ProviderDetailReport? {
            switch self {
            case .idle, .loading: nil
            case .refreshing(let previous): previous.report
            case .loaded(let report): report
            case .failed(let report, _): report
            }
        }
        var isReading: Bool {
            switch self {
            case .loading, .refreshing: true
            case .idle, .loaded, .failed: false
            }
        }
        /// A read stopped before it answered (the row collapsed): back to what was shown before it.
        var stopped: Self {
            switch self {
            case .loading: .idle
            case .refreshing(let previous): previous
            case .idle, .loaded, .failed: self
            }
        }

        /// The footer: what it says, in the failure colour or not, whether it spins and offers Try Again.
        struct Footer: Equatable {
            var text = ""
            var isFailure = false
            var spins = false
            var offersRetry = false
        }
        var footer: Footer {
            switch self {
            case .idle, .loaded: Footer()
            case .loading: Footer(text: String(localized: "Loading…"), spins: true)
            case .refreshing: Footer(text: String(localized: "Refreshing…"), spins: true)
            case .failed(_, let message): Footer(text: message, isFailure: true, offersRetry: true)
            }
        }
    }

    let item: ProviderItem
    private let loader: ProviderDetailLoader
    /// The detail sections (`ProviderDetailView+Sections`).
    let content = Deck.vstack([], spacing: 6)
    private let status = Deck.caption("")
    private let spinner = NSProgressIndicator()
    private let footer: NSStackView
    private var retry: PartsButton?
    private var task: Task<Void, Never>?
    private(set) var phase = Phase.idle
    var report: ProviderDetailReport? { phase.report }
    var showsHeader = true

    init(item: ProviderItem, loader: @escaping ProviderDetailLoader) {
        self.item = item
        self.loader = loader
        footer = Deck.hstack([spinner, status, Deck.spacer()], spacing: 6)
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let stack = Deck.vstack([content, footer], spacing: 8)
        Deck.pin(stack, in: self)
        content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        footer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        setAccessibilityElement(false)
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("ProviderDetailView is built in code") }
    isolated deinit { task?.cancel() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancel() } else if report == nil, !phase.isReading { load(force: false) }
    }
    func cancel() {
        task?.cancel()
        task = nil
        set(phase.stopped)
    }
    func load(force: Bool) {
        task?.cancel()
        set(force ? .refreshing(previous: phase.stopped) : .loading)
        let loader = loader
        let item = item
        task = Task { [weak self] in
            let report = await loader(item, force)
            // `cancel` and a newer `load` cancel on the main actor, so a read they replaced stops here.
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            guard let report, report.target == item.target else {
                self.set(.failed(self.phase.report, message: String(localized: "Details unavailable")))
                return
            }
            self.show(report)
        }
    }
    /// Shows `next`'s footer; the sections change only when a report arrives.
    private func set(_ next: Phase) {
        phase = next
        let shown = next.footer
        if shown.spins { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        status.stringValue = shown.text
        status.textColor = shown.isFailure ? Theme.failure : Theme.secondaryText
        if shown.offersRetry, retry == nil {
            let button = PartsButton.link(String(localized: "Try Again")) { [weak self] in self?.load(force: true) }
            footer.insertArrangedSubview(button, at: 2)
            retry = button
        } else if !shown.offersRetry {
            retry?.removeFromSuperview()
            retry = nil
        }
    }
    private func show(_ report: ProviderDetailReport) {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let detail = report.content else {
            set(.failed(report, message: ProviderDetailFacts.failure(report)))
            return
        }
        set(.loaded(report))
        switch detail {
        case .pullRequest(let value): showPullRequest(value)
        case .workflowRun(let value): showWorkflow(value)
        case .deployment(let value): showDeployment(value)
        }
        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
    }

    static func elapsed(_ started: Date?, _ completed: Date?) -> String {
        ProviderDetailFacts.elapsed(started, completed)
    }
}
