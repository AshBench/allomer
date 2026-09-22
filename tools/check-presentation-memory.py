#!/usr/bin/env python3
"""Sample conversion processes and newly started WebKit services on a quiet Mac."""
import hashlib
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent


def snapshot():
    output = subprocess.check_output(["/bin/ps", "-axo", "pid=,ppid=,rss=,comm="], text=True)
    result = {}
    for line in output.splitlines():
        fields = line.split(None, 3)
        if len(fields) == 4:
            pid, parent, rss, name = fields
            result[int(pid)] = {"parent": int(parent), "resident_bytes": int(rss) * 1024, "name": name}
    return result


def main():
    command = ROOT / "dist/preview/Allomer.app/Contents/MacOS/allomer"
    source = ROOT / ".tools/presentation-reader-check/benchmark-12-distinct.pptx"
    assert source.is_file(), "Run the presentation reader benchmark first."
    output = source.with_name("process-sample.pdf")
    output.unlink(missing_ok=True)
    baseline = snapshot()
    started = time.monotonic()
    process = subprocess.Popen([command, "convert", source, output], env={"PATH": "/usr/bin:/bin"},
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    samples = []
    while process.poll() is None:
        current = snapshot()
        children = {process.pid}
        while True:
            expanded = children | {pid for pid, info in current.items() if info["parent"] in children}
            if expanded == children:
                break
            children = expanded
        webkit = {pid for pid, info in current.items() if pid not in baseline
                  and info["name"].startswith("/System/Library/Frameworks/WebKit.framework/")}
        observed = {str(pid): current[pid] for pid in children | webkit if pid in current}
        samples.append({"elapsed_seconds": round(time.monotonic() - started, 3),
                        "resident_bytes": sum(info["resident_bytes"] for info in observed.values()),
                        "processes": observed})
        if time.monotonic() - started > 140:
            process.terminate()
            raise RuntimeError("The sample exceeded its deadline.")
        time.sleep(0.1)
    stdout, stderr = process.communicate(timeout=5)
    assert process.returncode == 0 and output.is_file(), stderr
    peak = max(samples, key=lambda sample: sample["resident_bytes"])
    report = {"source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
              "command_sha256": hashlib.sha256(command.read_bytes()).hexdigest(),
              "helper_sha256": hashlib.sha256((command.parent.parent / "Helpers/webconvert").read_bytes()).hexdigest(),
              "scope": "One diagnostic run. Sum of resident sizes for the command, its observed descendants, and WebKit processes absent from a pre-run snapshot. WebKit ownership is inferred from start time, not independently verified. Pre-existing shared services are excluded. Shared physical pages can be counted more than once. Samples can miss short peaks. Run without other WebKit activity. Sampling overhead makes elapsed times unsuitable for speed comparisons.",
              "peak_observed_resident_bytes": peak["resident_bytes"], "peak_sample": peak, "samples": samples}
    (ROOT / "research/presentation-process-memory.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"peak_observed_resident_bytes": peak["resident_bytes"], "processes": peak["processes"]}, indent=2))


if __name__ == "__main__":
    main()
