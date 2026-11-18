import SwiftSyntax

/// Cyclomatic and cognitive complexity of one function body. Nested functions are measured on their own and skipped.
///
/// Cyclomatic: 1, plus one per `if`, `guard`, loop, `case` label, `catch`, ternary, `&&` and `||`.
/// Cognitive follows the SonarSource definition: structural increments for `if`, `guard`, `switch`, loops, `catch`
/// and ternaries, each plus the current nesting; flat increments for `else`/`else if`, labeled jumps and every run of
/// like logical operators. Closures and the bodies of those structures nest one level deeper.
struct Complexity {
    private(set) var cyclomatic = 1
    private(set) var cognitive = 0

    /// Measures the children of `declaration` (the declaration itself is the function being measured).
    init(_ declaration: some SyntaxProtocol) {
        walkChildren(Syntax(declaration), nesting: 0)
    }

    private mutating func walk(_ node: Syntax, nesting: Int) {
        if node.isNestedDeclaration { return }
        if let ifExpr = node.as(IfExprSyntax.self) {
            visitIf(ifExpr, nesting: nesting, isElseIf: false)
            return
        }
        if structural(node, nesting: nesting) { return }
        if node.is(ClosureExprSyntax.self) {
            walkChildren(node, nesting: nesting + 1)
            return
        }
        countFlat(node)
        walkChildren(node, nesting: nesting)
    }

    private mutating func walkChildren(_ node: Syntax, nesting: Int) {
        for child in node.children(viewMode: .sourceAccurate) {
            walk(child, nesting: nesting)
        }
    }

    /// Loops, `guard`, `switch`, `catch` and ternaries: their own increment, then their children one level deeper.
    private mutating func structural(_ node: Syntax, nesting: Int) -> Bool {
        guard node.isStructural else { return false }
        // A `switch` adds its paths through its `case` labels, not through the `switch` itself.
        if !node.is(SwitchExprSyntax.self) { cyclomatic += 1 }
        cognitive += 1 + nesting
        walkChildren(node, nesting: nesting + 1)
        return true
    }

    private mutating func countFlat(_ node: Syntax) {
        if let switchCase = node.as(SwitchCaseSyntax.self), switchCase.label.is(SwitchCaseLabelSyntax.self) {
            cyclomatic += 1
        } else if let infix = node.as(InfixOperatorExprSyntax.self), let logical = infix.logicalOperator {
            cyclomatic += 1
            if infix.parentLogicalOperator != logical { cognitive += 1 }
        } else if node.isLabeledJump {
            cognitive += 1
        }
    }

    private mutating func visitIf(_ node: IfExprSyntax, nesting: Int, isElseIf: Bool) {
        cyclomatic += 1
        cognitive += isElseIf ? 1 : 1 + nesting
        walk(Syntax(node.conditions), nesting: nesting)
        walk(Syntax(node.body), nesting: nesting + 1)
        switch node.elseBody {
        case .ifExpr(let elseIf)?:
            visitIf(elseIf, nesting: nesting, isElseIf: true)
        case .codeBlock(let block)?:
            cognitive += 1
            walk(Syntax(block), nesting: nesting + 1)
        case nil:
            break
        }
    }
}

extension Syntax {
    /// Functions, types and other declarations inside a body: measured separately, so the enclosing body skips them.
    var isNestedDeclaration: Bool {
        `is`(FunctionDeclSyntax.self) || `is`(InitializerDeclSyntax.self) || `is`(DeinitializerDeclSyntax.self)
            || `is`(SubscriptDeclSyntax.self) || `is`(AccessorDeclSyntax.self) || isTypeDeclaration
    }

    var isTypeDeclaration: Bool {
        `is`(ClassDeclSyntax.self) || `is`(StructDeclSyntax.self) || `is`(EnumDeclSyntax.self)
            || `is`(ActorDeclSyntax.self) || `is`(ExtensionDeclSyntax.self) || `is`(ProtocolDeclSyntax.self)
    }

    var isStructural: Bool {
        `is`(GuardStmtSyntax.self) || `is`(ForStmtSyntax.self) || `is`(WhileStmtSyntax.self)
            || `is`(RepeatStmtSyntax.self) || `is`(SwitchExprSyntax.self) || `is`(CatchClauseSyntax.self)
            || `is`(TernaryExprSyntax.self)
    }

    var isLabeledJump: Bool {
        if let jump = `as`(BreakStmtSyntax.self) { return jump.label != nil }
        if let jump = `as`(ContinueStmtSyntax.self) { return jump.label != nil }
        return false
    }
}

extension InfixOperatorExprSyntax {
    var logicalOperator: String? {
        guard let binary = `operator`.as(BinaryOperatorExprSyntax.self) else { return nil }
        let text = binary.operator.text
        return text == "&&" || text == "||" ? text : nil
    }

    /// The logical operator of the directly enclosing infix expression, so `a && b && c` counts as one run.
    var parentLogicalOperator: String? {
        parent?.as(InfixOperatorExprSyntax.self)?.logicalOperator
    }
}
