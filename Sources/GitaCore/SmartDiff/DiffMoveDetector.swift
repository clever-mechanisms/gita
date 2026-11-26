import Foundation

public struct DiffMoveEndpoint: Sendable, Equatable, Hashable {
    public let filePath: String
    public let hunkIndex: Int
    public let lineIndices: Range<Int>
    public let displayStartLine: Int
    public let displayEndLine: Int

    fileprivate var summary: String { String(localized: "\(filePath), lines \(displayStartLine)–\(displayEndLine)") }
}

public struct DiffMoveMatch: Identifiable, Sendable, Equatable {
    public let id: String
    public let source: DiffMoveEndpoint
    public let destination: DiffMoveEndpoint
    public let lineCount: Int
    public let nonTrivialLineCount: Int
    public let previewLine: String
}

public enum DiffMoveRole: Sendable, Equatable {
    case movedFrom(matchID: String, destinationSummary: String, isBlockStart: Bool)
    case movedTo(matchID: String, sourceSummary: String, isBlockStart: Bool)

    public var isBlockStart: Bool {
        switch self {
        case .movedFrom(_, _, let start), .movedTo(_, _, let start): start
        }
    }
}

public struct DiffMoveAnalysis: Sendable, Equatable {
    package static let empty = Self(matches: [], rolesByFileAndLine: [:])
    public let matches: [DiffMoveMatch]
    public let rolesByFileAndLine: [String: [Int: DiffMoveRole]]

    public func role(filePath: String, lineIndex: Int) -> DiffMoveRole? { rolesByFileAndLine[filePath]?[lineIndex] }
}

public enum DiffMoveDetector {
    private struct Block {
        let endpoint: DiffMoveEndpoint
        let content: [String]
        let count: Int
        let preview: String
        let removed: Bool
    }

    public static func detect(
        in document: DiffDocument, filePath: String, minimumNonTrivialLines: Int = 3
    ) -> DiffMoveAnalysis {
        detect(in: [filePath: document], minimumNonTrivialLines: minimumNonTrivialLines)
    }

    public static func detect(
        in documentsByFile: [String: DiffDocument], minimumNonTrivialLines: Int = 3, maxLines: Int = 50_000
    ) -> DiffMoveAnalysis {
        var remaining = max(0, maxLines)
        for document in documentsByFile.values {
            guard document.lines.count <= remaining else { return .empty }
            remaining -= document.lines.count
        }
        var removed: [Int: [Block]] = [:]
        var longest = 0
        var inserted: [[String]: [Block]] = [:]
        for path in SmartDiffKeyOrder.sorted(documentsByFile.keys) {
            guard let document = documentsByFile[path] else { continue }
            scan(document.lines, path: path, threshold: max(3, minimumNonTrivialLines)) { block in
                if block.removed {
                    let length = block.content.count
                    longest = max(longest, length)
                    removed[length, default: []].append(block)
                } else {
                    inserted[block.content, default: []].append(block)
                }
            }
        }
        let candidates = stride(from: longest, through: 1, by: -1).flatMap { removed[$0, default: []] }
        return pair(candidates, with: inserted)
    }

    private static func scan(_ lines: [DiffLine], path: String, threshold: Int, emit: (Block) -> Void) {
        var index = 0
        while index < lines.count {
            let first = lines[index]
            let start = index
            index += 1
            guard let hunk = first.hunkIndex, first.kind == "-" || first.kind == "+" else { continue }
            while index < lines.count, lines[index].kind == first.kind, lines[index].hunkIndex == hunk { index += 1 }
            let slice = lines[start..<index]
            let content = slice.map { DiffLineContent.normalize(String($0.text.dropFirst())) }
            let significant = content.filter { !$0.isEmpty && !["{", "}", "[", "]", "(", ")"].contains($0) }
            guard significant.count >= threshold, let preview = significant.first, let last = slice.last else {
                continue
            }
            let removed = first.kind == "-"
            let endpoint = DiffMoveEndpoint(
                filePath: path, hunkIndex: hunk, lineIndices: start..<index,
                displayStartLine: Int(removed ? first.old : first.new) ?? start + 1,
                displayEndLine: Int(removed ? last.old : last.new) ?? index)
            emit(
                Block(
                    endpoint: endpoint, content: content, count: significant.count, preview: preview, removed: removed))
        }
    }

    // Only maximal same-sign runs compete. Different lengths have different keys and can never claim
    // one another's endpoints. A cursor per key consumes equal runs in stable file/line order.
    private static func pair(_ removed: [Block], with inserted: [[String]: [Block]]) -> DiffMoveAnalysis {
        var cursors: [[String]: Int] = [:]
        var matches: [DiffMoveMatch] = []
        var roles: [String: [Int: DiffMoveRole]] = [:]
        for block in removed {
            let cursor = cursors[block.content, default: 0]
            guard let candidates = inserted[block.content], cursor < candidates.count else { continue }
            cursors[block.content] = cursor + 1
            let source = block.endpoint
            let destination = candidates[cursor].endpoint
            let id = "\(source.filePath):\(source.lineIndices.lowerBound)"
            matches.append(
                DiffMoveMatch(
                    id: id, source: source, destination: destination, lineCount: block.content.count,
                    nonTrivialLineCount: block.count, previewLine: block.preview))
            let toSummary = destination.summary
            let fromSummary = source.summary
            for index in source.lineIndices {
                roles[source.filePath, default: [:]][index] = .movedFrom(
                    matchID: id, destinationSummary: toSummary, isBlockStart: index == source.lineIndices.lowerBound)
            }
            for index in destination.lineIndices {
                roles[destination.filePath, default: [:]][index] = .movedTo(
                    matchID: id, sourceSummary: fromSummary, isBlockStart: index == destination.lineIndices.lowerBound)
            }
        }
        return DiffMoveAnalysis(matches: matches, rolesByFileAndLine: roles)
    }
}
