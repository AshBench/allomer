import CoreGraphics
import Foundation

enum PresentationWriter {
    private static let drawing = "http://schemas.openxmlformats.org/drawingml/2006/main"
    private static let presentation = "http://schemas.openxmlformats.org/presentationml/2006/main"
    private static let relation = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    private static let contentType = "application/vnd.openxmlformats-officedocument.presentationml."
    private static let group = """
    <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
    <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>
    """

    static func convert(_ input: URL, to output: URL, sizes: [CGSize], tool: URL, options: PDFOptions) throws {
        let pages = try options.selectedPages(count: sizes.count)
        let first = sizes[pages[0] - 1]
        // PowerPoint accepts slide edges from one to 56 inches. Scale the canvas uniformly.
        let scale = min(1, 4032 / max(first.width, first.height))
        let width = max(914_400, Int((first.width * scale * 12_700).rounded()))
        let height = max(914_400, Int((first.height * scale * 12_700).rounded()))
        let slideIDs = pages.indices.map { "<p:sldId id=\"\($0 + 256)\" r:id=\"rId\($0 + 3)\"/>" }.joined()
        let slideRelations = pages.indices.map { ("slide", "slides/slide\($0 + 1).xml") }
        let overrides = [("presentation.xml", "presentation.main"), ("presProps.xml", "presProps"),
            ("slideMasters/slideMaster1.xml", "slideMaster"), ("slideLayouts/slideLayout1.xml", "slideLayout")]
            + pages.indices.map { ("slides/slide\($0 + 1).xml", "slide") }
        let types = overrides.map { "<Override PartName=\"/ppt/\($0.0)\" ContentType=\"\(contentType)\($0.1)+xml\"/>" }.joined()
        let parts: [(String, String)] = [
            ("[Content_Types].xml", """
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
            <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
            <Default Extension="png" ContentType="image/png"/>
            <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
            \(types)</Types>
            """),
            ("_rels/.rels", relationships([("officeDocument", "ppt/presentation.xml")])),
            ("ppt/presentation.xml", element("presentation", """
            <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>
            <p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx="\(width)" cy="\(height)" type="custom"/>
            <p:notesSz cx="6858000" cy="9144000"/>
            """)),
            ("ppt/_rels/presentation.xml.rels", relationships([
                ("slideMaster", "slideMasters/slideMaster1.xml"), ("presProps", "presProps.xml")] + slideRelations)),
            ("ppt/presProps.xml", element("presentationPr", "")),
            ("ppt/slideMasters/slideMaster1.xml", element("sldMaster", """
            <p:cSld><p:spTree>\(group)</p:spTree></p:cSld>
            <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>
            <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>
            """)),
            ("ppt/slideMasters/_rels/slideMaster1.xml.rels", relationships([
                ("slideLayout", "../slideLayouts/slideLayout1.xml"), ("theme", "../theme/theme1.xml")])),
            ("ppt/slideLayouts/slideLayout1.xml", element("sldLayout", """
            <p:cSld name="Blank"><p:spTree>\(group)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
            """, attributes: "type=\"blank\" preserve=\"1\"")),
            ("ppt/slideLayouts/_rels/slideLayout1.xml.rels", relationships([("slideMaster", "../slideMasters/slideMaster1.xml")])),
            ("ppt/theme/theme1.xml", theme)
        ]
        let fixed = Dictionary(uniqueKeysWithValues: parts)
        var paths = parts.map(\.0)
        var pageByPath: [String: Int] = [:]
        for index in pages.indices {
            let number = index + 1
            for path in ["ppt/slides/slide\(number).xml", "ppt/slides/_rels/slide\(number).xml.rels", "ppt/media/page\(number).png"] {
                paths.append(path)
                pageByPath[path] = index
            }
        }
        try ArchiveConverter.makeZIP(to: output, paths: paths) { path, temporary in
            if let xml = fixed[path] {
                try writeXML(xml, to: temporary)
                return
            }
            guard let index = pageByPath[path] else { throw ConversionError.message("A presentation part is missing.") }
            let page = pages[index]
            if path.hasSuffix(".png") {
                try PDFConverter.renderPNG(input, to: temporary, page: page, size: sizes[page - 1],
                    resolution: options.slideResolution, opaque: true, tool: tool)
            } else if path.hasSuffix(".rels") {
                try writeXML(relationships([("slideLayout", "../slideLayouts/slideLayout1.xml"),
                    ("image", "../media/page\(index + 1).png")]), to: temporary)
            } else {
                let size = sizes[page - 1]
                let fit = min(Double(width) / size.width, Double(height) / size.height)
                let cx = max(1, Int((size.width * fit).rounded()))
                let cy = max(1, Int((size.height * fit).rounded()))
                try writeXML(element("sld", """
                <p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>
                <p:spTree>\(group)<p:pic>
                <p:nvPicPr><p:cNvPr id="2" name="PDF page \(page)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>
                <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>
                <p:spPr><a:xfrm><a:off x="\((width - cx) / 2)" y="\((height - cy) / 2)"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>
                <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>
                </p:pic></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>
                """), to: temporary)
            }
        }
    }

    private static func element(_ name: String, _ contents: String, attributes: String = "") -> String {
        "<p:\(name) xmlns:a=\"\(drawing)\" xmlns:r=\"\(relation)\" xmlns:p=\"\(presentation)\" \(attributes)>\(contents)</p:\(name)>"
    }

    private static func relationships(_ items: [(String, String)]) -> String {
        let body = items.enumerated().map {
            "<Relationship Id=\"rId\($0.offset + 1)\" Type=\"\(relation)/\($0.element.0)\" Target=\"\($0.element.1)\"/>"
        }.joined()
        return "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(body)</Relationships>"
    }

    private static func writeXML(_ xml: String, to output: URL) throws {
        try Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + xml).utf8).write(to: output, options: .withoutOverwriting)
    }

    private static var theme: String {
        let colors = [("dk1", "000000"), ("lt1", "FFFFFF"), ("dk2", "222222"), ("lt2", "EEEEEE"),
            ("accent1", "2456A6"), ("accent2", "A63424"), ("accent3", "267044"), ("accent4", "743C91"),
            ("accent5", "207B87"), ("accent6", "996000"), ("hlink", "0000EE"), ("folHlink", "551A8B")]
            .map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined()
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let fonts = ["majorFont", "minorFont"].map {
            "<a:\($0)><a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/></a:\($0)>"
        }.joined()
        return """
        <a:theme xmlns:a="\(drawing)" name="Plain"><a:themeElements>
        <a:clrScheme name="Plain">\(colors)</a:clrScheme><a:fontScheme name="Plain">\(fonts)</a:fontScheme>
        <a:fmtScheme name="Plain"><a:fillStyleLst>\(String(repeating: fill, count: 3))</a:fillStyleLst>
        <a:lnStyleLst>\(String(repeating: "<a:ln w=\"12700\">\(fill)<a:prstDash val=\"solid\"/></a:ln>", count: 3))</a:lnStyleLst>
        <a:effectStyleLst>\(String(repeating: "<a:effectStyle><a:effectLst/></a:effectStyle>", count: 3))</a:effectStyleLst>
        <a:bgFillStyleLst>\(String(repeating: fill, count: 3))</a:bgFillStyleLst></a:fmtScheme>
        </a:themeElements></a:theme>
        """
    }
}
