import Foundation
import XCTest

@testable import ConversionCore

final class ConfigurationTests: XCTestCase {
    func testConfigurationFormatsPreserveValuesAndRejectLoss() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = try ConversionEngine()
        let input = directory.appendingPathComponent("original.json")
        let bytes = Data(#"{"name":"Café 東京 👋","code":"00123","enabled":"true","flag":true,"count":9223372036854775807,"negative":-9223372036854775808,"ratio":1.25,"whole":1.0,"empty":{},"list":["a",false,3],"nested":{"a/b":"x\ny","quote":"\"quoted\""}}"#.utf8)
        try bytes.write(to: input)
        let expected = try ConfigConverter.read(bytes, format: "json")
        let formats = engine.catalog.formats.filter { ConfigConverter.formats.contains($0.id) }
        XCTAssertEqual(formats.count, 5)
        XCTAssertEqual(Set(engine.availableOutputs(for: input).map(\.id)), ConfigConverter.formats.union(ArchiveConverter.formats))
        for sourceFormat in formats {
            let source = directory.appendingPathComponent("source.\(sourceFormat.extensions[0])")
            try engine.convert(input, to: source)
            for target in formats {
                let output = directory.appendingPathComponent("\(sourceFormat.id)-output.\(target.extensions[0])")
                try engine.convert(source, to: output)
                XCTAssertEqual(try ConfigConverter.read(Data(contentsOf: output), format: target.id), expected,
                               "\(sourceFormat.id) to \(target.id)")
            }
        }
        var options = ConfigOptions()
        options.prettyPrint = false
        options.inferStringTypes = true
        options.binaryPlist = true
        let inferred = directory.appendingPathComponent("inferred.plist")
        try engine.convert(input, to: inferred, settings: .init(configOptions: options))
        XCTAssertEqual(try Data(contentsOf: inferred).prefix(8), Data("bplist00".utf8))
        guard case .object(let fields) = try ConfigConverter.read(Data(contentsOf: inferred), format: "plist") else {
            return XCTFail("Missing plist object.")
        }
        XCTAssertEqual(fields["enabled"], .bool(true))
        XCTAssertEqual(fields["code"], .string("00123"))
        let compact = directory.appendingPathComponent("compact.json")
        try engine.convert(input, to: compact, settings: .init(configOptions: options))
        XCTAssertFalse(try String(contentsOf: compact, encoding: .utf8).contains("\n"))

        let compactYAML = directory.appendingPathComponent("compact.yaml")
        try engine.convert(input, to: compactYAML, settings: .init(configOptions: options))
        let yamlText = try String(contentsOf: compactYAML, encoding: .utf8)
        XCTAssertTrue(yamlText.contains("{"), yamlText)
        XCTAssertTrue(yamlText.contains("["), yamlText)
        XCTAssertEqual(try ConfigConverter.read(Data(yamlText.utf8), format: "yaml"),
                       try ConfigConverter.read(Data(contentsOf: compact), format: "json"))

        let xml = directory.appendingPathComponent("tree.xml")
        let xmlBytes = Data("<?xml version=\"1.0\"?><?test value?><!--top--><r xmlns=\"urn:test\" xmlns:p=\"urn:p\" p:id=\"001\">before<p:b a=\"&amp;\"><![CDATA[Café <text>]]></p:b>after<!--last--></r>".utf8)
        try xmlBytes.write(to: xml)
        let tree = try ConfigConverter.read(xmlBytes, format: "xml")
        for target in formats {
            let intermediate = directory.appendingPathComponent("tree.\(target.extensions[0])")
            if intermediate == xml { continue }
            try engine.convert(xml, to: intermediate)
            let restored = directory.appendingPathComponent("tree-from-\(target.id).xml")
            try engine.convert(intermediate, to: restored)
            XCTAssertEqual(try ConfigConverter.read(Data(contentsOf: restored), format: "xml"), tree)
        }
        let alias = Data("defaults: &base {name: \"true\", count: 3}\ncopy: {<<: *base, count: 4}\n".utf8)
        guard case .object(let merged) = try ConfigConverter.read(alias, format: "yaml") else { return XCTFail("Missing object.") }
        XCTAssertEqual(merged["copy"], .object(["name": .string("true"), "count": .integer("4")]))
        XCTAssertEqual(try ConfigConverter.read(Data("v: !!bool \"true\"\nn: !!int \"123\"".utf8), format: "yaml"),
                       .object(["v": .bool(true), "n": .integer("123")]))
        let renamed = directory.appendingPathComponent("automatic.toml")
        let priorName = directory.appendingPathComponent("automatic.json")
        try bytes.write(to: renamed)
        let record = try engine.convertRenamedFile(from: priorName, to: renamed,
            historyDirectory: directory.appendingPathComponent("history"), settings: .init(configOptions: options))
        guard case .object(let automatic) = try ConfigConverter.read(Data(contentsOf: renamed), format: "toml") else {
            return XCTFail("Missing automatic conversion output.")
        }
        XCTAssertEqual(automatic["enabled"], .bool(true))
        _ = try ConversionEngine.undo(record)
        XCTAssertEqual(try Data(contentsOf: priorName), bytes)

        let edge = directory.appendingPathComponent("edge.json")
        let unsigned = Data("{\"max\":18446744073709551615}".utf8)
        try unsigned.write(to: edge)
        for target in ["json", "yaml", "plist", "xml"] {
            let output = directory.appendingPathComponent("unsigned.\(target)")
            try engine.convert(edge, to: output)
            XCTAssertEqual(try ConfigConverter.read(Data(contentsOf: output), format: target),
                           .object(["max": .integer("18446744073709551615")]))
        }
        XCTAssertThrowsError(try engine.convert(edge, to: directory.appendingPathComponent("unsigned.toml")))
        try Data("{\"missing\":null}".utf8).write(to: edge)
        for target in ["toml", "plist"] {
            let output = directory.appendingPathComponent("null.\(target)")
            XCTAssertThrowsError(try engine.convert(edge, to: output))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
        for target in ["json", "yaml", "xml"] {
            try engine.convert(edge, to: directory.appendingPathComponent("null.\(target)"))
        }
        for invalid in ["{\"a\":1,\"a\":2}", "18446744073709551616", "0.10000000000000001", "1e-999"] {
            XCTAssertThrowsError(try ConfigConverter.read(Data(invalid.utf8), format: "json"), invalid)
        }
        for invalid in ["a: &a [*a]", "a: 1\na: 2", "a: !custom value", String(repeating: "[", count: 1000) + "0" + String(repeating: "]", count: 1000)] {
            XCTAssertThrowsError(try ConfigConverter.read(Data(invalid.utf8), format: "yaml"))
        }
        var expansion = "a0: &a0 [x,x,x,x,x,x,x,x,x,x]\n"
        for level in 1...9 {
            expansion += "a\(level): &a\(level) [" + Array(repeating: "*a\(level - 1)", count: 10).joined(separator: ",") + "]\n"
        }
        XCTAssertThrowsError(try ConfigConverter.read(Data(expansion.utf8), format: "yaml"))
        for invalid in ["v = inf", "v = 2026-09-08", "v = 9223372036854775808", "v = 1\nv = 2"] {
            XCTAssertThrowsError(try ConfigConverter.read(Data(invalid.utf8), format: "toml"))
        }
        for declaration in ["<!ENTITY x 'expanded'>", "<!ENTITY x SYSTEM 'file:///etc/hosts'>"] {
            let hostile = Data("<!DOCTYPE r [\(declaration)]><r>&x;</r>".utf8)
            XCTAssertThrowsError(try ConfigConverter.read(hostile, format: "xml"))
        }
        XCTAssertEqual(try Data(contentsOf: input), bytes)
        let retained = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix(".allomer-") }
        XCTAssertEqual(retained, [record.backupURL.deletingLastPathComponent().lastPathComponent])
    }
}
