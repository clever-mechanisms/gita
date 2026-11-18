import Foundation

/// Squash merges, found by content: a branch that was never merged, whose combined change since it left a main line
/// (`git diff-tree <merge-base> <tip>`) leaves the same files with the same content as one later commit on that main
/// line (`git merge --squash`, GitHub's "Squash and merge", or a cherry-picked one-commit branch).
///
/// Nearly the same counts too: a branch squashed after another one that also edited a shared file (an `AGENTS.md`, a
/// changelog), or tidied while merging, leaves a few files different. At least `minimumOverlap` of the files either
/// side changed must come out identical, two at the least, so a small change still has to match exactly.
///
/// Read-only. The history graph uses the result to draw the branch joining its squash commit, like a merge, without
/// changing any commit's real parents.
enum SquashMerges {
    /// Most recently committed unmerged branches checked per main line, and main-line commits searched.
    static let branchLimit = 60
    static let mainLineLimit = 500
    /// Share of the changed files (either side) that must come out identical for a near match.
    static let minimumOverlap = 0.75

    /// What a commit (or a range) leaves behind, independent of where it started: per path its new mode, new object
    /// and status letter ("100644 <new> M\tpath"). Two changes with the same entries produce the same files.
    static func entries(rawLines text: Substring) -> [String] {
        var entries: [String] = []
        for line in text.split(separator: "\n") where line.first == ":" {
            // ":100644 100644 <old> <new> M\tpath" → "100644 <new> M\tpath"
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let fields = line[line.index(after: line.startIndex)..<tab].split(separator: " ")
            guard fields.count >= 5 else { continue }
            entries.append(String(fields[1] + " " + fields[3] + " " + fields[4].prefix(1) + line[tab...]))
        }
        return entries
    }

    /// A main line's recent commits (newest first) and what each leaves behind, indexed for matching.
    struct MainLine {
        private(set) var ids: [String] = []
        private var pathCounts: [Int] = []
        private var byEntry: [String: [Int]] = [:]
        private var byPath: [String: [Int]] = [:]

        /// `git log --format=%x01%H --raw` output, newest first.
        init(log text: String) {
            for chunk in text.split(separator: "\u{1}") {
                let id = chunk.prefix { $0.isHexDigit }
                guard id.count >= 40 else { continue }
                let entries = Set(SquashMerges.entries(rawLines: chunk.dropFirst(id.count)))
                guard !entries.isEmpty else { continue }
                let index = ids.count
                ids.append(String(id))
                pathCounts.append(entries.count)
                for entry in entries {
                    byEntry[entry, default: []].append(index)
                    byPath[Self.path(entry), default: []].append(index)
                }
            }
        }
        var isEmpty: Bool { ids.isEmpty }
        private static func path(_ entry: String) -> String {
            entry.firstIndex(of: "\t").map { String(entry[$0...]) } ?? entry
        }

        /// The commit that squashed a branch's change: newer than `fork` (when the fork is on this line), not in
        /// `taken`, sharing the most identical files; an exact match always wins, the newest on a tie.
        func squash(of change: [String], fork: String, taken: Set<String>) -> String? {
            let entries = Set(change)
            guard !entries.isEmpty else { return nil }
            let (same, shared) = counts(entries, newerThan: ids.firstIndex(of: fork) ?? ids.count)
            var best: (index: Int, score: Double)?
            for (index, identical) in same where !taken.contains(ids[index]) {
                let union = entries.count + pathCounts[index] - (shared[index] ?? 0)
                let score = Double(identical) / Double(max(1, union))
                guard identical == union || (identical >= 2 && score >= SquashMerges.minimumOverlap) else { continue }
                if best.map({ score > $0.score || (score == $0.score && index < $0.index) }) ?? true {
                    best = (index, score)
                }
            }
            return best.map { ids[$0.index] }
        }

        /// Per candidate newer than `newerThan`: entries it leaves identical, and paths both sides changed.
        private func counts(_ entries: Set<String>, newerThan: Int) -> (same: [Int: Int], shared: [Int: Int]) {
            var same: [Int: Int] = [:]
            var shared: [Int: Int] = [:]
            for entry in entries {
                for index in byEntry[entry] ?? [] where index < newerThan { same[index, default: 0] += 1 }
                for index in byPath[Self.path(entry)] ?? [] where index < newerThan { shared[index, default: 0] += 1 }
            }
            return (same, shared)
        }
    }
}
