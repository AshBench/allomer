import Foundation

// Ordinary XML uses an ordered tree. Generated configuration XML keeps each value's type.
enum ConfigXML {
    private static let namespace = "urn:ashbench:allomer:config:1"

    static func read(_ data: Data) throws -> ConfigValue {
        let encoding: String.Encoding
        if data.starts(with: [0xff, 0xfe, 0, 0]) || data.starts(with: [0, 0, 0xfe, 0xff]) { encoding = .utf32 }
        else if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]) { encoding = .utf16 }
        else if data.starts(with: [0, 0x3c]) { encoding = .utf16BigEndian }
        else if data.starts(with: [0x3c, 0]) { encoding = .utf16LittleEndian }
        else { encoding = .utf8 }
        guard let text = String(data: data, encoding: encoding) else {
            throw ConversionError.message("Use UTF-8 or UTF-16 XML for configuration conversion.")
        }
        let declarations = try NSRegularExpression(pattern: "<!--.*?-->|<!\\[CDATA\\[.*?\\]\\]>|<\\?.*?\\?>|<!DOCTYPE",
                                                   options: [.dotMatchesLineSeparators])
        if declarations.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains(where: {
            Range($0.range, in: text).map { text[$0] == "<!DOCTYPE" } ?? false
        }) { throw ConversionError.message("XML document type declarations are unsupported.") }
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = reader
        guard parser.parse(), reader.failure == nil else {
            throw reader.failure ?? parser.parserError ?? ConversionError.message("The XML could not be read.")
        }
        if let root = reader.nodes.first(where: { $0.kind == .element }) as? XMLElement,
           root.name == "configuration", root.namespace(forPrefix: "")?.stringValue == namespace {
            guard let value = root.children?.compactMap({ $0 as? XMLElement }).only else { throw invalid() }
            return try decode(value)
        }
        return .object(["$xml": .array(try reader.nodes.map(tree))])
    }

    static func write(_ value: ConfigValue, pretty: Bool) throws -> Data {
        let document = XMLDocument()
        document.characterEncoding = "UTF-8"
        if case .object(let fields) = value, fields.count == 1, case .array(let nodes) = fields["$xml"] {
            document.setChildren(try nodes.map(fromTree))
            guard document.children?.filter({ $0.kind == .element }).count == 1 else { throw invalid() }
            return document.xmlData
        }
        let root = XMLElement(name: "configuration")
        root.addNamespace(XMLNode.namespace(withName: "", stringValue: namespace) as! XMLNode)
        root.addChild(try encode(value))
        document.setRootElement(root)
        return document.xmlData(options: pretty ? [.nodePrettyPrint] : [])
    }

    private static func invalid() -> ConversionError { .message("The XML configuration structure is invalid or unsupported.") }

    private static func encode(_ value: ConfigValue) throws -> XMLElement {
        let node = XMLElement(name: "value")
        let type: String
        switch value {
        case .object(let fields):
            type = "object"
            for key in fields.keys.sorted() {
                let entry = XMLElement(name: "entry")
                entry.addAttribute(XMLNode.attribute(withName: "key", stringValue: key) as! XMLNode)
                entry.addChild(try encode(fields[key]!))
                node.addChild(entry)
            }
        case .array(let items):
            type = "array"
            for item in items { node.addChild(try encode(item)) }
        case .string(let text): type = "string"; node.stringValue = text
        case .integer(let text): type = "integer"; node.stringValue = text
        case .real(let number): type = "real"; node.stringValue = String(number)
        case .bool(let flag): type = "boolean"; node.stringValue = flag ? "true" : "false"
        case .null: type = "null"
        case .data(let data): type = "data"; node.stringValue = data.base64EncodedString()
        case .date(let date): type = "date"; node.stringValue = String(date.timeIntervalSince1970)
        }
        node.addAttribute(XMLNode.attribute(withName: "type", stringValue: type) as! XMLNode)
        return node
    }

    private static func decode(_ node: XMLElement) throws -> ConfigValue {
        guard node.name == "value", node.attributes?.count == 1,
              let type = node.attribute(forName: "type")?.stringValue else { throw invalid() }
        let text = node.stringValue ?? ""
        let elements = node.children?.compactMap { $0 as? XMLElement } ?? []
        if ["object", "array"].contains(type), node.children?.contains(where: {
            $0.kind == .text && !($0.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) == true { throw invalid() }
        if !["object", "array"].contains(type), !elements.isEmpty { throw invalid() }
        switch type {
        case "object":
            var fields: [String: ConfigValue] = [:]
            for entry in elements {
                guard entry.name == "entry", entry.attributes?.count == 1,
                      let key = entry.attribute(forName: "key")?.stringValue, fields[key] == nil,
                      let child = entry.children?.compactMap({ $0 as? XMLElement }).only else { throw invalid() }
                fields[key] = try decode(child)
            }
            return .object(fields)
        case "array": return .array(try elements.map(decode))
        case "string": return .string(text)
        case "integer":
            if let number = Int64(text) { return .integer(String(number)) }
            if let number = UInt64(text) { return .integer(String(number)) }
        case "real": if let number = Double(text), number.isFinite { return .real(number) }
        case "boolean": if ["true", "false"].contains(text) { return .bool(text == "true") }
        case "null": if text.isEmpty { return .null }
        case "data": if let data = Data(base64Encoded: text) { return .data(data) }
        case "date": if let time = Double(text), time.isFinite { return .date(Date(timeIntervalSince1970: time)) }
        default: break
        }
        throw invalid()
    }

    private static func tree(_ node: XMLNode) throws -> ConfigValue {
        switch node.kind {
        case .element:
            guard let element = node as? XMLElement, let name = element.name else { throw invalid() }
            var attrs: [String: ConfigValue] = [:]
            for attr in (element.attributes ?? []) + (element.namespaces ?? []) {
                let key = attr.kind == .namespace ? (attr.name == "" ? "xmlns" : "xmlns:\(attr.name ?? "")") : attr.name!
                attrs[key] = .string(attr.stringValue ?? "")
            }
            return .object(["name": .string(name), "attributes": .object(attrs),
                            "children": .array(try (element.children ?? []).map(tree))])
        case .text: return .object(["text": .string(node.stringValue ?? "")])
        case .comment: return .object(["comment": .string(node.stringValue ?? "")])
        case .processingInstruction:
            return .object(["instruction": .string(node.name ?? ""), "value": .string(node.stringValue ?? "")])
        default: throw invalid()
        }
    }

    private static func fromTree(_ value: ConfigValue) throws -> XMLNode {
        guard case .object(let fields) = value else { throw invalid() }
        if fields.count == 1, case .string(let text) = fields["text"] { return XMLNode.text(withStringValue: text) as! XMLNode }
        if fields.count == 1, case .string(let text) = fields["comment"] { return XMLNode.comment(withStringValue: text) as! XMLNode }
        if fields.count == 2, case .string(let name) = fields["instruction"], case .string(let text) = fields["value"] {
            return XMLNode.processingInstruction(withName: name, stringValue: text) as! XMLNode
        }
        guard fields.count == 3, case .string(let name) = fields["name"],
              case .object(let attrs) = fields["attributes"], case .array(let children) = fields["children"] else { throw invalid() }
        let element = XMLElement(name: name)
        for key in attrs.keys.sorted() {
            guard case .string(let text) = attrs[key] else { throw invalid() }
            if key == "xmlns" || key.hasPrefix("xmlns:") {
                element.addNamespace(XMLNode.namespace(withName: key == "xmlns" ? "" : String(key.dropFirst(6)), stringValue: text) as! XMLNode)
            } else {
                element.addAttribute(XMLNode.attribute(withName: key, stringValue: text) as! XMLNode)
            }
        }
        for child in children { element.addChild(try fromTree(child)) }
        return element
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var nodes: [XMLNode] = []
        var stack: [XMLElement] = []
        var characters: [String] = []
        var count = 0
        var failure: Error?

        func append(_ node: XMLNode, parser: XMLParser) {
            count += 1
            guard count <= 250_000, !Task.isCancelled else {
                failure = Task.isCancelled ? CancellationError() : ConversionError.message("The XML exceeds the node limit.")
                parser.abortParsing()
                return
            }
            if let parent = stack.last { parent.addChild(node) } else { nodes.append(node) }
        }

        func flushCharacters(_ parser: XMLParser) {
            if !characters.isEmpty {
                if !stack.isEmpty { append(XMLNode.text(withStringValue: characters.joined()) as! XMLNode, parser: parser) }
                characters.removeAll(keepingCapacity: true)
            }
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String]) {
            flushCharacters(parser)
            count += attributes.count
            guard stack.count < 64, count <= 250_000 else {
                failure = ConversionError.message("The XML exceeds the size or depth limit.")
                parser.abortParsing()
                return
            }
            let element = XMLElement(name: name)
            for (key, value) in attributes {
                if key == "xmlns" || key.hasPrefix("xmlns:") {
                    element.addNamespace(XMLNode.namespace(withName: key == "xmlns" ? "" : String(key.dropFirst(6)), stringValue: value) as! XMLNode)
                } else { element.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode) }
            }
            append(element, parser: parser)
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            flushCharacters(parser)
            if !stack.isEmpty { stack.removeLast() }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            characters.append(string)
        }
        func parser(_ parser: XMLParser, foundCDATA data: Data) {
            guard let text = String(data: data, encoding: .utf8) else { failure = invalid(); parser.abortParsing(); return }
            self.parser(parser, foundCharacters: text)
        }
        func parser(_ parser: XMLParser, foundComment comment: String) {
            flushCharacters(parser)
            append(XMLNode.comment(withStringValue: comment) as! XMLNode, parser: parser)
        }
        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
            flushCharacters(parser)
            append(XMLNode.processingInstruction(withName: target, stringValue: data ?? "") as! XMLNode, parser: parser)
        }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            failure = ConversionError.message("XML entity declarations are unsupported.")
            parser.abortParsing()
        }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
            failure = ConversionError.message("XML external entities are unsupported.")
            parser.abortParsing()
        }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
