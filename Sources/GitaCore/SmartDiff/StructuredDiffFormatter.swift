import CoreFoundation
import Foundation

public enum StructuredDiffFormat: String, CaseIterable, Sendable, Equatable {
    case json, xcstrings, plist, svg, markdown
}

public enum StructuredChangeKind: String, Sendable, Equatable { case added, removed, modified }

public struct StructuredDiffEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let keyPath: String
    public let kind: StructuredChangeKind
    public let oldValue: String?
    public let newValue: String?
    public let section: String?

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.keyPath == rhs.keyPath
            && lhs.kind == rhs.kind
            && lhs.oldValue == rhs.oldValue
            && lhs.newValue == rhs.newValue
            && lhs.section == rhs.section
    }
}

public enum StructuredDiffResult: Sendable, Equatable {
    case unsupported
    case parsed(format: StructuredDiffFormat, entries: [StructuredDiffEntry], truncated: Bool)
    case fallback(format: StructuredDiffFormat, reason: String)
}

struct StructuredLeaf: Equatable {
    let value: String
    var type = "text"
    var section: String?

    func displayed(alongside other: Self?) -> String {
        if type == "text", let other, other.type != type, other.value == value { return String(reflecting: value) }
        return value
    }
}

struct StructuredFields {
    private(set) var values: [String: StructuredLeaf] = [:]
    private(set) var order: [String] = []
    private var containers: [String: String] = [:]
    private var pathBytes = 0

    enum ParseError: Error { case malformed, complexityLimit }

    mutating func add(_ path: String, _ value: String, type: String = "text", section: String? = nil) throws {
        try account(for: path)
        guard values[path] == nil else { throw ParseError.malformed }
        values[path] = StructuredLeaf(value: value, type: type, section: section)
        order.append(path)
    }

    private mutating func account(for path: String) throws {
        pathBytes += path.utf8.count
        guard pathBytes <= 16_000_000, values.count + containers.count < 250_000 else {
            throw ParseError.complexityLimit
        }
    }

    func changes(to new: Self, format: StructuredDiffFormat, limit: Int) -> StructuredDiffResult {
        var entries: [StructuredDiffEntry] = []
        let keys = order + new.order.filter { values[$0] == nil }
        for key in keys {
            let before = values[key]
            let after = new.values[key]
            guard before != after else { continue }
            if after == nil, let type = before?.type, type == new.containers[key] { continue }
            if before == nil, let type = after?.type, type == containers[key] { continue }
            guard entries.count < limit else { return .parsed(format: format, entries: entries, truncated: true) }
            let kind: StructuredChangeKind = before == nil ? .added : (after == nil ? .removed : .modified)
            entries.append(
                StructuredDiffEntry(
                    id: key, keyPath: key, kind: kind, oldValue: before?.displayed(alongside: after),
                    newValue: after?.displayed(alongside: before), section: after?.section ?? before?.section))
        }
        return .parsed(format: format, entries: entries, truncated: false)
    }
}

public enum StructuredDiffFormatter {
    public static func detectFormat(for path: String) -> StructuredDiffFormat? {
        switch URL(filePath: path).pathExtension.lowercased() {
        case "json": .json
        case "xcstrings": .xcstrings
        case "plist": .plist
        case "svg": .svg
        case "md", "markdown", "mdown": .markdown
        default: nil
        }
    }

    public static func diff(
        oldText: String, newText: String, path: String, maxEntries: Int = 2_000, maxInputBytes: Int = 2_000_000
    ) -> StructuredDiffResult {
        guard let format = detectFormat(for: path) else { return .unsupported }
        guard max(oldText.utf8.count, newText.utf8.count) <= maxInputBytes else { return oversized(format) }
        return diff(
            oldData: Data(oldText.utf8), newData: Data(newText.utf8), path: path,
            maxEntries: maxEntries, maxInputBytes: maxInputBytes)
    }

    /// Use this overload for binary plists, whose arbitrary bytes cannot round-trip through UTF-8 text.
    public static func diff(
        oldData: Data, newData: Data, path: String, maxEntries: Int = 2_000, maxInputBytes: Int = 2_000_000
    ) -> StructuredDiffResult {
        guard let format = detectFormat(for: path) else { return .unsupported }
        guard max(oldData.count, newData.count) <= maxInputBytes else { return oversized(format) }
        do {
            let before = try fields(oldData, format: format)
            let after = try fields(newData, format: format)
            return before.changes(to: after, format: format, limit: max(0, maxEntries))
        } catch {
            return .fallback(
                format: format, reason: String(localized: "Couldn’t read this file as structured content."))
        }
    }

