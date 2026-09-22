#!/usr/bin/env python3
"""Check PNG settings with Pillow and zlib; optionally measure complete conversions."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import random
import statistics
import struct
import subprocess
import tempfile
import zlib

from PIL import Image, ImageDraw, PngImagePlugin

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def chunks(path):
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    offset, compressed, other = 8, bytearray(), []
    while offset < len(data):
        size = struct.unpack_from(">I", data, offset)[0]
        kind, body = data[offset + 4:offset + 8], data[offset + 8:offset + 8 + size]
        assert zlib.crc32(kind + body) == struct.unpack_from(">I", data, offset + 8 + size)[0]
        if kind == b"IDAT":
            compressed.extend(body)
        else:
            other.append((kind, body))
        offset += 12 + size
    assert offset == len(data) and other[-1] == (b"IEND", b"")
    return zlib.decompress(compressed), other


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=ROOT / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=ROOT / ".tools/bin")
    parser.add_argument("--benchmark", action="store_true")
    parser.add_argument("--benchmark-only", action="store_true")
    parser.add_argument("--levels", type=int, nargs="+", default=[0, 6, 9])
    parser.add_argument("--report", type=Path, default=ROOT / "research/png-compression-performance.json")
    args = parser.parse_args()
    command = args.command.resolve()
    environment = {"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(args.tools.resolve())}
    with tempfile.TemporaryDirectory(prefix="png-compression-") as temporary:
        work = Path(temporary)

        def convert(source, output, level=6, measured=False, succeeds=True):
            settings = work / "options.json"
            settings.write_text(json.dumps({"pngCompressionLevel": level}))
            before = digest(source)
            arguments = [command, "convert", source, output, "--image-options", settings]
            if measured:
                arguments = ["/usr/bin/time", "-l", *arguments]
            result = subprocess.run(arguments, cwd=work, env=environment, capture_output=True, text=True)
            assert (result.returncode == 0) == succeeds, result.stderr
            assert digest(source) == before
            assert not list(work.glob(".allomer-*")), "Private output remains"
            if not succeeds:
                assert not output.exists()
            return result

        if not args.benchmark_only:
            rgb = Image.frombytes("RGB", (192, 128), random.Random(827).randbytes(192 * 128 * 3))
            alpha = rgb.convert("RGBA")
            alpha.putalpha(Image.frombytes("L", rgb.size, random.Random(828).randbytes(192 * 128)))
            gray16 = Image.frombytes("I;16", rgb.size, random.Random(829).randbytes(192 * 128 * 2))
            pictures = [rgb, alpha, rgb.convert("L"), alpha.convert("LA"), gray16, rgb.quantize(colors=32)]
            for index, picture in enumerate(pictures):
                source = work / f"source-{index}.png"
                metadata = PngImagePlugin.PngInfo()
                metadata.add_text("Description", "Original caption")
                picture.save(source, pnginfo=metadata)
                reference = None
                for level in range(10):
                    output = work / f"result-{index}-{level}.png"
                    convert(source, output, level)
                    current = chunks(output)
                    with Image.open(output) as decoded:
                        decoded.load()
                        assert decoded.size == picture.size
                        pixels = decoded.tobytes()
                    if reference is None:
                        reference = current, pixels
                    assert (current, pixels) == reference, (picture.mode, level)
                    if picture.mode in ("RGB", "L", "I;16"):
                        assert pixels == picture.tobytes(), picture.mode
                for level in (-1, 10):
                    convert(source, work / f"invalid-{index}-{level}.png", level, succeeds=False)

            # These writers share the final PNG settings path with raster input.
            svg = work / "drawing.svg"
            svg.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="320" height="240">'
                           '<rect width="320" height="240" fill="#269b7a"/></svg>')
            pdf = work / "drawing.pdf"
            convert(svg, pdf)
            for source in (svg, pdf):
                outputs = [work / f"{source.suffix[1:]}-{level}.png" for level in (0, 9)]
                for level, output in zip((0, 9), outputs):
                    convert(source, output, level)
                assert outputs[0].stat().st_size > outputs[1].stat().st_size
                assert chunks(outputs[0]) == chunks(outputs[1])
            print("PNG levels 0–9, RGB, alpha, grayscale, palette, 16-bit pixels, metadata, SVG/PDF routes, source preservation, and cleanup passed.")

        if args.benchmark or args.benchmark_only:
            reports = []
            for label, dimensions in [("flat", (1024, 1024)), ("noise", (6000, 4000))]:
                if label == "flat":
                    picture = Image.new("RGB", dimensions, (20, 120, 200))
                    ImageDraw.Draw(picture).rectangle((64, 64, 900, 900), fill=(230, 180, 60))
                else:
                    picture = Image.frombytes("RGB", dimensions, random.Random(830).randbytes(dimensions[0] * dimensions[1] * 3))
                source = work / f"{label}.tiff"
                picture.save(source, compression="raw")
                expected = hashlib.sha256(picture.tobytes()).hexdigest()
                for level in args.levels:
                    samples = []
                    for run in range(3):
                        output = work / f"{label}-{level}-{run}.png"
                        result = convert(source, output, level, measured=True)
                        lines = result.stderr.splitlines()
                        seconds = float(next(line for line in lines if " real " in line).split()[0])
                        resident = int(next(line for line in lines if "maximum resident set size" in line).split()[0])
                        with Image.open(output) as image:
                            assert hashlib.sha256(image.tobytes()).hexdigest() == expected
                        samples.append({"seconds": seconds, "resident_bytes": resident, "output_bytes": output.stat().st_size})
                        output.unlink()
                    reports.append({"fixture": label, "dimensions": dimensions, "compression_level": level,
                                    "input_bytes": source.stat().st_size, "input_sha256": digest(source), "runs": samples,
                                    "median_seconds": statistics.median(item["seconds"] for item in samples),
                                    "median_resident_bytes": statistics.median(item["resident_bytes"] for item in samples)})
            report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                      "architecture": platform.machine(), "command_sha256": digest(command),
                      "scope": "Three complete TIFF-to-PNG CLI conversions per setting. GUI excluded. Native ImageIO and system zlib run in the command process.",
                      "workloads": reports}
            args.report.write_text(json.dumps(report, indent=2) + "\n")
            print(f"PNG benchmark written to {args.report}")


if __name__ == "__main__":
    main()
