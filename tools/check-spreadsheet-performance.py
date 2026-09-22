#!/usr/bin/env python3
"""Measure the bundled spreadsheet helper, including its output validation."""

import csv
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import re
import statistics
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parent.parent
    tool = root / "dist/preview/Allomer.app/Contents/Helpers/tabular"
    samples = []
    with tempfile.TemporaryDirectory(prefix="spreadsheet-performance-") as temporary:
        work = Path(temporary)
        source = work / "source.csv"
        with source.open("w", newline="") as file:
            writer = csv.writer(file)
            writer.writerow(["id", "name", "code", "enabled", "amount"])
            writer.writerows((i, f"Café 東京 item {i}", f"{i:08}", i % 2 == 0, "12.50") for i in range(100000))
        original = source.read_bytes()
        for index in range(3):
            output = work / f"output-{index}.xlsx"
            run = subprocess.run(["/usr/bin/time", "-l", tool, source, output, "csv", "xlsx", "0", "44"],
                cwd=work, env={"PATH": "/usr/bin:/bin", "TMPDIR": str(work)}, check=True, capture_output=True, text=True)
            elapsed = re.search(r"([0-9.]+) real", run.stderr)
            memory = re.search(r"([0-9]+)\s+maximum resident set size", run.stderr)
            assert elapsed and memory, run.stderr
            samples.append({"elapsed_seconds": float(elapsed[1]), "peak_resident_bytes": int(memory[1]),
                            "output_bytes": output.stat().st_size})
            restored = work / f"restored-{index}.csv"
            subprocess.run([tool, output, restored, "xlsx", "csv", "0", "44"], cwd=work,
                env={"PATH": "/usr/bin:/bin", "TMPDIR": str(work)}, check=True, capture_output=True)
            with source.open(newline="") as before, restored.open(newline="") as after:
                assert list(csv.reader(before)) == list(csv.reader(after))
            assert source.read_bytes() == original
        report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                  "architecture": platform.machine(), "workload": "100000 data rows, 5 columns, CSV to XLSX with validation",
                  "scope": "Spreadsheet helper process only; native app memory is separate",
                  "input_bytes": len(original), "input_sha256": hashlib.sha256(original).hexdigest(),
                  "helper_sha256": hashlib.sha256(tool.read_bytes()).hexdigest(), "samples": samples,
                  "median_elapsed_seconds": statistics.median(s["elapsed_seconds"] for s in samples),
                  "median_peak_resident_bytes": statistics.median(s["peak_resident_bytes"] for s in samples)}
    output = root / "research/spreadsheet-performance.json"
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
