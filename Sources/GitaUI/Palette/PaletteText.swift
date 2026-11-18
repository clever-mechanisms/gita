import Foundation

/// How well one word of the query matches a text, best first.
enum PaletteMatchQuality: Int, Comparable {
    /// The whole text.
    case exact
    /// A whole word of it.
    case word
    /// Its beginning.
    case prefix
    /// The beginning of one of its words.
    case wordPrefix
    /// Somewhere inside a word.
    case substring
    /// The first letters of its words, in order ("fp" for Force Push).
    case initials
    /// Its letters in order, with others between.
    case scattered
    /// A word of it, one slip away ("psuh" for Push).
    case typo

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One query word found in a text: how well, and which characters (offsets into the text) it covers.
struct PaletteTokenMatch: Equatable {
    var quality: PaletteMatchQuality
    var ranges: [Range<Int>]
}

/// A text ready to be searched: one folded character (lower case, no accent) per character of the original, so a
/// match's ranges are character offsets in the original, and where its words start.
struct PaletteText {
    let folded: [Character]
    /// Whether a word starts at each offset: after a separator, and at a capital inside a camelCase word.
    let starts: [Bool]

    init(_ text: String) {
        var folded: [Character] = []
        var starts: [Bool] = []
        var previous: Character?
        for character in text {
            folded.append(Self.fold(character))
            starts.append(Self.startsWord(character, after: previous))
            previous = character
        }
        self.folded = folded
        self.starts = starts
    }

    /// The query's words, folded: split at spaces, each kept once, at most `limit`.
    static func tokens(_ query: String, limit: Int = 8) -> [[Character]] {
        var tokens: [[Character]] = []
        for word in query.split(whereSeparator: \.isWhitespace) {
            let token = word.map(fold)
            if !tokens.contains(token) { tokens.append(token) }
            if tokens.count == limit { break }
        }
        return tokens
    }

    static func fold(_ character: Character) -> Character {
        if character.isASCII { return Character(character.lowercased()) }
        let folded = String(character).folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded.first ?? character
    }

    private static func isWordCharacter(_ character: Character) -> Bool { character.isLetter || character.isNumber }

    private static func startsWord(_ character: Character, after previous: Character?) -> Bool {
        guard isWordCharacter(character) else { return false }
        guard let previous, isWordCharacter(previous) else { return true }
        return previous.isLowercase && character.isUppercase
    }

    /// The best way `token` is found in the text; nil when it is not.
    func match(_ token: [Character]) -> PaletteTokenMatch? {
        guard !token.isEmpty, !folded.isEmpty else { return nil }
        return literal(token) ?? initials(token) ?? scattered(token) ?? typo(token)
    }

    // MARK: The token as written

    private func literal(_ token: [Character]) -> PaletteTokenMatch? {
        guard token.count <= folded.count else { return nil }
        var best: PaletteTokenMatch?
        for start in 0...(folded.count - token.count) where folded[start...].starts(with: token) {
            let quality = literalQuality(start: start, end: start + token.count)
            if best.map({ quality < $0.quality }) ?? true {
                best = PaletteTokenMatch(quality: quality, ranges: [start..<start + token.count])
            }
            if quality <= .word { break }
        }
        return best
    }

    private func literalQuality(start: Int, end: Int) -> PaletteMatchQuality {
        let endsWord = end == folded.count || !Self.isWordCharacter(folded[end]) || starts[end]
        if start == 0 { return end == folded.count ? .exact : endsWord ? .word : .prefix }
        let beginsWord = starts[start] || !Self.isWordCharacter(folded[start - 1])
        guard beginsWord else { return .substring }
        return endsWord ? .word : .wordPrefix
    }

    // MARK: Its letters in order

    private func initials(_ token: [Character]) -> PaletteTokenMatch? {
        guard token.count >= 2 else { return nil }
        var ranges: [Range<Int>] = []
        var next = 0
        for index in folded.indices where starts[index] && next < token.count && folded[index] == token[next] {
            ranges.append(index..<index + 1)
            next += 1
        }
        return next == token.count ? PaletteTokenMatch(quality: .initials, ranges: ranges) : nil
    }

    /// From a word's start: each letter at the first place it comes after the one before.
    private func scattered(_ token: [Character]) -> PaletteTokenMatch? {
        guard token.count >= 3 else { return nil }
        for start in folded.indices where starts[start] && folded[start] == token[0] {
            let ranges = inOrder(token, from: start)
            if !ranges.isEmpty { return PaletteTokenMatch(quality: .scattered, ranges: ranges) }
        }
        return nil
    }

    /// Where the token's letters are, each after the one before; empty when one is missing.
    private func inOrder(_ token: [Character], from start: Int) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var next = 0
        for index in start..<folded.count where next < token.count && folded[index] == token[next] {
            if let last = ranges.last, last.upperBound == index {
                ranges[ranges.count - 1] = last.lowerBound..<index + 1
            } else {
                ranges.append(index..<index + 1)
            }
            next += 1
        }
        return next == token.count ? ranges : []
    }

    // MARK: One slip away

    /// A word that starts with the token's first letter and differs from it by one letter added, dropped, changed
    /// or swapped with its neighbour.
    private func typo(_ token: [Character]) -> PaletteTokenMatch? {
        guard token.count >= 4 else { return nil }
        for start in folded.indices where starts[start] && folded[start] == token[0] {
            let word = wordEnd(from: start) - start
            for length in [token.count, token.count + 1, token.count - 1] where length <= word {
                if Self.isOneSlip(Array(folded[start..<start + length]), token) {
                    return PaletteTokenMatch(quality: .typo, ranges: [start..<start + length])
                }
            }
        }
        return nil
    }

    private func wordEnd(from start: Int) -> Int {
        var end = start + 1
        while end < folded.count, Self.isWordCharacter(folded[end]), !starts[end] { end += 1 }
        return end
    }

    /// Whether `lhs` becomes `rhs` by one edit: a letter changed, added, dropped or swapped with the next.
    static func isOneSlip(_ lhs: [Character], _ rhs: [Character]) -> Bool {
        let (short, long) = lhs.count <= rhs.count ? (lhs, rhs) : (rhs, lhs)
        guard long.count - short.count <= 1 else { return false }
        let common = zip(short, long).prefix { $0 == $1 }.count
        if common == short.count { return true }
        if short.count < long.count { return short[common...].elementsEqual(long[(common + 1)...]) }
        if short[(common + 1)...].elementsEqual(long[(common + 1)...]) { return true }
        return common + 1 < short.count && short[common] == long[common + 1] && short[common + 1] == long[common]
            && short[(common + 2)...].elementsEqual(long[(common + 2)...])
    }
}
