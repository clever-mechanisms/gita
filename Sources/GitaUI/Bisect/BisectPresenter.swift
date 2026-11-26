import Foundation
import GitaCore

/// Lifecycle state for an in-flight bisect command (start, good, bad, skip, reset).
enum BisectActionState: Sendable, Equatable {
    case idle
    case running(String)
    case failed(String)

    var isBusy: Bool {
        if case .running = self { return true }
        return false
    }

    var runningTitle: String? {
        if case .running(let title) = self { return title }
        return nil
    }

    var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Pure presentation value driving `BisectBannerView`, testable without AppKit views.
struct BisectBannerModel: Equatable, Sendable {
    let isHidden: Bool
    let isFinished: Bool
    let title: String
    let shortSHA: String
    let commitSubject: String
    let commitTooltip: String?
    let stepsBadgeText: String?
    let statusDetail: String?
    let errorMessage: String?
    let goodButtonTitle: String
    let badButtonTitle: String
    let showsStepActions: Bool
    let showsOpenCommit: Bool
    let culpritCommitID: String?
    let canAct: Bool

    init(state: BisectState, action: BisectActionState) {
        self.errorMessage = action.errorMessage
        self.canAct = !action.isBusy

        switch state {
        case .inactive:
            self.isHidden = action.errorMessage == nil
            self.isFinished = false
            self.title = action.errorMessage != nil ? String(localized: "Bisect Error") : ""
            self.shortSHA = ""
            self.commitSubject = ""
            self.commitTooltip = nil
            self.stepsBadgeText = nil
            self.statusDetail = nil
            self.goodButtonTitle = String(localized: "Good")
            self.badButtonTitle = String(localized: "Bad")
            self.showsStepActions = false
            self.showsOpenCommit = false
            self.culpritCommitID = nil

        case .active(let session):
            self.isHidden = false
            self.isFinished = false
            self.title = action.runningTitle ?? String(localized: "Bisecting")
            self.shortSHA = session.currentShortID
            self.commitSubject = session.currentSubject
            self.commitTooltip = "\(session.currentCommitID)\n\(session.currentSubject)"
            self.stepsBadgeText = Self.stepsBadge(remaining: session.remainingCommits, steps: session.estimatedSteps)
            self.statusDetail = Self.activeDetail(session: session)
            self.goodButtonTitle = Self.termLabel(
                session.goodTerm, defaultTerm: "good", fallback: String(localized: "Good"))
            self.badButtonTitle = Self.termLabel(
                session.badTerm, defaultTerm: "bad", fallback: String(localized: "Bad"))
            self.showsStepActions = true
            self.showsOpenCommit = false
            self.culpritCommitID = nil

        case .finished(let culprit):
            self.isHidden = false
            self.isFinished = true
            self.title = action.runningTitle ?? String(localized: "Culprit Found")
            self.shortSHA = culprit.shortID
            self.commitSubject = culprit.subject
            let branchSuffix =
                culprit.startBranch.isEmpty ? "" : "\n" + String(localized: "Started on \(culprit.startBranch)")
            self.commitTooltip = "\(culprit.commitID)\n\(culprit.subject) (\(culprit.author))\(branchSuffix)"
            self.stepsBadgeText = String(localized: "First bad commit")
            self.statusDetail = culprit.author.isEmpty ? nil : String(localized: "by \(culprit.author)")
            self.goodButtonTitle = String(localized: "Good")
            self.badButtonTitle = String(localized: "Bad")
            self.showsStepActions = false
            self.showsOpenCommit = true
            self.culpritCommitID = culprit.commitID
        }
    }

    private static func termLabel(_ term: String, defaultTerm: String, fallback: String) -> String {
        term.lowercased() == defaultTerm ? fallback : term.capitalized
    }

    private static func stepsBadge(remaining: Int?, steps: Int?) -> String? {
        guard let steps else { return nil }
        let stepWord = steps == 1 ? String(localized: "~1 step") : String(localized: "~\(steps) steps")
        if let remaining {
            return String(localized: "\(stepWord) · \(remaining) left")
        }
        return stepWord
    }

    private static func activeDetail(session: BisectSession) -> String? {
        let skipped = session.skippedCommitIDs.count
        guard skipped > 0 else { return nil }
        return String(localized: "\(skipped) skipped")
    }
}

/// Coordinates visual `git bisect` state transitions and actions on the main actor.
@MainActor
final class BisectPresenter {
    struct Operations: Sendable {
        var readState: @Sendable () async throws -> BisectState
        var start: @Sendable (String, String) async throws -> BisectState
        var markGood: @Sendable () async throws -> BisectState
        var markBad: @Sendable () async throws -> BisectState
        var skip: @Sendable () async throws -> BisectState
        var reset: @Sendable () async throws -> BisectState

