import GitaCore

/// The reference review: which reference the request names, its loaded details (and the chosen upstream's), the
/// inputs, and what can be applied. Pure; the controller binds it to the pickers and fields.
struct ReferenceReviewState {
    enum UpstreamChoice: Equatable {
        case none
        case reference(String)
        case unavailable
    }
    /// What failed, with the message the status shows. Edits clear only an apply failure; a failed read needs Reload.
    struct Failure: Equatable {
        enum Kind { case source, upstream, apply }
        var kind: Kind
        var message: String
    }
    /// The one read in flight: the selected reference, then (when tracking) the chosen upstream.
    enum Read: Equatable {
        case idle
        case source
        case upstream
    }
    /// One picker item: a reference, "No upstream", or a placeholder that cannot be applied.
    struct Choice: Equatable {
        var title: String
        var fullName: String?
        var isNone = false
    }

    private static let branchPrefix = "refs/heads/"
    let request: ReferenceReviewRequest
    let references: [GitReference]
    let hasRemotes: Bool
    private(set) var sourceChoices: [Choice] = []
    private(set) var sourceIndex = 0
    private(set) var upstreamChoices: [Choice] = []
    private(set) var upstreamIndex = 0
    private(set) var selectedSource: String?
    private(set) var sourceDetails: GitReferenceDetails?
    private(set) var upstreamDetails: GitReferenceDetails?
    private(set) var read = Read.idle
    private(set) var failure: Failure?
    private(set) var name = ""
    private(set) var annotation = ""
    private(set) var pushToAllRemotes = false
    private(set) var deleteFromAllRemotes = false
    private var nameWasEdited = false
    private var upstreamWasEdited = false

    init(request: ReferenceReviewRequest, references: [GitReference], hasRemotes: Bool = false) {
        self.request = request
        self.references = references
        self.hasRemotes = hasRemotes
        configureSource()
    }

    // MARK: The request

    var title: String {
        switch request {
        case .renameBranch: String(localized: "Rename Branch")
        case .deleteBranch: String(localized: "Delete Branch")
        case .setUpstream: String(localized: "Set Upstream")
        case .createTag: String(localized: "Create Tag")
        case .deleteTag: String(localized: "Delete Tag")
        }
    }
    var applyTitle: String {
        switch request {
        case .renameBranch: String(localized: "Rename")
        case .deleteBranch: String(localized: "Delete Local Branch")
        case .deleteTag: String(localized: "Delete Local Tag")
        case .setUpstream: upstreamChoice == .none ? String(localized: "Unset Upstream") : title
        case .createTag: title
        }
    }
    var isRenaming: Bool { if case .renameBranch = request { true } else { false } }
    var isCreatingTag: Bool { if case .createTag = request { true } else { false } }
    var isDeletingTag: Bool { if case .deleteTag = request { true } else { false } }
    var isTracking: Bool { if case .setUpstream = request { true } else { false } }
    var sourceLoading: Bool { read == .source }
    var upstreamLoading: Bool { read == .upstream }
    var errorMessage: String? { failure?.message }
    /// Deleting a branch or tag: the button never answers Return, Cancel does.
    var isDestructive: Bool {
        switch request {
        case .deleteBranch, .deleteTag: true
        default: false
        }
    }
    /// No name was given: the sheet offers the branches or tags to choose from.
    var needsSourcePicker: Bool {
        switch request {
        case .deleteBranch(nil), .deleteTag(nil): true
        default: false
        }
    }
    var sourceKind: GitReference.Kind { if case .deleteTag = request { .tag } else { .branch } }
    var upstreamChoice: UpstreamChoice {
        guard upstreamChoices.indices.contains(upstreamIndex) else { return .unavailable }
        let choice = upstreamChoices[upstreamIndex]
        if choice.isNone { return .none }
        return choice.fullName.map(UpstreamChoice.reference) ?? .unavailable
    }

    // MARK: Choices

