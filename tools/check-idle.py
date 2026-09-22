#!/usr/bin/env python3
"""Measure one short idle sample from the running local app preview."""

from datetime import datetime, timezone
import json
from pathlib import Path
import platform
import subprocess
import time

root = Path(__file__).resolve().parent.parent
executable = root / "dist/preview/Allomer.app/Contents/MacOS/AllomerApp"
processes = subprocess.check_output(["ps", "-axo", "pid=,comm="], text=True).splitlines()
pids = [line.split(maxsplit=1)[0] for line in processes
        if len(line.split(maxsplit=1)) == 2 and line.split(maxsplit=1)[1] == str(executable)]
if len(pids) != 1:
    raise SystemExit("Start one local app preview and leave it idle on the Automatic tab.")


def sample():
    cpu, rss = subprocess.check_output(["ps", "-p", pids[0], "-o", "time=,rss="], text=True).split()
    seconds = sum(float(part) * 60 ** index for index, part in enumerate(reversed(cpu.split(":"))))
    return seconds, int(rss) * 1024


before = sample()
start = time.monotonic()
time.sleep(10)
after = sample()
elapsed = time.monotonic() - start
print(json.dumps({
    "date_utc": datetime.now(timezone.utc).isoformat(),
    "macos": platform.mac_ver()[0],
    "architecture": platform.machine(),
    "elapsed_seconds": round(elapsed, 3),
    "cpu_seconds": round(after[0] - before[0], 3),
    "one_core_percent": round((after[0] - before[0]) / elapsed * 100, 3),
    "resident_bytes_before": before[1],
    "resident_bytes_after": after[1],
    "limits": "One short sample. CPU time is rounded by ps. Keep the app idle while measuring. This is not an energy measurement or a peak-memory measurement.",
}, indent=2))
