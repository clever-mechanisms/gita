import AppKit
import GitaCore

/// Presenter & sparkle button controller for generating commit messages via a local agent CLI.
/// Holds the generation lifecycle in a single enum (`Lifecycle`) alongside availability inputs.
@MainActor
final class CommitMessageAssistController {
    /// Testable value snapshot describing how the sparkle button should render.
    struct ButtonPresentation: Equatable {
        let title: String
        let symbolName: String
        let isEnabled: Bool
        let isGenerating: Bool
        let toolTip: String
        let accessibilityLabel: String
        let errorMessage: String?
    }

    typealias GeneratorClosure =
        @Sendable (
            _ service: GitService,
            _ installedAgents: [ReviewAgent: URL],
            _ preferredAgent: String
        ) async throws -> GeneratedCommitMessage

    private enum Lifecycle {
        case idle
        case generating(agent: ReviewAgent, task: Task<Void, Never>)
        case ready(GeneratedCommitMessage)
        case failed(String)

        var publicState: CommitMessageDraftState {
            switch self {
            case .idle:
                return .idle
            case .generating(let agent, _):
                return .generating(agent: agent)
            case .ready(let message):
                return .ready(message)
            case .failed(let message):
                return .failed(message)
            }
        }
    }

    let button: PartsButton
    var onApplyMessage: ((GeneratedCommitMessage) -> Void)?
    var onStateChanged: ((CommitMessageDraftState) -> Void)?

    private var lifecycle: Lifecycle = .idle
    private var hasStagedChanges = false
    private var installedAgents: [ReviewAgent: URL] = [:]
    private var preferredAgent = ""
    private let runGenerator: GeneratorClosure

    var state: CommitMessageDraftState { lifecycle.publicState }

    var activeAgent: ReviewAgent? {
        ReviewAgentDetector.pick(preferredAgent, installed: installedAgents)
    }

    var buttonPresentation: ButtonPresentation {
        Self.makePresentation(
            state: state,
            hasStagedChanges: hasStagedChanges,
            agent: activeAgent
        )
    }

    init(
        generator: @escaping GeneratorClosure = { service, installed, preferred in
            try await CommitMessageGenerator().generate(
                service: service,
                installedAgents: installed,
                preferredAgent: preferred
            )
        }
    ) {
        self.runGenerator = generator
        self.button = PartsButton(
            [
                .symbol("sparkles", color: Theme.working, size: 11),
                .text(String(localized: "Generate"), font: Theme.captionEmphasis, color: Theme.text),
            ],
            background: .hover,
            accessibility: String(localized: "Generate commit message")
        )
        button.fixedHeight = 24
        button.horizontalPadding = 7
        button.spacing = 4
        button.cornerRadius = 6
        button.setAccessibilityIdentifier("changes.generateCommitMessage")
        syncButton()
    }

    isolated deinit {
        if case .generating(_, let task) = lifecycle {
            task.cancel()
        }
    }

    /// Updates availability when staged changes or installed agent CLIs change.
    func updateAvailability(
        hasStagedChanges: Bool,
        installedAgents: [ReviewAgent: URL],
        preferredAgent: String = ""
    ) {
        self.hasStagedChanges = hasStagedChanges
        self.installedAgents = installedAgents
        self.preferredAgent = preferredAgent
        syncButton()
    }

    /// Starts generating a commit message for staged changes, or cancels if already generating.
    @discardableResult
    func toggleGenerate(service: GitService) -> Bool {
        if case .generating = lifecycle {
            cancel()
            return false
        }
        return generate(service: service)
    }

    /// Invokes the selected local agent CLI to draft a commit message from the staged diff.
    @discardableResult
    func generate(service: GitService) -> Bool {
        guard hasStagedChanges else {
            transition(to: .failed(CommitMessageGeneratorError.noStagedChanges.localizedDescription))
            return false
        }
        guard let agent = activeAgent else {
            transition(to: .failed(CommitMessageGeneratorError.noAgentInstalled.localizedDescription))
            return false
        }
        if case .generating(_, let existing) = lifecycle {
            existing.cancel()
        }
        let installed = installedAgents
        let preferred = preferredAgent
        let runGenerator = runGenerator
        let task = Task { @MainActor [weak self] in
            do {
                let message = try await runGenerator(service, installed, preferred)
                guard let self, !Task.isCancelled else { return }
                self.finishSuccess(message)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.transition(to: .failed(error.localizedDescription))
            }
        }
        transition(to: .generating(agent: agent, task: task))
        return true
    }

    /// Cancels an in-flight generation and returns to `.idle`.
    func cancel() {
        if case .generating(_, let task) = lifecycle {
            task.cancel()
        }
        transition(to: .idle)
    }

    /// Clears any completed or failed state back to `.idle` (cancelling if busy).
    func reset() {
        cancel()
    }

    private func finishSuccess(_ message: GeneratedCommitMessage) {
        transition(to: .ready(message))
        onApplyMessage?(message)
    }

    private func transition(to next: Lifecycle) {
        lifecycle = next
        syncButton()
        onStateChanged?(state)
    }

    private func syncButton() {
        let model = buttonPresentation
        let accentColor = model.isGenerating ? Theme.needsInputText : Theme.working
        let textColor = model.isGenerating ? Theme.secondaryText : Theme.text
        button.parts = [
            .symbol(model.symbolName, color: accentColor, size: 11),
            .text(model.title, font: Theme.captionEmphasis, color: textColor),
        ]
        button.isEnabled = model.isEnabled
        button.background = model.isGenerating ? .tinted : .hover
        button.tintFill = Theme.control
        button.tintBorder = Theme.separator
        button.toolTip = model.toolTip
        button.setAccessibilityLabel(model.accessibilityLabel)
    }

    static func makePresentation(
        state: CommitMessageDraftState,
        hasStagedChanges: Bool,
        agent: ReviewAgent?
    ) -> ButtonPresentation {
        if case .generating(let active) = state {
            let label = String(localized: "Generating with \(active.displayName)… Click to cancel")
            return ButtonPresentation(
                title: String(localized: "Generating…"),
                symbolName: "stop.circle",
                isEnabled: true,
                isGenerating: true,
                toolTip: label,
                accessibilityLabel: label,
                errorMessage: nil
            )
        }
        let errorMessage = state.errorMessage
        guard let agent else {
            let tip = String(localized: "Install Claude, Codex, Gemini, or Cursor CLI to generate commit messages")
            return ButtonPresentation(
                title: String(localized: "Generate"),
                symbolName: "sparkles",
                isEnabled: false,
                isGenerating: false,
                toolTip: errorMessage ?? tip,
                accessibilityLabel: String(localized: "Generate commit message"),
                errorMessage: errorMessage
            )
        }
        guard hasStagedChanges else {
            let tip = String(localized: "Stage changes to generate a commit message with \(agent.displayName)")
            return ButtonPresentation(
                title: String(localized: "Generate"),
                symbolName: "sparkles",
                isEnabled: false,
                isGenerating: false,
                toolTip: errorMessage ?? tip,
                accessibilityLabel: String(localized: "Generate commit message"),
                errorMessage: errorMessage
            )
        }
        let tip =
            errorMessage ?? String(localized: "Generate commit message from staged diff with \(agent.displayName)")
        return ButtonPresentation(
            title: String(localized: "Generate"),
            symbolName: "sparkles",
            isEnabled: true,
            isGenerating: false,
            toolTip: tip,
            accessibilityLabel: String(localized: "Generate commit message with \(agent.displayName)"),
            errorMessage: errorMessage
        )
    }
}
