#!/usr/bin/env python3
"""Check PDF text, tables, images, and page rendering with independent readers."""
import argparse
import base64
import hashlib
import io
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET
import zipfile

from PIL import Image, ImageChops
from pypdf import PdfReader, PdfWriter
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfgen.canvas import Canvas


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--command", type=Path, default=root / ".build/debug/allomer")
    parser.add_argument("--renderer", type=Path, required=True)
    args = parser.parse_args()
    work = root / ".tools/pdf-document-check"
    work.mkdir(exist_ok=True)
    pdfmetrics.registerFont(TTFont("FixtureUnicode", "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"))
    image = Image.new("RGB", (40, 30))
    image.putdata([(x * 6, y * 8, 90) for y in range(30) for x in range(40)])
    image_bytes = io.BytesIO()
    image.save(image_bytes, format="PNG")
    source = work / "Café 100% ' document.pdf"
    canvas = Canvas(str(source), pagesize=(612, 792), pageCompression=1)
    canvas.setFont("Helvetica-Bold", 24)
    canvas.drawString(36, 750, "An original document")
    canvas.setFont("FixtureUnicode", 16)
    canvas.drawString(36, 714, "Café 東京 Ελληνικά")
    canvas.setFont("Helvetica", 12)
    canvas.drawString(36, 686, "A paragraph with editable text and a table.")
    values = [["Name", "Code"], ["Alpha", "00123"], ["Beta", "00456"]]
    for row, cells in enumerate(values):
        for column, value in enumerate(cells):
            x, y = 36 + column * 160, 630 - row * 32
            canvas.rect(x, y, 160, 32)
            canvas.drawString(x + 8, y + 11, value)
    canvas.drawImage(ImageReader(image_bytes), 36, 390, width=160, height=120)
    canvas.saveState()
    canvas.translate(400, 390)
    canvas.rotate(90)
    canvas.drawImage(ImageReader(image_bytes), 0, 0, width=160, height=120)
    canvas.restoreState()
    canvas.drawImage(ImageReader(image_bytes), 36, 270, width=80, height=60)
    canvas.showPage()
    canvas.setFont("Helvetica", 16)
    canvas.drawString(36, 710, "Second page remains editable.")
    canvas.save()
    assert len(PdfReader(source).pages) == 2
    original_hash = hashlib.sha256(source.read_bytes()).digest()
    env = {"PATH": "/usr/bin:/bin"}
    if ".app/" not in str(args.command):
        env["ALLOMER_TOOLS_DIR"] = str(root / ".tools/bin")

    def convert(extension, input=source, name="converted", success=True):
        output = work / f"{name}.{extension}"
        output.unlink(missing_ok=True)
        result = subprocess.run([args.command, "convert", input, output], cwd=work, env=env,
                                capture_output=True, text=True, timeout=130)
        assert (result.returncode == 0) == success, result.stderr
        assert output.exists() == success
        assert hashlib.sha256(source.read_bytes()).digest() == original_hash
        return output

    document = convert("docx")
    ns = {"w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main"}
    with zipfile.ZipFile(document) as archive:
        assert archive.testzip() is None
        tree = ET.fromstring(archive.read("word/document.xml"))
        text = "".join(element.text or "" for element in tree.findall(".//w:t", ns))
        for expected in ("Café 東京 Ελληνικά", "An original document", "Second page remains editable."):
            assert expected in text, (expected, text)
        tables = [[[("".join(cell.itertext())).strip() for cell in row.findall("w:tc", ns)]
                   for row in table.findall("w:tr", ns)] for table in tree.findall(".//w:tbl", ns)]
        assert any([["".join(value.split()) for value in row] for row in table] == values for table in tables), tables
        media = [name for name in archive.namelist() if name.startswith("word/media/")]
        assert len(media) == 3, "The DOCX lost a repeated or rotated image."
        images = [Image.open(io.BytesIO(archive.read(name))).convert("RGB") for name in media]
        assert sum(value.tobytes() == image.tobytes() for value in images) == 2
        rotated = image.transpose(Image.Transpose.ROTATE_90)
        assert any(value.size == rotated.size and value.tobytes() == rotated.tobytes() for value in images)
        extents = [(int(value.attrib["cx"]), int(value.attrib["cy"])) for value in
                   tree.iter("{http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing}extent")]
        assert sorted(extents) == sorted([(2032000, 1524000), (1524000, 2032000), (1016000, 762000)]), extents
        assert tree.find(".//w:b", ns) is not None, "The heading lost its bold style."

    html = convert("html")
    html_tree = ET.parse(html)
    html_text = "".join(html_tree.getroot().itertext())
    assert "Second page remains editable." in html_text
    assert "Café 東京 Ελληνικά" in html_text
    embedded = [element.attrib["src"] for element in html_tree.iter() if element.tag.endswith("}img")]
    assert embedded and embedded[0].startswith("data:image/")
    assert Image.open(io.BytesIO(base64.b64decode(embedded[0].split(",", 1)[1]))).convert("RGB").tobytes() == image.tobytes()
    markdown = convert("md").read_text()
    for value in ("Café 東京 Ελληνικά", "Second page remains editable.", "00123", "00456", "data:image/"):
        assert value in markdown, (value, markdown[:500])
    svg = convert("svg")
    svg_tree = ET.parse(svg)
    assert svg_tree.getroot().tag == "{http://www.w3.org/2000/svg}svg"
    assert svg_tree.find(".//{http://www.w3.org/2000/svg}path") is not None
    assert svg_tree.find(".//{http://www.w3.org/2000/svg}image") is not None
    subprocess.run(["/usr/bin/swift", "-e", '''import AppKit
let args = CommandLine.arguments
guard let image = NSImage(contentsOfFile: args[1]), let data = image.tiffRepresentation else {
    fatalError("The native SVG reader could not render the output.")
}
try data.write(to: URL(fileURLWithPath: args[2]))
''', str(svg), str(work / "svg-native.tiff")], capture_output=True, check=True)
    subprocess.run([args.renderer, "-f", "1", "-singlefile", "-r", "72", "-png", source, work / "independent-72"],
                   capture_output=True, check=True)
    with Image.open(work / "svg-native.tiff") as actual, Image.open(work / "independent-72.png") as expected:
        rendered = Image.alpha_composite(Image.new("RGBA", actual.size, "white"), actual.convert("RGBA")).convert("RGB")
        rendered.save(work / "svg-native-white.png")
        assert actual.size == expected.size == (612, 792)
        pixels = list(ImageChops.difference(rendered, expected.convert("RGB")).get_flattened_data())
        assert sum(max(pixel) > 32 for pixel in pixels) / len(pixels) < 0.02
    png = convert("png")
    subprocess.run([args.renderer, "-f", "1", "-singlefile", "-r", "300", "-png", source, work / "independent"],
                   capture_output=True, check=True)
    with Image.open(png) as actual, Image.open(work / "independent.png") as expected:
        white = Image.new("RGBA", actual.size, "white")
        rendered = Image.alpha_composite(white, actual.convert("RGBA")).convert("RGB")
        rendered.save(work / "converted-white.png")
        assert actual.size == expected.size == (2550, 3300)
        pixels = list(ImageChops.difference(rendered, expected.convert("RGB")).get_flattened_data())
        assert sum(max(pixel) > 32 for pixel in pixels) / len(pixels) < 0.02
    for extension in ("jpg", "tiff", "bmp", "gif", "heic", "avif"):
        output = convert(extension)
        assert output.stat().st_size > 0
    broken = work / "broken.pdf"
    broken.write_bytes(b"%PDF-1.7\nbroken")
    convert("png", input=broken, name="broken", success=False)
    writer = PdfWriter()
    writer.append(source)
    writer.encrypt("fixture")
    encrypted = work / "encrypted.pdf"
    writer.write(encrypted)
    convert("docx", input=encrypted, name="encrypted", success=False)
    assert not list(work.glob(".allomer-*"))
    print("PDF text, table cells, embedded image pixels, bold text, native SVG rendering, PNG rendering, six image routes, and invalid-input checks pass.")


if __name__ == "__main__":
    main()
