import AppKit
import CoreGraphics
import Foundation
import PDFKit
import XCTest

@testable import ConversionCore

/// Original WordprocessingML, written here rather than produced by any converter in this project.
/// A fixture built by the document tool would already have lost the layout these checks are about.
private enum WordFixture {
    static let namespaces = """
        xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"
        """

    /// `w:pgSz` and `w:pgMar` in twips, the unit Word records them in.
    static func section(width: Int, height: Int, landscape: Bool = false, top: Int = 1440, right: Int = 1440,
                        bottom: Int = 1440, left: Int = 1440, references: String = "", columns: String = "") -> String {
        """
        <w:sectPr>\(references)<w:pgSz w:w="\(width)" w:h="\(height)"\(landscape ? " w:orient=\"landscape\"" : "")/>\
        <w:pgMar w:top="\(top)" w:right="\(right)" w:bottom="\(bottom)" w:left="\(left)" \
        w:header="720" w:footer="720" w:gutter="0"/>\(columns)</w:sectPr>
        """
    }

    static func paragraph(_ text: String, properties: String = "", run: String = "") -> String {
        "<w:p>\(properties)<w:r>\(run)<w:t xml:space=\"preserve\">\(text)</w:t></w:r></w:p>"
    }

    static func write(_ body: String, to destination: URL, extra: [String: String] = [:],
                      overrides: [String] = [], relationships: [(String, String, String, Bool)] = []) throws {
        var parts = [
            "[Content_Types].xml": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
                <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
                <Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>\
                <Override PartName="/word/document.xml" \
                ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
                \(overrides.joined())</Types>
                """,
            "_rels/.rels": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                <Relationship Id="rId1" \
                Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" \
                Target="word/document.xml"/></Relationships>
                """,
            "word/document.xml": """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
                <w:document \(namespaces)><w:body>\(body)</w:body></w:document>
                """,
        ]
        if !relationships.isEmpty {
            let items = relationships.map { id, kind, target, external in
                "<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/\(kind)\" "
                    + "Target=\"\(target)\"\(external ? " TargetMode=\"External\"" : "")/>"
            }
            parts["word/_rels/document.xml.rels"] = """
                <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
                <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                \(items.joined())</Relationships>
                """
        }
        parts.merge(extra) { _, new in new }
        try ArchiveConverter.makeZIP(to: destination, paths: parts.keys.sorted()) { name, part in
            try Data(parts[name]!.utf8).write(to: part, options: .withoutOverwriting)
        }
    }
}

final class WordLayoutTests: XCTestCase {
    private func engine(_ file: StaticString = #filePath) throws -> (ConversionEngine, URL) {
        let root = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let tools = root.appendingPathComponent(".tools/bin")
        guard ["webguard", "webconvert", "pdfguard"].allSatisfy({
            FileManager.default.isExecutableFile(atPath: tools.appendingPathComponent($0).path)
        }), FileManager.default.fileExists(atPath:
            WordLayoutConverter.resources(tools: tools).appendingPathComponent("renderer.js").path) else {
            throw XCTSkip("Build the native helpers and the Word renderer to check Word page layout.")
        }
        return (try ConversionEngine(toolsDirectory: tools), tools)
    }

