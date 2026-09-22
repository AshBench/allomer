#!/usr/bin/env python3
"""Check WebP pixels, color, metadata, failure behavior, and conversion cost."""
import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import platform
import random
import statistics
import struct
import subprocess
import tempfile

from PIL import Image, ImageChops, ImageCms, ImageStat, PngImagePlugin

ROOT = Path(__file__).resolve().parent.parent


def digest(file):
    with file.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=ROOT / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=ROOT / ".tools/bin")
    parser.add_argument("--benchmark", action="store_true")
    args = parser.parse_args()
    command, tools = args.command.resolve(), args.tools.resolve()
    with tempfile.TemporaryDirectory(prefix="webp-check-") as temporary:
        work = Path(temporary)
        settings = work / "options.json"

        def convert(source, target, options=None, success=True, timed=False):
            settings.write_text(json.dumps(options or {}))
            before = digest(source)
            invocation = [str(command), "convert", str(source), str(target), "--image-options", str(settings)]
            if timed:
                invocation = ["/usr/bin/time", "-l", *invocation]
            result = subprocess.run(invocation, cwd=work, env={"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools)},
                                    capture_output=True, text=True)
            assert digest(source) == before, "Source changed"
            assert (result.returncode == 0) == success, (source.name, result.stderr)
            if not success:
                assert not target.exists(), "Failed conversion published output"
            assert not list(work.glob(".allomer-*")), "Private conversion files remain"
            return result

        original = Image.new("RGBA", (64, 48))
        original.putdata([(x * 4, y * 5, (x + y) * 2, (0, 128, 255)[x % 3]) for y in range(48) for x in range(64)])
        profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
        xmp = '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/" dc:description="Original XMP"/></rdf:RDF></x:xmpmeta>'
        for orientation in range(1, 9):
            exif = Image.Exif()
            exif[270], exif[274] = "Original description", orientation
            metadata = PngImagePlugin.PngInfo()
            metadata.add_itxt("XML:com.adobe.xmp", xmp)
            source = work / f"alpha-{orientation} café.png"
            original.save(source, exif=exif, icc_profile=profile, pnginfo=metadata)
            target = source.with_suffix(".webp")
            convert(source, target, {"webpMode": "lossless"})
            with Image.open(target) as image:
                assert image.n_frames == 1 and image.convert("RGBA").tobytes() == original.tobytes(), orientation
                assert image.getexif()[270] == "Original description" and image.getexif()[274] == orientation
                assert image.info["icc_profile"] == profile and image.info["xmp"] == xmp.encode()
            clean = work / f"clean-{orientation}.webp"
            convert(source, clean, {"webpMode": "lossless", "preserveMetadata": False})
            with Image.open(clean) as image:
                assert image.getexif().get(274, 1) == orientation
                assert 270 not in image.getexif() and "xmp" not in image.info
                actual = image.convert("RGBA").tobytes()
                expected = original.tobytes()
                assert actual[3::4] == expected[3::4]
                assert all(abs(actual[i + c] - expected[i + c]) <= 1 for i in range(0, len(actual), 4)
                           if expected[i + 3] == 255 for c in range(3))
            if orientation == 1:
                lossy = work / "lossy.webp"
                convert(source, lossy)
                with Image.open(lossy) as image:
                    assert image.convert("RGBA").getchannel("A").tobytes() == original.getchannel("A").tobytes()

        for mode in ("RGB", "L", "LA", "P"):
            source = work / f"mode-{mode}.png"
            bitmap = original.convert(mode)
            bitmap.save(source)
            target = source.with_suffix(".webp")
            convert(source, target, {"webpMode": "lossless", "webpEffort": 0})
            with Image.open(target) as image:
                assert image.convert("RGBA").tobytes() == bitmap.convert("RGBA").tobytes(), mode

        linear = work / "linear.png"
        gamma = PngImagePlugin.PngInfo()
        gamma.add(b"gAMA", struct.pack(">I", 100000))
        Image.new("RGB", (32, 24), (80, 120, 160)).save(linear, pnginfo=gamma)
        linear_webp = work / "linear.webp"
        convert(linear, linear_webp, {"webpMode": "lossless"})
        with Image.open(linear_webp) as image:
            assert image.getpixel((0, 0)) == (80, 120, 160), "Gamma changed stored colors despite source ICC retention"
            display = ImageCms.profileToProfile(image, ImageCms.ImageCmsProfile(io.BytesIO(image.info["icc_profile"])), ImageCms.createProfile("sRGB"))
            expected = [round((1.055 * (value / 255) ** (1 / 2.4) - 0.055) * 255) for value in (80, 120, 160)]
            assert all(abs(a - b) <= 2 for a, b in zip(display.getpixel((0, 0)), expected)), display.getpixel((0, 0))
        srgb = work / "srgb.webp"
        convert(linear, srgb, {"webpMode": "lossless", "convertToSRGB": True})
        with Image.open(srgb) as image:
            assert all(abs(a - b) <= 2 for a, b in zip(image.getpixel((0, 0)), expected)), image.getpixel((0, 0))

        for suffix in ("jpg", "tiff", "bmp"):
            source = work / f"bridge.{suffix}"
            original.convert("RGB").save(source)
            target = work / f"bridge-{suffix}.webp"
            convert(source, target, {"webpMode": "lossless"})
            with Image.open(source) as before, Image.open(target) as after:
                delta = ImageChops.difference(before.convert("RGB"), after.convert("RGB"))
                assert max(ImageStat.Stat(delta).mean) < (2 if suffix == "jpg" else 0.1), suffix

        depth = work / "depth16.png"
        values = [value * 257 for value in range(256)]
        Image.frombytes("I;16", (256, 1), struct.pack("<256H", *values)).save(depth)
        convert(depth, depth.with_suffix(".webp"), {"webpMode": "lossless"})
        with Image.open(depth.with_suffix(".webp")) as image:
            assert image.convert("L").tobytes() == bytes(range(256)), "16-bit input was not reduced to 8-bit correctly"

        p3 = ImageCms.getOpenProfile("/System/Library/ColorSync/Profiles/Display P3.icc")
        p3_source = work / "wide-color.png"
        colors = original.convert("RGB")
        colors.save(p3_source, icc_profile=p3.tobytes())
        expected = ImageCms.profileToProfile(colors, p3, ImageCms.createProfile("sRGB"))
        for force_srgb in (False, True):
            target = work / f"wide-color-{force_srgb}.webp"
            convert(p3_source, target, {"webpMode": "lossless", "preserveMetadata": False, "convertToSRGB": force_srgb})
            with Image.open(target) as image:
                if force_srgb:
                    actual = image.convert("RGB")
                else:
                    actual = ImageCms.profileToProfile(image, ImageCms.ImageCmsProfile(io.BytesIO(image.info["icc_profile"])), ImageCms.createProfile("sRGB"))
                delta = ImageChops.difference(actual, expected)
                assert max(high for low, high in delta.getextrema()) <= 2, "Wide-color appearance changed"

        renamed = work / "wrong-extension.jpg"
        renamed.write_bytes(linear.read_bytes())
        convert(renamed, work / "detected.webp", {"webpMode": "lossless"})

        tall = work / "too-wide.png"
        Image.new("RGB", (16384, 1)).save(tall)
        convert(tall, tall.with_suffix(".webp"), success=False)
        animated = work / "animation.gif"
        first, second = Image.new("RGB", (16, 12), "red"), Image.new("RGB", (16, 12), "blue")
        first.save(animated, save_all=True, append_images=[second], duration=[40, 90], loop=2)
        convert(animated, animated.with_suffix(".webp"))
        with Image.open(animated.with_suffix(".webp")) as image:
            assert image.n_frames == 2 and image.info["loop"] == 3
        damaged = work / "damaged.png"
        damaged.write_bytes(linear.read_bytes()[:-20])
        convert(damaged, damaged.with_suffix(".webp"), success=False)
        for options in ({"webpEffort": 7}, {"webpMode": "invalid"}, {"quality": -0.1}, {"quality": 1.1}):
            convert(linear, work / "invalid.webp", options, success=False)
        link = work / "link.png"
        link.symlink_to(linear)
        convert(link, link.with_suffix(".webp"), success=False)

        if args.benchmark:
            cases = []
            for width, height in ((1024, 1024), (6000, 4000)):
                pixels = random.Random(983).randbytes(width * height * 3)
                bitmap = Image.frombytes("RGB", (width, height), pixels)
                del pixels
                source = work / f"noise-{width}.png"
                bitmap.save(source)
                del bitmap
                for mode in ("lossy", "lossless"):
                    runs = []
                    for attempt in range(3):
                        target = work / f"benchmark-{attempt}.webp"
                        result = convert(source, target, {"webpMode": mode}, timed=True)
                        lines = result.stderr.splitlines()
                        runs.append({"seconds": float(next(line for line in lines if " real " in line).split()[0]),
                                     "resident_bytes": int(next(line for line in lines if "maximum resident set size" in line).split()[0])})
                        output_bytes = target.stat().st_size
                        target.unlink()
                    cases.append({"width": width, "height": height, "mode": mode, "input_sha256": digest(source),
                                  "input_bytes": source.stat().st_size, "output_bytes": output_bytes, "runs": runs,
                                  "median_seconds": statistics.median(run["seconds"] for run in runs),
                                  "median_resident_bytes": statistics.median(run["resident_bytes"] for run in runs)})
            report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                      "command_sha256": digest(command), "helper_sha256": {name: digest(tools / name) for name in ("cwebp", "webpguard")},
                      "quality": 0.85, "effort": 4, "lossy_low_memory": True, "cases": cases,
                      "scope": "Three complete PNG-to-WebP CLI conversions per case. RSS is not aggregate command-plus-helper memory. GUI excluded."}
            (ROOT / "research/webp-performance.json").write_text(json.dumps(report, indent=2) + "\n")
        print("Independent WebP checks completed.")


if __name__ == "__main__":
    main()
