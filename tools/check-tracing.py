#!/usr/bin/env python3
"""Check bitmap tracing with original fixtures and the native SVG renderer."""
import argparse
from datetime import datetime, timezone
import gzip
import hashlib
import json
from pathlib import Path
import platform
import random
import re
import statistics
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from PIL import Image, ImageChops, ImageDraw, ImageStat

ROOT = Path(__file__).resolve().parent.parent
SVG = "{http://www.w3.org/2000/svg}"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=ROOT / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=ROOT / ".tools/bin")
    parser.add_argument("--benchmark-only", action="store_true")
    parser.add_argument("--report", type=Path, default=ROOT / "research/tracing-performance.json")
    args = parser.parse_args()
    command, tools = args.command.resolve(), args.tools.resolve()
    with tempfile.TemporaryDirectory(prefix="tracing café 100%, ") as temporary:
        work = Path(temporary)
        sequence = 0

        def convert(source, extension="svg", tracing=None, success=True, target=None, timing=None):
            nonlocal sequence
            sequence += 1
            target = target or work / f"result-{sequence}.{extension}"
            options = work / "options.json"
            options.write_text(json.dumps({"tracing": tracing or {}}))
            original = digest(source)
            existing = digest(target) if target.exists() else None
            invocation = [command, "convert", source, target, "--image-options", options]
            if timing is not None: invocation = ["/usr/bin/time", "-l", *invocation]
            result = subprocess.run(invocation,
                env={"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools)},
                capture_output=True, text=True, timeout=135)
            assert (result.returncode == 0) == success, (source.name, tracing, result.stderr)
            assert digest(source) == original, "The source changed"
            assert not list(work.glob(".allomer-*")), "Private conversion files remain"
            if not success:
                assert digest(target) == existing if existing else not target.exists(), "Failed output published"
            if timing is not None:
                timing.update(seconds=float(re.search(r"([\d.]+)\s+real", result.stderr)[1]),
                    resident_bytes=int(re.search(r"(\d+)\s+maximum resident set size", result.stderr)[1]),
                    output_bytes=target.stat().st_size)
            return target

        def read_svg(path, size):
            data = gzip.decompress(path.read_bytes()) if path.suffix == ".svgz" else path.read_bytes()
            root = ET.fromstring(data)
            assert root.tag == SVG + "svg"
            assert (int(root.attrib["width"]), int(root.attrib["height"])) == size
            assert root.attrib["viewBox"] == f"0 0 {size[0]} {size[1]}"
            nodes = list(root.iter())
            assert len(nodes) <= 100_000 and len(data) <= 64 * 1024 * 1024
            assert not any(node.tag in (SVG + "image", SVG + "script", SVG + "foreignObject") for node in nodes)
            assert b"NaN" not in data and b"inf" not in data
            return data

        def render(path):
            return Image.open(convert(path, "png")).convert("RGBA")

        if args.benchmark_only:
            cases = []
            for name, width, height, preset in (("artwork", 512, 512, "poster"), ("noise", 1000, 1000, "photo"),
                                               ("flat", 6000, 4000, "photo"), ("opacity", 1000, 1000, "poster")):
                original = Image.new("RGBA", (width, height), (30, 100, 200, 255))
                if name == "noise":
                    original = Image.frombytes("RGB", (width, height), random.Random(147).randbytes(width * height * 3)).convert("RGBA")
                elif name == "artwork":
                    drawing = ImageDraw.Draw(original)
                    drawing.rectangle((64, 64, 447, 447), fill=(240, 180, 30, 255))
                    drawing.ellipse((160, 160, 351, 351), fill=(210, 40, 100, 255))
                elif name == "opacity":
                    row = bytes(value for x in range(width) for value in (20, 150, 80, x * 255 // (width - 1)))
                    original = Image.frombytes("RGBA", (width, height), row * height)
                source = work / f"{name}.png"
                original.save(source, compress_level=1)
                runs = []
                for _ in range(3):
                    timing = {}
                    output = convert(source, tracing={"preset": preset}, timing=timing)
                    read_svg(output, original.size)
                    if name == "flat":
                        assert {node.attrib["fill"] for node in ET.fromstring(output.read_bytes()).iter(SVG + "path")} == {"#1E64C8"}
                    runs.append(timing)
                decoded = render(output)
                assert decoded.size == original.size
                white = Image.new("RGBA", original.size, "white")
                error = ImageChops.difference(Image.alpha_composite(white, original).convert("RGB"),
                    Image.alpha_composite(white, decoded).convert("RGB"))
                alpha = ImageChops.difference(original.getchannel("A"), decoded.getchannel("A"))
                cases.append({"case": name, "width": width, "height": height, "preset": preset,
                    "input_bytes": source.stat().st_size, "input_sha256": digest(source), "runs": runs,
                    "median_seconds": statistics.median(run["seconds"] for run in runs),
                    "median_resident_bytes": statistics.median(run["resident_bytes"] for run in runs),
                    "rms_rgb_error_on_white": ImageStat.Stat(error).rms, "maximum_alpha_error": alpha.getextrema()[1]})
                print(name, cases[-1]["median_seconds"], cases[-1]["median_resident_bytes"], flush=True)
            report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                "chip": subprocess.check_output(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
                "command_sha256": digest(command), "helper_sha256": digest(tools / "vectortrace"), "cases": cases,
                "scope": "Three complete command conversions per original workload. Times include source preparation and SVG validation. Quality rendering is untimed. RSS can include a child helper's peak; it is not aggregate simultaneous process memory. GUI excluded."}
            args.report.write_text(json.dumps(report, indent=2) + "\n")
            return

        artwork = Image.new("RGBA", (128, 96), (220, 40, 20, 255))
        drawing = ImageDraw.Draw(artwork)
        drawing.rectangle((32, 24, 95, 71), fill=(20, 210, 80, 255))
        drawing.rectangle((4, 4, 7, 7), fill=(20, 40, 230, 255))
        source = work / "artwork.png"
        artwork.save(source)
        preset_files = {}
        for preset in ("photo", "poster", "line_art"):
            output = convert(source, tracing={"preset": preset})
            read_svg(output, artwork.size)
            preset_files[preset] = digest(output)
            result = render(output)
            assert result.size == artwork.size
            if preset == "line_art":
                assert result.getpixel((64, 48))[3] == 0, "Bright green should be omitted from black line art"
                assert result.getpixel((20, 48))[:3] == (0, 0, 0)
        assert len(set(preset_files.values())) == 3, "The presets did not change the drawing"

        exact = {"advanced": True, "pathMode": "pixel", "filterSpeckle": 0, "colorPrecision": 8, "layerDifference": 1}
        large = work / "large-flat.png"
        Image.new("RGB", (6000, 4000), (30, 100, 200)).save(large, compress_level=1)
        large_svg = convert(large, tracing=exact)
        paths = list(ET.fromstring(read_svg(large_svg, (6000, 4000))).iter(SVG + "path"))
        assert len(paths) == 1 and paths[0].attrib["fill"] == "#1E64C8", "Large-region color overflow"
        for color in ("color", "binary"):
            for hierarchy in ("stacked", "cutout"):
                for mode in ("pixel", "polygon", "spline"):
                    output = convert(source, tracing={**exact, "colorMode": color, "hierarchy": hierarchy, "pathMode": mode})
                    data = read_svg(output, artwork.size)
                    assert b"<path " in data
                    if mode != "spline":
                        assert all("C" not in node.attrib.get("d", "") for node in ET.fromstring(data).iter(SVG + "path"))
                    render(output)
        traced = convert(source, tracing=exact)
        assert render(traced).getpixel((64, 48))[:3] == (20, 210, 80)
        compressed = convert(source, "svgz", exact)
        assert read_svg(compressed, artwork.size) == traced.read_bytes()
        convert(source, success=False, target=traced)

        for precision in range(1, 13):
            output = convert(source, tracing={**exact, "colorPrecision": precision})
            if precision >= 8:
                assert digest(output) == digest(traced), "Precision above 8 changed eight-bit colors"
        tiny = work / "tiny.png"
        Image.new("RGBA", (1, 1), (20, 40, 60, 255)).save(tiny)
        ranges = {"filterSpeckle": (0, 256), "colorPrecision": (1, 12), "layerDifference": (1, 128),
                  "cornerThreshold": (0, 180), "lengthThreshold": (0, 100), "spliceThreshold": (0, 180), "maxIterations": (1, 100)}
        for key, (low, high) in ranges.items():
            for value in (low, high):
                read_svg(convert(tiny, tracing={**exact, "pathMode": "spline", key: value}), (1, 1))
            for value in (low - 1, high + 1):
                convert(source, tracing={**exact, key: value}, success=False)
        for key in ("preset", "colorMode", "hierarchy", "pathMode"):
            convert(source, tracing={key: "invalid"}, success=False)

        for name in ("partial", "hole", "transparent", "ramp"):
            original = Image.new("RGBA", (96, 64), (220, 40, 20, 255))
            draw = ImageDraw.Draw(original)
            if name == "partial": draw.rectangle((28, 20, 67, 43), fill=(20, 150, 80, 128))
            elif name == "hole": draw.rectangle((25, 6, 30, 11), fill=(10, 200, 130, 0))
            elif name == "transparent": original = Image.new("RGBA", (96, 64), (0, 0, 0, 0))
            else:
                original = Image.new("RGBA", (256, 64))
                original.putdata([(20, 150, 80, x) for y in range(64) for x in range(256)])
            image = work / f"{name}.png"
            original.save(image)
            output = convert(image, tracing=exact)
            read_svg(output, original.size)
            result = render(output)
            if name == "partial": assert result.getpixel((40, 30))[3] == 128
            elif name == "hole": assert result.getpixel((27, 8))[3] == 0
            elif name == "transparent": assert result.getchannel("A").getextrema() == (0, 0)
            else:
                assert result.getchannel("A").tobytes() == original.getchannel("A").tobytes()
                assert output.stat().st_size < 100_000

        for orientation in range(1, 9):
            image = work / f"orientation-{orientation}.tiff"
            artwork.save(image, tiffinfo={274: orientation})
            transforms = {2: Image.Transpose.FLIP_LEFT_RIGHT, 3: Image.Transpose.ROTATE_180,
                4: Image.Transpose.FLIP_TOP_BOTTOM, 5: Image.Transpose.TRANSPOSE,
                6: Image.Transpose.ROTATE_270, 7: Image.Transpose.TRANSVERSE, 8: Image.Transpose.ROTATE_90}
            expected = artwork.transpose(transforms[orientation]) if orientation in transforms else artwork
            output = convert(image, tracing=exact)
            read_svg(output, expected.size)
            actual = render(output)
            assert ImageChops.difference(actual.convert("RGB"), expected.convert("RGB")).getbbox() is None, ("orientation", orientation)
            assert actual.getchannel("A").tobytes() == expected.getchannel("A").tobytes(), ("orientation alpha", orientation)

        for extension in ("jpg", "bmp", "tiff", "gif", "webp", "heic", "avif", "jxl"):
            image = convert(source, extension)
            output = convert(image, tracing={"preset": "poster"})
            read_svg(output, artwork.size)
            render(output)
        for extension in ("gif", "png", "webp"):
            animated = work / f"animated.{extension}"
            artwork.save(animated, save_all=True, append_images=[artwork.transpose(Image.Transpose.FLIP_LEFT_RIGHT)], duration=100, loop=0)
            convert(animated, success=False)
        pages = work / "pages.tiff"
        artwork.save(pages, save_all=True, append_images=[artwork])
        convert(pages, success=False)
        checker = Image.new("RGB", (512, 512))
        checker.putdata([((255, 255, 255) if (x+y) % 2 else (0, 0, 0)) for y in range(512) for x in range(512)])
        complex_image = work / "too-many-paths.png"
        checker.save(complex_image)
        convert(complex_image, tracing=exact, success=False)
        print("Tracing presets, controls, opacity, orientation, input formats, limits, and source checks passed.")


if __name__ == "__main__":
    main()
