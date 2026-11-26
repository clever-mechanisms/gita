import Foundation

final class SVGFields: NSObject, XMLParserDelegate {
    private struct Element {
        let path: String
        var siblings: [String: Int] = [:]
        var text = ""
    }

    private var fields = StructuredFields()
    private var stack: [Element] = []
    private var invalid = false

    static func parse(_ data: Data) throws -> StructuredFields {
        // A visual comparison only needs the document's elements. Reject DTDs before XMLParser
        // can expand any internal entities (including documents supplied in UTF-16).
        let markup = String(decoding: data.filter { $0 != 0 }, as: UTF8.self)
        guard markup.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil else {
            throw StructuredFields.ParseError.malformed
        }
        let reader = SVGFields()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = reader
        guard parser.parse(), parser.parserError == nil, !reader.invalid, reader.stack.isEmpty,
            !reader.fields.order.isEmpty
        else {
            throw StructuredFields.ParseError.malformed
        }
        return reader.fields
    }

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI _: String?, qualifiedName _: String?,
        attributes: [String: String]
    ) {
        let path: String
        if stack.isEmpty {
            guard name == "svg", fields.order.isEmpty else {
                reject(parser)
                return
            }
            path = name
        } else {
            let parent = stack.count - 1
            let index = stack[parent].siblings[name, default: 0]
            stack[parent].siblings[name] = index + 1
            let component = attributes["id"].map { "\(name)#\($0)" } ?? "\(name)[\(index)]"
            path = "\(stack[parent].path)/\(component)"
        }
        guard stack.count < 128, path.utf8.count < 32_768 else {
            reject(parser)
            return
        }
        stack.append(Element(path: path))
        do {
            try fields.add(path, "<\(name)>")
            for key in SmartDiffKeyOrder.sorted(attributes.keys) {
                if let value = attributes[key] { try fields.add("\(path)@\(key)", value, section: path) }
            }
        } catch { reject(parser) }
    }

    func parser(_: XMLParser, foundCharacters string: String) {
        if !stack.isEmpty { stack[stack.count - 1].text.append(string) }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        self.parser(parser, foundCharacters: String(decoding: data, as: UTF8.self))
    }

    func parser(_ parser: XMLParser, didEndElement _: String, namespaceURI _: String?, qualifiedName _: String?) {
        guard let element = stack.popLast() else {
            reject(parser)
            return
        }
        let text = element.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do { try fields.add(element.path + "/text()", text, section: element.path) } catch { reject(parser) }
    }

    private func reject(_ parser: XMLParser) {
        invalid = true
        parser.abortParsing()
    }
}

enum MarkdownFields {
    static func parse(_ data: Data) throws -> StructuredFields {
        guard let text = String(data: data, encoding: .utf8) else { throw StructuredFields.ParseError.malformed }
        var headings: [(level: Int, title: String)] = []
        var fields = StructuredFields()
        var body: [Substring] = []
        var path = String(localized: "Preamble")
        var counts: [String: Int] = [:]
        var fence: Substring = ""
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.drop(while: { $0 == " " })
            let marker = trimmed.prefix { $0 == trimmed.first }
            if fence.isEmpty, marker.count >= 3, marker.first == "\u{60}" || marker.first == "~" {
                fence = marker
            } else if !fence.isEmpty, trimmed.hasPrefix(fence),
                trimmed.dropFirst(marker.count).allSatisfy(\.isWhitespace)
            {
                fence = ""
            } else if fence.isEmpty, marker.first == "#", marker.count <= 6,
                trimmed.dropFirst(marker.count).first?.isWhitespace == true
            {
                if !headings.isEmpty || !body.isEmpty {
                    try fields.add(path, body.joined(separator: "\n"), section: path)
                }
                while let last = headings.last, last.level >= marker.count { headings.removeLast() }
                headings.append((marker.count, String(trimmed)))
                let base = headings.map(\.title).joined(separator: " > ")
                counts[base, default: 0] += 1
                let count = counts[base, default: 1]
                path = count == 1 ? base : "\(base) [\(count)]"
                body.removeAll(keepingCapacity: true)
                continue
            }
            body.append(line)
        }
        try fields.add(path, body.joined(separator: "\n"), section: path)
        return fields
    }
}
