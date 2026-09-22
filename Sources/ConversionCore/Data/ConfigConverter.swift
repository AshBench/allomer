import ConfigBridge
import CoreFoundation
import CYaml
import Foundation
import Yams

public struct ConfigOptions: Codable, Equatable, Sendable {
    public var prettyPrint = true
    public var inferStringTypes = false
    public var binaryPlist = false
    public init() {}
}

indirect enum ConfigValue: Equatable {
    case object([String: ConfigValue]), array([ConfigValue]), string(String)
    case integer(String), real(Double), bool(Bool), null, data(Data), date(Date)
}

public enum ConfigConverter {
    public static let formats: Set<String> = ["json", "yaml", "toml", "plist", "xml"]
    private static let inputLimit = 16 * 1024 * 1024
    private static let outputLimit = 64 * 1024 * 1024

    public static func convert(_ source: URL, to destination: URL, from input: FileFormat,
                               to output: FileFormat, options: ConfigOptions = ConfigOptions()) throws {
        guard formats.contains(input.id), formats.contains(output.id) else {
            throw ConversionError.message("These configuration formats cannot be converted together.")
        }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: inputLimit + 1) ?? Data()
        guard bytes.count <= inputLimit else {
            throw ConversionError.message("Configuration files are limited to 16 MiB in this build.")
        }
        try Task.checkCancellation()
        let value = try read(bytes, format: input.id, inferStrings: options.inferStringTypes)
        let result = try write(value, format: output.id, options: options)
        guard result.count <= outputLimit else {
            throw ConversionError.message("The expanded configuration exceeds 64 MiB.")
        }
        guard try read(result, format: output.id) == value else {
            throw ConversionError.message("The output would change a configuration value. The original was kept.")
        }
        try Task.checkCancellation()
        try result.write(to: destination, options: .withoutOverwriting)
    }

    static func read(_ data: Data, format: String, inferStrings: Bool = false) throws -> ConfigValue {
        var result: ConfigValue
        switch format {
        case "plist":
            result = try fromPropertyList(PropertyListSerialization.propertyList(from: data, format: nil))
        case "xml":
            result = try ConfigXML.read(data)
        case "toml":
            var success: Int32 = 0
            let text = try utf8(data)
            let pointer = text.withCString { rc_toml_json($0, text.utf8.count, &success) }
            guard let pointer else { throw ConversionError.message("The TOML parser ran out of memory.") }
            defer { free(pointer) }
            let converted = String(cString: pointer)
            guard success == 1 else { throw ConversionError.message(converted) }
            result = try read(Data(converted.utf8), format: "json")
        case "json", "yaml":
            if format == "json" {
                try autoreleasepool {
                    _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                }
            }
            _ = try utf8(data)
            result = try parseValues(data, json: format == "json")
        default:
            throw ConversionError.message("Unknown configuration format.")
        }
        if inferStrings { result = try infer(result) }
        return result
    }

    static func write(_ value: ConfigValue, format: String, options: ConfigOptions) throws -> Data {
        switch format {
        case "json": return Data(try json(value, pretty: options.prettyPrint).utf8)
        case "yaml":
            return Data(try Yams.serialize(node: yaml(value, pretty: options.prettyPrint),
                indent: 2, allowUnicode: true, sortKeys: true).utf8)
        case "toml":
            guard case .object(let fields) = value else {
                throw ConversionError.message("TOML requires an object at the top level.")
            }
            return Data(try fields.keys.sorted().map { key in
                try quoted(key) + " = " + toml(fields[key]!)
            }.joined(separator: "\n").appending("\n").utf8)
        case "plist":
            return try PropertyListSerialization.data(fromPropertyList: propertyList(value),
                format: options.binaryPlist ? .binary : .xml, options: 0)
        case "xml": return try ConfigXML.write(value, pretty: options.prettyPrint)
        default: throw ConversionError.message("Unknown configuration format.")
        }
    }

    private static func utf8(_ bytes: Data) throws -> String {
        guard let text = String(data: bytes, encoding: .utf8), !text.contains("\0") else {
            throw ConversionError.message("Use a UTF-8 configuration file without raw NUL bytes.")
        }
        return text
    }

    private static func scalar(_ node: Node) throws -> ConfigValue {
        if case .scalar(let scalar) = node {
            let typed = Node.scalar(.init(scalar.string, node.tag, .plain))
            switch node.tag {
            case Tag(.str): return .string(scalar.string)
            case Tag(.null): return .null
            case Tag(.bool):
                if let value = typed.bool { return .bool(value) }
            case Tag(.int):
                if let value = Int64.construct(from: typed.scalar!) { return .integer(String(value)) }
                if let value = UInt64.construct(from: typed.scalar!) { return .integer(String(value)) }
            case Tag(.float):
                if let value = typed.float, value.isFinite,
                   normalizedNumber(scalar.string) == normalizedNumber(String(value)) { return .real(value) }
            case Tag(.binary):
                if let value = typed.binary { return .data(value) }
            case Tag(.timestamp):
                if let value = typed.timestamp { return .date(value) }
            default: break
            }
            throw ConversionError.message("A YAML value has an unsupported type or exceeds the numeric precision limit.")
        }
        throw ConversionError.message("A scalar value was expected.")
    }

    // Compare decimal spellings without rounding them through floating point.
    private static func normalizedNumber(_ text: String) -> String? {
        let text = text.lowercased().replacingOccurrences(of: "_", with: "")
        guard text.count <= 4096,
              text.range(of: "^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:e[+-]?[0-9]+)?$",
                         options: .regularExpression) != nil else { return nil }
        let parts = text.split(separator: "e")
        guard let exponent = parts.count == 2 ? Int(parts[1]) : 0,
              (-10000...10000).contains(exponent) else { return nil }
        let negative = parts[0].hasPrefix("-")
        let mantissa = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        let fraction = mantissa.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
        var digits = mantissa.replacingOccurrences(of: ".", with: "")
        while digits.first == "0" { digits.removeFirst() }
        if digits.isEmpty { return "0" }
        var power = exponent - fraction
        while digits.last == "0" { digits.removeLast(); power += 1 }
        return (negative ? "-" : "") + digits + "e\(power)"
    }

    static func infer(_ value: ConfigValue) throws -> ConfigValue {
        switch value {
        case .object(let fields): return .object(try fields.mapValues(infer))
        case .array(let items): return .array(try items.map(infer))
        case .string(let text):
            if text == "true" { return .bool(true) }
            if text == "false" { return .bool(false) }
            if let number = Int64(text), String(number) == text { return .integer(text) }
            if let number = UInt64(text), String(number) == text { return .integer(text) }
            if text.contains(".") || text.lowercased().contains("e"), let number = Double(text), number.isFinite,
               normalizedNumber(text) == normalizedNumber(String(number)) { return .real(number) }
            return value
        default: return value
        }
    }

    private static func quoted(_ text: String) throws -> String {
        try autoreleasepool {
            String(decoding: try JSONSerialization.data(withJSONObject: text,
                options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
        }
    }

    private static func json(_ value: ConfigValue, pretty: Bool, depth: Int = 0) throws -> String {
        let space = pretty ? " " : ""
        let indent = pretty ? String(repeating: "  ", count: depth + 1) : ""
        let line = pretty ? "\n" : ""
        func collection(_ items: [String], _ open: String, _ close: String) -> String {
            if items.isEmpty { return open + close }
            return open + line + indent + items.joined(separator: "," + line + indent)
                + line + (pretty ? String(repeating: "  ", count: depth) : "") + close
        }
        switch value {
        case .object(let fields):
            return try collection(fields.keys.sorted().map {
                try quoted($0) + ":" + space + json(fields[$0]!, pretty: pretty, depth: depth + 1)
            }, "{", "}")
        case .array(let items):
            return try collection(items.map { try json($0, pretty: pretty, depth: depth + 1) }, "[", "]")
        case .string(let text): return try quoted(text)
        case .integer(let text): return text
        case .real(let number): return String(number)
        case .bool(let flag): return flag ? "true" : "false"
        case .null: return "null"
        case .data, .date: throw ConversionError.message("JSON cannot store plist data or date values without changing their type.")
        }
    }

    private static func yaml(_ value: ConfigValue, pretty: Bool) throws -> Node {
        switch value {
        case .object(let fields):
            return Node(try fields.keys.sorted().map { (Node($0, Tag(.str)), try yaml(fields[$0]!, pretty: pretty)) },
                .implicit, pretty ? .block : .flow)
        case .array(let items):
            return Node(try items.map { try yaml($0, pretty: pretty) }, .implicit, pretty ? .block : .flow)
        case .string(let text): return Node(text, Tag(.str), .doubleQuoted)
        case .integer(let text): return Node(text, Tag(.int))
        case .real(let number): return Node(String(number), Tag(.float))
        case .bool(let flag): return Node(flag ? "true" : "false", Tag(.bool))
        case .null: return Node("null", Tag(.null))
        case .data(let data): return Node(data.base64EncodedString(), Tag(.binary))
        case .date(let date):
            return Node(date.ISO8601Format(.init(includingFractionalSeconds: true)), Tag(.timestamp))
        }
    }

    private static func toml(_ value: ConfigValue) throws -> String {
        switch value {
        case .object(let fields):
            return try "{ " + fields.keys.sorted().map { try quoted($0) + " = " + toml(fields[$0]!) }.joined(separator: ", ") + " }"
        case .array(let items): return try "[" + items.map(toml).joined(separator: ", ") + "]"
        case .integer(let text):
            guard Int64(text) != nil else { throw ConversionError.message("TOML integers must fit in signed 64 bits.") }
            return text
        case .null, .data, .date:
            throw ConversionError.message("TOML cannot store this null, binary, or date value through this conversion path.")
        default: return try json(value, pretty: false)
        }
    }

    private static func fromPropertyList(_ value: Any, depth: Int = 0) throws -> ConfigValue {
        guard depth <= 64 else { throw ConversionError.message("The plist is nested too deeply.") }
        switch value {
        case let fields as [String: Any]: return .object(try fields.mapValues { try fromPropertyList($0, depth: depth + 1) })
        case let items as [Any]: return .array(try items.map { try fromPropertyList($0, depth: depth + 1) })
        case let string as String: return .string(string)
        case let data as Data: return .data(data)
        case let date as Date: return .date(date)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if ["f", "d"].contains(String(cString: number.objCType)) {
                guard number.doubleValue.isFinite else { throw ConversionError.message("Non-finite plist numbers are unsupported.") }
                return .real(number.doubleValue)
            }
            return .integer(number.stringValue)
        default: throw ConversionError.message("This plist value is unsupported.")
        }
    }

    private static func propertyList(_ value: ConfigValue) throws -> Any {
        switch value {
        case .object(let fields): return try fields.mapValues(propertyList)
        case .array(let items): return try items.map(propertyList)
        case .string(let text): return text
        case .integer(let text):
            if let number = Int64(text) { return NSNumber(value: number) }
            if let number = UInt64(text) { return NSNumber(value: number) }
            throw ConversionError.message("The integer exceeds the plist limit.")
        case .real(let number): return NSNumber(value: number)
        case .bool(let flag): return flag
        case .data(let data): return data
        case .date(let date): return date
        case .null: throw ConversionError.message("Property lists cannot store null values.")
        }
    }

    private static func parseValues(_ data: Data, json: Bool) throws -> ConfigValue {
        struct Value {
            var value: ConfigValue
            var nodes = 1
            var bytes = 0
            var depth = 0
            var merge = false
        }
        struct Frame {
            var mapping: Bool
            var anchor: String?
            var key: (name: String, merge: Bool)?
            var fields: [String: ConfigValue] = [:]
            var defaults: [String: ConfigValue] = [:]
            var items: [ConfigValue] = []
            var keys: Set<String> = []
            var size = Value(value: .null)
        }
        var parser = yaml_parser_t()
        guard yaml_parser_initialize(&parser) == 1 else { throw ConversionError.message("The YAML parser could not start.") }
        defer { yaml_parser_delete(&parser) }
        return try data.withUnsafeBytes { buffer in
            yaml_parser_set_input_string(&parser, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
            var stack: [Frame] = []
            var anchors: [String: Value] = [:]
            var root: ConfigValue?
            var documents = 0
            while true {
                try Task.checkCancellation()
                var event = yaml_event_t()
                guard yaml_parser_parse(&parser, &event) == 1 else {
                    throw ConversionError.message("Invalid YAML near line \(parser.problem_mark.line + 1).")
                }
                defer { yaml_event_delete(&event) }
                func string(_ pointer: UnsafePointer<UInt8>?) -> String? { pointer.map { String(cString: $0) } }
                var value = Value(value: .null)
                var anchor: String?
                switch event.type {
                case YAML_STREAM_END_EVENT:
                    guard let root else { throw ConversionError.message("The configuration file is empty.") }
                    return root
                case YAML_DOCUMENT_START_EVENT:
                    documents += 1
                    guard documents == 1 else { throw ConversionError.message("Use one YAML document per file.") }
                    continue
                case YAML_MAPPING_START_EVENT, YAML_SEQUENCE_START_EVENT:
                    guard stack.count < 64 else { throw ConversionError.message("The configuration is nested too deeply.") }
                    let mapping = event.type == YAML_MAPPING_START_EVENT
                    anchor = mapping ? string(event.data.mapping_start.anchor) : string(event.data.sequence_start.anchor)
                    let tag = mapping ? string(event.data.mapping_start.tag) : string(event.data.sequence_start.tag)
                    guard tag == nil || tag == "!" || tag == (mapping ? Tag.Name.map.rawValue : Tag.Name.seq.rawValue) else {
                        throw ConversionError.message("Custom YAML collection tags are unsupported.")
                    }
                    stack.append(Frame(mapping: mapping, anchor: anchor))
                    continue
                case YAML_MAPPING_END_EVENT, YAML_SEQUENCE_END_EVENT:
                    let frame = stack.removeLast()
                    guard frame.key == nil else { throw ConversionError.message("An object value is missing.") }
                    value = frame.size
                    value.value = frame.mapping ? .object(frame.defaults.merging(frame.fields) { _, explicit in explicit }) : .array(frame.items)
                    anchor = frame.anchor
                case YAML_SCALAR_EVENT:
                    let raw = event.data.scalar
                    let text = String(decoding: UnsafeBufferPointer(start: raw.value, count: raw.length), as: UTF8.self)
                    value.bytes = raw.length
                    anchor = string(raw.anchor)
                    if json {
                        if raw.style != YAML_PLAIN_SCALAR_STYLE { value.value = .string(text) }
                        else if text == "null" { value.value = .null }
                        else if text == "true" || text == "false" { value.value = .bool(text == "true") }
                        else if !text.contains(".") && !text.lowercased().contains("e"), Int64(text) != nil || UInt64(text) != nil {
                            value.value = .integer(Int64(text).map(String.init) ?? String(UInt64(text)!))
                        } else if text.contains(".") || text.lowercased().contains("e"), let number = Double(text), number.isFinite,
                                  normalizedNumber(text) == normalizedNumber(String(number)) {
                            value.value = .real(number)
                        } else { throw ConversionError.message("A JSON number exceeds the numeric precision limit.") }
                    } else {
                        value.value = try autoreleasepool {
                            let tag = string(raw.tag).map { Tag(.init(rawValue: $0)) } ?? (raw.quoted_implicit == 1 ? Tag(.str) : .implicit)
                            let node = Node(text, tag)
                            value.merge = node.tag == Tag(.merge)
                            return value.merge ? .string("<<") : try scalar(node)
                        }
                    }
                case YAML_ALIAS_EVENT:
                    guard let name = string(event.data.alias.anchor), let known = anchors[name] else {
                        throw ConversionError.message("The YAML has a recursive or unknown alias.")
                    }
                    value = known
                default: continue
                }
                if let anchor { anchors[anchor] = value }
                guard var frame = stack.popLast() else { root = value.value; continue }
                frame.size.nodes += value.nodes
                frame.size.bytes += value.bytes
                frame.size.depth = max(frame.size.depth, value.depth + 1)
                guard frame.size.nodes <= 250_000, frame.size.bytes <= outputLimit, frame.size.depth <= 64 else {
                    throw ConversionError.message("YAML alias expansion exceeds the conversion limit.")
                }
                if !frame.mapping { frame.items.append(value.value) }
                else if let key = frame.key {
                    if key.merge {
                        let items: [ConfigValue]
                        if case .array(let entries) = value.value { items = entries } else { items = [value.value] }
                        for item in items {
                            guard case .object(let defaults) = item else { throw ConversionError.message("A YAML merge needs an object or list of objects.") }
                            frame.defaults.merge(defaults) { first, _ in first }
                        }
                    } else { frame.fields[key.name] = value.value }
                    frame.key = nil
                } else {
                    guard case .string(let key) = value.value, frame.keys.insert(key).inserted else {
                        throw ConversionError.message("Configuration object keys must be unique strings.")
                    }
                    frame.key = (key, value.merge)
                }
                stack.append(frame)
            }
        }
    }
}