        init(
            readState: @escaping @Sendable () async throws -> BisectState,
            start: @escaping @Sendable (String, String) async throws -> BisectState,
            markGood: @escaping @Sendable () async throws -> BisectState,
            markBad: @escaping @Sendable () async throws -> BisectState,
            skip: @escaping @Sendable () async throws -> BisectState,
            reset: @escaping @Sendable () async throws -> BisectState
        ) {
            self.readState = readState
            self.start = start
            self.markGood = markGood
            self.markBad = markBad
            self.skip = skip
            self.reset = reset
        }

        static func live(_ service: GitService, gitDirectory: URL? = nil) -> Self {
            Self(
                readState: { try await service.bisectState(gitDirectory: gitDirectory) },
                start: { bad, good in try await service.bisectStart(bad: bad, good: good) },
                markGood: { try await service.bisectGood() },
                markBad: { try await service.bisectBad() },
                skip: { try await service.bisectSkip() },
                reset: { try await service.bisectReset() }
            )
        }
    }

    private(set) var state: BisectState = .inactive
    private(set) var action: BisectActionState = .idle
    var onChange: ((BisectBannerModel) -> Void)?
    var onRepositoryMutated: (() -> Void)?
    var onOpenCommit: ((String) -> Void)?

    private let operations: Operations
    private let refreshTask = LatestTask()
    private var pendingRefresh = false

    convenience init(service: GitService, gitDirectory: URL? = nil) {
        self.init(operations: .live(service, gitDirectory: gitDirectory))
    }

    init(operations: Operations) {
        self.operations = operations
    }

    var bannerModel: BisectBannerModel {
        BisectBannerModel(state: state, action: action)
    }

    /// Reads current bisect state. If a mutation is in flight, coalesces the refresh to run once the step finishes.
    func refresh() {
        guard !action.isBusy else {
            pendingRefresh = true
            return
        }
        startRefresh(preservingFailure: false)
    }

    func start(bad: String, good: String) async throws {
        try await performMutation(title: String(localized: "Starting bisect…")) { [operations] in
            try await operations.start(bad, good)
        }
    }

    func markGood() {
        runInteractiveStep(title: String(localized: "Marking good…")) { [operations] in
            try await operations.markGood()
        }
    }

    func markBad() {
        runInteractiveStep(title: String(localized: "Marking bad…")) { [operations] in
            try await operations.markBad()
        }
    }

    func skip() {
        runInteractiveStep(title: String(localized: "Skipping commit…")) { [operations] in
            try await operations.skip()
        }
    }

    func reset() {
        runInteractiveStep(title: String(localized: "Resetting bisect…")) { [operations] in
            try await operations.reset()
        }
    }

    func openCulpritCommit() {
        guard let commitID = state.culprit?.commitID else { return }
        onOpenCommit?(commitID)
    }

    func cancelReads() {
        refreshTask.cancel()
        pendingRefresh = false
    }

    private func startRefresh(preservingFailure: Bool) {
        refreshTask.run(
            { [operations] in try await operations.readState() },
            then: { [weak self] result in
                guard let self, !self.action.isBusy else { return }
                switch result {
                case .success(let next):
                    let changed = next != self.state
                    self.state = next
                    if !preservingFailure, changed, case .failed = self.action {
                        self.action = .idle
                    }
                case .failure(let error):
                    if !preservingFailure {
                        self.action = .failed(error.localizedDescription)
                    }
                }
                self.notify()
            }
        )
    }

    private func runInteractiveStep(title: String, work: @escaping @Sendable () async throws -> BisectState) {
        guard !action.isBusy else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = try? await self.performMutation(title: title, work: work)
        }
    }

    @discardableResult
    private func performMutation(
        title: String, work: @escaping @Sendable () async throws -> BisectState
    ) async throws -> BisectState {
        guard !action.isBusy else { return state }
        refreshTask.cancel()
        pendingRefresh = false
        action = .running(title)
        notify()
        do {
            let next = try await work()
            state = next
            action = .idle
            notify()
            onRepositoryMutated?()
            if pendingRefresh {
                pendingRefresh = false
                startRefresh(preservingFailure: false)
            }
            return next
        } catch {
            if let synced = try? await operations.readState() {
                state = synced
            }
            action = .failed(error.localizedDescription)
            notify()
            if pendingRefresh {
                pendingRefresh = false
                startRefresh(preservingFailure: true)
            }
            throw error
        }
    }

    private func notify() {
        onChange?(bannerModel)
    }
}
