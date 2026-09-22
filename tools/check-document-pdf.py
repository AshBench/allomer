#!/usr/bin/env python3
"""Check local document PDF content, pagination, resources, and print behavior."""
import argparse
from datetime import datetime, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import logging
import platform
import re
import statistics
import subprocess
import threading
import xml.etree.ElementTree as ET
import zipfile

from PIL import Image
from pypdf import PdfReader


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--command", type=Path, default=root / ".build/debug/allomer")
    parser.add_argument("--renderer", type=Path, required=True)
    parser.add_argument("--benchmark", action="store_true")
    args = parser.parse_args()
    warnings = []
    class PDFWarnings(logging.Handler):
        def emit(self, record):
            warnings.append(record.getMessage())
    logging.getLogger("pypdf").addHandler(PDFWarnings(level=logging.WARNING))
    work = root / ".tools/document-pdf-check"
    work.mkdir(exist_ok=True)
    env = {"PATH": "/usr/bin:/bin"}
    if ".app/" not in str(args.command):
        env["ALLOMER_TOOLS_DIR"] = str(root / ".tools/bin")

    def convert(source, output, success=True):
        output.unlink(missing_ok=True)
        before = hashlib.sha256(source.read_bytes()).hexdigest()
        result = subprocess.run([args.command, "convert", source, output], cwd=work, env=env,
                                capture_output=True, text=True, timeout=130)
        assert (result.returncode == 0) == success, result.stderr
        assert hashlib.sha256(source.read_bytes()).hexdigest() == before
        assert output.is_file() == success
        return output

    asset = Image.new("RGB", (32, 24))
    asset.putdata([(x * 8, y * 10, (x + y) * 4) for y in range(24) for x in range(32)])
    asset.save(work / "asset % café.png")
    (work / "print.css").write_text("body {font:16px Helvetica;margin:0} h1 {color:#17325b} td {border:1px solid #777;padding:8px} table {border-collapse:collapse} @media print {.screen {display:none}}")
    source = work / "original.html"
    source.write_text('''<!DOCTYPE html><meta charset="utf-8"><title>Original document PDF check</title>
      <link rel="stylesheet" href="print.css"><h1>Original document — Café</h1>
      <p>A paragraph with <b>bold text</b> and an <a href="https://example.invalid/reference">external link</a>.</p>
      <p><a href="#second">Go to the second page</a></p><p class="screen">Screen-only material</p>
      <div style="background:#00aa77;width:120px;height:40px"></div>
      <table><tr><td>Heading one</td><td>Heading two</td></tr><tr><td>Cell 123</td><td>Cell 456</td></tr></table>
      <img src="asset%20%25%20caf%C3%A9.png" width="64" height="48">
      <h1 id="second" style="break-before:page">Second printed page</h1><p>Last original paragraph.</p>''')
    pdf = convert(source, work / "original.pdf")
    document = PdfReader(pdf)
    assert document.metadata.title == "Original document PDF check"
    assert len(document.pages) == 2
    for page in document.pages:
        assert abs(float(page.mediabox.width) - 595.28) <= 1 and abs(float(page.mediabox.height) - 841.89) <= 1
    first, last = (page.extract_text() for page in document.pages)
    assert all(value in first for value in ("Original document — Café", "bold text", "Heading one", "Cell 456"))
    assert "Screen-only material" not in first
    assert "Last original paragraph." in last
    images = list(document.pages[0].images)
    assert any(item.image.size == asset.size and item.image.convert("RGB").tobytes() == asset.tobytes() for item in images)
    links = [annotation.get_object() for annotation in document.pages[0].get("/Annots", [])]
    assert any("/A" in link and "/URI" in link["/A"]
               and link["/A"]["/URI"] == "https://example.invalid/reference" for link in links)
    assert any("/Dest" in link or link.get("/A", {}).get("/S") == "/GoTo" for link in links)
    destination = next(link["/Dest"] for link in links if "/Dest" in link)
    assert destination[0].idnum == document.pages[1].indirect_reference.idnum
    subprocess.run([args.renderer, "-r", "90", "-png", pdf, work / "page"], check=True, capture_output=True)
    with Image.open(work / "page-1.png") as image:
        assert sum(g > 120 and r < 30 and 80 < b < 150 for r, g, b in image.convert("RGB").get_flattened_data()) > 1000, "The authored print background was lost."

    markdown = work / "original.md"
    markdown.write_text('''# Original Markdown — Café

A **bold** paragraph with a [link](https://example.invalid/markdown).

| Column one | Column two |
| --- | --- |
| Cell 123 | Cell 456 |

![Original picture](asset%20%25%20caf%C3%A9%2Epng?cache=1#image)

```swift
let answer = 42
print("Local conversion")
```
''')
    result = PdfReader(convert(markdown, work / "markdown.pdf"))
    text = "\n".join(page.extract_text() for page in result.pages)
    assert all(value in text for value in ("Original Markdown — Café", "Cell 123", "let answer = 42", "Local conversion"))
    assert any(item.image.size == asset.size and item.image.convert("RGB").tobytes() == asset.tobytes()
               for page in result.pages for item in page.images)
    for extension in ("docx", "odt", "rtf", "epub"):
        # ODT, RTF, and EPUB reflow through HTML here; they are not original-page-layout checks.
        # DOCX now prints directly; tools/check-word-pdf.py checks that path's page layout.
        intermediate = convert(markdown, work / f"intermediate.{extension}")
        if extension != "rtf":
            with zipfile.ZipFile(intermediate) as archive:
                manifest = {"docx": "[Content_Types].xml", "odt": "META-INF/manifest.xml"}.get(extension)
                if manifest is None:
                    manifest = next(name for name in archive.namelist() if name.endswith(".opf"))
                content = ET.fromstring(archive.read(manifest))
                assert any("image/png" in node.attrib.values() for node in content.iter()), f"Wrong image type in {extension}"
        restored = PdfReader(convert(intermediate, work / f"from-{extension}.pdf"))
        text = "\n".join(page.extract_text() for page in restored.pages)
        assert "Original Markdown" in text and "Cell 123" in text
        assert any(item.image.size == asset.size and item.image.convert("RGB").tobytes() == asset.tobytes()
                   for page in restored.pages for item in page.images), f"Image lost through {extension}"

    missing = work / "missing.md"
    outside = work.parent / "document-pdf-check-outside.png"
    asset.save(outside)
    link = work / "outside-link.png"
    link.unlink(missing_ok=True)
    link.symlink_to(outside)
    try:
        for reference in ("missing.png", "https://example.invalid/missing.png",
                          "../document-pdf-check-outside.png", "outside-link.png", "asset%00.png"):
            missing.write_text(f"![Picture]({reference})")
            convert(missing, work / "refused.docx", success=False)
    finally:
        link.unlink()
        outside.unlink()

    basic = work / "basic.md"
    basic.write_text("# Original bridge heading\n\nOriginal bridge paragraph.\n")
    for extension in ("ipynb", "tex", "man", "wiki", "opml", "org", "rst"):
        intermediate = convert(basic, work / f"basic.{extension}")
        printed = PdfReader(convert(intermediate, work / f"basic-{extension}.pdf"))
        text = "\n".join(page.extract_text() for page in printed.pages)
        assert "Original bridge heading" in text and "Original bridge paragraph" in text, extension
    for extension, delimiter in (("csv", ","), ("tsv", "\t")):
        table = work / f"table.{extension}"
        table.write_text(f"Name{delimiter}Value\nCafé{delimiter}123\n")
        printed = PdfReader(convert(table, work / f"table-{extension}.pdf"))
        text = "\n".join(page.extract_text() for page in printed.pages)
        assert "Café" in text and "123" in text

    requests = []
    class Probe(BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            self.send_response(200)
            self.end_headers()
        def log_message(self, *args):
            pass
    server = ThreadingHTTPServer(("127.0.0.1", 0), Probe)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        hostile = work / "hostile.html"
        for content in (f'<img src="http://127.0.0.1:{server.server_port}/image">', '<img src="missing.png">',
                        f'<style>@import url("http://127.0.0.1:{server.server_port}/style");</style><p>Text</p>'):
            hostile.write_text(content)
            convert(hostile, work / "refused.pdf", success=False)
        hostile.write_text(f'''<p id="text">Original text</p><script>
          document.getElementById('text').textContent='Changed text';fetch('http://127.0.0.1:{server.server_port}/script');
          </script>''')
        text = PdfReader(convert(hostile, work / "scripts-disabled.pdf")).pages[0].extract_text()
        assert "Original text" in text and "Changed text" not in text
        assert not requests, requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    assert not list(work.glob(".allomer-*"))
    assert not warnings, warnings
    print("Document PDF text, pages, links, table content, image pixels, print backgrounds, Markdown, document bridges, and blocked resources pass.")
    if args.benchmark:
        packaged = ".app/" in str(args.command)
        tools = args.command.parent.parent / "Helpers" if packaged else root / ".tools/bin"
        samples = []
        for _ in range(3):
            output = work / "benchmark.pdf"
            output.unlink(missing_ok=True)
            result = subprocess.run(["/usr/bin/time", "-l", tools / "webguard", source, work, work,
                "html", source, output.name, "pdf", "a4", "none"], cwd=work, env=env,
                check=True, capture_output=True, text=True, timeout=130)
            elapsed = re.search(r"([0-9.]+) real", result.stderr)
            memory = re.search(r"([0-9]+)\s+maximum resident set size", result.stderr)
            assert elapsed and memory and len(PdfReader(output).pages) == 2, result.stderr
            samples.append({"elapsed_seconds": float(elapsed[1]), "peak_resident_bytes": int(memory[1]),
                            "output_bytes": output.stat().st_size})
        report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
            "architecture": platform.machine(), "workload": "Original two-page HTML with print CSS, table, links, Unicode text, and a local bitmap",
            "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "source_bytes": source.stat().st_size,
            "assets_sha256": {name: hashlib.sha256((work / name).read_bytes()).hexdigest() for name in ("print.css", "asset % café.png")},
            "helper_sha256": hashlib.sha256((tools / "webconvert").read_bytes()).hexdigest(),
            "launcher_sha256": hashlib.sha256((tools / "webguard").read_bytes()).hexdigest(),
            "packaged": packaged, "samples": samples,
            "median_elapsed_seconds": statistics.median(s["elapsed_seconds"] for s in samples),
            "median_peak_resident_bytes": statistics.median(s["peak_resident_bytes"] for s in samples),
            "memory_scope": "Peak renderer helper RSS from macOS time -l. Excludes separate WebKit services, the native app, Swift adapter checks, and PDF index rebuilding. This is not total conversion memory. Three warm serial runs after content checks."}
        (root / "research/document-pdf-performance.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
