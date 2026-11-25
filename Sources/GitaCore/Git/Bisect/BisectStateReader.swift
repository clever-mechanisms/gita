import Foundation

/// Reads `.git/BISECT_START`, `BISECT_LOG`, `BISECT_TERMS`, and `refs/bisect/*` metadata from a `.git` directory.
public enum BisectStateReader {
    /// Raw bisect metadata read from `.git`.
    public struct RawSnapshot: Sendable, Equatable {
        public let startBranch: String
        public let badTerm: String
        public let goodTerm: String
        public let badCommitID: String?
        public let goodCommitIDs: Set<String>
        public let skippedCommitIDs: Set<String>
        public let culpritCommitID: String?
        public let culpritSubject: String?
        public let identity: String
    }

    /// Reads bisect metadata from `gitDirectory`. Optional `bisectRefs` (from `git for-each-ref refs/bisect/`)
    /// merges with loose files in `.git/refs/bisect/` so packed refs are also observed.
    public static func read(
        gitDirectory: URL,
        head: String?,
        bisectRefs: [String: String] = [:]
    ) throws -> RawSnapshot? {
        guard let startFile = try BoundedFile.read(gitDirectory.appendingPathComponent("BISECT_START")) else {
            return nil
        }
        let startBranch = String(decoding: startFile.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let logFile = try BoundedFile.read(gitDirectory.appendingPathComponent("BISECT_LOG"))
        let logText = logFile.map { String(decoding: $0.data, as: UTF8.self) } ?? ""
        let logLines = GitOutput.lines(logText)
        let termsFile = try BoundedFile.read(gitDirectory.appendingPathComponent("BISECT_TERMS"))
        let terms = parseTerms(from: termsFile?.data)
        let refs = mergedRefs(gitDirectory: gitDirectory, provided: bisectRefs)

        let classified = classifyRefs(refs, badTerm: terms.bad, goodTerm: terms.good)
        let culprit = parseCulprit(from: logLines, badTerm: terms.bad)
        var fingerprint = Fingerprint()
        fingerprint.add("start", startFile.identity)
        fingerprint.add("head", head ?? "unborn")
        if let logFile { fingerprint.add("log", logFile.identity) }
        if let termsFile { fingerprint.add("terms", termsFile.identity) }
        for key in refs.keys.sorted() {
            fingerprint.add(key, refs[key] ?? "")
        }

        return RawSnapshot(
            startBranch: startBranch,
            badTerm: terms.bad,
            goodTerm: terms.good,
            badCommitID: classified.bad,
            goodCommitIDs: classified.good,
            skippedCommitIDs: classified.skipped,
            culpritCommitID: culprit?.commitID,
            culpritSubject: culprit?.subject,
            identity: fingerprint.hex
        )
    }

    /// Parses `.git/BISECT_TERMS` (line 1 = bad/new term, line 2 = good/old term); defaults to `("bad", "good")`.
    public static func parseTerms(from data: Data?) -> (bad: String, good: String) {
        guard let data else { return ("bad", "good") }
        let lines = GitOutput.lines(String(decoding: data, as: UTF8.self))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return ("bad", "good") }
        return (lines[0], lines[1])
    }

    /// Estimates the remaining bisect steps for `remainingCommits` untested commits (matching Git's log2 estimate).
    public static func estimatedSteps(forRemaining remainingCommits: Int) -> Int {
        guard remainingCommits > 1 else { return max(0, remainingCommits) }
        return Int(ceil(log2(Double(remainingCommits))))
    }

    /// Parses Git's `# first <badTerm> commit: [<sha>] <subject>` line from `BISECT_LOG`.
    public static func parseCulprit(
        from logLines: [String], badTerm: String = "bad"
    ) -> (commitID: String, subject: String)? {
        let prefix = "# first \(badTerm) commit: ["
        for line in logLines.reversed() {
            guard let range = line.range(of: prefix) else { continue }
            let remainder = line[range.upperBound...]
            guard let closeBracket = remainder.firstIndex(of: "]") else { continue }
            let sha = String(remainder[..<closeBracket])
            guard GitParsers.isObjectID(sha) else { continue }
            let subject = String(remainder[remainder.index(after: closeBracket)...])
                .trimmingCharacters(in: .whitespaces)
            return (sha, subject)
        }
        return nil
    }

    /// Parses a culprit SHA from `git bisect` stdout (`<sha> is the first <badTerm> commit`).
    public static func parseCulpritFromOutput(_ text: String, badTerm: String = "bad") -> String? {
        let suffix = " is the first \(badTerm) commit"
        for line in GitOutput.lines(text) {
            guard line.hasSuffix(suffix) else { continue }
            let candidate = String(line.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
            if GitParsers.isObjectID(candidate) { return candidate }
        }
        return nil
    }

    private static func classifyRefs(
        _ refs: [String: String], badTerm: String, goodTerm: String
    ) -> (bad: String?, good: Set<String>, skipped: Set<String>) {
        let badRefName = "refs/bisect/\(badTerm)"
        let goodPrefix = "refs/bisect/\(goodTerm)-"
        var badCommitID: String?
        var goodCommitIDs: Set<String> = []
        var skippedCommitIDs: Set<String> = []
        for (name, sha) in refs {
            guard GitParsers.isObjectID(sha) else { continue }
            if name == badRefName {
                badCommitID = sha
            } else if name.hasPrefix(goodPrefix) {
                goodCommitIDs.insert(sha)
            } else if name.hasPrefix("refs/bisect/skip-") {
                skippedCommitIDs.insert(sha)
            }
        }
        return (badCommitID, goodCommitIDs, skippedCommitIDs)
    }

    private static func mergedRefs(gitDirectory: URL, provided: [String: String]) -> [String: String] {
        var refs = readLooseBisectRefs(in: gitDirectory)
        for (name, sha) in provided {
            refs[name] = sha
        }
        return refs
    }

    private static func readLooseBisectRefs(in gitDirectory: URL) -> [String: String] {
        let bisectDir = gitDirectory.appendingPathComponent("refs/bisect", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: bisectDir.path) else {
            return [:]
        }
        var refs: [String: String] = [:]
        for name in names {
            let fileURL = bisectDir.appendingPathComponent(name)
            guard let data = try? BoundedFile.contents(fileURL, limit: 1_024) else { continue }
            let sha = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if GitParsers.isObjectID(sha) {
                refs["refs/bisect/" + name] = sha
            }
        }
        return refs
    }
}
