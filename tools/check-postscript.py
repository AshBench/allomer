#!/usr/bin/env python3
"""Check PDF and PostScript with independent PDF readers and original pages."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess

from PIL import Image, ImageChops
from pypdf import PdfReader, PdfWriter
from pypdf.generic import DecodedStreamObject, NameObject, NumberObject, DictionaryObject
from reportlab.pdfgen.canvas import Canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--command", type=Path, default=root / ".build/debug/allomer")
    parser.add_argument("--renderer", type=Path, required=True)
    args = parser.parse_args()
    work = root / ".tools/pdf-check"
    work.mkdir(exist_ok=True)
    original = work / "original.pdf"
    canvas = Canvas(str(original), pagesize=(360, 240), pageCompression=1)
    canvas.setFillColorRGB(0.95, 0.96, 1)
    canvas.rect(0, 0, 360, 240, stroke=0, fill=1)
    canvas.setFillColorRGB(0.1, 0.2, 0.65)
    canvas.setFont("Helvetica", 24)
    canvas.drawString(24, 188, "Original first page")
    canvas.setFillColorRGB(0.85, 0.15, 0.1)
    canvas.rect(24, 24, 110, 110, stroke=0, fill=1)
    canvas.setFillColorRGB(0.1, 0.3, 0.9)
    canvas.circle(120, 94, 50, stroke=0, fill=1)
    canvas.showPage()
    canvas.setPageSize((200, 300))
    canvas.setFillColorRGB(0.1, 0.5, 0.2)
    canvas.rect(0, 0, 200, 300, stroke=0, fill=1)
    canvas.setFillColorRGB(1, 1, 1)
    canvas.setFont("Helvetica", 12)
    canvas.drawString(25, 180, "Rotated second page")
    canvas.showPage()
    canvas.setPageSize((360, 240))
    canvas.setFillColorRGB(0.85, 0.15, 0.1)
    canvas.rect(24, 24, 110, 110, stroke=0, fill=1)
    canvas.setFillAlpha(0.5)
    canvas.setFillColorRGB(0.1, 0.3, 0.9)
    canvas.circle(120, 94, 50, stroke=0, fill=1)
    canvas.save()
    reader = PdfReader(original)
    writer = PdfWriter()
    for page in reader.pages:
        writer.add_page(page)
    writer.pages[1].cropbox.lower_left = (20, 30)
    writer.pages[1].cropbox.upper_right = (180, 270)
    writer.pages[1].rotate(90)
    source = work / "Café 100% ' (original).pdf"
    writer.write(source)
    env = {"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(root / ".tools/bin"),
           "GS_OPTIONS": "-dNOSAFER -sOutputFile=/should-not-be-used", "GS_LIB": "/should-not-be-read"}
    # The packaged command must find tools inside the app, without a development override.
    if ".app/" in str(args.command):
        env.pop("ALLOMER_TOOLS_DIR")

    def convert(input, name, success=True, options=None):
        output = work / name
        output.unlink(missing_ok=True)
        before = hashlib.sha256(input.read_bytes()).digest()
        extra = []
        if options is not None:
            settings = work / "postscript-options.json"
            settings.write_text(json.dumps(options))
            extra = ["--postscript-options", settings]
        result = subprocess.run([args.command, "convert", input, output, *extra], cwd=work, env=env,
                                capture_output=True, text=True, timeout=130)
        assert (result.returncode == 0) == success, result.stderr
        assert hashlib.sha256(input.read_bytes()).digest() == before
        assert output.exists() == success
        return output

    postscript = convert(source, "all-pages.ps")
    restored = convert(postscript, "all-pages.pdf")
    eps = convert(source, "first-page.eps")
    cropped = convert(eps, "first-page.pdf")
    assert postscript.read_bytes().startswith(b"%!PS-Adobe-")
    assert b"%%LanguageLevel: 3" in postscript.read_bytes()[:4096]
    assert b"/FlateDecode filter" in postscript.read_bytes()
    assert b"EPSF-" in eps.read_bytes()[:64]
    pdf = PdfReader(restored)
    assert len(pdf.pages) == 3
    assert [tuple(map(float, p.mediabox[2:])) for p in pdf.pages] == [(360.0, 240.0), (240.0, 160.0), (360.0, 240.0)]
    assert "Original first page" in pdf.pages[0].extract_text()
    assert "Rotated second page" in pdf.pages[1].extract_text()
    assert len(PdfReader(cropped).pages) == 1

    def render(path, name):
        prefix = work / name
        for old in work.glob(name + "-*.png"):
            old.unlink()
        subprocess.run([args.renderer, "-cropbox", "-r", "72", "-png", path, prefix], check=True, capture_output=True)
        return sorted(work.glob(name + "-*.png"))

    before, after = render(source, "original"), render(restored, "restored")
    for left, right in zip(before, after, strict=True):
        with Image.open(left) as a, Image.open(right) as b:
            assert a.size == b.size
            delta = ImageChops.difference(a.convert("RGB"), b.convert("RGB"))
            pixels = list(delta.get_flattened_data())
            changed = sum(max(pixel) > 32 for pixel in pixels) / len(pixels)
            assert changed < 0.03, (left, changed)
    render(cropped, "eps")

    level2 = convert(source, "level-2.ps", options={"languageLevel": 2})
    assert b"%%LanguageLevel: 2" in level2.read_bytes()[:4096]
    for index in (1, 2, 3):
        selected = convert(source, f"selected-{index}.eps", options={"epsPage": index})
        result = convert(selected, f"selected-{index}.pdf")
        assert len(PdfReader(result).pages) == 1
        assert tuple(map(float, PdfReader(result).pages[0].mediabox[2:])) == [(360, 240), (240, 160), (360, 240)][index - 1]
    for options in ({"languageLevel": 1}, {"languageLevel": 4}, {"epsPage": 4}, {"epsPage": 0}):
        convert(source, "invalid-option.eps", success=False, options=options)

    # Embedded TrueType, gradients, JPEG, and JPEG 2000 keep visible content at both language levels.
    features = work / "features.pdf"
    pdfmetrics.registerFont(TTFont("EmbeddedFixture", "/System/Library/Fonts/Supplemental/Arial.ttf"))
    canvas = Canvas(str(features), pagesize=(360, 240))
    canvas.linearGradient(0, 0, 360, 240, ((1, 0, 0), (0, 0, 1)))
    canvas.setFont("EmbeddedFixture", 20)
    canvas.drawString(20, 120, "Café Ω Ж")
    canvas.showPage()
    pixels = Image.new("RGB", (64, 48))
    pixels.putdata([(x * 4, y * 5, (x + y) * 2) for y in range(48) for x in range(64)])
    jpeg = work / "embedded.jpg"
    pixels.save(jpeg, quality=94)
    canvas.drawImage(str(jpeg), 20, 20, 256, 192)
    canvas.showPage()
    canvas.saveState()
    clip = canvas.beginPath()
    clip.rect(20, 20, 320, 200)
    canvas.clipPath(clip, stroke=0)
    canvas.translate(40, 20)
    canvas.rotate(17)
    canvas.scale(1, 0.7)
    canvas.radialGradient(140, 100, 170, ((1, 0, 0), (0, 1, 0), (0, 0, 1)), positions=(0, 0.3, 1), extend=True)
    canvas.restoreState()
    canvas.save()
    features_writer = PdfWriter(clone_from=features)
    jpx = io.BytesIO()
    pixels.save(jpx, format="JPEG2000", irreversible=False)
    image = DecodedStreamObject()
    image.set_data(jpx.getvalue())
    image.update({NameObject("/Type"): NameObject("/XObject"), NameObject("/Subtype"): NameObject("/Image"),
                  NameObject("/Width"): NumberObject(64), NameObject("/Height"): NumberObject(48),
                  NameObject("/ColorSpace"): NameObject("/DeviceRGB"), NameObject("/BitsPerComponent"): NumberObject(8),
                  NameObject("/Filter"): NameObject("/JPXDecode")})
    page = features_writer.add_blank_page(360, 240)
    page[NameObject("/Resources")] = DictionaryObject({NameObject("/XObject"): DictionaryObject({NameObject("/Im"): features_writer._add_object(image)})})
    content = DecodedStreamObject()
    content.set_data(b"q 256 0 0 192 20 20 cm /Im Do Q")
    page[NameObject("/Contents")] = features_writer._add_object(content)
    features_writer.write(features)
    original_images = render(features, "features-source")
    for level in (2, 3):
        ps = convert(features, f"features-{level}.ps", options={"languageLevel": level})
        returned = convert(ps, f"features-{level}.pdf")
        returned_page = PdfReader(returned).pages[0]
        # PostScript can lose PDF Unicode mappings. Check glyph appearance below, and keep vector text here.
        assert "Caf" in returned_page.extract_text()
        if level == 3:
            assert not list(returned_page.images)
            assert b">> shfill" in ps.read_bytes()
        for left, right in zip(original_images, render(returned, f"features-{level}"), strict=True):
            with Image.open(left) as a, Image.open(right) as b:
                assert a.size == b.size, (left, right, a.size, b.size)
                delta = ImageChops.difference(a.convert("RGB"), b.convert("RGB"))
                changed = sum(max(p) > 32 for p in delta.get_flattened_data()) / (a.width * a.height)
                assert changed < 0.03, (left, right, changed)

    scaled_writer = PdfWriter(clone_from=source)
    scaled_writer.pages[0][NameObject("/UserUnit")] = NumberObject(2)
    scaled_writer.pages[1][NameObject("/UserUnit")] = NumberObject(3)
    scaled = work / "scaled.pdf"
    scaled_writer.write(scaled)
    scaled_ps = convert(scaled, "scaled.ps")
    scaled_pdf = PdfReader(convert(scaled_ps, "scaled-restored.pdf"))
    assert [tuple(map(float, p.mediabox[2:])) for p in scaled_pdf.pages] == [(720.0, 480.0), (720.0, 480.0), (360.0, 240.0)]
    assert "Original first page" in scaled_pdf.pages[0].extract_text()
    assert "Rotated second page" in scaled_pdf.pages[1].extract_text()

    # A readable page tree with broken drawing commands must not produce an apparently valid blank page.
    bad_writer = PdfWriter()
    bad_page = bad_writer.add_blank_page(200, 200)
    bad_content = DecodedStreamObject()
    bad_content.set_data(b"1 2 3 invalid_drawing_operator")
    bad_page[NameObject("/Contents")] = bad_writer._add_object(bad_content)
    bad_drawing = work / "bad-drawing.pdf"
    bad_writer.write(bad_drawing)
    convert(bad_drawing, "bad-drawing.ps", success=False)
    convert(bad_drawing, "bad-drawing-level2.ps", success=False, options={"languageLevel": 2})
    bad_page[NameObject("/UserUnit")] = NumberObject(2)
    bad_writer.write(bad_drawing)
    convert(bad_drawing, "bad-scaled-drawing.ps", success=False)

    # Both the interpreter and the native process boundary must keep unrelated files private.
    protected = work / "private-text.txt"
    protected.write_text("Unrelated private data")
    for operation in (f"({protected}) (r) file closefile", f"({work / 'escaped.txt'}) (w) file closefile",
                      "(%pipe%touch /tmp/postscript-escape-check) (w) file closefile"):
        hostile = work / "hostile.ps"
        hostile.write_text("%!PS-Adobe-3.0\n" + operation + "\nshowpage\n")
        convert(hostile, "hostile.pdf", success=False)
    assert protected.read_text() == "Unrelated private data"
    assert not (work / "escaped.txt").exists()
    launcher = (args.command.parent.parent / "Helpers/postscript" if ".app/" in str(args.command)
                else root / ".tools/bin/postscript")
    boundary = work / "boundary"
    boundary.mkdir(exist_ok=True)
    for path in (protected, Path("/System/Volumes/Data") / protected.relative_to("/")):
        hostile.write_text(f"%!PS-Adobe-3.0\n({path}) (r) file closefile showpage\n")
        result = subprocess.run([launcher, hostile, boundary, "-q", "-dNOSAFER", "-dBATCH", "-dNOPAUSE",
                                 "-sDEVICE=nullpage", "-f", hostile], capture_output=True, timeout=10)
        assert result.returncode != 0 and b"/ioerror in --file--" in result.stdout \
            and b"Operation not permitted" in result.stdout + result.stderr, \
            "The native boundary must hold without the interpreter's file checks."
    broken = work / "broken.pdf"
    broken.write_bytes(b"%PDF-1.7\ntruncated")
    convert(broken, "broken.ps", success=False)
    encrypted = work / "encrypted.pdf"
    writer.encrypt("test-password")
    writer.write(encrypted)
    convert(encrypted, "encrypted.ps", success=False)
    assert not list(work.glob(".allomer-*"))
    print("PDF/PostScript checks pass: both language levels, Flate compression, page selection, scaled and rotated crop boxes, embedded fonts, JPEG/JPX images, gradients, transparency, invalid drawing rejection, and file access denial.")


if __name__ == "__main__":
    main()
