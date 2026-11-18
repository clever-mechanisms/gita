import CoreGraphics
import GitaCore

/// The remotes list and the one edit in progress (add, change URL, rename or remove), with the rules for what can be
/// applied.
struct RemoteManagementState {
    /// The latest read of the remotes. A failed read lists nothing: the list it would show is no longer known.
    enum Load: Equatable {
        /// Not read yet, or the read was stopped.
        case idle
        case loading
        case loaded
        /// The read failed with this message; only Reload clears it.
        case failed(String)
    }
    /// The edit in progress, and whether its remote vanished in the last reload.
    private struct OpenEdit {
        var edit: Edit
        var isUnavailable = false
    }
    enum Edit {
        case add
        case url(GitRemoteDetails)
        case rename(GitRemoteDetails)
        case remove(GitRemoteDetails)
        var remote: GitRemoteDetails? {
            switch self {
            case .add: nil
            case .url(let remote), .rename(let remote), .remove(let remote): remote
            }
        }
        func with(_ remote: GitRemoteDetails) -> Self {
            switch self {
            case .add: .add
            case .url: .url(remote)
            case .rename: .rename(remote)
            case .remove: .remove(remote)
            }
        }
    }
    /// Which toolbar buttons can act on the selection.
    struct Toolbar: Equatable {
        var add = false
        var edit = false
        var rename = false
        var remove = false
        var fetch = false
    }
    /// The edit form's title, fields and Save button.
    struct Form: Equatable {
        var title: String
        var showsName: Bool
        var showsURL: Bool
        var applyTitle: String
        var isDestructive: Bool
    }
    private enum Metrics {
        static let rowHeight: CGFloat = 25
        static let headerHeight: CGFloat = 28
        static let maximumVisibleRows = 5
        static let minimumListHeight: CGFloat = 53
    }

    private(set) var remotes: [GitRemoteDetails] = []
    var selectedName: String?
    private var openEdit: OpenEdit?
    private(set) var load = Load.idle
    /// The first successful read selects the first remote; later reads keep the user's selection.
    private var selectsFirstRemote = true
    /// Why the last action failed; edited input clears it.
    private(set) var actionError: String?
    var nameInput = ""
    var urlInput = ""

    var selected: GitRemoteDetails? {
        selectedName.flatMap { name in remotes.first { ReviewText.same($0.name, name) } }
    }
    var selectedRow: Int? {
        selectedName.flatMap { name in remotes.firstIndex { ReviewText.same($0.name, name) } }
    }
    var editing: Edit? { openEdit?.edit }
    var editingUnavailable: Bool { openEdit?.isUnavailable == true }
    var isEditing: Bool { openEdit != nil }
    var isLoading: Bool { load == .loading }
    var loadFailed: Bool { if case .failed = load { true } else { false } }
    /// The load error, else the action error.
    var errorMessage: String? {
        if case .failed(let message) = load { return message }
        return actionError
    }
    private var isAdding: Bool { if case .add = editing { true } else { false } }
    private var canMutateSelection: Bool { selected != nil && selected?.mutationRestriction == nil }

