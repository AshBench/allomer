#!/usr/bin/env python3
"""Check image OCR, EXIF orientation, and searchable PDF appearance."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import re
import statistics
import subprocess
import xml.etree.ElementTree as ET
import zipfile

from PIL import Image, ImageChops, ImageDraw, ImageFont
import pypdfium2 as pdfium
from pypdf import PdfReader, PdfWriter
from pypdf.generic import DecodedStreamObject, NameObject, NumberObject, RectangleObject
from reportlab.pdfgen.canvas import Canvas
from reportlab.lib.utils import ImageReader


def measure(arguments, work, env):
    result = subprocess.run(["/usr/bin/time", "-l", *arguments], cwd=work, env=env,
                            capture_output=True, text=True, check=True, timeout=130)
    elapsed = re.search(r"([0-9.]+) real", result.stderr)
    memory = re.search(r"([0-9]+)\s+maximum resident set size", result.stderr)
    assert elapsed and memory, result.stderr
    return {"elapsed_seconds": float(elapsed[1]), "peak_resident_bytes": int(memory[1])}


def check_scanned_pdf(work, helper, renderer, original, env, command):
    source = work / "mixed-source.pdf"
    canvas = Canvas(str(source), pagesize=original.size, invariant=1)
    canvas.setTitle("Original scan checks")
    canvas.drawString(50, 400, "Already selectable 7821")
    canvas.acroForm.textfield(name="kept-field", value="Unchanged value", x=50, y=80)
    canvas.linkURL("https://example.org/", (50, 300, 250, 330))
    canvas.bookmarkPage("start")
    canvas.addOutlineEntry("Kept outline", "start")
    canvas.showPage()
    canvas.drawImage(ImageReader(original), 0, 0, width=1000, height=480)
    canvas.showPage()
    canvas.showPage()
    for angle, transpose in [(0, None), (90, Image.Transpose.ROTATE_90),
                             (180, Image.Transpose.ROTATE_180), (270, Image.Transpose.ROTATE_270)]:
        pixels = original.transpose(transpose) if transpose is not None else original
        canvas.setPageSize(pixels.size)
        canvas.drawImage(ImageReader(pixels), 0, 0, width=pixels.width, height=pixels.height)
        canvas.showPage()
    canvas.save()
    writer = PdfWriter(clone_from=source)
    content = DecodedStreamObject()
    content.set_data(writer.pages[1].get_contents().get_data() + b"\nq 2 0 0 2 500 500 cm\n")
    writer.pages[1][NameObject("/Contents")] = writer._add_object(content)
    for index, angle in enumerate((0, 90, 180, 270), start=3):
        page = writer.pages[index]
        page[NameObject("/Rotate")] = NumberObject(angle)
        page.mediabox = RectangleObject([-20, -30, page.mediabox.width + 10, page.mediabox.height + 15])
        page.cropbox = RectangleObject([5, 10, page.mediabox.right - 15, page.mediabox.top - 20])
        if angle == 180:
            page[NameObject("/UserUnit")] = NumberObject(2)
    writer.write(source)
    before = hashlib.sha256(source.read_bytes()).hexdigest()
    layer, prepared = work / "scan-layer.pdf", work / "scan-prepared.pdf"
    result = subprocess.run([helper, source, work, "pdf-overlay", source, layer.name, "1,2,3,4,5,6,7"],
                            cwd=work, env=env, capture_output=True, text=True, timeout=130)
    assert result.returncode == 0, result.stderr
    guard = helper.with_name("pdfguard")
    result = subprocess.run([guard, source, work, "overlay", source, layer, prepared.name],
                            cwd=work, env=env, capture_output=True, text=True, timeout=130)
    assert result.returncode == 0, result.stderr
    old, new, overlay = PdfReader(source), PdfReader(prepared), PdfReader(layer)
    assert len(new.pages) == len(old.pages) == 7
    assert old.metadata == new.metadata
    assert old.get_fields()["kept-field"]["/V"] == new.get_fields()["kept-field"]["/V"] == "Unchanged value"
    assert old.outline[0].title == new.outline[0].title == "Kept outline"
    assert not overlay.pages[0].extract_text().strip() and not overlay.pages[2].extract_text().strip()
    for index, (prior, page) in enumerate(zip(old.pages, new.pages)):
        for key in ("/MediaBox", "/CropBox", "/Rotate", "/UserUnit"):
            assert prior.get(key) == page.get(key), (index, key)
        old_images = [image.indirect_reference.get_object()._data for image in prior.images]
        new_images = [image.indirect_reference.get_object()._data for image in page.images]
        assert old_images == new_images, index
        if index == 0:
            assert page.extract_text().count("Already selectable 7821") == 1
            assert len(prior["/Annots"]) == len(page["/Annots"]) == 2
            assert page["/Annots"][1].get_object()["/A"]["/URI"] == "https://example.org/"
        elif index == 2:
            assert not page.extract_text().strip()
        else:
            assert "Invoice number 4827" in page.extract_text(), (index, page.extract_text())
        for label, pdf in (("source", source), ("prepared", prepared)):
            subprocess.run([renderer, "-f", str(index + 1), "-l", str(index + 1), "-singlefile",
                            "-cropbox", "-r", "72", "-png", pdf, work / f"{label}-{index}"],
                           capture_output=True, check=True)
        with Image.open(work / f"source-{index}.png") as a, Image.open(work / f"prepared-{index}.png") as b:
            assert a.size == b.size and a.tobytes() == b.tobytes(), index
    # Independent text positions must overlap the original printed line on every rotation.
    with pdfium.PdfDocument(prepared) as pages:
        for index, angle in ((1, 0), (3, 0), (4, 90), (5, 180), (6, 270)):
            page = pages[index]
            text = page.get_textpage()
            try:
                left, bottom, right, top = text.get_charbox(text.get_text_range().index("Invoice"))
                # Map raw PDF coordinates back to the original image's top-left origin.
                x, y = {0: (left, 480 - top), 90: (bottom, left),
                        180: (1000 - right, bottom), 270: (1000 - top, 480 - right)}[angle]
                assert 35 < x < 65 and 155 < y < 205, (index, x, y)
            finally:
                text.close()
                page.close()
    # Selecting only a blank page must leave every existing page's text unchanged.
    subprocess.run([helper, source, work, "pdf-overlay", source, "selected-layer.pdf", "3"],
                   cwd=work, env=env, capture_output=True, check=True, timeout=130)
    assert all(not page.extract_text().strip() for page in PdfReader(work / "selected-layer.pdf").pages)
    subprocess.run([helper, source, work, "pdf-overlay", source, "english-layer.pdf", "2", "en-US"],
                   cwd=work, env=env, capture_output=True, check=True, timeout=130)
    english = PdfReader(work / "english-layer.pdf")
    assert "Invoice number 4827" in english.pages[1].extract_text()
    assert all(not page.extract_text().strip() for index, page in enumerate(english.pages) if index != 1)
    # Reject incompatible layer geometry and invalid page choices.
    incompatible = PdfWriter(clone_from=layer)
    incompatible.pages[1].mediabox = RectangleObject([0, 0, 10, 10])
    incompatible.write(work / "wrong-bounds.pdf")
    result = subprocess.run([guard, source, work, "overlay", source, work / "wrong-bounds.pdf", "rejected.pdf"],
                            cwd=work, env=env, capture_output=True, text=True, timeout=130)
    assert result.returncode != 0 and "different page bounds" in result.stderr
    incompatible.remove_page(0)
    incompatible.write(work / "wrong-count.pdf")
    result = subprocess.run([guard, source, work, "overlay", source, work / "wrong-count.pdf", "rejected.pdf"],
                            cwd=work, env=env, capture_output=True, text=True, timeout=130)
    assert result.returncode != 0 and "different page count" in result.stderr
    for selection in ("0", "8", "1,1", "", "-1"):
        result = subprocess.run([helper, source, work, "pdf-overlay", source, "rejected-layer.pdf", selection],
                                cwd=work, env=env, capture_output=True, text=True, timeout=130)
        assert result.returncode != 0, selection
    encrypted = PdfWriter(clone_from=source)
    encrypted.encrypt("locked")
    encrypted.write(work / "encrypted.pdf")
    result = subprocess.run([helper, work / "encrypted.pdf", work, "pdf-overlay", work / "encrypted.pdf", "rejected-layer.pdf", "1"],
                            cwd=work, env=env, capture_output=True, text=True, timeout=130)
    assert result.returncode != 0 and "unencrypted" in result.stderr
    assert hashlib.sha256(source.read_bytes()).hexdigest() == before
    for extension in ("docx", "html", "md"):
        output = work / f"scanned-document.{extension}"
        output.unlink(missing_ok=True)
        result = subprocess.run([command, "convert", prepared, output], cwd=work, env=env,
                                capture_output=True, text=True, timeout=130)
        assert result.returncode == 0, result.stderr
        if extension == "docx":
            with zipfile.ZipFile(output) as archive:
                assert archive.testzip() is None
                text = "".join(ET.fromstring(archive.read("word/document.xml")).itertext())
        elif extension == "html":
            text = "".join(ET.parse(output).getroot().itertext())
        else:
            text = output.read_text()
        assert text.count("Invoice number 4827") >= 5, (extension, text[:1000])
        assert text.count("Already selectable 7821") >= 1, extension
    assert not list(work.glob(".allomer-*"))
    print("Scanned PDFs preserve page appearance, original image streams, fields, links, outlines, metadata, rotation, and crop bounds.")


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--command", type=Path, default=root / ".build/debug/allomer")
    parser.add_argument("--renderer", type=Path, required=True)
    parser.add_argument("--benchmark", action="store_true")
    args = parser.parse_args()
    packaged = ".app/" in str(args.command)
    helper = args.command.parent.parent / "Helpers/nativeguard" if packaged else root / ".tools/bin/nativeguard"
    work = root / ".tools/ocr-check"
    work.mkdir(exist_ok=True)
    env = {"PATH": "/usr/bin:/bin"}
    if not packaged:
        env["ALLOMER_TOOLS_DIR"] = str(root / ".tools/bin")
    original = Image.new("RGB", (1000, 480), "white")
    draw = ImageDraw.Draw(original)
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 48)
    lines = ["Local text stays here", "Invoice number 4827", "Total 123.45"]
    for index, line in enumerate(lines):
        draw.text((50, 60 + index * 110), line, font=font, fill="black")
    draw.rectangle((800, 40, 950, 160), fill=(220, 40, 60))
    draw.ellipse((770, 300, 900, 430), fill=(20, 90, 220))
    original.save(work / "original.png")
    inverse = {2: Image.Transpose.FLIP_LEFT_RIGHT, 3: Image.Transpose.ROTATE_180,
               4: Image.Transpose.FLIP_TOP_BOTTOM, 5: Image.Transpose.TRANSPOSE,
               6: Image.Transpose.ROTATE_90, 7: Image.Transpose.TRANSVERSE, 8: Image.Transpose.ROTATE_270}
    for orientation in range(1, 9):
        source = work / f"orientation-{orientation}.png"
        exif = Image.Exif()
        exif[274] = orientation
        pixels = original.transpose(inverse[orientation]) if orientation != 1 else original
        pixels.save(source, exif=exif)
        before = hashlib.sha256(source.read_bytes()).hexdigest()
        output = work / f"orientation-{orientation}.pdf"
        output.unlink(missing_ok=True)
        base = work / f"image-{orientation}.pdf"
        layer = work / f"text-{orientation}.pdf"
        base.unlink(missing_ok=True)
        result = subprocess.run([args.command, "convert", source, base], cwd=work,
                                env=env, capture_output=True, text=True, timeout=130)
        assert result.returncode == 0, result.stderr
        result = subprocess.run([helper, source, work, "image", source, layer.name, "pdf-layer"], cwd=work,
                                env=env, capture_output=True, text=True, timeout=130)
        assert result.returncode == 0, result.stderr
        text_page = PdfReader(layer).pages[0]
        assert not list(text_page.images), "The OCR layer must contain no second image."
        assert b"3 Tr" in text_page.get_contents().get_data(), "OCR text must be invisible."
        result = subprocess.run([helper.with_name("pdfguard"), base, work, "overlay", base, layer, output.name], cwd=work,
                                env=env, capture_output=True, text=True, timeout=130)
        assert result.returncode == 0, result.stderr
        pdf = PdfReader(output)
        assert len(pdf.pages) == 1
        page = pdf.pages[0]
        assert abs(float(page.mediabox.width) - 1000) < 0.01 and abs(float(page.mediabox.height) - 480) < 0.01
        embedded = list(page.images)
        expected = list(PdfReader(base).pages[0].images)
        assert len(embedded) == len(expected) == 1, orientation
        assert embedded[0].indirect_reference.get_object()._data == expected[0].indirect_reference.get_object()._data, orientation
        assert embedded[0].image.convert("RGB").tobytes() == expected[0].image.convert("RGB").tobytes(), orientation
        text = page.extract_text()
        for line in lines:
            assert line in text, (orientation, line, text)
        subprocess.run([args.renderer, "-singlefile", "-r", "72", "-png", output, work / f"rendered-{orientation}"],
                       capture_output=True, check=True)
        with Image.open(work / f"rendered-{orientation}.png") as rendered:
            assert rendered.size == original.size, (orientation, rendered.size)
            delta = list(ImageChops.difference(rendered.convert("RGB"), original).get_flattened_data())
            # The independent reader interpolates image edges at the page boundary.
            assert sum(max(pixel) > 32 for pixel in delta) / len(delta) < 0.02, orientation
        assert hashlib.sha256(source.read_bytes()).hexdigest() == before
    source = work / "original.png"
    subprocess.run([helper, source, work, "image", source, "english.txt", "txt", "en-US"],
                   cwd=work, env=env, capture_output=True, check=True, timeout=130)
    assert "Invoice number 4827" in (work / "english.txt").read_text()
    for arguments in (["image", source, "bad-language.txt", "txt"],
                      ["pdf-overlay", work / "orientation-1.pdf", "bad-language.pdf", "1"]):
        # The image path must reject the setting. Already-selectable PDF pages skip OCR.
        result = subprocess.run([helper, arguments[1], work, *arguments, "unsupported-language"],
                                cwd=work, env=env, capture_output=True, text=True, timeout=130)
        if arguments[0] == "image":
            assert result.returncode != 0 and "language is not supported" in result.stderr
        else:
            assert result.returncode == 0, result.stderr
    for extension in ("txt", "html", "md", "docx"):
        output = work / f"recognized.{extension}"
        output.unlink(missing_ok=True)
        result = subprocess.run([args.command, "convert", source, output], cwd=work, env=env,
                                capture_output=True, text=True, timeout=130)
        assert result.returncode == 0, result.stderr
        if extension == "docx":
            with zipfile.ZipFile(output) as archive:
                assert archive.testzip() is None
                text = "".join(ET.fromstring(archive.read("word/document.xml")).itertext())
        elif extension == "html":
            text = "".join(ET.parse(output).getroot().itertext())
        else:
            text = output.read_text()
        for line in lines:
            assert line in text, (extension, text)
    blank = work / "blank.png"
    Image.new("RGB", (640, 480), "white").save(blank)
    empty = work / "blank.txt"
    empty.unlink(missing_ok=True)
    result = subprocess.run([args.command, "convert", blank, empty], cwd=work, env=env, capture_output=True, text=True, timeout=130)
    assert result.returncode != 0 and "No readable text" in result.stderr and not empty.exists()
    subprocess.run([helper, blank, work, "image", blank, "blank.pdf", "pdf"], cwd=work, env=env, capture_output=True, check=True)
    assert not PdfReader(work / "blank.pdf").pages[0].extract_text().strip()
    oversized = work / "too-wide.png"
    Image.new("RGB", (100001, 1), "white").save(oversized)
    rejected = work / "too-wide.txt"
    rejected.unlink(missing_ok=True)
    result = subprocess.run([args.command, "convert", oversized, rejected], cwd=work, env=env, capture_output=True, text=True, timeout=130)
    assert result.returncode != 0 and "OCR needs a single image" in result.stderr and not rejected.exists()
    assert not list(work.glob(".allomer-*"))
    print("Eight EXIF orientations preserve PDF appearance and searchable text. TXT, HTML, Markdown, DOCX, blank-image, and image-size checks pass.")
    check_scanned_pdf(work, helper, args.renderer, original, env, args.command)
    if args.benchmark:
        samples = []
        for index in range(3):
            output = work / f"benchmark-{index}.pdf"
            sample = measure([helper, source, work, "image", source, output.name, "pdf"], work, env)
            samples.append(dict(sample, output_bytes=output.stat().st_size))
        report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                  "architecture": platform.machine(), "workload": "1000 by 480 RGB image with three text lines and two colored shapes to searchable PDF",
                  "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "source_bytes": source.stat().st_size,
                  "helper_sha256": hashlib.sha256(helper.with_name("nativeconvert").read_bytes()).hexdigest(),
                  "launcher_sha256": hashlib.sha256(helper.read_bytes()).hexdigest(), "samples": samples,
                  "memory_scope": "Peak helper RSS from macOS time -l, including PDF text checks. Excludes the app and separate system services. Warm runs after the content checks.",
                  "median_elapsed_seconds": statistics.median(value["elapsed_seconds"] for value in samples),
                  "median_peak_resident_bytes": statistics.median(value["peak_resident_bytes"] for value in samples)}
        (root / "research/ocr-performance.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
        scan = work / "mixed-source.pdf"
        guard = helper.with_name("pdfguard")
        samples = []
        for _ in range(3):
            layer, prepared, output = work / "timed-layer.pdf", work / "timed-prepared.pdf", work / "timed.docx"
            for file in (layer, prepared, output):
                file.unlink(missing_ok=True)
            stages = [measure([helper, scan, work, "pdf-overlay", scan, layer.name, "1,2,3,4,5,6,7"], work, env),
                      measure([guard, scan, work, "overlay", scan, layer, prepared.name], work, env),
                      measure([guard, prepared, work, "convert", "-F", "docx", "-o", output.name, prepared, "1-7"], work, env)]
            with zipfile.ZipFile(output) as archive:
                assert archive.testzip() is None
                text = "".join(ET.fromstring(archive.read("word/document.xml")).itertext())
                assert text.count("Invoice number 4827") >= 5
            samples.append({"stages": dict(zip(("recognition", "text_layer_merge", "docx_export"), stages)),
                            "elapsed_seconds": sum(stage["elapsed_seconds"] for stage in stages),
                            "peak_resident_bytes": max(stage["peak_resident_bytes"] for stage in stages),
                            "output_bytes": output.stat().st_size})
        report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                  "architecture": platform.machine(),
                  "workload": "Seven-page PDF with five scanned images, one selectable page, and one blank page to DOCX. Includes crop bounds and four rotations.",
                  "source_bytes": scan.stat().st_size, "source_sha256": hashlib.sha256(scan.read_bytes()).hexdigest(),
                  "helper_sha256": {name: hashlib.sha256(helper.with_name(name).read_bytes()).hexdigest()
                                    for name in ("nativeconvert", "nativeguard", "mutool", "pdfguard")},
                  "samples": samples,
                  "memory_scope": "Maximum of sequential helper peaks from macOS time -l. Not aggregate app memory. Excludes Swift adapter checks and separate system services. Warm runs after content checks.",
                  "median_elapsed_seconds": statistics.median(sample["elapsed_seconds"] for sample in samples),
                  "median_peak_resident_bytes": statistics.median(sample["peak_resident_bytes"] for sample in samples)}
        (root / "research/pdf-ocr-performance.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