    private static func oversized(_ format: StructuredDiffFormat) -> StructuredDiffResult {
        .fallback(format: format, reason: String(localized: "File exceeds the structured diff size limit."))
    }

    private static func fields(_ data: Data, format: StructuredDiffFormat) throws -> StructuredFields {
        if data.isEmpty { return StructuredFields() }
        var fields = StructuredFields()
        switch format {
        case .json, .xcstrings:
            let object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
            if format == .xcstrings { try fields.catalog(object) } else { try fields.flatten(object) }
        case .plist:
            try fields.flatten(PropertyListSerialization.propertyList(from: data, options: [], format: nil))
        case .svg: return try SVGFields.parse(data)
        case .markdown: return try MarkdownFields.parse(data)
        }
        return fields
    }
}

extension StructuredFields {
    mutating func flatten(_ object: Any, at path: String = "", depth: Int = 0, section: String? = nil) throws {
        guard depth < 128, path.utf8.count < 32_768 else { throw ParseError.complexityLimit }
        let key = path.isEmpty ? "$" : path
        if let dict = object as? [String: Any] {
            try account(for: key)
            containers[key] = "object"
            if dict.isEmpty { try add(key, "{}", type: "object", section: section) }
            for name in SmartDiffKeyOrder.sorted(dict.keys) {
                guard let value = dict[name] else { continue }
                try flatten(value, at: Self.child(name, of: path), depth: depth + 1, section: section)
            }
        } else if let array = object as? [Any] {
            try account(for: key)
            containers[key] = "array"
            if array.isEmpty { try add(key, "[]", type: "array", section: section) }
            for (index, value) in array.enumerated() {
                try flatten(value, at: "\(path)[\(index)]", depth: depth + 1, section: section)
            }
        } else {
            let scalar = try Self.scalar(object)
            try add(key, scalar.value, type: scalar.type, section: section)
        }
    }

    private static func child(_ name: String, of path: String) -> String {
        if name.isEmpty || name.contains(where: { ".[]\\\"$".contains($0) }) {
            return "\(path)[\(String(reflecting: name))]"
        }
        return path.isEmpty ? name : "\(path).\(name)"
    }

    private static func scalar(_ value: Any) throws -> StructuredLeaf {
        if let string = value as? String { return StructuredLeaf(value: string) }
        let type = CFGetTypeID(value as CFTypeRef)
        if type == CFBooleanGetTypeID(), let boolean = value as? Bool {
            return StructuredLeaf(value: boolean ? "true" : "false", type: "boolean")
        }
        if type == CFNumberGetTypeID() {
            return StructuredLeaf(value: String(describing: value), type: "number")
        }
        if value is NSNull { return StructuredLeaf(value: "null", type: "null") }
        if let date = value as? Date {
            return StructuredLeaf(
                value: date.ISO8601Format(.init(includingFractionalSeconds: true)), type: "date")
        }
        if let data = value as? Data { return StructuredLeaf(value: data.base64EncodedString(), type: "data") }
        throw ParseError.malformed
    }

    mutating func catalog(_ object: Any) throws {
        guard var root = object as? [String: Any], let strings = root.removeValue(forKey: "strings") as? [String: Any]
        else { throw ParseError.malformed }
        try flatten(root, at: "$catalog")
        for key in SmartDiffKeyOrder.sorted(strings.keys) {
            guard var entry = strings[key] as? [String: Any] else { throw ParseError.malformed }
            let prefix = String(reflecting: key)
            let locales = entry.removeValue(forKey: "localizations")
            if !entry.isEmpty || locales == nil { try flatten(entry, at: prefix, section: key) }
            if let locales { try flattenLocales(locales, prefix: prefix, section: key) }
        }
    }

    private mutating func flattenLocales(_ locales: Any, prefix: String, section: String) throws {
        guard let dictionary = locales as? [String: Any] else { throw ParseError.malformed }
        for locale in SmartDiffKeyOrder.sorted(dictionary.keys) {
            guard var unit = dictionary[locale] as? [String: Any] else { throw ParseError.malformed }
            let path = "\(prefix) [\(locale)]"
            if let simple = unit.removeValue(forKey: "stringUnit") {
                try flatten(simple, at: path, section: section)
            }
            if !unit.isEmpty { try flatten(unit, at: "\(path).details", section: section) }
        }
    }
}
