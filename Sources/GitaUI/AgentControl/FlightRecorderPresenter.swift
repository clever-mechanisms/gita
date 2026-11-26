import AppKit
import GitaCore

@MainActor
final class FlightRecorderPresenter {
    enum Comparison: Equatable {
        case previous, workingTree
        case turn(String)
    }

    let history: FlightHistory
    private(set) var state = FlightRecorderState.idle
    private(set) var isEnabled = false
    private(set) var turns: [FlightSnapshot] = []
    private(set) var selectedTurnIndex: Int?
    private(set) var comparison = Comparison.previous
    private(set) var diff: FlightDiffResult?
    private(set) var selectedFile: String?
    private(set) var selectedHunkIndex: Int?
    private(set) var patch: FlightFilePatch?
    private(set) var feedback = ""
    private(set) var task: Task<Void, Never>?
    private var sections: [String: Substring] = [:]
    var confirmDestructive: AgentControlConfirmation = DestructiveConfirmation.present

    private var isWriting: Bool {
        switch state {
        case .writing, .restoring: true
        default: false
        }
    }
    private var selectedID: String?
    var shouldReloadAfterWrite: () -> Bool = { true }
    var onStateChange: (() -> Void)?

    init(service: FlightRecorderService, repositoryRoot: URL) {
        history = FlightHistory(service: service, root: repositoryRoot)
    }

    var selectedTurn: FlightSnapshot? {
        guard let index = selectedTurnIndex, turns.indices.contains(index) else { return nil }
        return turns[index]
    }

    var effectiveComparison: Comparison {
        if case .turn(let id) = comparison, id == selectedID || !turns.contains(where: { $0.id == id }) {
            return selectedTurn?.parentOID == nil ? .workingTree : .previous
        }
        if comparison == .previous, selectedTurn?.parentOID == nil { return .workingTree }
        return comparison
    }

    private var comparisonID: String? {
        switch effectiveComparison {
        case .previous: selectedTurn?.parentOID
        case .workingTree: nil
        case .turn(let id): id
        }
    }

    func load() {
        guard !isWriting else { return }
        feedback = ""
        reload()
    }

    private func reload() {
        begin(.loading) { [weak self, history] in
            let enabled = await history.service.isEnabled(for: history.root)
            try Task.checkCancellation()
            self?.isEnabled = enabled
            let snapshots = enabled ? try await history.snapshots() : []
            try Task.checkCancellation()
            self?.accept(snapshots)
        }
    }

    private func accept(_ snapshots: [FlightSnapshot]) {
        turns = snapshots
        selectedTurnIndex = snapshots.firstIndex { $0.id == selectedID } ?? snapshots.indices.last
        selectedID = selectedTurn?.id
        guard !snapshots.isEmpty else {
            clearDiff()
            update(isEnabled ? .empty : .disabled)
            return
        }
        loadDiff()
    }

    func setEnabled(_ enabled: Bool) {
        guard !isWriting else { return }
        mutate(.writing(enabled ? .enabling : .disabling)) { [history] in
            await history.service.setEnabled(enabled, for: history.root)
        }
    }

    func captureManualSnapshot() {
        guard isEnabled, !isWriting else { return }
        mutate(.writing(.capturing)) { [self] in
            let turn = try await history.service.captureSnapshot(in: history.root)
            selectedID = turn.id
        }
    }

    func selectTurn(index: Int) {
        guard !isWriting, turns.indices.contains(index) else { return }
        selectedTurnIndex = index
        selectedID = selectedTurn?.id
        feedback = ""
        loadDiff()
    }

    func selectComparison(toSnapshotID id: String?) {
        guard !isWriting, let selectedTurn else { return }
        if let id, id == selectedTurn.id || !turns.contains(where: { $0.id == id }) { return }
        feedback = ""
        comparison = id.map(Comparison.turn) ?? .workingTree
        loadDiff()
    }

    func selectPrevious() {
        guard !isWriting else { return }
        feedback = ""
        comparison = .previous
        loadDiff()
    }

    private func loadDiff() {
        guard let turn = selectedTurn else { return }
        let from = comparisonID ?? turn.id
        let to = comparisonID.map { _ in turn.id }
        begin(.loading) { [weak self, history] in
            let result = try await history.service.diff(in: history.root, from: from, to: to)
            try Task.checkCancellation()
            self?.accept(result)
        }
    }

    private func accept(_ result: FlightDiffResult) {
        diff = result
        sections = FlightFilePatch.sections(result)
        state = .loaded(turns)
        displayFile(selectedFile.flatMap { result.files.contains($0) ? $0 : nil } ?? result.files.first)
    }

