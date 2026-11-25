import Foundation
import GitaCore

/// Lifecycle state for an in-flight bisect command (start, good, bad, skip, reset).
public enum BisectActionState: Sendable, Equatable {
    case idle
    case running(String)
    case failed(String)

    public var isBusy: Bool {
        if case .running = self { return true }
        return false
    }

    public var runningTitle: String? {
        if case .running(let title) = self { return title }
        return nil
    }

    public var errorMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

/// Pure presentation value driving `BisectBannerView`, testable without AppKit views.
public struct BisectBannerModel: Equatable, Sendable {
    public let isHidden: Bool
    public let isFinished: Bool
    public let isBusy: Bool
    public let title: String
    public let shortSHA: String
    public let commitSubject: String
    public let commitTooltip: String?
    public let stepsBadgeText: String?
    public let statusDetail: String?
    public let errorMessage: String?
    public let goodButtonTitle: String
    public let badButtonTitle: String
    public let showsStepActions: Bool
    public let showsOpenCommit: Bool
    public let culpritCommitID: String?
    public let canAct: Bool

    public init(state: BisectState, action: BisectActionState) {
        self.isBusy = action.isBusy
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
            self.commitTooltip = "\(culprit.commitID)\n\(culprit.subject) (\(culprit.author))"
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
public final class BisectPresenter {
    public struct Operations: Sendable {
        public var readState: @Sendable () async throws -> BisectState
        public var start: @Sendable (String, String) async throws -> BisectState
        public var markGood: @Sendable () async throws -> BisectState
        public var markBad: @Sendable () async throws -> BisectState
        public var skip: @Sendable () async throws -> BisectState
        public var reset: @Sendable () async throws -> BisectState

        public init(
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

        public static func live(_ service: GitService) -> Self {
            Self(
                readState: { try await service.bisectState() },
                start: { bad, good in try await service.bisectStart(bad: bad, good: good) },
                markGood: { try await service.bisectGood() },
                markBad: { try await service.bisectBad() },
                skip: { try await service.bisectSkip() },
                reset: { try await service.bisectReset() }
            )
        }
    }

    public private(set) var state: BisectState = .inactive
    public private(set) var action: BisectActionState = .idle
    public var onChange: ((BisectBannerModel) -> Void)?
    public var onRepositoryMutated: (() -> Void)?
    public var onOpenCommit: ((String) -> Void)?

    private let operations: Operations
    private let refreshTask = LatestTask()
    private var pendingRefresh = false

    public init(service: GitService) {
        self.operations = .live(service)
    }

    public init(operations: Operations) {
        self.operations = operations
    }

    public var bannerModel: BisectBannerModel {
        BisectBannerModel(state: state, action: action)
    }

    /// Reads current bisect state. If a mutation is in flight, coalesces the refresh to run once the step finishes.
    public func refresh() {
        guard !action.isBusy else {
            pendingRefresh = true
            return
        }
        startRefresh(preservingFailure: false)
    }

    public func start(bad: String, good: String) async throws {
        try await performMutation(title: String(localized: "Starting bisect…")) { [operations] in
            try await operations.start(bad, good)
        }
    }

    public func markGood() {
        runInteractiveStep(title: String(localized: "Marking good…")) { [operations] in
            try await operations.markGood()
        }
    }

    public func markBad() {
        runInteractiveStep(title: String(localized: "Marking bad…")) { [operations] in
            try await operations.markBad()
        }
    }

    public func skip() {
        runInteractiveStep(title: String(localized: "Skipping commit…")) { [operations] in
            try await operations.skip()
        }
    }

    public func reset() {
        runInteractiveStep(title: String(localized: "Resetting bisect…")) { [operations] in
            try await operations.reset()
        }
    }

    public func openCulpritCommit() {
        guard let commitID = state.culprit?.commitID else { return }
        onOpenCommit?(commitID)
    }

    public func cancelReads() {
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
