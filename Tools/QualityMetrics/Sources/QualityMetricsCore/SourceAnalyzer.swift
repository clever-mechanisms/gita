import SwiftOperators
import SwiftParser
import SwiftSyntax

/// Parses one Swift file and measures its size and every function-like declaration in it.
public enum SourceAnalyzer {
    public static func analyze(source: String, path: String) -> FileMetrics {
        let parsed = Parser.parse(source: source)
        let tree = OperatorTable.standardOperators.foldAll(parsed) { _ in }.as(SourceFileSyntax.self) ?? parsed
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        let collector = DeclarationCollector(path: path, converter: converter)
        collector.walk(tree)
        return FileMetrics(path: path, ncloc: codeLines(in: tree, converter: converter), functions: collector.functions)
    }

    /// Lines that hold a token. Comments live in trivia, so comment-only and blank lines are not counted.
    static func codeLines(in tree: SourceFileSyntax, converter: SourceLocationConverter) -> Int {
        var lines = Set<Int>()
        for token in tree.tokens(viewMode: .sourceAccurate) where token.tokenKind != .endOfFile {
            let first = converter.location(for: token.positionAfterSkippingLeadingTrivia).line
            let last = converter.location(for: token.endPositionBeforeTrailingTrivia).line
            lines.formUnion(first...max(first, last))
        }
        return lines.count
    }
}

/// Finds functions, initializers, deinitializers, subscripts, accessors and computed or closure-initialized
/// properties declared at type or file level.
final class DeclarationCollector: SyntaxVisitor {
    private let path: String
    private let converter: SourceLocationConverter
    private(set) var functions: [FunctionMetrics] = []

    init(path: String, converter: SourceLocationConverter) {
        self.path = path
        self.converter = converter
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node, name: node.name.text + node.signature.parameterClause.labels)
    }

    override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node, name: "init" + node.signature.parameterClause.labels)
    }

    override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node, name: "deinit")
    }

    override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind {
        if case .accessors? = node.accessorBlock?.accessors { return .visitChildren }
        return record(node, name: "subscript" + node.parameterClause.labels)
    }

    override func visit(_ node: AccessorDeclSyntax) -> SyntaxVisitorContinueKind {
        record(node, name: node.ownerName + "." + node.accessorSpecifier.text)
    }

    override func visit(_ node: PatternBindingSyntax) -> SyntaxVisitorContinueKind {
        guard node.isMemberOrGlobal else { return .visitChildren }
        let name = node.pattern.trimmedDescription
        if case .getter? = node.accessorBlock?.accessors { return record(node, name: name) }
        if let value = node.initializer?.value, value.containsClosure { return record(node, name: name) }
        return .visitChildren
    }

    private func record(_ node: some SyntaxProtocol, name: String) -> SyntaxVisitorContinueKind {
        let complexity = Complexity(node)
        functions.append(
            FunctionMetrics(
                file: path,
                name: Syntax(node).qualifiedName(name),
                startLine: converter.location(for: node.positionAfterSkippingLeadingTrivia).line,
                endLine: converter.location(for: node.endPositionBeforeTrailingTrivia).line,
                cyclomatic: complexity.cyclomatic,
                cognitive: complexity.cognitive,
                halsteadDifficulty: Halstead.difficulty(of: node)
            ))
        return .visitChildren
    }
}

extension FunctionParameterClauseSyntax {
    var labels: String {
        "(" + parameters.map { $0.firstName.text + ":" }.joined() + ")"
    }
}

extension AccessorDeclSyntax {
    var ownerName: String {
        var current = parent
        while let node = current {
            if let binding = node.as(PatternBindingSyntax.self) { return binding.pattern.trimmedDescription }
            if node.is(SubscriptDeclSyntax.self) { return "subscript" }
            current = node.parent
        }
        return "accessor"
    }
}

extension PatternBindingSyntax {
    /// True for properties of a type or of the file, false for locals inside a body (those belong to their function).
    var isMemberOrGlobal: Bool {
        var current = parent
        while let node = current {
            if node.is(MemberBlockItemSyntax.self) { return true }
            if node.is(CodeBlockSyntax.self) || node.is(ClosureExprSyntax.self) || node.is(AccessorBlockSyntax.self) {
                return false
            }
            if node.is(SourceFileSyntax.self) { return true }
            current = node.parent
        }
        return false
    }
}

extension ExprSyntax {
    var containsClosure: Bool {
        `is`(ClosureExprSyntax.self) || tokens(viewMode: .sourceAccurate).contains { $0.tokenKind == .leftBrace }
    }
}

extension Syntax {
    /// `Outer.Inner.name` from the enclosing type and extension declarations.
    func qualifiedName(_ name: String) -> String {
        var parts = [name]
        var current = parent
        while let node = current {
            if let typeName = node.declaredTypeName { parts.insert(typeName, at: 0) }
            current = node.parent
        }
        return parts.joined(separator: ".")
    }

    private var declaredTypeName: String? {
        if let decl = `as`(ClassDeclSyntax.self) { return decl.name.text }
        if let decl = `as`(StructDeclSyntax.self) { return decl.name.text }
        if let decl = `as`(EnumDeclSyntax.self) { return decl.name.text }
        if let decl = `as`(ActorDeclSyntax.self) { return decl.name.text }
        if let decl = `as`(ProtocolDeclSyntax.self) { return decl.name.text }
        if let decl = `as`(ExtensionDeclSyntax.self) { return decl.extendedType.trimmedDescription }
        return nil
    }
}
