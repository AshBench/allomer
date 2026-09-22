#!/usr/bin/env python3
"""Check direct Word-to-PDF page geometry, layout, running blocks, and refusals."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
import json
from pathlib import Path
import platform
import re
import statistics
import struct
import subprocess
import threading
import zipfile
import zlib

from PIL import Image
from pypdf import PdfReader
import pypdfium2 as pdfium

# Every fixture below is original WordprocessingML written here. None of it comes from a converter.
W = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
R = 'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'
WP = 'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"'
A = 'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"'
PIC = 'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"'
CT_NS = "http://schemas.openxmlformats.org/package/2006/content-types"
REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
OFFICE = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
RUNNING = "application/vnd.openxmlformats-officedocument.wordprocessingml"
HEADER1 = f'<Override PartName="/word/header1.xml" ContentType="{RUNNING}.header+xml"/>'
HEADER2 = f'<Override PartName="/word/header2.xml" ContentType="{RUNNING}.header+xml"/>'
FOOTER1 = f'<Override PartName="/word/footer1.xml" ContentType="{RUNNING}.footer+xml"/>'
STYLES = f'<Override PartName="/word/styles.xml" ContentType="{RUNNING}.styles+xml"/>'

TWIPS = 20.0                      # Word records lengths in twentieths of a point.
A4 = (11906, 16838)               # 210 x 297 mm portrait.
A5_LANDSCAPE = (11906, 8391)      # 210 x 148 mm landscape.
MARGIN = 1440                     # 1 inch, the default in every fixture below.
BAND = 720                        # Header and footer distance from the page edge.
GEOMETRY_MARGINS = (1417, 1134, 1417, 1134)   # 25 / 20 / 25 / 20 mm.
TABLE_WIDTH = 8000                # w:tblW, 400 pt.
FIRST_COLUMN = 1701               # w:gridCol, 85.05 pt.
SPACE_AFTER = 480                 # w:spacing w:after, 24 pt.
PICTURE_EMU = 914400              # wp:extent, 72 pt.
LINK_TARGET = "https://example.invalid/target"
PROBE_TARGET = "http://127.0.0.1:PROBEPORT/square.png"


def png(width, height, rgb):
    def chunk(tag, payload):
        return struct.pack(">I", len(payload)) + tag + payload + struct.pack(">I", zlib.crc32(tag + payload))
    raw = b"".join(b"\0" + bytes(rgb) * width for _ in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def content_types(extra=()):
    defaults = ['<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
                '<Default Extension="xml" ContentType="application/xml"/>',
                '<Default Extension="png" ContentType="image/png"/>']
    parts = [f'<Override PartName="/word/document.xml" ContentType="{RUNNING}.document.main+xml"/>'] + list(extra)
    return f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="{CT_NS}">{"".join(defaults)}{"".join(parts)}</Types>'


def doc_rels(entries):
    items = "".join(f'<Relationship Id="{identifier}" Type="{OFFICE}/{kind}" Target="{target}"{mode}/>'
                    for identifier, kind, target, mode in entries)
    return f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="{REL_NS}">{items}</Relationships>'


def sect(size, margins=(MARGIN,) * 4, orient=None, refs="", cols=""):
    top, right, bottom, left = margins
    turn = f' w:orient="{orient}"' if orient else ""
    return (f'<w:sectPr>{refs}<w:pgSz w:w="{size[0]}" w:h="{size[1]}"{turn}/>'
            f'<w:pgMar w:top="{top}" w:right="{right}" w:bottom="{bottom}" w:left="{left}" '
            f'w:header="{BAND}" w:footer="{BAND}" w:gutter="0"/>{cols}</w:sectPr>')


def para(text, props="", runprops=""):
    body = f'<w:r>{runprops}<w:t xml:space="preserve">{text}</w:t></w:r>' if text is not None else ""
    return f'<w:p>{props}{body}</w:p>'


def document(body):
    return (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            f'<w:document {W} {R} {WP} {A} {PIC}><w:body>{body}</w:body></w:document>')


def parts(document_xml, extra=None, overrides=(), rels=None):
    root = (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="{REL_NS}">'
            f'<Relationship Id="rId1" Type="{OFFICE}/officeDocument" Target="word/document.xml"/></Relationships>')
    made = {"[Content_Types].xml": content_types(overrides), "_rels/.rels": root, "word/document.xml": document_xml}
    if rels is not None:
        made["word/_rels/document.xml.rels"] = doc_rels(rels)
    made.update(extra or {})
    return made


def write(path, members):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, data in members.items():
            archive.writestr(name, data)
    return path


def header_part(text):
    return f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:hdr {W} {R}>{para(text)}</w:hdr>'


def footer_part(inner):
    return f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:ftr {W} {R}>{inner}</w:ftr>'


def picture(wrapper):
    """An inline or floating drawing of the embedded square, 72 pt on each side."""
    return ('<w:p><w:r><w:drawing>' + wrapper[0]
            + f'<wp:extent cx="{PICTURE_EMU}" cy="{PICTURE_EMU}"/><wp:docPr id="1" name="Picture 1"/>'
            + wrapper[1]
            + '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
              '<pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="square.png"/><pic:cNvPicPr/></pic:nvPicPr>'
              '<pic:blipFill><a:blip r:embed="rIdI"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
              f'<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="{PICTURE_EMU}" cy="{PICTURE_EMU}"/></a:xfrm>'
              '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>'
              '</a:graphicData></a:graphic>' + wrapper[2] + '</w:drawing></w:r></w:p>')


INLINE = picture(('<wp:inline distT="0" distB="0" distL="0" distR="0">', "", "</wp:inline>"))
FLOATING = picture(('<wp:anchor distT="0" distB="0" distL="114300" distR="114300" simplePos="0" '
                    'relativeHeight="251658240" behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1">'
                    '<wp:simplePos x="0" y="0"/>'
                    '<wp:positionH relativeFrom="page"><wp:posOffset>2000000</wp:posOffset></wp:positionH>'
                    '<wp:positionV relativeFrom="page"><wp:posOffset>3000000</wp:posOffset></wp:positionV>',
                   '<wp:wrapSquare wrapText="bothSides"/>', "</wp:anchor>"))


def red(pixel):
    return pixel[0] > 150 and pixel[1] < 90 and pixel[2] < 90


def blue(pixel):
    return pixel[2] > 150 and pixel[0] < 90 and pixel[1] < 90


def grey(pixel):
    return all(abs(value - 217) <= 6 for value in pixel)


def text_boxes(pdf, index=0):
    """Glyph rectangles and their text, read by a renderer that never wrote the file."""
    reader = pdfium.PdfDocument(pdf)
    page = reader[index].get_textpage()
    boxes = [(page.get_rect(n), page.get_text_bounded(*page.get_rect(n)).strip()) for n in range(page.count_rects())]
    page.close()
    reader.close()
    return boxes


def render(pdf, index=0, dpi=144):
    reader = pdfium.PdfDocument(pdf)
    bitmap = reader[index].render(scale=dpi / 72)
    image = bitmap.to_pil().convert("RGB")
    bitmap.close()
    reader.close()
    return image


def vertical_rules(image, dpi=144):
    """Centres, in points, of each red rule that runs down the image."""
    pixels = image.load()
    columns = Counter(x for y in range(image.height) for x in range(image.width) if red(pixels[x, y]))
    hits = sorted(x for x, height in columns.items() if height > 20)
    rules, group = [], [hits[0]]
    for x in hits[1:]:
        if x - group[-1] > 1:
            rules.append(sum(group) / len(group) * 72 / dpi)
            group = []
        group.append(x)
    return rules + [sum(group) / len(group) * 72 / dpi]


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--command", type=Path, default=root / ".build/debug/allomer")
    parser.add_argument("--benchmark", action="store_true")
    args = parser.parse_args()
    args.command = args.command.resolve()
    work = root / ".tools/word-layout-check"
    work.mkdir(exist_ok=True)
    env = {"PATH": "/usr/bin:/bin"}
    if ".app/" not in str(args.command):
        env["ALLOMER_TOOLS_DIR"] = str(root / ".tools/bin")
    checks = []

    def convert(source, output):
        output.unlink(missing_ok=True)
        before = hashlib.sha256(source.read_bytes()).hexdigest()
        result = subprocess.run([args.command, "convert", source, output], cwd=work, env=env,
                                capture_output=True, text=True, timeout=130)
        assert result.returncode == 0, (source.name, result.stderr)
        assert hashlib.sha256(source.read_bytes()).hexdigest() == before, source.name
        assert output.is_file(), source.name
        return output

    def refuse(source, fragment):
        output = work / "refused.pdf"
        output.unlink(missing_ok=True)
        before = source.read_bytes()
        result = subprocess.run([args.command, "convert", source, output], cwd=work, env=env,
                                capture_output=True, text=True, timeout=130)
        assert result.returncode != 0, (source.name, result.stdout)
        assert fragment in result.stderr, (source.name, result.stderr)
        assert not output.exists(), source.name
        assert source.read_bytes() == before, source.name

    # 1. Page size and orientation, on an A5 landscape page and on an A4 portrait page.
    geometry = write(work / "geometry.docx", parts(document(
        para("ORIGINAL GEOMETRY PARAGRAPH") + sect(A5_LANDSCAPE, GEOMETRY_MARGINS, "landscape"))))
    page_break = write(work / "break.docx", parts(document(
        para("FIRST PAGE PARAGRAPH") + '<w:p><w:r><w:br w:type="page"/></w:r></w:p>'
        + para("SECOND PAGE PARAGRAPH") + sect(A4))))
    for source, (declared_width, declared_height) in ((geometry, A5_LANDSCAPE), (page_break, A4)):
        for page in PdfReader(convert(source, source.with_suffix(".pdf"))).pages:
            assert abs(float(page.mediabox.width) - declared_width / TWIPS) <= 1, source.name
            assert abs(float(page.mediabox.height) - declared_height / TWIPS) <= 1, source.name
    checks.append("page size")

    # 2. Asymmetric margins: the first line starts at the declared left margin.
    (first, _), = text_boxes(work / "geometry.pdf")
    assert abs(first[0] - GEOMETRY_MARGINS[3] / TWIPS) <= 2, first

    # 3. Manual page break.
    broken = PdfReader(work / "break.pdf")
    assert len(broken.pages) == 2
    assert "FIRST PAGE PARAGRAPH" in broken.pages[0].extract_text()
    assert "SECOND PAGE PARAGRAPH" not in broken.pages[0].extract_text()
    assert "SECOND PAGE PARAGRAPH" in broken.pages[1].extract_text()
    checks.append("margins and page break")

    # 4. A 24 pt red run beside a 12 pt control of the same word.
    source = write(work / "run.docx", parts(document(
        para("SCARLET", runprops='<w:rPr><w:sz w:val="48"/><w:szCs w:val="48"/><w:color w:val="FF0000"/></w:rPr>')
        + para("SCARLET", runprops='<w:rPr><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr>') + sect(A4))))
    boxes = sorted(text_boxes(convert(source, work / "run.pdf")), key=lambda box: -box[0][1])
    assert [text for _, text in boxes] == ["SCARLET", "SCARLET"], boxes
    large, small = (box for box, _ in boxes)
    assert abs((large[2] - large[0]) / (small[2] - small[0]) - 2) <= 0.04, (large, small)
    assert abs((large[3] - large[1]) / (small[3] - small[1]) - 2) <= 0.04, (large, small)
    assert sum(1 for pixel in render(work / "run.pdf").get_flattened_data() if red(pixel)) > 500
    checks.append("run size and colour")

    # 5. A table with a declared width, a declared first column, red borders, and a shaded cell.
    borders = "".join(f'<w:{edge} w:val="single" w:sz="8" w:color="FF0000"/>'
                      for edge in ("top", "left", "bottom", "right", "insideH", "insideV"))

    def cell(text, width, shade=None):
        fill = f'<w:shd w:val="clear" w:color="auto" w:fill="{shade}"/>' if shade else ""
        return f'<w:tc><w:tcPr><w:tcW w:w="{width}" w:type="dxa"/>{fill}</w:tcPr>{para(text)}</w:tc>'

    rest = TABLE_WIDTH - FIRST_COLUMN
    table = (f'<w:tbl><w:tblPr><w:tblW w:w="{TABLE_WIDTH}" w:type="dxa"/><w:tblBorders>{borders}</w:tblBorders></w:tblPr>'
             f'<w:tblGrid><w:gridCol w:w="{FIRST_COLUMN}"/><w:gridCol w:w="{rest}"/></w:tblGrid>'
             f'<w:tr>{cell("AB", FIRST_COLUMN, "D9D9D9")}{cell("WIDE CELL", rest)}</w:tr>'
             f'<w:tr>{cell("CD", FIRST_COLUMN)}{cell("SECOND WIDE", rest)}</w:tr></w:tbl>')
    source = write(work / "table.docx", parts(document(table + para("AFTER TABLE") + sect(A4))))
    image = render(convert(source, work / "table.pdf"))
    rules = vertical_rules(image)
    assert len(rules) == 3, rules
    assert abs(rules[2] - rules[0] - TABLE_WIDTH / TWIPS) <= 2, rules
    assert abs(rules[1] - rules[0] - FIRST_COLUMN / TWIPS) <= 2, rules
    assert sum(1 for pixel in image.get_flattened_data() if grey(pixel)) > 1000, "The cell shading was lost."
    assert sum(1 for pixel in image.get_flattened_data() if red(pixel)) > 1000, "The table borders were lost."
    checks.append("table")

    # 6. A custom paragraph style: 18 pt Georgia in blue.
    styles = (f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:styles {W}>'
              '<w:style w:type="paragraph" w:styleId="MyQuote"><w:name w:val="My Quote"/>'
              '<w:rPr><w:rFonts w:ascii="Georgia" w:hAnsi="Georgia"/><w:sz w:val="36"/><w:szCs w:val="36"/>'
              '<w:color w:val="0000FF"/></w:rPr></w:style></w:styles>')
    source = write(work / "style.docx", parts(
        document(para("STYLED QUOTE LINE", props='<w:pPr><w:pStyle w:val="MyQuote"/></w:pPr>') + sect(A4)),
        extra={"word/styles.xml": styles}, overrides=(STYLES,), rels=[("rIdS", "styles", "styles.xml", "")]))
    page = PdfReader(convert(source, work / "style.pdf")).pages[0]
    faces = [str(font.get_object()["/BaseFont"]) for font in page["/Resources"]["/Font"].values()]
    assert any("Georgia" in face for face in faces), faces
    assert sum(1 for pixel in render(work / "style.pdf").get_flattened_data() if blue(pixel)) > 500
    checks.append("custom style")

    # 7. Paragraph space after, measured against an unspaced pair in the same document.
    source = write(work / "spacing.docx", parts(document(
        para("SPACED FIRST", props=f'<w:pPr><w:spacing w:after="{SPACE_AFTER}"/></w:pPr>') + para("SPACED SECOND")
        + para("TIGHT FIRST") + para("TIGHT SECOND") + sect(A4))))
    baselines = {text: box[1] for box, text in text_boxes(convert(source, work / "spacing.pdf"))}
    spaced = baselines["SPACED FIRST"] - baselines["SPACED SECOND"]
    tight = baselines["TIGHT FIRST"] - baselines["TIGHT SECOND"]
    assert abs(spaced - tight - SPACE_AFTER / TWIPS) <= 3, (spaced, tight)
    checks.append("paragraph spacing")

    # 8 and 9. An inline image and an external hyperlink.
    square = png(48, 48, (0, 128, 255))
    link = '<w:p><w:hyperlink r:id="rIdL"><w:r><w:t>ORIGINAL LINK</w:t></w:r></w:hyperlink></w:p>'
    source = write(work / "media.docx", parts(
        document(INLINE + link + sect(A4)), extra={"word/media/square.png": square},
        rels=[("rIdI", "image", "media/square.png", ""),
              ("rIdL", "hyperlink", LINK_TARGET, ' TargetMode="External"')]))
    media = convert(source, work / "media.pdf")
    reader = pdfium.PdfDocument(media)
    drawn = [item.get_bounds() for item in reader[0].get_objects()
             if item.type == pdfium.raw.FPDF_PAGEOBJ_IMAGE]
    reader.close()
    assert len(drawn) == 1, drawn
    left, bottom, right, top = drawn[0]
    assert abs(right - left - PICTURE_EMU / 12700) <= 1 and abs(top - bottom - PICTURE_EMU / 12700) <= 1, drawn
    with zipfile.ZipFile(source) as archive:
        embedded = archive.read("word/media/square.png")
    assert embedded == square, "The source archive no longer holds the authored image."
    with Image.open(BytesIO(embedded)) as picture_file:
        assert picture_file.format == "PNG" and picture_file.size == (48, 48)
    annotations = [item.get_object() for item in PdfReader(media).pages[0].get("/Annots", [])]
    assert any(item.get("/Subtype") == "/Link" and "/URI" in item.get("/A", {})
               and item["/A"]["/URI"] == LINK_TARGET for item in annotations), annotations
    checks.append("inline image and link")

    # 10. One header and one footer, repeated on every page of a body long enough to break.
    body = "".join(para(f"BODY LINE {n:03d} the quick brown fox jumps over the lazy dog again and again.")
                   for n in range(1, 91))
    running_refs = ('<w:headerReference w:type="default" r:id="rIdH"/>'
                    '<w:footerReference w:type="default" r:id="rIdF"/>')
    running_parts = {"word/header1.xml": header_part("ORIGINAL HEADER"),
                     "word/footer1.xml": footer_part(para("ORIGINAL FOOTER"))}
    running_rels = [("rIdH", "header", "header1.xml", ""), ("rIdF", "footer", "footer1.xml", "")]
    source = write(work / "running.docx", parts(document(body + sect(A4, refs=running_refs)),
                                                extra=running_parts, overrides=(HEADER1, FOOTER1), rels=running_rels))
    running = PdfReader(convert(source, work / "running.pdf"))
    assert len(running.pages) > 1
    for index, page in enumerate(running.pages):
        found = {text: box for box, text in text_boxes(work / "running.pdf", index)}
        assert "ORIGINAL HEADER" in found and "ORIGINAL FOOTER" in found, index
        height = float(page.mediabox.height)
        assert BAND / TWIPS <= height - found["ORIGINAL HEADER"][3] <= MARGIN / TWIPS, index
        assert BAND / TWIPS <= found["ORIGINAL FOOTER"][1] <= MARGIN / TWIPS, index
    checks.append("header and footer")

    # 11. Everything this path refuses before it renders anything.
    write(work / "mixed-geometry.docx", parts(document(
        f'<w:p><w:pPr>{sect(A5_LANDSCAPE, orient="landscape")}</w:pPr><w:r><w:t>LANDSCAPE SECTION</w:t></w:r></w:p>'
        + para("PORTRAIT SECTION") + sect(A4))))
    write(work / "columns.docx", parts(document(
        para("COLUMN TEXT") + sect(A4, cols='<w:cols w:num="2" w:space="425"/>'))))
    boxed = ('<w:p><w:r><w:pict><v:shape xmlns:v="urn:schemas-microsoft-com:vml" style="width:200pt;height:60pt">'
             f'<v:textbox><w:txbxContent>{para("BOXED TEXT")}</w:txbxContent></v:textbox></v:shape></w:pict></w:r></w:p>')
    write(work / "textbox.docx", parts(document(boxed + para("PLAIN TEXT") + sect(A4))))
    write(work / "floating.docx", parts(document(FLOATING + para("TEXT AFTER FLOAT") + sect(A4)),
                                        extra={"word/media/square.png": square},
                                        rels=[("rIdI", "image", "media/square.png", "")]))
    field = ('<w:p><w:r><w:t xml:space="preserve">Page </w:t></w:r>'
             '<w:fldSimple w:instr=" PAGE "><w:r><w:t>1</w:t></w:r></w:fldSimple></w:p>')
    write(work / "page-field.docx", parts(
        document(body + sect(A4, refs='<w:footerReference w:type="default" r:id="rIdF"/>')),
        extra={"word/footer1.xml": footer_part(field)}, overrides=(FOOTER1,),
        rels=[("rIdF", "footer", "footer1.xml", "")]))
    write(work / "two-headers.docx", parts(document(
        '<w:p><w:pPr>' + sect(A4, refs='<w:headerReference w:type="default" r:id="rIdH"/>')
        + '</w:pPr><w:r><w:t>FIRST SECTION</w:t></w:r></w:p>' + para("SECOND SECTION")
        + sect(A4, refs='<w:headerReference w:type="default" r:id="rIdH2"/>')),
        extra={"word/header1.xml": header_part("FIRST HEADER"), "word/header2.xml": header_part("SECOND HEADER")},
        overrides=(HEADER1, HEADER2),
        rels=[("rIdH", "header", "header1.xml", ""), ("rIdH2", "header", "header2.xml", "")]))
    write(work / "missing-media.docx", parts(document(INLINE + sect(A4)),
                                             rels=[("rIdI", "image", "media/square.png", "")]))
    write(work / "no-geometry.docx", parts(document(para("NO SECTION PROPERTIES"))))
    # A link inside a running block would print with an empty target, so it is refused instead.
    write(work / "running-link.docx", parts(
        document(para("BODY") + sect(A4, refs='<w:footerReference w:type="default" r:id="rIdF"/>')),
        extra={"word/footer1.xml": footer_part('<w:p><w:hyperlink r:id="rIdL">'
                                               "<w:r><w:t>FOOTER LINK</w:t></w:r></w:hyperlink></w:p>"),
               "word/_rels/footer1.xml.rels": doc_rels(
                   [("rIdL", "hyperlink", LINK_TARGET, ' TargetMode="External"')])},
        overrides=(FOOTER1,), rels=[("rIdF", "footer", "footer1.xml", "")]))
    # The scan reads word/document.xml, so a package that keeps its text elsewhere is refused
    # rather than judged on a part it never looked at.
    renamed = parts(document(para("DECOY") + sect((12240, 15840))), overrides=[
        '<Override PartName="/word/body.xml" ContentType="application/vnd.openxmlformats-'
        'officedocument.wordprocessingml.document.main+xml"/>'])
    renamed["_rels/.rels"] = renamed["_rels/.rels"].replace("word/document.xml", "word/body.xml")
    renamed["word/body.xml"] = document(para("ELSEWHERE") + sect(A4))
    write(work / "renamed-main.docx", renamed)
    for name, fragment in (("mixed-geometry", "mixes page sizes or margins between sections"),
                           ("columns", "uses multiple text columns"),
                           ("textbox", "uses text boxes, which this conversion cannot place"),
                           ("floating", "uses floating images or shapes"),
                           ("page-field", "fields such as page numbers in a header or footer"),
                           ("two-headers", "uses more than one header"),
                           ("missing-media", "A part this document refers to is missing from it"),
                           ("no-geometry", "declares no usable page size"),
                           ("running-link", "link in a header or footer"),
                           ("renamed-main", "stores its text in an unusual place")):
        refuse(work / f"{name}.docx", fragment)
    checks.append("refusals")

    # 12. Nothing on the network is fetched, and no relationship target escapes the package.
    requests = []

    class Probe(BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            self.send_response(200)
            self.end_headers()

        def log_message(self, *ignored):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Probe)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        target = PROBE_TARGET.replace("PROBEPORT", str(server.server_port))
        write(work / "remote-media.docx", parts(document(INLINE + sect(A4)),
                                                rels=[("rIdI", "image", target, ' TargetMode="External"')]))
        refuse(work / "remote-media.docx", "links an image from another location")
        assert not requests, requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    # An absolute target is rejected by name; a traversal one resolves outside the package and is
    # then missing from it. Either way nothing outside the archive is read.
    for name, escape, fragment in (("absolute-target", "/etc/passwd", "relationship target is invalid"),
                                   ("traversal-target", "../../../etc/passwd", "is missing from it")):
        write(work / f"{name}.docx", parts(document(INLINE + sect(A4)),
                                           extra={"word/media/square.png": square},
                                           rels=[("rIdI", "image", escape, "")]))
        refuse(work / f"{name}.docx", fragment)
    checks.append("offline and package-relative targets")

    # 13. An occupied destination is left alone.
    occupied = work / "occupied.pdf"
    occupied.write_bytes(b"ORIGINAL DESTINATION BYTES")
    result = subprocess.run([args.command, "convert", geometry, occupied], cwd=work, env=env,
                            capture_output=True, text=True, timeout=130)
    assert result.returncode != 0 and "already in use" in result.stderr, result.stderr
    assert occupied.read_bytes() == b"ORIGINAL DESTINATION BYTES"
    checks.append("occupied destination")

    assert not list(work.glob(".allomer-*")) and not list(work.glob("word-*"))
    print(f"Word layout PDF: {len(checks)} checks pass — {', '.join(checks)}.")

    if args.benchmark:
        packaged = ".app/" in str(args.command)
        tools = args.command.parent.parent / "Helpers" if packaged else root / ".tools/bin"
        resources = (tools / "webguard").resolve().parent.parent / "Resources/Word"
        source = write(work / "benchmark.docx", parts(
            document(body + table + INLINE + sect(A4, refs=running_refs)),
            extra=dict(running_parts, **{"word/media/square.png": square}),
            overrides=(HEADER1, FOOTER1), rels=running_rels + [("rIdI", "image", "media/square.png", "")]))
        # Eight point values then the two flags saying a header and a footer must be drawn.
        geometry_arguments = ",".join(f"{value / TWIPS:.4f}" for value in
                                      (A4[0], A4[1], MARGIN, MARGIN, MARGIN, MARGIN, BAND, BAND)) + ",1,1"
        pages, samples = 0, []
        for _ in range(3):
            output = work / "benchmark.pdf"
            output.unlink(missing_ok=True)
            result = subprocess.run(["/usr/bin/time", "-l", tools / "webguard", source, work, resources,
                                     "docx", source, output.name, geometry_arguments],
                                    cwd=work, env=env, check=True, capture_output=True, text=True, timeout=130)
            elapsed = re.search(r"([0-9.]+) real", result.stderr)
            memory = re.search(r"([0-9]+)\s+maximum resident set size", result.stderr)
            printed = PdfReader(output)
            assert elapsed and memory, result.stderr
            assert len(printed.pages) == (pages or len(printed.pages)) > 1, len(printed.pages)
            pages = len(printed.pages)
            samples.append({"elapsed_seconds": float(elapsed[1]), "peak_resident_bytes": int(memory[1]),
                            "output_bytes": output.stat().st_size})
        report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
            "architecture": platform.machine(),
            "workload": f"Original {pages}-page Word document with a repeated header and footer, a bordered and shaded table, and an inline bitmap",
            "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "source_bytes": source.stat().st_size,
            "assets_sha256": {"word/media/square.png": hashlib.sha256(square).hexdigest()},
            "helper_sha256": hashlib.sha256((tools / "webconvert").read_bytes()).hexdigest(),
            "launcher_sha256": hashlib.sha256((tools / "webguard").read_bytes()).hexdigest(),
            "packaged": packaged, "pages": pages, "samples": samples,
            "median_elapsed_seconds": statistics.median(s["elapsed_seconds"] for s in samples),
            "median_peak_resident_bytes": statistics.median(s["peak_resident_bytes"] for s in samples),
            "memory_scope": "Peak renderer helper RSS from macOS time -l. Excludes separate WebKit services, the native app, Swift adapter checks, and PDF cleaning. This is not total conversion memory. Three warm serial runs after content checks."}
        (root / "research/word-layout-performance.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
