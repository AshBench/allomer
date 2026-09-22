#!/usr/bin/env python3
"""Measure a generated configuration workload with the packaged command."""

from datetime import datetime, timezone
import hashlib
import json
import platform
from pathlib import Path
import re
import statistics
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parent.parent
    command = root / "dist/preview/Allomer.app/Contents/MacOS/allomer"
    values = {"items": [{"id": i, "name": f"Café 東京 item {i}", "enabled": i % 2 == 0,
                          "code": f"{i:08}", "ratio": 1.25} for i in range(10000)]}
    samples = []
    with tempfile.TemporaryDirectory(prefix="config-performance-") as temporary:
        work = Path(temporary)
        source = work / "source.json"
        source.write_text(json.dumps(values, ensure_ascii=False, separators=(",", ":")))
        original = source.read_bytes()
        for index in range(3):
            output = work / f"output-{index}.toml"
            run = subprocess.run(["/usr/bin/time", "-l", command, "convert", source, output],
                                 cwd=work, env={"PATH": "/usr/bin:/bin"}, check=True, capture_output=True, text=True)
            elapsed = re.search(r"([0-9.]+) real", run.stderr)
            memory = re.search(r"([0-9]+)\s+maximum resident set size", run.stderr)
            assert elapsed and memory, run.stderr
            samples.append({"elapsed_seconds": float(elapsed[1]), "peak_resident_bytes": int(memory[1])})
            restored = work / f"restored-{index}.json"
            subprocess.run([command, "convert", output, restored], cwd=work, env={"PATH": "/usr/bin:/bin"},
                           check=True, capture_output=True)
            assert json.loads(restored.read_text()) == values
            assert source.read_bytes() == original
        report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                  "architecture": platform.machine(), "workload": "10000 objects, JSON to TOML",
                  "input_bytes": len(original), "input_sha256": hashlib.sha256(original).hexdigest(),
                  "command_sha256": hashlib.sha256(command.read_bytes()).hexdigest(),
                  "samples": samples,
                  "median_elapsed_seconds": statistics.median(s["elapsed_seconds"] for s in samples),
                  "median_peak_resident_bytes": statistics.median(s["peak_resident_bytes"] for s in samples)}
    destination = root / "research/config-performance.json"
    destination.write_text(json.dumps(report, indent=2) + "\n")
    print(destination)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