    private mutating func configureSource() {
        guard !isCreatingTag else { return }
        let preferred: String?
        switch request {
        case .renameBranch(let name), .setUpstream(let name):
            preferred = name ?? references.first { $0.kind == .branch && $0.isCurrent }?.fullName
        case .deleteBranch(let name), .deleteTag(let name): preferred = name
        case .createTag: preferred = nil
        }
        guard needsSourcePicker else {
            selectedSource = preferred
            populateName()
            return
        }
        let placeholder =
            sourceKind == .tag ? String(localized: "Choose a tag") : String(localized: "Choose a branch")
        sourceChoices =
            [Choice(title: placeholder)]
            + references.filter { $0.kind == sourceKind }.map { Choice(title: $0.name, fullName: $0.fullName) }
        sourceIndex = 0
        guard let preferred else { return }
        sourceIndex = Self.index(of: preferred, in: &sourceChoices)
        selectedSource = preferred
        populateName()
    }
    /// The choice for `fullName`, added at the end when the list does not have it.
    private static func index(of fullName: String, in choices: inout [Choice]) -> Int {
        if let index = choices.firstIndex(where: { $0.fullName.map { ReviewText.same($0, fullName) } ?? false }) {
            return index
        }
        choices.append(Choice(title: fullName, fullName: fullName))
        return choices.count - 1
    }
    private mutating func populateName() {
        guard isRenaming, !nameWasEdited, let selectedSource else { return }
        name =
            sourceDetails?.reference.name ?? references.first { ReviewText.same($0.fullName, selectedSource) }?.name
            ?? (selectedSource.hasPrefix(Self.branchPrefix)
                ? String(selectedSource.dropFirst(Self.branchPrefix.count)) : selectedSource)
    }
    private mutating func configureUpstream() {
        let preserved = upstreamWasEdited ? upstreamChoice : nil
        upstreamChoices =
            [Choice(title: String(localized: "No upstream"), isNone: true)]
            + references.filter { $0.kind == .branch || $0.kind == .remote }.map { reference in
                let kind = reference.kind == .remote ? String(localized: "Remote") : String(localized: "Local")
                return Choice(title: kind + " · " + reference.name, fullName: reference.fullName)
            }
        let choice: UpstreamChoice
        if let preserved {
            choice = preserved
        } else if let upstream = sourceDetails?.upstream {
            choice = upstream.fullName.map(UpstreamChoice.reference) ?? .unavailable
        } else {
            choice = .none
        }
        switch choice {
        case .none: upstreamIndex = 0
        case .reference(let fullName): upstreamIndex = Self.index(of: fullName, in: &upstreamChoices)
        case .unavailable:
            upstreamChoices.append(Choice(title: String(localized: "Configured upstream unavailable")))
            upstreamIndex = upstreamChoices.count - 1
        }
    }

    // MARK: Input

    mutating func chooseSource(at index: Int) {
        guard sourceChoices.indices.contains(index) else { return }
        sourceIndex = index
        selectedSource = sourceChoices[index].fullName
        sourceDetails = nil
        upstreamWasEdited = false
        upstreamChoices = [Choice(title: String(localized: "Not loaded"))]
        upstreamIndex = 0
        populateName()
    }
    mutating func chooseUpstream(at index: Int) {
        guard upstreamChoices.indices.contains(index) else { return }
        upstreamIndex = index
        upstreamWasEdited = true
    }
    mutating func editName(_ value: String) {
        nameWasEdited = true
        name = value
        editedInput()
    }
    mutating func editAnnotation(_ value: String) {
        annotation = value
        editedInput()
    }
    mutating func setPushToAllRemotes(_ value: Bool) {
        pushToAllRemotes = isCreatingTag && hasRemotes && value
        editedInput()
    }
    mutating func setDeleteFromAllRemotes(_ value: Bool) {
        deleteFromAllRemotes = isDeletingTag && hasRemotes && value
        editedInput()
    }
    /// Edited input clears an apply error (the edit may fix it), not a failed read.
    private mutating func editedInput() { if failure?.kind == .apply { failure = nil } }

    // MARK: Loading

    /// Starts reading the selected reference; returns its full name, or nil when there is nothing to read.
    mutating func beginSourceLoad() -> String? {
        sourceDetails = nil
        upstreamDetails = nil
        failure = nil
        read = .idle
        guard !isCreatingTag, let selectedSource else { return nil }
        read = .source
        return selectedSource
    }
    /// Takes the read details; returns true when the upstream should be read next.
    mutating func finishSourceLoad(_ result: Result<GitReferenceDetails, any Error>, expected: String) -> Bool {
        read = .idle
        switch result {
        case .success(let details)
        where ReviewText.same(details.reference.fullName, expected) && details.reference.kind == sourceKind:
            sourceDetails = details
            populateName()
            guard isTracking else { return false }
            configureUpstream()
            return true
        case .success:
            fail(String(localized: "The selected reference is unavailable or has a different type."), as: .source)
        case .failure(let error): fail(error.localizedDescription, as: .source)
        }
        return false
    }
    /// Starts reading the chosen upstream; returns its full name, or nil when there is nothing to read.
    mutating func beginUpstreamLoad() -> String? {
        if read == .upstream { read = .idle }
        upstreamDetails = nil
        failure = nil
        guard sourceDetails != nil else { return nil }
        switch upstreamChoice {
        case .none: return nil
        case .unavailable:
            fail(String(localized: "Choose an upstream branch or No upstream."), as: .upstream)
            return nil
        case .reference(let fullName):
            read = .upstream
            return fullName
        }
    }
    mutating func finishUpstreamLoad(_ result: Result<GitReferenceDetails, any Error>, expected: String) {
        read = .idle
        switch result {
        case .success(let details) where isUpstream(details, expected: expected): upstreamDetails = details
        case .success:
            fail(String(localized: "The selected upstream is unavailable or has a different type."), as: .upstream)
        case .failure(let error): fail(error.localizedDescription, as: .upstream)
        }
    }
    private func isUpstream(_ details: GitReferenceDetails, expected: String) -> Bool {
        guard let sourceDetails else { return false }
        return ReviewText.same(details.reference.fullName, expected)
            && (details.reference.kind == .branch || details.reference.kind == .remote)
            && ReviewText.same(details.root.path, sourceDetails.root.path)
    }
    mutating func cancelLoads() { read = .idle }
    mutating func beginApply() { failure = nil }
    mutating func applyFailed(_ error: any Error) { fail(error.localizedDescription, as: .apply) }
    private mutating func fail(_ text: String, as kind: Failure.Kind) {
        failure = Failure(kind: kind, message: ReviewText.clipped(text))
    }
}
