import Foundation

public struct BlameCommitInfo: Sendable, Equatable {
    public var id: String
    public var author: String
    public var email: String
    public var date: Date
    public var summary: String
    public var isBoundary: Bool
    public var isUncommitted: Bool

    public init(
        id: String, author: String, email: String, date: Date, summary: String,
        isBoundary: Bool = false, isUncommitted: Bool = false
    ) {
        self.id = id
        self.author = author
        self.email = email
        self.date = date
        self.summary = summary
        self.isBoundary = isBoundary
        self.isUncommitted = isUncommitted
    }
}

public struct BlameHunk: Sendable, Equatable {
    public var commitID: String
    public var finalLine: Int
    public var lineCount: Int
    public var previousCommit: String?
    public var previousPath: String?

    public init(
        commitID: String, finalLine: Int, lineCount: Int,
        previousCommit: String? = nil, previousPath: String? = nil
    ) {
        self.commitID = commitID
        self.finalLine = finalLine
        self.lineCount = lineCount
        self.previousCommit = previousCommit
        self.previousPath = previousPath
    }
}

public struct BlameLineAnnotation: Sendable, Equatable {
    public var lineNumber: Int
    public var text: String
    public var commit: BlameCommitInfo?
    public var previousCommit: String?
    public var previousPath: String?
    public var isBlockStart: Bool

    public init(
        lineNumber: Int, text: String, commit: BlameCommitInfo? = nil,
        previousCommit: String? = nil, previousPath: String? = nil, isBlockStart: Bool = false
    ) {
        self.lineNumber = lineNumber
        self.text = text
        self.commit = commit
        self.previousCommit = previousCommit
        self.previousPath = previousPath
        self.isBlockStart = isBlockStart
    }
}

public enum BlameError: Error, Equatable, Sendable, LocalizedError {
    case binaryFile
    case unsupportedWorkingFile
    case invalidPath
    case invalidRevision
    case timedOut
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .binaryFile: String(localized: "Blame is unavailable for binary files.")
        case .invalidPath: String(localized: "Invalid file path for blame.")
        case .unsupportedWorkingFile:
            String(localized: "Working-tree blame requires a readable regular file of 16 MiB or smaller.")
        case .invalidRevision: String(localized: "Invalid revision for blame.")
        case .timedOut: String(localized: "Blame timed out.")
        case .failed(let message): message
        }
    }
}

public struct BlameDocument: Sendable, Equatable {
    public var path: String
    public var revision: String?
    public var lines: [String]
    public var commits: [String: BlameCommitInfo]
    public private(set) var annotations: [BlameLineAnnotation]
    public private(set) var oldestDate: Date
    public private(set) var newestDate: Date

    public init(
        path: String, revision: String?, lines: [String],
        commits: [String: BlameCommitInfo] = [:], hunks: [BlameHunk] = []
    ) {
        self.path = path
        self.revision = revision
        self.lines = lines
        self.commits = commits
        self.annotations = lines.enumerated().map { index, text in
            BlameLineAnnotation(lineNumber: index + 1, text: text)
        }
        self.oldestDate = .distantFuture
        self.newestDate = .distantPast
        if !hunks.isEmpty {
            apply(hunks: hunks, commits: commits)
        }
    }

    public mutating func apply(hunks newHunks: [BlameHunk], commits newCommits: [String: BlameCommitInfo]) {
        for (id, info) in newCommits {
            commits[id] = info
            if !info.isUncommitted {
                if info.date < oldestDate { oldestDate = info.date }
                if info.date > newestDate { newestDate = info.date }
            }
        }
        for hunk in newHunks {
            let commit = commits[hunk.commitID]
            let start = max(0, hunk.finalLine - 1)
            let end = min(annotations.count, start + hunk.lineCount)
            guard start < end else { continue }
            for row in start..<end {
                annotations[row].commit = commit
                annotations[row].previousCommit = hunk.previousCommit
                annotations[row].previousPath = hunk.previousPath
            }
        }
        recomputeBlockStarts()
    }

    private mutating func recomputeBlockStarts() {
        var previousCommitID: String?
        for index in annotations.indices {
            let currentID = annotations[index].commit?.id
            annotations[index].isBlockStart = currentID != nil && currentID != previousCommitID
            previousCommitID = currentID
        }
    }

    /// 0.0 (oldest) to 1.0 (newest).
    public func ageHeat(for date: Date) -> Double {
        let span = newestDate.timeIntervalSince(oldestDate)
        guard span > 1 else { return 1.0 }
        let ratio = date.timeIntervalSince(oldestDate) / span
        return min(1.0, max(0.0, ratio))
    }

    /// Discrete tier: 2 = hot (`▇`), 1 = warm (`▅`), 0 = cool (`▂`).
    public func heatLevel(for date: Date) -> Int {
        let heat = ageHeat(for: date)
        if heat >= 0.66 { return 2 }
        if heat >= 0.33 { return 1 }
        return 0
    }

    public func blockRange(at lineIndex: Int) -> Range<Int> {
        guard annotations.indices.contains(lineIndex) else { return lineIndex..<lineIndex }
        let targetID = annotations[lineIndex].commit?.id
        var lower = lineIndex
        while lower > 0 && annotations[lower - 1].commit?.id == targetID {
            lower -= 1
        }
        var upper = lineIndex + 1
        while upper < annotations.count && annotations[upper].commit?.id == targetID {
            upper += 1
        }
        return lower..<upper
    }

    public func priorRevision(at lineIndex: Int) -> (commit: String, path: String)? {
        guard annotations.indices.contains(lineIndex) else { return nil }
        let annotation = annotations[lineIndex]
        if let previous = annotation.previousCommit {
            return (previous, annotation.previousPath ?? path)
        }
        if let commit = annotation.commit, !commit.isUncommitted, !commit.isBoundary {
            return (commit.id + "^", path)
        }
        return nil
    }

    public static func splitLines(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.utf8.split(separator: 0x0A, omittingEmptySubsequences: false).map { line in
            String(decoding: line.last == 0x0D ? line.dropLast() : line, as: UTF8.self)
        }
        if text.utf8.last == 0x0A {
            lines.removeLast()
        }
        return lines
    }
}
