import Foundation

public struct CustomActionStore: Sendable {
    public let fileURL: URL
    private static let lock = NSLock()
    private static let currentSchemaVersion = 1

    private struct LibraryDocument: Codable {
        var schemaVersion: Int
        var actions: [CustomAction]
    }

    private struct LossyAction: Decodable {
        let value: CustomAction?
        init(from decoder: Decoder) {
            value = try? CustomAction(from: decoder)
        }
    }

    private struct LossyLibraryDocument: Decodable {
        var actions: [LossyAction]
    }

    public init(
        fileURL: URL = URL.applicationSupportDirectory
            .appending(path: "Gita/custom-actions.json")
    ) {
        self.fileURL = fileURL
    }

    /// Lenient load so one invalid or future-schema entry never bricks editing or removing the rest of the library.
    public func load() throws -> [CustomAction] {
        do { return try decodeResilient(Data(contentsOf: fileURL)) } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile
        { return [] }
    }

    public func upsert(_ action: CustomAction) throws -> [CustomAction] {
        try Self.validate(action)
        return try update { actions in
            if let index = actions.firstIndex(where: { $0.id == action.id }) {
                actions[index] = action
            } else {
                actions.append(action)
            }
        }
    }

    public func delete(id: UUID) throws -> [CustomAction] {
        try update { $0.removeAll { $0.id == id } }
    }

    public func duplicate(id: UUID) throws -> (actions: [CustomAction], copy: CustomAction) {
        try Self.lock.withLock {
            var actions = try load()
            guard let index = actions.firstIndex(where: { $0.id == id }) else { throw CustomActionError.missingAction }
            var copy = actions[index]
            copy.id = UUID()
            copy.name = String(localized: "\(copy.name) Copy")
            actions.insert(copy, at: index + 1)
            try write(actions, enforceValidation: false)
            return (actions, copy)
        }
    }

    public func actions(for scope: CustomActionScope) throws -> [CustomAction] {
        try load().filter { $0.scope == scope }
    }

    public func exportJSON(_ actions: [CustomAction]) throws -> Data {
        try Self.validateCollection(actions)
        return try encodeLibrary(actions)
    }

    /// Validates an import payload and enforces confirmation before running on every imported action.
    public func previewImport(_ data: Data) throws -> [CustomAction] {
        let decoded = try decodeStrict(data)
        let hardened = decoded.map { action in
            var copy = action
            copy.confirmsBeforeRun = true
            return copy
        }
        try Self.validateCollection(hardened)
        return hardened
    }

    /// Existing IDs update in place (always enforcing confirmsBeforeRun = true). New IDs append in import order.
    public func importJSON(_ data: Data) throws -> [CustomAction] {
        let imported = try previewImport(data)
        let byID = Dictionary(uniqueKeysWithValues: imported.map { ($0.id, $0) })
        return try update { actions in
            let existing = Set(actions.map(\.id))
            actions = actions.map { byID[$0.id] ?? $0 } + imported.filter { !existing.contains($0.id) }
        }
    }

    public static func validate(_ action: CustomAction) throws {
        guard !action.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CustomActionError.emptyName
        }
        guard action.timeoutSeconds.isFinite, action.timeoutSeconds > 0 else { throw CustomActionError.invalidTimeout }
        guard action.workingDirectory?.contains("\0") != true else { throw CustomActionError.invalidArgument }
        try CommandTemplate.validateTemplate(
            executable: action.executable, arguments: action.arguments,
            knownPlaceholders: CommandTemplate.actionPlaceholders)
        let tokens = action.arguments + [action.workingDirectory].compactMap { $0 }
        let allowed = Set(action.scope.supportedPlaceholders)
        for placeholder in CommandTemplate.referencedPlaceholders(in: tokens, known: CommandTemplate.actionPlaceholders)
        where !allowed.contains(placeholder) {
            throw CustomActionError.unsupportedPlaceholder(placeholder, scope: action.scope)
        }
    }

    private static func validateCollection(_ actions: [CustomAction]) throws {
        guard Set(actions.map(\.id)).count == actions.count else { throw CustomActionError.duplicateID }
        try actions.forEach(validate)
    }

    private func decodeStrict(_ data: Data) throws -> [CustomAction] {
        let decoder = JSONDecoder()
        if let document = try? decoder.decode(LibraryDocument.self, from: data) {
            return document.actions
        }
        return try decoder.decode([CustomAction].self, from: data)
    }

    private func decodeResilient(_ data: Data) throws -> [CustomAction] {
        let decoder = JSONDecoder()
        if let document = try? decoder.decode(LossyLibraryDocument.self, from: data) {
            return document.actions.compactMap(\.value)
        }
        return try decoder.decode([LossyAction].self, from: data).compactMap(\.value)
    }

    private func encodeLibrary(_ actions: [CustomAction]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(LibraryDocument(schemaVersion: Self.currentSchemaVersion, actions: actions))
    }

    private func update(_ edit: (inout [CustomAction]) throws -> Void) throws -> [CustomAction] {
        try Self.lock.withLock {
            var actions = try load()
            try edit(&actions)
            try write(actions, enforceValidation: false)
            return actions
        }
    }

    private func write(_ actions: [CustomAction], enforceValidation: Bool) throws {
        guard Set(actions.map(\.id)).count == actions.count else { throw CustomActionError.duplicateID }
        if enforceValidation { try actions.forEach(Self.validate) }
        let data = try encodeLibrary(actions)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}