    func isReady(_ activity: SheetActivity) -> Bool { activity.isActive && load == .loaded }
    func canChangeSelection(_ activity: SheetActivity) -> Bool {
        !activity.isApplying && !isLoading && editing == nil
    }
    func toolbar(_ activity: SheetActivity) -> Toolbar {
        guard isReady(activity), editing == nil else { return Toolbar() }
        return Toolbar(
            add: true, edit: canMutateSelection && selected?.editableURL != nil, rename: canMutateSelection,
            remove: canMutateSelection, fetch: selected != nil)
    }
    var emptyText: String {
        switch load {
        case .idle: ""
        case .loading: String(localized: "Loading…")
        case .loaded: String(localized: "No remotes")
        case .failed: String(localized: "Unavailable")
        }
    }
    /// The list shows up to five rows before it scrolls.
    var listPreferredHeight: CGFloat {
        CGFloat(min(max(remotes.count, 1), Metrics.maximumVisibleRows)) * Metrics.rowHeight + Metrics.headerHeight
    }
    var listMinimumHeight: CGFloat { Metrics.minimumListHeight }
    /// The push URLs, when they differ from the fetch URLs.
    var pushText: String? {
        guard let remote = selected, !isAdding else { return nil }
        let differs =
            remote.pushURLs.count != remote.fetchURLs.count
            || !zip(remote.pushURLs, remote.fetchURLs).allSatisfy { ReviewText.same($0.0, $0.1) }
        guard differs else { return nil }
        return String(localized: "Push: \(Self.urls(remote.pushURLs))")
    }
    /// Why the selection cannot be changed, if it cannot.
    var restriction: String? {
        guard !isAdding else { return nil }
        if editingUnavailable { return String(localized: "The selected remote is no longer available.") }
        guard let remote = selected else { return nil }
        if let restriction = remote.mutationRestriction { return restriction.isEmpty ? nil : restriction }
        return remote.editableURL == nil ? String(localized: "This fetch URL configuration is read-only.") : nil
    }
    var form: Form? {
        switch editing {
        case .add:
            Form(
                title: String(localized: "Add Remote"), showsName: true, showsURL: true,
                applyTitle: String(localized: "Add"), isDestructive: false)
        case .url(let remote):
            Form(
                title: String(localized: "URL for “\(remote.name)”"), showsName: false, showsURL: true,
                applyTitle: String(localized: "Save"), isDestructive: false)
        case .rename(let remote):
            Form(
                title: String(localized: "Rename “\(remote.name)”"), showsName: true, showsURL: false,
                applyTitle: String(localized: "Rename"), isDestructive: false)
        case .remove(let remote):
            Form(
                title: String(localized: "Remove “\(remote.name)” and its local tracking references?"),
                showsName: false, showsURL: false, applyTitle: String(localized: "Remove \(remote.name)"),
                isDestructive: true)
        case nil: nil
        }
    }
    func pendingAction(_ activity: SheetActivity) -> RemoteManagementAction? {
        guard isReady(activity), !editingUnavailable, let editing else { return nil }
        switch editing {
        case .add:
            guard !nameInput.isEmpty, !urlInput.isEmpty else { return nil }
            return .add(name: nameInput, url: urlInput)
        case .url(let remote):
            guard remote.mutationRestriction == nil, let original = remote.editableURL, !urlInput.isEmpty,
                !ReviewText.same(original, urlInput)
            else { return nil }
            return .setURL(remote, urlInput)
        case .rename(let remote):
            guard remote.mutationRestriction == nil, !nameInput.isEmpty, !ReviewText.same(remote.name, nameInput)
            else { return nil }
            return .rename(remote, nameInput)
        case .remove(let remote): return remote.mutationRestriction == nil ? .remove(remote) : nil
        }
    }
    func status(_ activity: SheetActivity) -> SheetStatus {
        let message =
            activity.isApplying
            ? (activity.refusedClose
                ? String(localized: "Wait for this action to finish.") : String(localized: "Applying…"))
            : errorMessage ?? (isLoading ? String(localized: "Loading remotes…") : "")
        return SheetStatus(
            message: message, isBusy: isLoading || activity.isApplying,
            isError: errorMessage != nil && !activity.isApplying)
    }
    static func urls(_ values: [String]) -> String {
        values.isEmpty ? String(localized: "Not configured") : values.joined(separator: " · ")
    }

    // MARK: Changes

    mutating func beginLoad() {
        load = .loading
        actionError = nil
    }
    mutating func cancelLoad() {
        if load == .loading { load = .idle }
    }
    /// Takes the read remotes. A failure clears the list rather than leave remotes listed that cannot be acted on;
    /// the selection's name is kept for the next successful read.
    mutating func finishLoad(_ result: Result<[GitRemoteDetails], any Error>) {
        switch result {
        case .success(let next):
            if selectsFirstRemote, selectedName == nil { selectedName = next.first?.name }
            selectsFirstRemote = false
            load = .loaded
            remotes = next
            refreshEdit()
        case .failure(let error):
            load = .failed(ReviewText.message(error))
            remotes = []
        }
    }
    /// The edit follows the reloaded remote of the same name, or is marked unavailable when it is gone.
    private mutating func refreshEdit() {
        guard var open = openEdit else { return }
        open.isUnavailable = false
        if let expected = open.edit.remote {
            if let current = remotes.first(where: { ReviewText.same($0.name, expected.name) }) {
                open.edit = open.edit.with(current)
            } else {
                open.isUnavailable = true
            }
        }
        openEdit = open
    }
    /// Starts an edit; returns false when the sheet cannot edit now.
    mutating func begin(_ edit: Edit, activity: SheetActivity) -> Bool {
        guard activity.isActive, load != .loading, !loadFailed, openEdit == nil else { return false }
        openEdit = OpenEdit(edit: edit)
        actionError = nil
        nameInput = edit.remote?.name ?? ""
        urlInput = edit.remote?.editableURL ?? ""
        return true
    }
    mutating func cancelEdit() {
        openEdit = nil
        clearInputError()
    }
    /// Edited input clears an action error, not a load error (that one needs Reload).
    mutating func clearInputError() { actionError = nil }
    mutating func beginApply() { actionError = nil }
    mutating func applied(_ action: RemoteManagementAction) {
        switch action {
        case .add(let name, _), .rename(_, let name): selectedName = name
        case .remove: selectedName = nil
        case .setURL(let remote, _), .fetch(let remote): selectedName = remote.name
        }
        openEdit = nil
    }
    mutating func applyFailed(_ error: any Error) { actionError = ReviewText.message(error) }
}
