#!/usr/bin/env python3
"""Measure original vector and transparent PDF pages with a packaged command."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import re
import statistics
import subprocess
import tempfile

from reportlab.pdfgen.canvas import Canvas


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--command", type=Path, default=root / "dist/preview/Allomer.app/Contents/MacOS/allomer")
    parser.add_argument("--output", type=Path, default=root / "research/postscript-performance.json")
    args = parser.parse_args()
    command = args.command.resolve()
    assert ".app/Contents/MacOS/" in str(command), "Use a packaged release command."
    results = {}
    with tempfile.TemporaryDirectory(prefix="postscript-performance-") as temporary:
        work = Path(temporary)
        for kind, pages in (("vector", 30), ("gradient", 20), ("transparent", 1)):
            source = work / f"{kind}.pdf"
            canvas = Canvas(str(source), pagesize=(720, 720), invariant=1)
            for index in range(pages):
                if kind == "gradient":
                    canvas.linearGradient(0, 0, 720, 720, ((1, 0, 0), (0, 0, 1)))
                canvas.setFillColorRGB(0.1, 0.2, 0.7)
                canvas.setFont("Helvetica", 20)
                canvas.drawString(20, 670, f"Original {kind} page {index + 1}")
                canvas.rect(20, 20, 420, 420, fill=1, stroke=0)
                if kind == "transparent":
                    canvas.setFillAlpha(0.5)
                canvas.setFillColorRGB(0.9, 0.2, 0.1)
                canvas.circle(390, 390, 230, fill=1, stroke=0)
                canvas.showPage()
            canvas.save()
            before = digest(source)
            samples = []
            for index in range(3):
                output = work / f"{kind}-{index}.ps"
                run = subprocess.run(["/usr/bin/time", "-l", command, "convert", source, output],
                    cwd=work, env={"PATH": "/usr/bin:/bin"}, check=True, capture_output=True, text=True)
                elapsed = re.search(r"([0-9.]+) real", run.stderr)
                memory = re.search(r"([0-9]+)\s+maximum resident set size", run.stderr)
                level = re.search(rb"%%LanguageLevel: (\d)", output.read_bytes()[:4096])
                assert elapsed and memory and level, run.stderr
                assert digest(source) == before
                samples.append({"elapsed_seconds": float(elapsed[1]), "reported_peak_resident_bytes": int(memory[1]),
                                "output_bytes": output.stat().st_size, "language_level": int(level[1])})
            results[kind] = {"input_sha256": before, "input_bytes": source.stat().st_size, "pages": pages,
                "samples": samples, "median_elapsed_seconds": statistics.median(s["elapsed_seconds"] for s in samples),
                "median_reported_peak_resident_bytes": statistics.median(s["reported_peak_resident_bytes"] for s in samples)}
    helpers = command.parent.parent / "Helpers"
    report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
        "architecture": platform.machine(), "command_sha256": digest(command),
        "helpers_sha256": {name: digest(helpers / name) for name in ("gs", "postscript", "pdftops", "psguard") if (helpers / name).is_file()},
        "memory_scope": "macOS time -l peak for the command; not aggregate simultaneous app and helper memory. GUI excluded.",
        "scope": "Three runs per original fixture. Includes output reinterpretation and page checks. Default settings may differ between writers.",
        "results": results}
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({kind: {k: v for k, v in result.items() if k.startswith("median_")} for kind, result in results.items()}))


if __name__ == "__main__":
    main()
