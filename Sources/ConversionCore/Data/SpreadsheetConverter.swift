import Foundation

public struct SpreadsheetOptions: Codable, Equatable, Sendable {
    public enum Delimiter: String, Codable, CaseIterable, Sendable {
        case comma, semicolon, tab, pipe
        var code: Int {
            switch self {
            case .comma: 44
            case .semicolon: 59
            case .tab: 9
            case .pipe: 124
            }
        }
    }
    public var csvDelimiter: Delimiter = .comma
    public var sheetIndex = 0
    // JSON record output only. Off generates positional column names and keeps every row.
    public var csvHeaderRow = true
    public var xmlHeaderRow = true
    public var inferTypes = false
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case csvDelimiter, sheetIndex, csvHeaderRow, xmlHeaderRow, inferTypes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        csvDelimiter = try values.decodeIfPresent(Delimiter.self, forKey: .csvDelimiter) ?? .comma
        sheetIndex = try values.decodeIfPresent(Int.self, forKey: .sheetIndex) ?? 0
        csvHeaderRow = try values.decodeIfPresent(Bool.self, forKey: .csvHeaderRow) ?? true
        xmlHeaderRow = try values.decodeIfPresent(Bool.self, forKey: .xmlHeaderRow) ?? true
        inferTypes = try values.decodeIfPresent(Bool.self, forKey: .inferTypes) ?? false
    }
}

enum SpreadsheetConverter {
    static let inputFormats: Set<String> = ["csv", "tsv", "xls", "xlsx", "json", "xml"]
    static let outputFormats: Set<String> = ["csv", "tsv", "xlsx", "json"]

