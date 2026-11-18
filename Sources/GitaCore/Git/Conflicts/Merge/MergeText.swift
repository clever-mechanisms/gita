import Foundation

/// How the merge splits text: into lines that keep their terminator, so joining them gives the text back byte for
/// byte, and lines into words for the simple merge and for highlighting.
public enum MergeText {
    public static func lines(_ text: String) -> [String] {
        var lines = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self) + "\n"
        }
        // The last piece has no terminator: drop it when empty, else take its added one back.
        if let last = lines.popLast(), last != "\n" { lines.append(String(last.dropLast())) }
        return lines
    }

    /// Runs of letters and digits, runs of white space, and every other character on its own.
    public static func words(_ line: String) -> [String] {
        var words: [String] = []
        var current = String.UnicodeScalarView()
        var currentKind = WordKind.symbol
        for scalar in line.unicodeScalars {
            let kind = WordKind(scalar)
            if kind == currentKind, kind != .symbol, !current.isEmpty {
                current.append(scalar)
            } else {
                if !current.isEmpty { words.append(String(current)) }
                current = String.UnicodeScalarView([scalar])
                currentKind = kind
            }
        }
        if !current.isEmpty { words.append(String(current)) }
        return words
    }

    /// The words of `line` that `base` does not have, as UTF-16 offsets into `line`.
    public static func changedWords(in line: String, comparedTo base: String) -> [Range<Int>] {
        let lineWords = words(line)
        var offsets = [0]
        var offset = 0
        for word in lineWords {
            offset += word.utf16.count
            offsets.append(offset)
        }
        return SequenceDiff.hunks(words(base), lineWords).compactMap { hunk in
            hunk.new.isEmpty ? nil : offsets[hunk.new.lowerBound]..<offsets[hunk.new.upperBound]
        }
    }

    private enum WordKind {
        case word, space, symbol

        init(_ scalar: Unicode.Scalar) {
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "_" {
                self = .word
            } else if scalar.properties.isWhitespace {
                self = .space
            } else {
                self = .symbol
            }
        }
    }
}
