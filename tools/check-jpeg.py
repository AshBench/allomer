#!/usr/bin/env python3
"""Check JPEG decoding with original fixtures and the bundled validators."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import random
import shutil
import statistics
import struct
import subprocess
import tempfile

from PIL import Image, ImageChops, ImageDraw, ImageStat

ROOT = Path(__file__).resolve().parent.parent


def digest(file):
    with file.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=ROOT / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=ROOT / ".tools/bin")
    parser.add_argument("--cjpeg", default=shutil.which("cjpeg"))
    parser.add_argument("--benchmark", action="store_true")
    parser.add_argument("--benchmark-only", action="store_true")
    parser.add_argument("--report", type=Path, default=ROOT / "research/jpeg-validation-performance.json")
    args = parser.parse_args()
    if not args.cjpeg:
        raise SystemExit("Development checks need libjpeg-turbo's cjpeg fixture encoder.")
    command, tools = args.command.resolve(), args.tools.resolve()
    with tempfile.TemporaryDirectory(prefix="jpeg-check-") as temporary:
        work = Path(temporary)

        def run(*command):
            return subprocess.run(list(map(str, command)), cwd=work, env={"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools)},
                                  capture_output=True, text=True)

        original = Image.new("RGB", (320, 240), (180, 40, 80))
        draw = ImageDraw.Draw(original)
        draw.rectangle((20, 20, 99, 79), fill=(30, 190, 90))
        draw.ellipse((120, 90, 240, 210), fill=(20, 90, 220))
        ppm = work / "original.ppm"
        original.save(ppm)
        variants = {"baseline": [], "progressive": ["-progressive"], "arithmetic": ["-arithmetic"],
                    "arithmetic-progressive": ["-arithmetic", "-progressive"],
                    "extended-12": ["-precision", "12"], "lossless-12": ["-lossless", "1", "-precision", "12"]}
        if not args.benchmark_only:
            for name, options in variants.items():
                source = work / f"{name} café.jpg"
                encoded = run(args.cjpeg, *options, "-outfile", source, ppm)
                assert encoded.returncode == 0, encoded.stderr
                before = digest(source)
                output = source.with_suffix(".png")
                converted = run(command, "convert", source, output)
                assert converted.returncode == 0, (name, converted.stderr)
                assert digest(source) == before
                with Image.open(output) as image:
                    assert image.size == original.size
                    if "12" not in name:
                        with Image.open(source) as reference:
                            delta = ImageChops.difference(image.convert("RGB"), reference.convert("RGB"))
                            assert max(ImageStat.Stat(delta).mean) < 2, (name, ImageStat.Stat(delta).mean)
                    else:
                        delta = ImageChops.difference(image.convert("RGB"), original)
                        if name == "lossless-12":
                            assert delta.getbbox() is None
                        else:
                            assert max(ImageStat.Stat(delta).mean) < 5, ImageStat.Stat(delta).mean
                complete = source.read_bytes()
                damaged_inputs = [("missing-eoi", complete[:-2]), ("truncated", complete[:-50])]
                if name in ("baseline", "progressive"):
                    damaged_inputs.append(("fake-eoi", complete[:-50] + b"\xff\xd9"))
                for ending, data in damaged_inputs:
                    damaged = work / f"{name}-{ending}.jpg"
                    damaged.write_bytes(data)
                    destination = damaged.with_suffix(".png")
                    failed = run(command, "convert", damaged, destination)
                    assert failed.returncode != 0 and not destination.exists(), (name, ending, failed.stderr)
                    assert damaged.read_bytes() == data
                if "12" not in name:
                    trailing = work / f"{name}-trailing.jpg"
                    trailing.write_bytes(complete + b"harmless trailing data")
                    result = run(tools / "pdfguard", trailing, work, "jpegcheck", trailing)
                    assert result.returncode == 0 and result.stdout == "valid\n", (name, result.stderr)
                    if "arithmetic" not in name:
                        result = run(command, "convert", trailing, trailing.with_suffix(".png"))
                        assert result.returncode == 0, (name, result.stderr)
            for mode in ("L", "CMYK"):
                source = work / f"{mode}.jpg"
                original.convert(mode).save(source)
                result = run(command, "convert", source, source.with_suffix(".png"))
                assert result.returncode == 0, result.stderr
            baseline = work / "baseline café.jpg"
            data = bytearray(baseline.read_bytes())
            offset = 2
            while offset < len(data):
                assert data[offset] == 255
                marker = data[offset + 1]
                length = struct.unpack_from(">H", data, offset + 2)[0]
                if marker == 0xC0:
                    struct.pack_into(">HH", data, offset + 5, 65000, 65000)
                    break
                offset += 2 + length
            else:
                raise AssertionError("The original baseline JPEG has no frame header")
            large = work / "excessive.jpg"
            large.write_bytes(data)
            rejected = run(command, "convert", large, large.with_suffix(".png"))
            assert rejected.returncode and "32 million pixels" in rejected.stderr, rejected.stderr
            rejected = run(tools / "pdfguard", large, work, "jpegcheck", large)
            assert rejected.returncode and "image limits" in rejected.stderr, rejected.stderr
            link = work / "symlink.jpg"
            link.symlink_to(baseline)
            assert run(tools / "pdfguard", link, work, "jpegcheck", link).returncode != 0
            assert not list(work.glob(".allomer-*")), "Temporary files remain"

        if args.benchmark or args.benchmark_only:
            workloads = []
            for width, height in [(1024, 1024), (6000, 4000)]:
                pixels = random.Random(611).randbytes(width * height * 3)
                bitmap = Image.frombytes("RGB", (width, height), pixels)
                del pixels
                for progressive in (False, True):
                    source = work / f"noise-{width}-{progressive}.jpg"
                    bitmap.save(source, quality=90, progressive=progressive)
                    samples = []
                    for attempt in range(3):
                        output = work / f"noise-{attempt}.png"
                        result = run("/usr/bin/time", "-l", command, "convert", source, output)
                        assert result.returncode == 0, result.stderr
                        lines = result.stderr.splitlines()
                        samples.append({"seconds": float(next(line for line in lines if " real " in line).split()[0]),
                            "resident_bytes": int(next(line for line in lines if "maximum resident set size" in line).split()[0])})
                        output.unlink()
                    workloads.append({"width": width, "height": height, "progressive": progressive,
                        "input_bytes": source.stat().st_size, "input_sha256": digest(source), "runs": samples,
                        "median_seconds": statistics.median(item["seconds"] for item in samples),
                        "median_resident_bytes": statistics.median(item["resident_bytes"] for item in samples)})
                del bitmap
            report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                "architecture": platform.machine(), "command_sha256": digest(command),
                "tool_sha256": {name: digest(tools / name) for name in ["mutool", "pdfguard", "ffmpeg"]},
                "scope": "Three complete JPEG-to-PNG CLI conversions per case. Reported RSS is not aggregate parent-plus-helper memory. GUI excluded.",
                "workloads": workloads}
            args.report.write_text(json.dumps(report, indent=2) + "\n")
        print("JPEG checks completed.")


if __name__ == "__main__":
    main()
