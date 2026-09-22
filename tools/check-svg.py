#!/usr/bin/env python3
"""Check original SVG artwork, local assets, dimensions, and resource boundaries."""
import argparse
from datetime import datetime, timezone
import gzip
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import json
import platform
import re
import shutil
import statistics
import subprocess
import threading
import uuid

from PIL import Image, ImageChops
from pypdf import PdfReader


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--command", type=Path, default=root / ".build/debug/allomer")
    parser.add_argument("--renderer", type=Path, required=True)
    parser.add_argument("--benchmark", action="store_true")
    args = parser.parse_args()
    work = root / ".tools/svg-content-check"
    work.mkdir(exist_ok=True)
    packaged = ".app/" in str(args.command)
    tools = args.command.parent.parent / "Helpers" if packaged else root / ".tools/bin"
    env = {"PATH": "/usr/bin:/bin"}
    if not packaged:
        env["ALLOMER_TOOLS_DIR"] = str(tools)
    asset = Image.new("RGB", (32, 24))
    asset.putdata([(x * 8, y * 10, (x + y) * 4) for y in range(24) for x in range(32)])
    asset.save(work / "asset % café.png")
    shutil.copyfile("/System/Library/Fonts/Supplemental/Arial.ttf", work / "fixture.ttf")
    (work / "extra.css").write_text(".title {font-weight:bold; font-size:28px; fill:#17325b}")
    (work / "style.css").write_text('@import url("extra.css"); @font-face {font-family:Fixture; src:url("fixture.ttf")} text {font-family:Fixture}')
    (work / "shape.svg").write_text('<svg xmlns="http://www.w3.org/2000/svg"><path id="triangle" d="M0 0 L40 0 L20 40 Z" fill="#00aa77"/></svg>')
    source = work / "original.svg"
    source.write_text('''<svg xmlns="http://www.w3.org/2000/svg" width="640" height="400" viewBox="0 0 640 400">
      <defs>
        <linearGradient id="color"><stop stop-color="#ef3340"/><stop offset="1" stop-color="#2468ee"/></linearGradient>
        <clipPath id="circle"><circle cx="520" cy="210" r="65"/></clipPath>
        <filter id="blur"><feGaussianBlur stdDeviation="8"/></filter>
        <pattern id="grid" width="20" height="20" patternUnits="userSpaceOnUse"><rect width="10" height="10" fill="#ffb800"/></pattern>
      </defs>
      <style>@import url("style.css"); .dash {stroke:#17325b;stroke-width:4;stroke-dasharray:10 6;fill:none}</style>
      <rect width="640" height="400" fill="white"/>
      <text class="title" x="30" y="55">Original SVG check — Café</text>
      <rect x="30" y="90" width="280" height="90" rx="16" fill="url(#color)"/>
      <rect x="30" y="210" width="130" height="110" fill="url(#grid)"/>
      <rect x="190" y="225" width="100" height="70" fill="#2468ee" filter="url(#blur)"/>
      <g clip-path="url(#circle)"><rect x="440" y="130" width="180" height="170" fill="url(#color)"/><path d="M430 180 L620 260" stroke="white" stroke-width="25"/></g>
      <path class="dash" d="M350 90 Q280 280 380 320"/>
      <image href="asset%20%25%20caf%C3%A9.png?v=1" x="420" y="290" width="64" height="48"/>
      <use href="shape.svg#triangle" x="560" y="310"/>
      <text x="30" y="365" font-size="22">Text and local resources</text>
    </svg>''')
    original = source.read_bytes()
    before = hashlib.sha256(original).hexdigest()

    def convert(source, extension, name="converted", success=True):
        output = work / f"{name}.{extension}"
        output.unlink(missing_ok=True)
        result = subprocess.run([args.command, "convert", source, output], cwd=work, env=env,
                                capture_output=True, text=True, timeout=130)
        assert (result.returncode == 0) == success, result.stderr
        assert output.exists() == success, (name, result.stderr)
        return output

    pdf = convert(source, "pdf")
    png = convert(source, "png")
    document = PdfReader(pdf)
    assert len(document.pages) == 1 and list(document.pages[0].mediabox) == [0, 0, 640, 400]
    assert "Original SVG check — Café" in document.pages[0].extract_text()
    assert "Text and local resources" in document.pages[0].extract_text()
    # Only the blur and source bitmap need image objects. The full artwork must stay vector content.
    images = list(document.pages[0].images)
    assert 1 <= len(images) <= 4
    assert any(image.image.size == asset.size and image.image.convert("RGB").tobytes() == asset.tobytes() for image in images)
    subprocess.run([args.renderer, "-singlefile", "-r", "72", "-png", pdf, work / "independent"], check=True, capture_output=True)
    with Image.open(png) as image, Image.open(work / "independent.png") as reference:
        assert image.size == reference.size == (640, 400)
        image = image.convert("RGB")
        delta = list(ImageChops.difference(image, reference.convert("RGB")).get_flattened_data())
        assert sum(max(pixel) > 40 for pixel in delta) / len(delta) < 0.03
        assert image.getpixel((45, 130))[0] > 180 and image.getpixel((295, 130))[2] > 180
        assert min(image.getpixel((445, 140))) > 245, "The clip path was lost."
        assert image.getpixel((45, 225))[0] > 245 and image.getpixel((45, 225))[2] < 10, "The pattern was lost."
        assert 100 < image.getpixel((183, 250))[0] < 245, "The blur was lost."
        assert image.getpixel((580, 325))[1] > 120 and image.getpixel((580, 325))[0] < 40, "The external use element was lost."
    compressed = convert(source, "svgz")
    assert gzip.decompress(compressed.read_bytes()) == original
    assert convert(compressed, "svg", "restored").read_bytes() == original
    for extension in ("jpg", "tiff", "bmp", "gif", "heic", "avif"):
        assert convert(source, extension).stat().st_size > 0
    transparent = work / "transparent.svg"
    transparent.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="100" height="80"><circle cx="50" cy="40" r="20" fill="red"/></svg>')
    with Image.open(convert(transparent, "png", "transparent")) as image:
        assert image.convert("RGBA").getpixel((0, 0))[3] == 0
        assert image.convert("RGBA").getpixel((50, 40)) == (255, 0, 0, 255)
    for width, height, scale, expected in [(0, 0, 2, (200, 160)), (250, 0, -1, (250, 200)),
                                            (0, 40, -1, (50, 40)), (120, 120, -1, (120, 120))]:
        output = work / "sized.png"
        output.unlink(missing_ok=True)
        result = subprocess.run([tools / "webguard", transparent, work, work, "svg", transparent, output.name,
                                 "png", str(width), str(height), str(scale)], cwd=work, env=env,
                                capture_output=True, text=True, timeout=130)
        assert result.returncode == 0, result.stderr
        with Image.open(output) as image:
            assert image.size == expected, (expected, image.size)
            bounds = image.convert("RGBA").getchannel("A").getbbox()
            planned = (0.3 * expected[0], 0.25 * expected[1], 0.7 * expected[0], 0.75 * expected[1])
            assert all(abs(a - b) <= 1 for a, b in zip(bounds, planned)), (bounds, planned)
    fractional = work / "fractional.svg"
    fractional.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="123.5" height="80.25"><rect width="100%" height="100%" fill="red"/></svg>')
    page = PdfReader(convert(fractional, "pdf", "fractional")).pages[0]
    assert abs(float(page.mediabox.width) - 123.5) < 0.01 and abs(float(page.mediabox.height) - 80.25) < 0.01
    animated = work / "animated.svg"
    animated.write_text('''<svg xmlns="http://www.w3.org/2000/svg" width="100" height="80">
      <style>@keyframes move {from {transform:translateX(0)} to {transform:translateX(60px)}} #css {animation:move 0.01s infinite}</style>
      <rect id="css" x="10" y="10" width="20" height="20" fill="red"/>
      <rect x="10" y="50" width="20" height="20" fill="blue"><animate attributeName="x" from="10" to="70" dur="0.01s" repeatCount="indefinite"/></rect>
    </svg>''')
    with Image.open(convert(animated, "png", "animation-start")) as image:
        pixels = image.convert("RGBA")
        assert pixels.getpixel((15, 15)) == (255, 0, 0, 255)
        assert pixels.getpixel((15, 55)) == (0, 0, 255, 255)
        assert pixels.getpixel((75, 15))[3] == pixels.getpixel((75, 55))[3] == 0
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
    outside = work.parent / f"svg-outside-{uuid.uuid4()}.png"
    asset.save(outside)
    escaped = work / "escaped.png"
    escaped.unlink(missing_ok=True)
    escaped.symlink_to(outside)
    try:
        bad = work / "bad.svg"
        for index, reference in enumerate((f"http://127.0.0.1:{server.server_port}/image.png", "../" + outside.name, "escaped.png", "missing.png")):
            bad.write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="100" height="80"><image href="{reference}" width="100" height="80"/></svg>')
            convert(bad, "png", f"rejected-{index}", success=False)
        bad.write_text(f'''<svg xmlns="http://www.w3.org/2000/svg" width="100" height="80">
          <rect id="box" width="100" height="80" fill="red"/>
          <script><![CDATA[document.getElementById('box').setAttribute('fill','blue'); fetch('http://127.0.0.1:{server.server_port}/script');]]></script>
        </svg>''')
        with Image.open(convert(bad, "png", "script-disabled")) as image:
            assert image.convert("RGB").getpixel((50, 40)) == (255, 0, 0)
        assert not requests, requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
        outside.unlink()
        escaped.unlink()
    for index, content in enumerate(("<svg", '<svg xmlns="urn:wrong"/>',
                                    '<svg xmlns="http://www.w3.org/2000/svg" width="100001" height="1"/>')):
        bad.write_text(content)
        convert(bad, "png", f"invalid-{index}", success=False)
    broken = work / "broken.svgz"
    broken.write_bytes(gzip.compress(original)[:-4])
    convert(broken, "svg", "invalid-gzip", success=False)
    assert hashlib.sha256(source.read_bytes()).hexdigest() == before
    assert not list(work.glob(".allomer-*"))
    print("SVG styles, local fonts/images/use, gradients, filters, clipping, transparency, sizes, SVGZ bytes, and resource boundaries pass.")
    if args.benchmark:
        runs = []
        for extension, scale in (("pdf", 1), ("png", 4)):
            samples = []
            for _ in range(3):
                output = work / f"benchmark.{extension}"
                output.unlink(missing_ok=True)
                result = subprocess.run(["/usr/bin/time", "-l", tools / "webguard", source, work, work,
                    "svg", source, output.name, extension, "0", "0", str(scale)], cwd=work, env=env,
                    check=True, capture_output=True, text=True, timeout=130)
                elapsed = re.search(r"([0-9.]+) real", result.stderr)
                memory = re.search(r"([0-9]+)\s+maximum resident set size", result.stderr)
                assert elapsed and memory, result.stderr
                if extension == "png":
                    with Image.open(output) as image:
                        assert image.size == (2560, 1600)
                else:
                    assert "Original SVG check" in PdfReader(output).pages[0].extract_text()
                samples.append({"elapsed_seconds": float(elapsed[1]), "peak_resident_bytes": int(memory[1]),
                                "output_bytes": output.stat().st_size})
            runs.append({"format": extension, "scale": scale, "samples": samples,
                         "median_elapsed_seconds": statistics.median(s["elapsed_seconds"] for s in samples),
                         "median_peak_resident_bytes": statistics.median(s["peak_resident_bytes"] for s in samples)})
        report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                  "architecture": platform.machine(), "workload": "Original 640 by 400 SVG with styled text, gradients, clipping, a filter, a pattern, local font, bitmap, and SVG use",
                  "source_sha256": before, "source_bytes": len(original),
                  "assets_sha256": {name: hashlib.sha256((work / name).read_bytes()).hexdigest()
                      for name in ("asset % café.png", "fixture.ttf", "style.css", "extra.css", "shape.svg")},
                  "helper_sha256": hashlib.sha256((tools / "webconvert").read_bytes()).hexdigest(),
                  "launcher_sha256": hashlib.sha256((tools / "webguard").read_bytes()).hexdigest(),
                  "packaged": packaged, "runs": runs,
                  "memory_scope": "Peak renderer helper RSS from macOS time -l. Excludes separate WebKit services, the native app, and Swift adapter checks. This is not total conversion memory. Three warm serial runs after content checks."}
        (root / "research/svg-performance.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