    private func work(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Word layout café 100% \(name) \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    /// Page size, orientation, asymmetric margins, and the route this takes.
    func testDeclaredPageGeometryAndDirectRoute() throws {
        let (engine, _) = try engine()
        let directory = try work("geometry")
        let source = directory.appendingPathComponent("geometry.docx")
        // A5 landscape, margins 25 mm top and bottom, 20 mm left and right.
        try WordFixture.write(WordFixture.paragraph("ORIGINAL GEOMETRY PARAGRAPH")
            + WordFixture.section(width: 11906, height: 8391, landscape: true,
                                  top: 1417, right: 1134, bottom: 1417, left: 1134), to: source)
        let docx = try XCTUnwrap(engine.catalog.format(forExtension: "docx"))
        let pdf = try XCTUnwrap(engine.catalog.format(forExtension: "pdf"))
        XCTAssertEqual(engine.conversionRoute(from: docx, to: pdf)?.map(\.id), ["pdf"])
        // Every other Word route still goes through the document tool.
        for target in ["html", "markdown", "rtf", "odt", "epub", "txt"] {
            let format = try XCTUnwrap(engine.catalog.format(forExtension: target == "markdown" ? "md" : target))
            XCTAssertEqual(engine.conversionRoute(from: docx, to: format)?.map(\.id), [format.id], target)
        }
        let output = directory.appendingPathComponent("geometry.pdf")
        try engine.convert(source, to: output)
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 1)
        let box = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertEqual(box.width, 595.3, accuracy: 1)
        XCTAssertEqual(box.height, 419.55, accuracy: 1)
        let selection = try XCTUnwrap(document.findString("ORIGINAL GEOMETRY PARAGRAPH", withOptions: []).first)
        let bounds = selection.bounds(for: try XCTUnwrap(document.page(at: 0)))
        XCTAssertEqual(bounds.minX, 56.7, accuracy: 2, "text should start at the declared 20 mm left margin")
    }

