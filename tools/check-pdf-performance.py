#!/usr/bin/env python3
"""Measure the packaged PDF renderer on an original A4 page."""
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import platform
import re
import statistics
import subprocess
import tempfile

from PIL import Image
from reportlab.lib.utils import ImageReader
from reportlab.pdfgen.canvas import Canvas


def main():
    root = Path(__file__).resolve().parent.parent
    helpers = root / "dist/preview/Allomer.app/Contents/Helpers"
    with tempfile.TemporaryDirectory(prefix="pdf-performance-") as temporary:
        work = Path(temporary)
        source = work / "original-a4.pdf"
        image = Image.new("RGB", (1024, 1024))
        image.putdata([(x % 256, y % 256, (x + y) % 256) for y in range(1024) for x in range(1024)])
        encoded = io.BytesIO()
        image.save(encoded, format="PNG")
        canvas = Canvas(str(source), pagesize=(595.28, 841.89), invariant=1)
        canvas.setFont("Helvetica-Bold", 24)
        canvas.drawString(36, 790, "Original A4 render benchmark")
        canvas.setFont("Helvetica", 12)
        for index in range(10):
            canvas.drawString(36, 754 - index * 18, f"Editable text line {index + 1}. An original performance fixture.")
        canvas.drawImage(ImageReader(encoded), 36, 220, width=320, height=320)
        for index in range(12):
            canvas.setFillColorRGB(index / 12, 0.2, 1 - index / 12)
            canvas.rect(36 + index * 40, 100, 40, 70, fill=1, stroke=0)
        canvas.save()
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        groups = []
        for resolution in (144, 1200):
            samples = []
            arguments = ["draw", "-q", "-a", "-L", "-m", "268435456", "-F", "png", "-o", "output.png",
                         "-r", str(resolution), "-c", "rgba", "-B", "128", "-T", "1", str(source), "1"]
            for _ in range(3):
                output = work / "output.png"
                output.unlink(missing_ok=True)
                result = subprocess.run(["/usr/bin/time", "-l", helpers / "pdfguard", source, work, *arguments],
                    cwd=work, env={"PATH": "/usr/bin:/bin"}, check=True, capture_output=True, text=True, timeout=130)
                elapsed = re.search(r"([0-9.]+) real", result.stderr)
                memory = re.search(r"([0-9]+)\s+maximum resident set size", result.stderr)
                assert elapsed and memory, result.stderr
                with Image.open(output) as rendered:
                    assert rendered.size == ((1191, 1684) if resolution == 144 else (9922, 14032))
                samples.append({"elapsed_seconds": float(elapsed[1]), "peak_resident_bytes": int(memory[1]),
                                "output_bytes": output.stat().st_size})
                assert hashlib.sha256(source.read_bytes()).hexdigest() == digest
            groups.append({"resolution_dpi": resolution, "samples": samples,
                           "median_elapsed_seconds": statistics.median(s["elapsed_seconds"] for s in samples),
                           "median_peak_resident_bytes": statistics.median(s["peak_resident_bytes"] for s in samples)})
        report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                  "architecture": platform.machine(), "workload": "One A4 page with text, vector shapes, and a 1024-square RGB image",
                  "source_bytes": source.stat().st_size, "source_sha256": digest,
                  "helper_sha256": hashlib.sha256((helpers / "mutool").read_bytes()).hexdigest(),
                  "launcher_sha256": hashlib.sha256((helpers / "pdfguard").read_bytes()).hexdigest(),
                  "memory_scope": "Peak RSS from macOS time -l for the renderer process. Excludes the app, Swift adapter validation, and subsequent image encoding.",
                  "render_band_rows": 128, "render_workers": 1, "runs": groups}
    (root / "research/pdf-performance.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
