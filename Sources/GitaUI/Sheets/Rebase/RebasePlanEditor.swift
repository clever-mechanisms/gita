import Foundation
import GitaCore

/// The interactive rebase plan being edited: the reviewed range, the replay order and actions, and the complete
/// replacement messages of reworded commits. Pure; the controller shows it and forwards edits.
struct RebasePlanEditor {
    static let messageLimit = 64 * 1_024
    static let totalMessageLimit = 1_024 * 1_024
    static let maximumCommits = 500
    private static let shortIDLength = 10

    private(set) var plan: GitInteractiveRebasePlan?
    private(set) var steps: [GitRebaseStep] = []
    private(set) var commits: [String: GitCommit] = [:]
    /// Messages as read from the repository, by commit.
    private(set) var originals: [String: String] = [:]
    /// Edited messages that differ from the originals.
    private(set) var drafts: [String: String] = [:]
    /// Why a message could not be read, by commit.
    private(set) var messageErrors: [String: String] = [:]

    var orderChanged: Bool { steps.map(\.commitID) != plan?.commits.map(\.id) }
    var hasPlanChanges: Bool { orderChanged || steps.contains { $0.action != .pick } }
    var isDirty: Bool { plan != nil && (hasPlanChanges || !drafts.isEmpty) }
    var dropCount: Int { steps.filter { $0.action == .drop }.count }
    func message(for id: String) -> String? { drafts[id] ?? originals[id] }
    func index(of id: String) -> Int? { steps.firstIndex { $0.commitID == id } }
    func step(_ id: String) -> GitRebaseStep? { index(of: id).map { steps[$0] } }
    func needsMessage(_ id: String) -> Bool {
        steps.contains { $0.commitID == id && $0.action == .reword } && originals[id] == nil && drafts[id] == nil
    }

    /// A reviewed range the editor accepts: after `baseID`, ending at HEAD, non-empty, bounded and without repeats.
    static func accepts(_ plan: GitInteractiveRebasePlan, baseID: String) -> Bool {
        ReviewText.same(plan.base.id, baseID) && !plan.commits.isEmpty && plan.commits.count <= maximumCommits
            && plan.commits.allSatisfy { ReviewText.isFullObjectID($0.id) && $0.id != baseID }
            && plan.commits.last?.id == plan.headID && Set(plan.commits.map(\.id)).count == plan.commits.count
    }

    /// Starts over from a freshly read plan; messages already read for its commits are kept.
    mutating func load(_ next: GitInteractiveRebasePlan) {
        plan = next
        steps = next.commits.map { GitRebaseStep(commitID: $0.id) }
        commits = Dictionary(uniqueKeysWithValues: next.commits.map { ($0.id, $0) })
        originals = originals.filter { commits[$0.key] != nil }
        drafts.removeAll()
        messageErrors.removeAll()
    }
    mutating func move(from source: Int, to destination: Int) -> Bool {
        guard steps.indices.contains(source), steps.indices.contains(destination), source != destination else {
            return false
        }
        steps.insert(steps.remove(at: source), at: destination)
        return true
    }
    mutating func setAction(_ action: GitRebaseAction, for id: String) -> Bool {
        guard let row = index(of: id) else { return false }
        steps[row].action = action
        return true
    }
    /// An edit equal to the original message is no draft.
    mutating func setDraft(_ value: String, for id: String) {
        drafts[id] = originals[id].map { ReviewText.same($0, value) } == true ? nil : value
    }
    /// Takes a read message, or records why it cannot be edited.
    mutating func messageLoaded(_ result: Result<String, any Error>, for id: String) {
        switch result {
        case .success(let value) where value.utf8.prefix(Self.messageLimit + 1).count > Self.messageLimit:
            messageErrors[id] = String(localized: "The complete message exceeds 64 KiB.")
        case .success(let value) where value.utf8.contains(0):
            messageErrors[id] = String(localized: "The commit message contains an unsupported NUL character.")
        case .success(let value):
            originals[id] = value
            messageErrors[id] = nil
        case .failure(let error):
            messageErrors[id] = ReviewText.message(error)
        }
    }
    mutating func clearMessageError(_ id: String) { messageErrors[id] = nil }

    /// Whether replacing `range` of `current` with `replacement` keeps the message within the limits.
    static func acceptsEdit(of current: String, range: NSRange, replacement: String) -> Bool {
        guard replacement.utf8.prefix(messageLimit + 1).count <= messageLimit, !replacement.utf8.contains(0),
            let bounds = Range(range, in: current)
        else { return false }
        return current.replacingCharacters(in: bounds, with: replacement).utf8.count <= messageLimit
    }

    /// Why the plan cannot be applied yet; nil when it can.
    var validation: String? {
        guard plan != nil, !steps.isEmpty else { return String(localized: "No commits to replay.") }
        var retained = false
        var totalBytes = 0
        for step in steps where step.action != .drop {
            if (step.action == .squash || step.action == .fixup) && !retained {
                return String(localized: "The first retained commit cannot be Squash or Fixup.")
            }
            retained = true
            guard step.action == .reword else { continue }
            if let problem = messageProblem(step.commitID) { return problem }
            totalBytes += message(for: step.commitID)?.utf8.count ?? 0
            if totalBytes > Self.totalMessageLimit {
                return String(localized: "Combined replacement messages exceed 1 MiB.")
            }
        }
        return nil
    }
    private func messageProblem(_ id: String) -> String? {
        let short = id.prefix(Self.shortIDLength)
        guard let value = message(for: id) else {
            if let error = messageErrors[id] { return String(localized: "Message for \(short): \(error)") }
            return String(localized: "Loading the message for \(short)…")
        }
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return String(localized: "Enter a complete message for \(short).")
        }
        guard !value.utf8.contains(0), value.utf8.count <= Self.messageLimit else {
            return String(localized: "The message for \(short) must fit in 64 KiB.")
        }
        return nil
    }
    /// The steps to submit: reworded commits carry their complete message.
    var submittedSteps: [GitRebaseStep] {
        steps.map {
            GitRebaseStep(
                commitID: $0.commitID, action: $0.action,
                message: $0.action == .reword ? message(for: $0.commitID) : nil)
        }
    }
}