    /// An explicit page break must start a new page rather than disappear.
    func testManualPageBreakStartsANewPage() throws {
        let (engine, _) = try engine()
        let directory = try work("break")
        let source = directory.appendingPathComponent("break.docx")
        try WordFixture.write(WordFixture.paragraph("FIRST PAGE PARAGRAPH")
            + "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            + WordFixture.paragraph("SECOND PAGE PARAGRAPH")
            + WordFixture.section(width: 11906, height: 16838), to: source)
        let output = directory.appendingPathComponent("break.pdf")
        try engine.convert(source, to: output)
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 2)
        let first = try XCTUnwrap(document.page(at: 0)).string ?? ""
        XCTAssertTrue(first.contains("FIRST PAGE PARAGRAPH"))
        XCTAssertFalse(first.contains("SECOND PAGE PARAGRAPH"))
        XCTAssertTrue(try XCTUnwrap(document.page(at: 1)).string?.contains("SECOND PAGE PARAGRAPH") == true)
    }

    /// Run size and colour, measured against a control run of the same word at half the size.
    func testRunSizeAndColour() throws {
        let (engine, _) = try engine()
        let directory = try work("run")
        let source = directory.appendingPathComponent("run.docx")
        try WordFixture.write(
            WordFixture.paragraph("SCARLET", run: "<w:rPr><w:sz w:val=\"48\"/><w:color w:val=\"FF0000\"/></w:rPr>")
            + WordFixture.paragraph("SCARLET", run: "<w:rPr><w:sz w:val=\"24\"/></w:rPr>")
            + WordFixture.section(width: 11906, height: 16838), to: source)
        let output = directory.appendingPathComponent("run.pdf")
        try engine.convert(source, to: output)
        let document = try XCTUnwrap(PDFDocument(url: output))
        let page = try XCTUnwrap(document.page(at: 0))
        let found = document.findString("SCARLET", withOptions: [])
        XCTAssertEqual(found.count, 2)
        let widths = found.map { $0.bounds(for: page).width }.sorted()
        XCTAssertEqual(widths[1] / widths[0], 2, accuracy: 0.04, "24 pt beside a 12 pt control")
        XCTAssertEqual(try redPixels(of: output), true)
    }

    /// Header and footer must repeat on every page and sit in their declared bands.
    func testHeaderAndFooterRepeatOnEveryPage() throws {
        let (engine, _) = try engine()
        let directory = try work("running")
        let source = directory.appendingPathComponent("running.docx")
        let body = (1...90).map { WordFixture.paragraph("BODY LINE \($0) the quick brown fox jumps over the lazy dog.") }.joined()
        let header = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
            <w:hdr \(WordFixture.namespaces)>\(WordFixture.paragraph("ORIGINAL HEADER"))</w:hdr>
            """
        let footer = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
            <w:ftr \(WordFixture.namespaces)>\(WordFixture.paragraph("ORIGINAL FOOTER"))</w:ftr>
            """
        try WordFixture.write(body + WordFixture.section(width: 11906, height: 16838,
            references: "<w:headerReference w:type=\"default\" r:id=\"rIdH\"/><w:footerReference w:type=\"default\" r:id=\"rIdF\"/>"),
            to: source, extra: ["word/header1.xml": header, "word/footer1.xml": footer],
            overrides: ["<Override PartName=\"/word/header1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml\"/>",
                        "<Override PartName=\"/word/footer1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml\"/>"],
            relationships: [("rIdH", "header", "header1.xml", false), ("rIdF", "footer", "footer1.xml", false)])
        let output = directory.appendingPathComponent("running.pdf")
        try engine.convert(source, to: output)
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertGreaterThan(document.pageCount, 1)
        for index in 0..<document.pageCount {
            let text = try XCTUnwrap(document.page(at: index)).string ?? ""
            XCTAssertTrue(text.contains("ORIGINAL HEADER"), "header missing on page \(index + 1)")
            XCTAssertTrue(text.contains("ORIGINAL FOOTER"), "footer missing on page \(index + 1)")
        }
        let page = try XCTUnwrap(document.page(at: 0))
        let headerBounds = try XCTUnwrap(document.findString("ORIGINAL HEADER", withOptions: []).first).bounds(for: page)
        let footerBounds = try XCTUnwrap(document.findString("ORIGINAL FOOTER", withOptions: []).first).bounds(for: page)
        // The header band starts 720 twips below the top edge; the footer band 720 twips above the bottom.
        XCTAssertLessThan(headerBounds.maxY, 841.9 - 36 + 1)
        XCTAssertGreaterThan(headerBounds.minY, 841.9 - 72)
        XCTAssertGreaterThan(footerBounds.minY, 36 - 1)
        XCTAssertLessThan(footerBounds.maxY, 72)
    }

    /// Links must survive the composition pass, and one this path cannot carry is refused by name.
    func testLinksSurviveComposition() throws {
        let (engine, _) = try engine()
        let directory = try work("links")
        let source = directory.appendingPathComponent("links.docx")
        let footer = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
            <w:ftr \(WordFixture.namespaces)><w:p><w:hyperlink r:id="rIdL">\
            <w:r><w:t>FOOTER LINK</w:t></w:r></w:hyperlink></w:p></w:ftr>
            """
        let body = "<w:p><w:hyperlink r:id=\"rIdL\"><w:r><w:t>OUTSIDE LINK</w:t></w:r></w:hyperlink></w:p>"
            + "<w:p><w:hyperlink w:anchor=\"mark\"><w:r><w:t>INSIDE LINK</w:t></w:r></w:hyperlink></w:p>"
            + "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            + "<w:p><w:bookmarkStart w:id=\"1\" w:name=\"mark\"/><w:r><w:t>MARKED HEADING</w:t></w:r>"
            + "<w:bookmarkEnd w:id=\"1\"/></w:p>"
        try WordFixture.write(body + WordFixture.section(width: 11906, height: 16838,
            references: "<w:footerReference w:type=\"default\" r:id=\"rIdF\"/>"), to: source,
            extra: ["word/footer1.xml": footer,
                    "word/_rels/footer1.xml.rels": """
                        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
                        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
                        <Relationship Id="rIdL" \
                        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" \
                        Target="https://example.invalid/footer" TargetMode="External"/></Relationships>
                        """],
            overrides: ["<Override PartName=\"/word/footer1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml\"/>"],
            relationships: [("rIdF", "footer", "footer1.xml", false),
                            ("rIdL", "hyperlink", "https://example.invalid/body", true)])
        // A footer link would print with an empty target, so the whole document is refused.
        XCTAssertThrowsError(try engine.convert(source, to: directory.appendingPathComponent("refused.pdf"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("link in a header or footer"), error.localizedDescription)
        }
        let plain = directory.appendingPathComponent("plain.docx")
        try WordFixture.write(body + WordFixture.section(width: 11906, height: 16838), to: plain,
            relationships: [("rIdL", "hyperlink", "https://example.invalid/body", true)])
        let output = directory.appendingPathComponent("links.pdf")
        try engine.convert(plain, to: output)
        let document = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(document.pageCount, 2)
        var addresses: Set<String> = []
        var jumps = 0
        for index in 0..<document.pageCount {
            for annotation in try XCTUnwrap(document.page(at: index)).annotations where annotation.type == "Link" {
                if let action = annotation.action as? PDFActionURL, let url = action.url {
                    addresses.insert(url.absoluteString)
                } else if annotation.action is PDFActionGoTo {
                    jumps += 1
                }
            }
        }
        XCTAssertTrue(addresses.contains("https://example.invalid/body"), "\(addresses)")
        XCTAssertGreaterThan(jumps, 0, "the bookmark link should still jump")
    }

    /// A Word file this path cannot lay out faithfully is refused by name, and nothing is written.
    func testUnsupportedLayoutIsRefusedAndTheSourceIsUntouched() throws {
        let (engine, _) = try engine()
        let directory = try work("refusals")
        let picture = """
            <w:p><w:r><w:drawing><wp:anchor distT="0" distB="0" distL="0" distR="0" simplePos="0" \
            relativeHeight="1" behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1">\
            <wp:simplePos x="0" y="0"/><wp:positionH relativeFrom="page"><wp:posOffset>2000000</wp:posOffset></wp:positionH>\
            <wp:positionV relativeFrom="page"><wp:posOffset>3000000</wp:posOffset></wp:positionV>\
            <wp:extent cx="914400" cy="914400"/><wp:docPr id="1" name="Floating"/><a:graphic>\
            <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\
            <pic:nvPicPr><pic:cNvPr id="0" name="x.png"/><pic:cNvPicPr/></pic:nvPicPr>\
            <pic:blipFill><a:blip/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
            <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="914400" cy="914400"/></a:xfrm>\
            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic>\
            </wp:anchor></w:drawing></w:r></w:p>
            """
        let cases: [(String, String, String, [(String, String, String, Bool)])] = [
            ("mixed", "mixes page sizes",
             "<w:p><w:pPr>\(WordFixture.section(width: 11906, height: 8391, landscape: true))</w:pPr><w:r><w:t>A</w:t></w:r></w:p>"
                + WordFixture.paragraph("B") + WordFixture.section(width: 11906, height: 16838), []),
            ("columns", "multiple text columns",
             WordFixture.paragraph("C") + WordFixture.section(width: 11906, height: 16838,
                columns: "<w:cols w:num=\"2\" w:space=\"425\"/>"), []),
            ("textbox", "text boxes",
             "<w:p><w:r><w:pict><v:shape xmlns:v=\"urn:schemas-microsoft-com:vml\" style=\"width:200pt;height:60pt\">"
                + "<v:textbox><w:txbxContent>\(WordFixture.paragraph("BOXED"))</w:txbxContent></v:textbox></v:shape>"
                + "</w:pict></w:r></w:p>" + WordFixture.section(width: 11906, height: 16838), []),
            ("floating", "floating images",
             picture + WordFixture.section(width: 11906, height: 16838), []),
            ("missing", "is missing from it",
             WordFixture.paragraph("D") + WordFixture.section(width: 11906, height: 16838),
             [("rIdI", "image", "media/absent.png", false)]),
            ("remote", "links an image from another location",
             WordFixture.paragraph("E") + WordFixture.section(width: 11906, height: 16838),
             [("rIdI", "image", "http://127.0.0.1:9/x.png", true)]),
            ("nogeometry", "declares no usable page size", WordFixture.paragraph("F"), []),
        ]
        for (name, fragment, body, relationships) in cases {
            let source = directory.appendingPathComponent("\(name).docx")
            try WordFixture.write(body, to: source, relationships: relationships)
            let before = try Data(contentsOf: source)
            let output = directory.appendingPathComponent("\(name).pdf")
            XCTAssertThrowsError(try engine.convert(source, to: output), name) { error in
                XCTAssertTrue(error.localizedDescription.contains(fragment),
                              "\(name): \(error.localizedDescription)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), name)
            XCTAssertEqual(try Data(contentsOf: source), before, name)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".allomer-") || $0.hasPrefix("word-") }
        XCTAssertEqual(leftovers, [], "a refused conversion should leave no working files")
    }

    /// A page-number field in a footer cannot be recomputed per page, so it is refused.
    func testRunningFieldIsRefused() throws {
        let (engine, _) = try engine()
        let directory = try work("field")
        let source = directory.appendingPathComponent("field.docx")
        let footer = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
            <w:ftr \(WordFixture.namespaces)><w:p><w:r><w:t xml:space="preserve">Page </w:t></w:r>\
            <w:fldSimple w:instr=" PAGE "><w:r><w:t>1</w:t></w:r></w:fldSimple></w:p></w:ftr>
            """
        try WordFixture.write(WordFixture.paragraph("BODY") + WordFixture.section(width: 11906, height: 16838,
            references: "<w:footerReference w:type=\"default\" r:id=\"rIdF\"/>"), to: source,
            extra: ["word/footer1.xml": footer],
            overrides: ["<Override PartName=\"/word/footer1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml\"/>"],
            relationships: [("rIdF", "footer", "footer1.xml", false)])
        XCTAssertThrowsError(try engine.convert(source, to: directory.appendingPathComponent("field.pdf"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("fields such as page numbers"), error.localizedDescription)
        }
    }

    /// Collision, automatic conversion, exact Undo, and the saved page size still meaning nothing here.
    func testOccupiedDestinationAutomaticConversionAndUndo() throws {
        let (engine, _) = try engine()
        let directory = try work("automatic")
        let source = directory.appendingPathComponent("letter.docx")
        try WordFixture.write(WordFixture.paragraph("AUTOMATIC BODY TEXT")
            + WordFixture.section(width: 12240, height: 15840), to: source)
        let original = try Data(contentsOf: source)
        let output = directory.appendingPathComponent("letter.pdf")
        var options = DocumentOptions()
        options.pdfPageSize = "a4"
        try engine.convert(source, to: output, settings: .init(documentOptions: options))
        let taken = try Data(contentsOf: output)
        // US Letter is declared by the document; the saved A4 setting does not apply to Word files.
        let sizes = try PostScriptConverter.pageSizes(output)
        XCTAssertEqual(sizes.first?.width ?? 0, 612, accuracy: 1)
        XCTAssertEqual(sizes.first?.height ?? 0, 792, accuracy: 1)
        XCTAssertThrowsError(try engine.convert(source, to: output, settings: .init(documentOptions: options)))
        XCTAssertEqual(try Data(contentsOf: output), taken)
        XCTAssertEqual(try Data(contentsOf: source), original)

        let before = directory.appendingPathComponent("renamed.docx")
        let renamed = directory.appendingPathComponent("renamed.pdf")
        try original.write(to: before)
        try FileManager.default.moveItem(at: before, to: renamed)
        let record = try engine.convertRenamedFile(from: before, to: renamed,
            historyDirectory: directory.appendingPathComponent("history"), settings: .init(documentOptions: options))
        let produced = try XCTUnwrap(PDFDocument(url: renamed))
        XCTAssertTrue(produced.string?.contains("AUTOMATIC BODY TEXT") == true)
        XCTAssertEqual(try ConversionEngine.undo(record).state, .undone)
        XCTAssertEqual(try Data(contentsOf: before), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
    }

    /// A stage override saved against the old two-stage route stops the conversion rather than
    /// being applied to the wrong stage. The message tells the person what to do.
    func testStaleStageOverrideStopsTheConversion() throws {
        let (engine, _) = try engine()
        let directory = try work("override")
        let source = directory.appendingPathComponent("override.docx")
        try WordFixture.write(WordFixture.paragraph("OVERRIDE BODY")
            + WordFixture.section(width: 11906, height: 16838), to: source)
        let stale = ConversionStageOverride(sourceID: "docx", targetID: "html", settings: ConversionSettings())
        XCTAssertThrowsError(try engine.convert(source, to: directory.appendingPathComponent("override.pdf"),
                                                stageOverrides: [stale])) { error in
            XCTAssertTrue(error.localizedDescription.contains("no longer matches this conversion route"),
                          error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("override.pdf").path))
    }

    /// A header taller than its declared distance pushes the body down, as Word does, instead of
    /// printing over it.
    func testTallRunningBlockPushesTheBodyDown() throws {
        let (engine, _) = try engine()
        let directory = try work("tall")
        let source = directory.appendingPathComponent("tall.docx")
        let lines = (1...12).map { WordFixture.paragraph("TALL HEADER LINE \($0)") }.joined()
        let header = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
            <w:hdr \(WordFixture.namespaces)>\(lines)</w:hdr>
            """
        try WordFixture.write(WordFixture.paragraph("BODY") + WordFixture.section(width: 11906, height: 16838,
            references: "<w:headerReference w:type=\"default\" r:id=\"rIdH\"/>"), to: source,
            extra: ["word/header1.xml": header],
            overrides: ["<Override PartName=\"/word/header1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml\"/>"],
            relationships: [("rIdH", "header", "header1.xml", false)])
        let output = directory.appendingPathComponent("tall.pdf")
        try engine.convert(source, to: output)
        let document = try XCTUnwrap(PDFDocument(url: output))
        let page = try XCTUnwrap(document.page(at: 0))
        let text = page.string ?? ""
        for line in 1...12 { XCTAssertTrue(text.contains("TALL HEADER LINE \(line)"), "header line \(line)") }
        XCTAssertTrue(text.contains("BODY"))
        let lowest = try XCTUnwrap(document.findString("TALL HEADER LINE 12", withOptions: []).first).bounds(for: page)
        let body = try XCTUnwrap(document.findString("BODY", withOptions: []).first).bounds(for: page)
        XCTAssertLessThan(body.maxY, lowest.minY, "the body must start below the header, not under it")
    }

    /// Cancelling must leave the source, the folder, and the working files exactly as they were.
    func testCancellationLeavesNothingBehind() async throws {
        let (engine, _) = try engine()
        let directory = try work("cancel")
        let source = directory.appendingPathComponent("cancel.docx")
        let body = (1...200).map { WordFixture.paragraph("CANCEL LINE \($0) the quick brown fox jumps over the lazy dog.") }.joined()
        try WordFixture.write(body + WordFixture.section(width: 11906, height: 16838), to: source)
        let original = try Data(contentsOf: source)
        let before = try Set(FileManager.default.contentsOfDirectory(atPath: directory.path))
        let output = directory.appendingPathComponent("cancel.pdf")

        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try engine.convert(source, to: output)
        }
        do { _ = try await early.value; XCTFail("A cancelled conversion reported success.") }
        catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)), before)

        // Cancel once the first stage has been announced, after the engine has made its work folder.
        let started = Task {
            try engine.convert(source, to: output) { _, _ in withUnsafeCurrentTask { $0?.cancel() } }
        }
        do { _ = try await started.value; XCTFail("A cancelled conversion reported success.") }
        catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)), before)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    private func redPixels(of pdf: URL) throws -> Bool {
        let document = try XCTUnwrap(CGPDFDocument(pdf as CFURL))
        let page = try XCTUnwrap(document.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        let scale = 2.0
        let width = Int(box.width * scale), height = Int(box.height * scale)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var red = 0
        for index in stride(from: 0, to: width * height * 4, by: 4)
        where pixels[index] > 200 && pixels[index + 1] < 60 && pixels[index + 2] < 60 { red += 1 }
        return red > 200
    }
}