    func selectFile(_ path: String?) {
        guard case .loaded = state else { return }
        feedback = ""
        displayFile(path)
    }

    private func displayFile(_ path: String?) {
        let previous = selectedFile == path ? selectedHunkIndex : nil
        selectedFile = path
        patch = path.flatMap { sections[$0] }.map { FlightFilePatch(String($0)) }
        let hunks = patch?.document.hunks ?? []
        selectedHunkIndex = previous.flatMap { hunks.indices.contains($0) ? $0 : nil } ?? hunks.first?.index
        onStateChange?()
    }

    func selectHunk(_ index: Int) {
        guard case .loaded = state, let patch, patch.document.hunks.indices.contains(index) else { return }
        feedback = ""
        selectedHunkIndex = index
        onStateChange?()
    }

    func restoreSelectedTurn(on window: NSWindow?) {
        guard let turn = selectedTurn else { return }
        restore(
            action: String(localized: "Restore Turn"),
            question: String(localized: "Restore turn \(turn.sequence)?"),
            target: history.root.path, on: window
        ) {
            try await $0.service.restoreTurn(in: $0.root, snapshotID: $1)
        }
    }

    func restoreFile(_ path: String, on window: NSWindow?) {
        guard let turn = selectedTurn else { return }
        restore(
            action: String(localized: "Restore File"),
            question: String(localized: "Restore file from turn \(turn.sequence)?"),
            target: path, on: window
        ) {
            try await $0.service.restoreFile(in: $0.root, snapshotID: $1, path: path)
        }
    }

    func restoreHunk(path: String, hunkIndex: Int, expectedDiff: String, on window: NSWindow?) {
        guard let turn = selectedTurn, effectiveComparison == .workingTree, diff?.isTruncated == false,
            patch?.document.hunks.indices.contains(hunkIndex) == true
        else { return }
        restore(
            action: String(localized: "Restore Hunk"),
            question: String(localized: "Restore hunk from turn \(turn.sequence)?"),
            target: String(localized: "\(path), hunk \(hunkIndex + 1)"),
            on: window
        ) {
            try await $0.service.restoreHunk(
                in: $0.root, snapshotID: $1, path: path, hunkIndex: hunkIndex, expectedDiff: expectedDiff)
        }
    }

    private func restore(
        action: String, question: String, target: String, on window: NSWindow?,
        operation: @escaping (FlightHistory, String) async throws -> Void
    ) {
        guard case .loaded = state, let turn = selectedTurn else { return }
        feedback = ""
        onStateChange?()
        let detail = String(
            localized: "Replace changes in \(target) with turn \(turn.sequence)? A safety snapshot will be saved first."
        )
        confirmDestructive(.init(message: question, detail: detail, action: action), window) { [self] in
            mutate(.restoring(snapshotID: turn.id), success: String(localized: "Restored to the working tree.")) {
                [history] in try await operation(history, turn.id)
            }
        }
    }

    func clearSnapshots(on window: NSWindow?) {
        guard case .loaded = state else { return }
        feedback = ""
        onStateChange?()
        let title = String(localized: "Clear")
        let detail = String(localized: "Permanently delete all recorded snapshots for \(history.root.path)?")
        confirmDestructive(.init(message: String(localized: "Clear snapshots?"), detail: detail, action: title), window)
        {
            [self] in mutate(.writing(.clearing)) { [history] in try await history.clear() }
        }
    }

    private func mutate(
        _ state: FlightRecorderState, success: String = "",
        operation: @escaping @MainActor () async throws -> Void
    ) {
        guard !isWriting else { return }
        task?.cancel()
        task = nil
        feedback = ""
        update(state)
        Task {
            do {
                try await operation()
                feedback = success
                if shouldReloadAfterWrite() { reload() } else { update(.idle) }
            } catch {
                update(.failed(error.localizedDescription))
            }
        }
    }

    private func begin(_ state: FlightRecorderState, operation: @escaping @MainActor () async throws -> Void) {
        task?.cancel()
        task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                try await operation()
            } catch  where !Task.isCancelled {
                self?.update(.failed(error.localizedDescription))
            } catch {}
        }
        update(state)
    }

    private func update(_ value: FlightRecorderState) {
        state = value
        onStateChange?()
    }

    private func clearDiff() {
        diff = nil
        sections = [:]
        patch = nil
    }

    func cancel() {
        task?.cancel()
        task = nil
        guard !isWriting else { return }
        update(.idle)
    }

    deinit { task?.cancel() }
}
