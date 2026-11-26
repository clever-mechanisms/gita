import Foundation
import GitaCore

enum SpeculativePreviewContent: Sendable, Equatable {
    case rebase(RebaseSimulationResult)
    case pairwiseMerge(PairwiseMergePrediction)
    case preFlight(PreFlightPrediction)

    struct Step: Equatable {
        let title: String
        let outcome: RebaseStepOutcome
        let treeID: String?
        var mono = false
    }

    var steps: [Step] {
        switch self {
        case .rebase(let result):
            result.steps.map {
                Step(
                    title: String(localized: "\($0.action.previewTitle) \($0.commitID.prefix(10))"),
                    outcome: $0.outcome, treeID: $0.resultingTreeID, mono: true)
            }
        case .pairwiseMerge(let result):
            [
                Step(
                    title: String(localized: "Merge \(result.theirsRef) into \(result.oursRef)"),
                    outcome: result.outcome.stepOutcome, treeID: result.outcome.treeID)
            ]
        case .preFlight(let result):
            [
                Step(
                    title: result.kind == .stash
                        ? String(localized: "Apply \(result.targetRef) onto \(result.ontoRef)")
                        : String(localized: "Cherry-pick \(result.targetRef) onto \(result.ontoRef)"),
                    outcome: result.outcome, treeID: result.treeID)
            ]
        }
    }
}

extension GitRebaseAction {
    fileprivate var previewTitle: String {
        switch self {
        case .pick: String(localized: "pick")
        case .reword: String(localized: "reword")
        case .edit: String(localized: "edit")
        case .squash: String(localized: "squash")
        case .fixup: String(localized: "fixup")
        case .drop: String(localized: "drop")
        }
    }
}

extension PairwiseMergeOutcome {
    fileprivate var stepOutcome: RebaseStepOutcome {
        switch self {
        case .clean: .clean
        case .conflict(_, let files, let details): .conflict(files: files, details: details)
        case .unsupported(let reason): .unsupported(reason: reason)
        }
    }
}

extension RebaseStepOutcome {
    var descriptionText: String {
        switch self {
        case .clean: ConflictRiskLevel.clean.title
        case .empty: String(localized: "No changes to apply")
        case .dropped: String(localized: "Dropped")
        case .unsupported(let reason): reason
        case .conflict(_, let details): details.isEmpty ? ConflictRiskLevel.conflict.title : details
        }
    }
}

@MainActor final class SpeculativePreviewPresenter {
    typealias Simulation = @Sendable () async throws -> SpeculativePreviewContent
    private(set) var state = SpeculationState<SpeculativePreviewContent>.idle
    private(set) var filePreview = SpeculationState<ConflictPreview>.idle
    private(set) var selectedStep: Int?
    private(set) var selectedFile: String?
    private(set) var showsLoadingIndicator = false
    var onChange: (() -> Void)?
    private let simulation = LatestTask()
    private let preview = LatestTask()
    private let indicator = LatestTask()
    private let service: SpeculativeGitService
    private var request: Simulation?

    private let waitForDebounce: @MainActor (Duration) async throws -> Void

    convenience init(service: SpeculativeGitService) {
        self.init(service: service) { try await Task.sleep(for: $0) }
    }

    init(service: SpeculativeGitService, waitForDebounce: @escaping @MainActor (Duration) async throws -> Void) {
        self.service = service
        self.waitForDebounce = waitForDebounce
    }

    func simulate(_ request: @escaping Simulation, debounce: Duration = .zero) {
        self.request = request
        run(request, debounce: debounce)
    }

    func refresh() {
        guard let request else { return }
        run(request, debounce: .zero)
    }

    private func run(_ request: @escaping Simulation, debounce: Duration) {
        resetPreview()
        state = .loading
        delayIndicator()
        onChange?()
        simulation.run { [waitForDebounce] in
            if debounce > .zero { try await waitForDebounce(debounce) }
            try Task.checkCancellation()
            return try await request()
        } then: { [weak self] result in
            guard let self else { return }
            stopIndicator()
            switch result {
            case .success(let value):
                state = .loaded(value)
                select(step: 0)
            case .failure(let error):
                state = .failed(error.localizedDescription)
                onChange?()
            }
        }
    }

    func select(step index: Int, file path: String? = nil) {
        resetPreview()
        guard case .loaded(let content) = state, content.steps.indices.contains(index) else {
            onChange?()
            return
        }
        selectedStep = index
        let step = content.steps[index]
        guard let tree = step.treeID, let file = path ?? step.outcome.conflictingFiles.first,
            step.outcome.conflictingFiles.contains(file)
        else {
            onChange?()
            return
        }
        selectedFile = file
        filePreview = .loading
        delayIndicator()
        onChange?()
        preview.run { [service] in
            try await service.previewConflictedFile(treeID: tree, path: file)
        } then: {
            [weak self] result in
            guard let self else { return }
            stopIndicator()
            switch result {
            case .success(let value): filePreview = .loaded(value)
            case .failure(let error): filePreview = .failed(error.localizedDescription)
            }
            onChange?()
        }
    }

    private func delayIndicator() {
        showsLoadingIndicator = false
        indicator.run {
            try await Task.sleep(for: .milliseconds(150))
        } then: { [weak self] _ in
            self?.showsLoadingIndicator = true
            self?.onChange?()
        }
    }

    private func stopIndicator() {
        indicator.cancel()
        showsLoadingIndicator = false
    }

    private func resetPreview() {
        preview.cancel()
        stopIndicator()
        filePreview = .idle
        selectedStep = nil
        selectedFile = nil
    }

    func cancel() {
        simulation.cancel()
        resetPreview()
        state = .idle
        onChange?()
    }
}