    static func convert(_ input: URL, to output: URL, from source: FileFormat, to target: FileFormat,
                        tool: URL, options: SpreadsheetOptions, configOptions: ConfigOptions) throws {
        guard inputFormats.contains(source.id), outputFormats.contains(target.id), (0..<10_000).contains(options.sheetIndex) else {
            throw ConversionError.message("These spreadsheet formats or sheet settings are not supported.")
        }
        let work = output.deletingLastPathComponent()
        let fromRows = work.appendingPathComponent("input-\(UUID().uuidString).rows")
        let toRows = work.appendingPathComponent("output-\(UUID().uuidString).rows")
        defer {
            try? FileManager.default.removeItem(at: fromRows)
            try? FileManager.default.removeItem(at: toRows)
        }
        let tableInput = ["json", "xml"].contains(source.id)
        if tableInput {
            let value = try ConfigConverter.read(readData(input), format: source.id)
            let rows = source.id == "xml" ? try xmlRows(value, options: options) : try jsonRows(value)
            let tree = ConfigValue.array(rows.map { .array($0.map(ConfigValue.string)) })
            var compact = ConfigOptions()
            compact.prettyPrint = false
            try ConfigConverter.write(tree, format: "json", options: compact).write(to: fromRows, options: .withoutOverwriting)
        }
        try ExternalTool.run(tool, arguments: [tableInput ? fromRows.path : input.path,
            target.id == "json" ? toRows.path : output.path, tableInput ? "rows" : source.id,
            target.id == "json" ? "rows" : target.id, String(options.sheetIndex), String(options.csvDelimiter.code)],
            workDirectory: work)
        if target.id == "json" {
            let table = try ConfigConverter.read(readData(toRows), format: "json")
            guard case .array(let items) = table else { throw invalidTable() }
            let rows = try items.map { row -> [String] in
                guard case .array(let fields) = row else { throw invalidTable() }
                return try fields.map { field in
                    guard case .string(let text) = field else { throw invalidTable() }
                    return text
                }
            }
            let value: ConfigValue
            let columns: [String]? = options.csvHeaderRow ? rows.first
                : rows.first.map { first in (1...max(1, first.count)).map { "column\($0)" } }
            if let header = columns {
                guard Set(header).count == header.count, !header.contains("") else {
                    throw ConversionError.message("JSON record output requires unique, nonempty column headers.")
                }
                value = .array(try (options.csvHeaderRow ? Array(rows.dropFirst()) : rows).map { row in
                    guard row.count == header.count else { throw invalidTable() }
                    return .object(try Dictionary(uniqueKeysWithValues: zip(header, row).map { key, text in
                        (key, options.inferTypes ? try ConfigConverter.infer(.string(text)) : .string(text))
                    }))
                })
            } else { value = .array([]) }
            let data = try ConfigConverter.write(value, format: "json", options: configOptions)
            guard try ConfigConverter.read(data, format: "json") == value else { throw invalidTable() }
            try data.write(to: output, options: .withoutOverwriting)
        }
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw ConversionError.message("The spreadsheet converter did not produce a file.")
        }
    }

    private static func readData(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 16 * 1024 * 1024 else {
            throw ConversionError.message("JSON and XML table data are limited to 16 MiB in this build.")
        }
        return data
    }

    private static func invalidTable() -> ConversionError {
        .message("Use a table with consistent columns. Nested XML and mixed row structures are not supported.")
    }

    private static func cell(_ value: ConfigValue) throws -> String {
        switch value {
        case .string(let text): return text
        case .null: return ""
        default:
            var options = ConfigOptions()
            options.prettyPrint = false
            return String(decoding: try ConfigConverter.write(value, format: "json", options: options), as: UTF8.self)
        }
    }

    private static func jsonRows(_ value: ConfigValue) throws -> [[String]] {
        let items: [ConfigValue]
        switch value {
        case .array(let array): items = array
        case .object: items = [value]
        default: throw invalidTable()
        }
        guard !items.isEmpty else { return [] }
        if case .array = items[0] {
            return try items.map {
                guard case .array(let row) = $0 else { throw invalidTable() }
                return try row.map(cell)
            }
        }
        var headers = Set<String>()
        for item in items {
            guard case .object(let fields) = item else { throw invalidTable() }
            headers.formUnion(fields.keys)
        }
        let columns = headers.sorted()
        guard !columns.isEmpty else { throw invalidTable() }
        try checkTableSize(rows: items.count + 1, columns: columns.count)
        return [columns] + (try items.map { item in
            guard case .object(let fields) = item else { throw invalidTable() }
            return try columns.map { try cell(fields[$0] ?? .null) }
        })
    }

    private static func xmlRows(_ value: ConfigValue, options: SpreadsheetOptions) throws -> [[String]] {
        guard case .object(let document) = value, case .array(let nodes) = document["$xml"] else {
            return try jsonRows(value)
        }
        func elements(_ values: [ConfigValue]) throws -> [[String: ConfigValue]] {
            try values.compactMap { value in
                guard case .object(let node) = value else { throw invalidTable() }
                if case .string = node["name"] { return node }
                if case .string(let text) = node["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw invalidTable()
                }
                return nil
            }
        }
        let roots = try elements(nodes)
        guard roots.count == 1, case .array(let children) = roots[0]["children"],
              case .object(let rootAttributes) = roots[0]["attributes"],
              rootAttributes.keys.allSatisfy({ $0 == "xmlns" || $0.hasPrefix("xmlns:") }) else { throw invalidTable() }
        let entries = try elements(children)
        if entries.isEmpty { return [] }
        var headers: [String] = []
        var headerSet = Set<String>()
        var records: [[String: String]] = []
        for entry in entries {
            guard entry["name"] == entries.first?["name"], case .object(let attributes) = entry["attributes"],
                  case .array(let fields) = entry["children"] else { throw invalidTable() }
            var row: [String: String] = [:]
            for name in attributes.keys.sorted() where name != "xmlns" && !name.hasPrefix("xmlns:") {
                row["@" + name] = try cell(options.inferTypes ? ConfigConverter.infer(attributes[name]!) : attributes[name]!)
                if headerSet.insert("@" + name).inserted { headers.append("@" + name) }
            }
            for field in try elements(fields) {
                guard case .string(let name) = field["name"], case .array(let content) = field["children"],
                      case .object(let attributes) = field["attributes"], attributes.isEmpty, row[name] == nil else { throw invalidTable() }
                var text = ""
                for part in content {
                    guard case .object(let node) = part else { throw invalidTable() }
                    if case .string(let fragment) = node["text"] { text += fragment }
                    else if node["comment"] == nil && node["instruction"] == nil { throw invalidTable() }
                }
                row[name] = options.inferTypes ? try cell(ConfigConverter.infer(.string(text))) : text
                if headerSet.insert(name).inserted { headers.append(name) }
            }
            records.append(row)
        }
        guard !headers.isEmpty else { throw invalidTable() }
        try checkTableSize(rows: records.count + 1, columns: headers.count)
        return (options.xmlHeaderRow ? [headers] : []) + records.map { record in headers.map { record[$0] ?? "" } }
    }

    private static func checkTableSize(rows: Int, columns: Int) throws {
        guard rows <= 250_000, columns <= 16_384, rows * (columns + 1) < 250_000 else {
            throw ConversionError.message("The JSON or XML table expands beyond its 250,000-value limit.")
        }
    }
}
