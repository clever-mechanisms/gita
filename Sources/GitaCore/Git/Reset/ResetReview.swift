import Foundation

/// Everything a reset is checked against at the moment it runs.
struct ResetReview {
    var preview: GitResetPreview
    var options: [String]
    var index: [String: TreeEntries.Entry]
    var target: [String: TreeEntries.Entry]
    var otherPaths: [String]
    var status: Data
    var caseSensitive: Bool
}

/// HEAD, its branch, replacement refs and the index file, compared before and after a review is read.
struct ResetState: Equatable {
    var head: Data
    var headID: String
    var symbolic: Data
    var branch: String?
    var replacements: Data
    var index: Data

    func add(to identity: inout Fingerprint) {
        identity.add("head", head)
        identity.add("branch", symbolic)
        identity.add("index", index)
        identity.add("replacements", replacements)
    }
}

/// The index, both trees, status and the untracked/ignored listing of one review.
struct ResetInputs {
    var sharedIndex: Data
    var staged: Data
    var targetTree: Data
    var status: Data
    var other: Data
    var index: [String: TreeEntries.Entry]
    var target: [String: TreeEntries.Entry]
    var otherPaths: [String]
    /// HEAD's and the index's paths: the working files a reset can overwrite.
    var trackedPaths: [String]

    init(sharedIndex: Data, staged: Data, headTree: Data, targetTree: Data, status: Data, other: Data) throws {
        self.sharedIndex = sharedIndex
        self.staged = staged
        self.targetTree = targetTree
        self.status = status
        self.other = other
        index = try TreeEntries.parse(staged, index: true)
        target = try TreeEntries.parse(targetTree, index: false)
        let head = try TreeEntries.parse(headTree, index: false)
        otherPaths = try TreeEntries.otherPaths(other)
        trackedPaths = Set(head.keys).union(index.keys).sorted()
    }

    func add(to identity: inout Fingerprint) {
        identity.add("shared-index", sharedIndex)
        identity.add("stages", staged)
        identity.add("status", status)
        identity.add("untracked", other)
        identity.add("target-tree", targetTree)
    }
}
