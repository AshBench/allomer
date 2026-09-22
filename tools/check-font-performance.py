#!/usr/bin/env python3
"""Measure an upstream OFL font with the bundled command and conversion checks."""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import re
import statistics
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
COMMIT = "87b37a2daaed80fcb8e8ccb0085c4d72ddade12e"
BASE = f"https://raw.githubusercontent.com/adobe-fonts/source-sans/{COMMIT}/"


def main():
    cache = ROOT / ".tools/fonts/benchmarks"
    cache.mkdir(exist_ok=True)
    for name, digest in [("OTF/SourceSans3-Regular.otf", "08df266400933d3178d081a45f94a08814c3e55b4b7dd2e0ff69cb1329f13ab6"),
                         ("LICENSE.md", "56af9b9c6715597e458284a474dc118a50a4150e9d547c70f7b4a33c3e6a9328")]:
        file = cache / Path(name).name
        if not file.exists():
            urllib.request.urlretrieve(BASE + name, file)
        assert hashlib.sha256(file.read_bytes()).hexdigest() == digest, name
    command = ROOT / "dist/preview/Allomer.app/Contents/MacOS/allomer"
    helper = command.parent.parent / "Helpers/fontconvert"
    source = cache / "SourceSans3-Regular.otf"
    original = source.read_bytes()
    samples = []
    with tempfile.TemporaryDirectory(prefix="font-performance-") as temporary:
        work = Path(temporary)
        for index in range(3):
            output = work / f"output-{index}.woff2"
            run = subprocess.run(["/usr/bin/time", "-l", command, "convert", source, output],
                cwd=work, env={"PATH": "/usr/bin:/bin"}, check=True, capture_output=True, text=True)
            elapsed = re.search(r"([0-9.]+) real", run.stderr)
            memory = re.search(r"([0-9]+)\s+maximum resident set size", run.stderr)
            assert elapsed and memory, run.stderr
            assert output.read_bytes()[:4] == b"wOF2"
            samples.append({"elapsed_seconds": float(elapsed[1]), "reported_peak_resident_bytes": int(memory[1]),
                            "output_bytes": output.stat().st_size})
            restored = work / f"restored-{index}.otf"
            subprocess.run([command, "convert", output, restored], cwd=work, env={"PATH": "/usr/bin:/bin"},
                           check=True, capture_output=True)
            assert restored.read_bytes()[:4] == b"OTTO"
            assert source.read_bytes() == original
    report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
              "architecture": platform.machine(), "workload": "Source Sans 3 Regular, OTF to WOFF2 with native validation",
              "input_url": BASE + "OTF/SourceSans3-Regular.otf", "input_license": "SIL Open Font License 1.1",
              "input_bytes": len(original), "input_sha256": hashlib.sha256(original).hexdigest(),
              "command_sha256": hashlib.sha256(command.read_bytes()).hexdigest(),
              "helper_sha256": hashlib.sha256(helper.read_bytes()).hexdigest(), "samples": samples,
              "memory_scope": "Peak reported by macOS time -l for the command; not combined app and helper memory.",
              "median_elapsed_seconds": statistics.median(s["elapsed_seconds"] for s in samples),
              "median_reported_peak_resident_bytes": statistics.median(s["reported_peak_resident_bytes"] for s in samples)}
    destination = ROOT / "research/font-performance.json"
    destination.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
