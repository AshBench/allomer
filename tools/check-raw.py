#!/usr/bin/env python3
"""Check pinned CC0 camera files with the packaged converter and an independent image reader."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import tempfile
import urllib.request

from PIL import Image, ImageChops, ImageStat, __version__ as pillow_version

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=ROOT / "dist/preview/Allomer.app/Contents/MacOS/allomer")
    parser.add_argument("--tools", type=Path, default=ROOT / "dist/preview/Allomer.app/Contents/Helpers")
    parser.add_argument("--fixtures", type=Path, default=ROOT / ".tools/raw-check")
    parser.add_argument("--download", action="store_true", help="Download missing, hash-pinned development fixtures.")
    parser.add_argument("--sample", action="append", help="Check only this manifest filename; can be repeated.")
    parser.add_argument("--formats", nargs="+", choices=["png", "jpg", "tiff"], default=["png", "jpg", "tiff"])
    parser.add_argument("--runs", type=int, choices=range(1, 6), default=1)
    parser.add_argument("--report", type=Path, default=ROOT / "research/raw-check.json")
    args = parser.parse_args()
    samples = json.loads((ROOT / "tools/raw-samples.json").read_text())
    if args.sample:
        assert set(args.sample) <= {sample["file"] for sample in samples}, "Unknown sample filename"
        samples = [sample for sample in samples if sample["file"] in args.sample]
    args.fixtures.mkdir(parents=True, exist_ok=True)
    for sample in samples:
        path = args.fixtures / sample["file"]
        if args.download and (not path.exists() or digest(path) != sample["sha256"]):
            with urllib.request.urlopen(sample["url"], timeout=120) as response, path.open("wb") as output:
                total = 0
                while chunk := response.read(1024 * 1024):
                    total += len(chunk)
                    assert total <= 512 * 1024 * 1024, "Fixture download exceeds 512 MiB"
                    output.write(chunk)
        assert path.is_file() and not path.is_symlink(), f"Missing fixture: {path}. Use --download."
        assert digest(path) == sample["sha256"], f"Fixture checksum mismatch: {path}"

    command, tools = args.command.resolve(), args.tools.resolve()
    environment = {"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools)}
    records = []
    with tempfile.TemporaryDirectory(prefix="RAW café 100%, ") as temporary:
        work = Path(temporary)
        for sample in samples:
            source = (args.fixtures / sample["file"]).resolve()
            for extension in args.formats:
                runs = []
                for run in range(args.runs):
                    output = work / f"{source.stem}-{run}.{extension}"
                    result = subprocess.run(["/usr/bin/time", "-l", command, "convert", source, output],
                        env=environment, capture_output=True, text=True, timeout=120)
                    assert result.returncode == 0, (sample["file"], extension, result.stderr)
                    with Image.open(output) as image:
                        image.load()
                        assert image.size == tuple(sample["pixels"]), (sample["file"], image.size)
                        assert image.format == {"png": "PNG", "jpg": "JPEG", "tiff": "TIFF"}[extension]
                        assert image.info.get("icc_profile"), "Missing color profile"
                        assert any(low != high for low, high in image.getextrema()), "Image is flat"
                        if extension == "tiff": assert set(image.tag_v2[258]) == {16}
                        if extension == "tiff" and run == 0:
                            expected = image.convert("RGB").resize((64, 64))
                    if extension == "tiff" and run == 0:
                        roundtrip = work / "camera-tiff.jpg"
                        checked = subprocess.run([command, "convert", output, roundtrip], env=environment,
                            capture_output=True, timeout=120)
                        assert checked.returncode == 0, (sample["file"], "TIFF roundtrip", checked.stderr)
                        with Image.open(roundtrip) as image:
                            assert image.size == tuple(sample["pixels"])
                            assert max(ImageStat.Stat(ImageChops.difference(expected,
                                image.convert("RGB").resize((64, 64)))).rms) < 4
                        roundtrip.unlink()
                    if extension == "png":
                        with output.open("rb") as file: assert file.read(25)[24] == 16
                    assert digest(source) == sample["sha256"], "Source changed"
                    assert not list(work.glob(".allomer-*")), "Private conversion folder remained"
                    runs.append({"seconds": float(re.search(r"([\d.]+)\s+real", result.stderr)[1]),
                        "resident_bytes": int(re.search(r"(\d+)\s+maximum resident set size", result.stderr)[1]),
                        "output_bytes": output.stat().st_size})
                    output.unlink()
                records.append({"camera": sample["camera"], "file": sample["file"], "input_sha256": sample["sha256"],
                    "pixels": sample["pixels"], "output": extension, "runs": runs,
                    "median_seconds": statistics.median(run["seconds"] for run in runs),
                    "median_resident_bytes": statistics.median(run["resident_bytes"] for run in runs)})
                print(sample["file"], extension, "passed", flush=True)

        for sample in samples:
            source = (args.fixtures / sample["file"]).resolve()
            for suffix in ("jpg", "png", "tiff"):
                renamed = work / (source.name + "." + suffix)
                shutil.copyfile(source, renamed)
                output = work / "renamed-result.jpg"
                result = subprocess.run([command, "convert", renamed, output], env=environment, capture_output=True, timeout=120)
                assert result.returncode == 0, (sample["file"], suffix, result.stderr)
                with Image.open(output) as image: assert image.size == tuple(sample["pixels"]), (sample["file"], suffix, image.size)
                assert digest(renamed) == sample["sha256"]
                renamed.unlink(); output.unlink()
        source = (args.fixtures / samples[0]["file"]).resolve()
        output = work / "occupied.jpg"
        output.write_bytes(b"Existing destination")
        result = subprocess.run([command, "convert", source, output], env=environment, capture_output=True, timeout=120)
        assert result.returncode != 0 and output.read_bytes() == b"Existing destination"
        linked = work / "linked.raw"; linked.symlink_to(source)
        damaged = work / source.name
        with source.open("rb") as file: damaged.write_bytes(file.read(32))
        for invalid in (linked, damaged):
            target = work / (invalid.name + ".png")
            result = subprocess.run([command, "convert", invalid, target], env=environment, capture_output=True, timeout=120)
            assert result.returncode != 0 and not target.exists(), result.stderr
        assert not list(work.glob(".allomer-*"))

    args.report.write_text(json.dumps({"recorded_at_utc": datetime.now(timezone.utc).isoformat(),
        "macos": platform.mac_ver()[0], "chip": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
        "command_sha256": digest(command), "pillow": pillow_version, "cases": records,
        "scope": "Complete command conversions of pinned CC0 camera samples. Includes native RAW decoding, output encoding, validation, and publication. PNG also includes recompression. Fixture integrity reads warm cache. Python image checks and GUI are excluded. RSS is per-process high-water memory, not aggregate simultaneous memory. One run is a check, not a stable performance estimate. Camera support depends on macOS."}, indent=2) + "\n")
    print("RAW pixels, bit depth, profiles, source preservation, changed extensions, collisions, invalid input, and cleanup passed.")


if __name__ == "__main__":
    main()
