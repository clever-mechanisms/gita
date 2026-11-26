import Foundation

public enum DiffHunkNoiseKind: String, Sendable, Equatable {
    case substantive, whitespaceOnly, importOrderOnly, mixedNoise
}

public struct DiffHunkClassification: Sendable, Equatable {
    public let hunkIndex: Int
    public let noiseKind: DiffHunkNoiseKind
    public let changedLineCount: Int

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hunkIndex == rhs.hunkIndex
            && lhs.noiseKind == rhs.noiseKind
            && lhs.changedLineCount == rhs.changedLineCount
    }
}

public struct CollapsedNoiseRun: Sendable, Equatable {
    public let hunkIndices: [Int]
    public var hunkCount: Int { hunkIndices.count }
    public var summaryText: String { DiffNoiseFilter.summary(hunkCount) }
    /// Index in the original document, before any filtering.
    public let anchorLineIndex: Int
}

public struct FilteredDiffResult: Sendable, Equatable {
    public let classifications: [DiffHunkClassification]
    public let hiddenNoiseHunkIndices: Set<Int>
    public let visibleLines: [DiffLine]
    public let collapsedNoiseRuns: [CollapsedNoiseRun]
    public var hiddenNoiseHunkCount: Int { hiddenNoiseHunkIndices.count }
    public var summaryText: String { DiffNoiseFilter.summary(hiddenNoiseHunkCount) }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.classifications == rhs.classifications
            && lhs.hiddenNoiseHunkIndices == rhs.hiddenNoiseHunkIndices
            && lhs.visibleLines == rhs.visibleLines
            && lhs.collapsedNoiseRuns == rhs.collapsedNoiseRuns
    }
}

public enum DiffNoiseFilter {
    fileprivate static func summary(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 formatting/import hunk hidden")
            : String(localized: "\(count) formatting/import hunks hidden")
    }

    private struct Hunk {
        var old: [String] = []
        var new: [String] = []
        var changed = 0
        var unsafeMetadata = false

        mutating func append(_ line: DiffLine) {
            let text = String(line.text.dropFirst())
            switch line.kind {
            case "-": old.append(text)
            case "+": new.append(text)
            case " ":
                old.append(text)
                new.append(text)
                return
            case "@": return
            default:
                unsafeMetadata = true
                return
            }
            changed += 1
        }

        var kind: DiffHunkNoiseKind {
            guard changed > 0, !unsafeMetadata else { return .substantive }
            let before = old.map(DiffLineContent.normalize).filter { !$0.isEmpty }
            let after = new.map(DiffLineContent.normalize).filter { !$0.isEmpty }
            if before == after { return .whitespaceOnly }
            guard reorderedImports(old) == reorderedImports(new) else { return .substantive }
            let rawOld = old.filter { !$0.isEmpty }
            let rawNew = new.filter { !$0.isEmpty }
            return frequencies(rawOld) == frequencies(rawNew) ? .importOrderOnly : .mixedNoise
        }

        private func frequencies(_ values: [String]) -> [String: Int] {
            values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }

        private func reorderedImports(_ lines: [String]) -> [String] {
            var ordered: [String] = []
            var imports: [String] = []
            for raw in lines {
                let line = DiffLineContent.normalize(raw)
                guard !line.isEmpty else { continue }
                let declaration = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if isImport(declaration) {
                    imports.append(line)
                } else {
                    ordered.append(contentsOf: SmartDiffKeyOrder.sorted(imports))
                    imports.removeAll(keepingCapacity: true)
                    ordered.append(line)
                }
            }
            return ordered + SmartDiffKeyOrder.sorted(imports)
        }

        private func isImport(_ text: String) -> Bool {
            if ["import ", "@testable import ", "use ", "pub use ", "#include"].contains(where: text.hasPrefix) {
                return true
            }
            if text.hasPrefix("from ") { return text.contains(" import ") }
            if text.hasPrefix("export ") { return text.contains(" from ") }
            if text.hasPrefix("\"") && text.hasSuffix("\"") { return !text.dropFirst().dropLast().contains("\"") }
            let bindings = ["const ", "let ", "var "]
            return text.hasPrefix("require(") || (bindings.contains(where: text.hasPrefix) && text.contains("require("))
        }
    }

    public static func analyze(_ document: DiffDocument, maxLines: Int = 50_000) -> [DiffHunkClassification] {
        guard document.lines.count <= maxLines else { return [] }
        var hunks: [Int: Hunk] = [:]
        for line in document.lines {
            if let index = line.hunkIndex { hunks[index, default: Hunk()].append(line) }
        }
        return document.hunks.map { hunk in
            let data = hunks[hunk.index, default: Hunk()]
            return DiffHunkClassification(hunkIndex: hunk.index, noiseKind: data.kind, changedLineCount: data.changed)
        }
    }

    public static func filter(
        _ document: DiffDocument, hideNoise: Bool, expandedHunks: Set<Int> = [], maxLines: Int = 50_000
    ) -> FilteredDiffResult {
        let classifications = analyze(document, maxLines: maxLines)
        return filter(document, classifications: classifications, hideNoise: hideNoise, expandedHunks: expandedHunks)
    }

    package static func filter(
        _ document: DiffDocument, classifications: [DiffHunkClassification], hideNoise: Bool, expandedHunks: Set<Int>
    ) -> FilteredDiffResult {
        let hidden = Set(
            classifications.compactMap { item in
                hideNoise && item.noiseKind != .substantive && !expandedHunks.contains(item.hunkIndex)
                    ? item.hunkIndex : nil
            })
        var visible: [DiffLine] = []
        var runs: [CollapsedNoiseRun] = []
        var current: [Int] = []
        var anchor = 0
        for (index, line) in document.lines.enumerated() {
            if let hunk = line.hunkIndex, hidden.contains(hunk) {
                if current.isEmpty { anchor = index }
                if current.last != hunk { current.append(hunk) }
            } else {
                if !current.isEmpty { runs.append(CollapsedNoiseRun(hunkIndices: current, anchorLineIndex: anchor)) }
                current.removeAll(keepingCapacity: true)
                visible.append(line)
            }
        }
        if !current.isEmpty { runs.append(CollapsedNoiseRun(hunkIndices: current, anchorLineIndex: anchor)) }
        return FilteredDiffResult(
            classifications: classifications, hiddenNoiseHunkIndices: hidden,
            visibleLines: visible, collapsedNoiseRuns: runs)
    }
}
