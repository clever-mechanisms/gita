import Foundation

/// The checks Git's own hard reset skips: an untracked or ignored path it would overwrite (or that sits where a
/// tracked directory must go), a submodule with local changes, and a submodule appearing or disappearing.
struct HardResetSafety {
    private let review: ResetReview

    init(review: ResetReview) { self.review = review }

    func check() throws {
        try checkUntrackedObstructions()
        try checkDirtySubmodules()
        try checkSubmoduleTransitions()
    }

    /// How the volume compares names: Unicode-normalized, and case-folded unless it is case-sensitive.
    func filesystemName(_ path: String) -> String {
        let normalized = path.precomposedStringWithCanonicalMapping
        return review.caseSensitive
            ? normalized : normalized.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    private func checkUntrackedObstructions() throws {
        let protected = Set(review.index.keys.map(filesystemName)).union(review.target.keys.map(filesystemName))
        let sorted = protected.sorted()
        for raw in review.otherPaths {
            let path = filesystemName(raw.hasSuffix("/") ? String(raw.dropLast()) : raw)
            guard !Self.isObstructed(path, protected: protected, sorted: sorted) else {
                throw ResetError.untrackedOverwritten
            }
        }
    }

    /// The path itself, one of its ancestors, or anything below it is tracked.
    static func isObstructed(_ path: String, protected: Set<String>, sorted: [String]) -> Bool {
        if protected.contains(path) { return true }
        var ancestor = path
        while let slash = ancestor.lastIndex(of: "/") {
            ancestor = String(ancestor[..<slash])
            if protected.contains(ancestor) { return true }
        }
        let prefix = path + "/"
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if sorted[mid] < prefix { low = mid + 1 } else { high = mid }
        }
        return low < sorted.count && sorted[low].hasPrefix(prefix)
    }

    /// Porcelain v2 `1`/`2` records carry a submodule state field `S<c><m><u>`; anything but `S...` is dirty.
    private func checkDirtySubmodules() throws {
        for record in review.status.split(separator: GitOutput.nul)
        where record.starts(with: Data("1 ".utf8)) || record.starts(with: Data("2 ".utf8)) {
            let fields = record.split(separator: UInt8(ascii: " "), maxSplits: 3)
            if fields.count > 2, fields[2].first == UInt8(ascii: "S"), !fields[2].elementsEqual(Data("S...".utf8)) {
                throw ResetError.submoduleChanges
            }
        }
    }

    private func checkSubmoduleTransitions() throws {
        let submodules = Set(review.index.filter { $0.value.mode == .submodule }.keys).union(
            review.target.filter { $0.value.mode == .submodule }.keys)
        guard
            submodules.allSatisfy({
                review.index[$0]?.mode == .submodule && review.target[$0]?.mode == .submodule
            })
        else {
            throw ResetError.submodulePathsChange
        }
    }
}
