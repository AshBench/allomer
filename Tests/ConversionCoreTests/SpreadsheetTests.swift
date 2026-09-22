import Foundation
import XCTest

@testable import ConversionCore

final class SpreadsheetTests: XCTestCase {
    func testSpreadsheetConversionAndAutomaticUndo() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("tabular").path) else {
            throw XCTSkip("Build the spreadsheet helper to check spreadsheet conversion.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ConversionEngine(toolsDirectory: tools)
        let input = directory.appendingPathComponent("Café 東京.csv")
        let source = "name,code,text,empty\nCafé 東京,00123,=SUM(A1:A2),\n,,,\n"
        try source.write(to: input, atomically: false, encoding: .utf8)
        XCTAssertTrue(SpreadsheetConverter.outputFormats.isSubset(of: Set(engine.availableOutputs(for: input).map(\.id))))
        for format in ["csv", "tsv", "xlsx"] {
            let output = directory.appendingPathComponent("converted.\(format)")
            let restored = directory.appendingPathComponent("from-\(format).csv")
            try engine.convert(input, to: output)
            try engine.convert(output, to: restored)
            XCTAssertEqual(try String(contentsOf: restored, encoding: .utf8), source)
            let bytes = try Data(contentsOf: output)
            XCTAssertThrowsError(try engine.convert(input, to: output))
            XCTAssertEqual(try Data(contentsOf: output), bytes)
        }
        let legacy = root.appendingPathComponent("Tests/Fixtures/sheet-values.xls")
        var options = SpreadsheetOptions()
        options.sheetIndex = 1
        options.csvDelimiter = .semicolon
        let selected = directory.appendingPathComponent("selected.csv")
        try engine.convert(legacy, to: selected, settings: .init(spreadsheetOptions: options))
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8),
                       ";;\n;;\n;offset;\n;;2024-02-29T12:34:56.000\n")
        options.sheetIndex = 2
        let failed = directory.appendingPathComponent("missing.csv")
        XCTAssertThrowsError(try engine.convert(legacy, to: failed, settings: .init(spreadsheetOptions: options)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
        let text = "name;value\nCafé 東京;00123\n"
        try text.write(to: input, atomically: false, encoding: .utf8)
        options.sheetIndex = 0
        let renamed = directory.appendingPathComponent("Café 東京.xlsx")
        try FileManager.default.moveItem(at: input, to: renamed)
        let record = try engine.convertRenamedFile(from: input, to: renamed,
            historyDirectory: directory.appendingPathComponent("history"), settings: .init(spreadsheetOptions: options))
        let roundTrip = directory.appendingPathComponent("automatic.csv")
        try engine.convert(renamed, to: roundTrip, settings: .init(spreadsheetOptions: options))
        XCTAssertEqual(try String(contentsOf: roundTrip, encoding: .utf8), text)
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), text)
    }
    func testJSONAndXMLTableValues() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent("tabular").path) else {
            throw XCTSkip("Build the spreadsheet helper to check table conversion.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ConversionEngine(toolsDirectory: tools)
        let source = directory.appendingPathComponent("table.csv")
        try "name,code,count,enabled\nCafé 東京,00123,9223372036854775807,true\n"
            .write(to: source, atomically: false, encoding: .utf8)
        let json = directory.appendingPathComponent("table.json")
        try engine.convert(source, to: json)
        let strings: ConfigValue = .array([.object(["name": .string("Café 東京"), "code": .string("00123"),
            "count": .string("9223372036854775807"), "enabled": .string("true")])])
        XCTAssertEqual(try ConfigConverter.read(Data(contentsOf: json), format: "json"), strings)
        var options = SpreadsheetOptions()
        let legacy = try JSONDecoder().decode(SpreadsheetOptions.self,
            from: Data(#"{"csvDelimiter":"semicolon","sheetIndex":2,"xmlHeaderRow":false,"inferTypes":true}"#.utf8))
        XCTAssertTrue(legacy.csvHeaderRow)
        XCTAssertEqual(legacy.csvDelimiter, .semicolon)
        XCTAssertEqual(legacy.sheetIndex, 2)
        XCTAssertFalse(legacy.xmlHeaderRow)
        XCTAssertTrue(legacy.inferTypes)
        options.inferTypes = true
        let typed = directory.appendingPathComponent("typed.json")
        try engine.convert(source, to: typed, settings: .init(spreadsheetOptions: options))
        XCTAssertEqual(try ConfigConverter.read(Data(contentsOf: typed), format: "json"), try ConfigConverter.infer(strings))
        let restored = directory.appendingPathComponent("restored.tsv")
        try engine.convert(typed, to: restored)
        XCTAssertEqual(try String(contentsOf: restored, encoding: .utf8),
            "code\tcount\tenabled\tname\n00123\t9223372036854775807\ttrue\tCafé 東京\n")
        // Without a header row, columns are named by position and every row becomes a record.
        var positional = SpreadsheetOptions()
        positional.csvHeaderRow = false
        let byPosition = directory.appendingPathComponent("by-position.json")
        try engine.convert(source, to: byPosition, settings: .init(spreadsheetOptions: positional))
        XCTAssertEqual(try ConfigConverter.read(Data(contentsOf: byPosition), format: "json"), .array([
            .object(["column1": .string("name"), "column2": .string("code"),
                     "column3": .string("count"), "column4": .string("enabled")]),
            .object(["column1": .string("Café 東京"), "column2": .string("00123"),
                     "column3": .string("9223372036854775807"), "column4": .string("true")])
        ]))
        let xml = directory.appendingPathComponent("table.xml")
        try """
        <rows xmlns="urn:test"><row id="01"><name>Café 東京</name><amount>1e2</amount><flag>true</flag></row>
        <row id="02"><name><![CDATA[Line <two>]]></name><amount>12.5</amount></row></rows>
        """.write(to: xml, atomically: false, encoding: .utf8)
        let csv = directory.appendingPathComponent("xml.csv")
        try engine.convert(xml, to: csv)
        XCTAssertEqual(try String(contentsOf: csv, encoding: .utf8),
            "@id,name,amount,flag\n01,Café 東京,1e2,true\n02,Line <two>,12.5,\n")
        options.xmlHeaderRow = false
        options.csvDelimiter = .semicolon
        let noHeaders = directory.appendingPathComponent("xml-no-headers.csv")
        try engine.convert(xml, to: noHeaders, settings: .init(spreadsheetOptions: options))
        XCTAssertEqual(try String(contentsOf: noHeaders, encoding: .utf8),
            "01;Café 東京;100.0;true\n02;Line <two>;12.5;\n")
        for (index, bad) in ["a,a\n1,2\n", "a,b\n1,2,3\n"].enumerated() {
            try bad.write(to: source, atomically: false, encoding: .utf8)
            let output = directory.appendingPathComponent("bad-\(index).json")
            XCTAssertThrowsError(try engine.convert(source, to: output))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        try "<rows><row><value><nested>unsafe structure</nested></value></row></rows>"
            .write(to: xml, atomically: false, encoding: .utf8)
        let invalid = directory.appendingPathComponent("invalid.csv")
        XCTAssertThrowsError(try engine.convert(xml, to: invalid))
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalid.path))
        let original = directory.appendingPathComponent("automatic.json")
        let renamed = directory.appendingPathComponent("automatic.csv")
        let originalBytes = try Data(contentsOf: typed)
        try originalBytes.write(to: renamed)
        let record = try engine.convertRenamedFile(from: original, to: renamed,
            historyDirectory: directory.appendingPathComponent("history"))
        XCTAssertTrue(try String(contentsOf: renamed, encoding: .utf8).contains("00123"))
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try Data(contentsOf: original), originalBytes)
    }
}
