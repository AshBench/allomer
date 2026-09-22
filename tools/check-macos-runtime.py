#!/usr/bin/env python3
"""Check native framework behavior inside the same sandbox used by Allomer."""

from pathlib import Path
import os
import platform
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
PROBE_NAME = "allomer-native-probe"


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("Run this check on an Apple Silicon Mac.")
    sdk = subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True
    ).strip()
    cache = Path.home() / "Library/Caches" / PROBE_NAME
    shutil.rmtree(cache, ignore_errors=True)
    try:
        with tempfile.TemporaryDirectory(prefix="allomer-macos-runtime-") as temporary:
            directory = Path(temporary)
            work = directory / "work"
            work.mkdir()
            converter = directory / PROBE_NAME
            guard = directory / "nativeguard"
            allowed = directory / "allowed.txt"
            blocked = directory / "blocked.txt"
            allowed.write_text("allowed\n")
            blocked.write_text("blocked\n")
            environment = dict(
                os.environ,
                PATH="/usr/bin:/bin:/usr/sbin:/sbin",
                MACOSX_DEPLOYMENT_TARGET="14.0",
                SDKROOT=sdk,
            )
            subprocess.run([
                "swiftc", "-O", "-whole-module-optimization",
                "-target", "arm64-apple-macosx14.0", "-sdk", sdk,
                ROOT / "tools/compatibility/NativeOCRProbe.swift", "-o", converter,
            ], env=environment, check=True)
            subprocess.run([
                "clang", "-O2", "-arch", "arm64", "-mmacosx-version-min=14.0",
                "-Wno-deprecated-declarations",
                f'-DCONVERTER_BINARY_NAME="{PROBE_NAME}"',
                "-DNATIVE_FRAMEWORK_CACHES", ROOT / "helpers/toolguard/main.c", "-o", guard,
            ], env=environment, check=True)
            result = subprocess.run([
                guard, allowed, work, allowed, blocked,
            ], cwd=work, env={"PATH": "/usr/bin:/bin"}, text=True,
                capture_output=True, timeout=180)
            if result.returncode:
                raise SystemExit(result.stderr.strip() or "The native runtime probe failed.")
            if "4827" not in result.stdout:
                raise SystemExit("The native runtime probe returned an unexpected result.")
            print(f"macOS {platform.mac_ver()[0]} arm64: {result.stdout.strip()}")
    finally:
        shutil.rmtree(cache, ignore_errors=True)


if __name__ == "__main__":
    main()
