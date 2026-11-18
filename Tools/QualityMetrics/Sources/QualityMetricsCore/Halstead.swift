import SwiftSyntax

/// Halstead difficulty `D = (n1 / 2) · (N2 / n2)` over the tokens of one declaration.
///
/// Operands are identifiers, literals, `self`, `Self`, `super`, `true`, `false` and `nil`; operators are every other
/// keyword, punctuator and operator. Closing brackets and string quotes pair with an opening token and are not
/// counted again. Tokens of nested declarations are skipped, like in `Complexity`.
enum Halstead {
    static func difficulty(of declaration: some SyntaxProtocol) -> Double {
        var operators = Set<String>()
        var operands = Set<String>()
        var operandCount = 0
        for token in tokens(of: Syntax(declaration)) {
            switch classify(token.tokenKind) {
            case .operand:
                operands.insert(token.text)
                operandCount += 1
            case .operator:
                operators.insert(token.text)
            case .ignored:
                break
            }
        }
        guard !operands.isEmpty else { return 0 }
        return Double(operators.count) / 2 * Double(operandCount) / Double(operands.count)
    }

    private enum Role { case `operator`, operand, ignored }

    private static let operandKeywords: Set<Keyword> = [.self, .Self, .super, .true, .false, .nil]

    private static func classify(_ kind: TokenKind) -> Role {
        switch kind {
        case .identifier, .dollarIdentifier, .integerLiteral, .floatLiteral, .stringSegment, .regexLiteralPattern:
            return .operand
        case .keyword(let keyword):
            return operandKeywords.contains(keyword) ? .operand : .operator
        case .rightParen, .rightBrace, .rightSquare, .rightAngle, .stringQuote, .multilineStringQuote,
            .singleQuote, .rawStringPoundDelimiter, .regexSlash, .regexPoundDelimiter, .endOfFile:
            return .ignored
        default:
            return .operator
        }
    }

    private static func tokens(of declaration: Syntax) -> [TokenSyntax] {
        var result: [TokenSyntax] = []
        var stack = Array(declaration.children(viewMode: .sourceAccurate).reversed())
        while let node = stack.popLast() {
            if node.isNestedDeclaration { continue }
            if let token = node.as(TokenSyntax.self) {
                result.append(token)
            } else {
                stack.append(contentsOf: node.children(viewMode: .sourceAccurate).reversed())
            }
        }
        return result
    }
}
