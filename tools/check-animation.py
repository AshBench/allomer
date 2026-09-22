#!/usr/bin/env python3
"""Check GIF or WebP animation output against original GIF, WebP, and PNG fixtures."""
import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import platform
import statistics
import struct
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from PIL import Image, ImageChops, ImageCms, ImageDraw, ImageOps, ImageStat, PngImagePlugin

ROOT = Path(__file__).resolve().parent.parent


def digest(file):
    with file.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=ROOT / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=ROOT / ".tools/bin")
    parser.add_argument("--benchmark", action="store_true")
    parser.add_argument("--report", type=Path)
    parser.add_argument("--format", choices=("gif", "webp"), default="gif")
    parser.add_argument("--benchmark-webp-mode", choices=("lossless", "lossy"), default="lossless")
    args = parser.parse_args()
    command = args.command.resolve()
    with tempfile.TemporaryDirectory(prefix="Animation café 100%, ") as temporary:
        work = Path(temporary)

        def convert(source, target, options=None, success=True, timed=False):
            settings = work / "options.json"
            settings.write_text(json.dumps({"webpMode": "lossless", **(options or {})}))
            before = digest(source)
            invocation = [command, "convert", source, target, "--image-options", settings]
            if timed:
                invocation = ["/usr/bin/time", "-l", *invocation]
            result = subprocess.run(invocation, cwd=work,
                                    env={"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(args.tools.resolve())},
                                    capture_output=True, text=True)
            assert digest(source) == before, "Source changed"
            assert (result.returncode == 0) == success, (source.name, result.stderr)
            if not success:
                assert not target.exists(), "Failed conversion published output"
            assert not list(work.glob(".allomer-*")), "Private files remain"
            return result

        frames = []
        for index in range(3):
            frame = Image.new("RGBA", (80, 60), (0, 0, 0, 0))
            draw = ImageDraw.Draw(frame)
            draw.rectangle((5 + index * 15, 10, 24 + index * 15, 40), fill=(240, 40, 80, 255))
            draw.rectangle((65, 2 + index * 10, 78, 9 + index * 10), fill=(20, 180, 220, 255))
            frames.append(frame)

        def check(source, target, tolerance=0, composite=False, lossy=False):
            header = target.read_bytes()[:12]
            assert header[:6] == b"GIF89a" if args.format == "gif" else header[:4] == b"RIFF" and header[8:] == b"WEBP"
            maximum_error = 0
            with Image.open(source) as before, Image.open(target) as after:
                first = 1 if before.info.get("default_image") else 0
                loops = before.info.get("loop", 1)
                plays = (loops + 1 if loops else 0) if before.format == "GIF" and "loop" in before.info else loops
                expected_loop = (None if plays == 1 else (plays - 1 if plays else 0)) if args.format == "gif" else plays
                assert after.info.get("loop") == expected_loop, (source.name, plays, after.info)
                assert after.n_frames == before.n_frames - first, source.name
                for index in range(after.n_frames):
                    before.seek(index + first)
                    expected = ImageOps.exif_transpose(before.copy()).convert("RGBA")
                    before.load()
                    duration = before.info.get("duration", 100)
                    after.seek(index)
                    after.load()
                    unit = 10 if args.format == "gif" else 1
                    expected_delay = max(unit, int(duration / unit + 0.5) * unit) if duration else 0
                    if "duration" in before.info:
                        assert after.info.get("duration", 100) == expected_delay, (source.name, index, duration, after.info)
                    actual = ImageOps.exif_transpose(after.copy()).convert("RGBA")
                    assert actual.size == expected.size, (source.name, index, actual.size, expected.size)
                    assert actual.getchannel("A").tobytes() == expected.getchannel("A").tobytes(), (source.name, index, "alpha")
                    # Transparent RGB has no visible effect in a palette animation.
                    pairs = [(actual, expected)]
                    if composite:
                        pairs = [(Image.alpha_composite(Image.new("RGBA", actual.size, color), actual),
                                  Image.alpha_composite(Image.new("RGBA", expected.size, color), expected))
                                 for color in ("black", "white")]
                    for actual_pixels, expected_pixels in pairs:
                        delta = ImageChops.difference(actual_pixels, expected_pixels)
                        mask = expected_pixels.getchannel("A").point(lambda value: 255 if value else 0)
                        for channel in delta.split()[:3]:
                            error = ImageChops.multiply(channel, mask).getextrema()[1]
                            maximum_error = max(maximum_error, error)
                            if lossy:
                                assert ImageStat.Stat(channel, mask).rms[0] <= 24, (source.name, index, "Excessive lossy error")
                            else:
                                assert error <= tolerance, (source.name, index, delta.getextrema())
            return maximum_error

        for suffix in ("gif", "webp", "png"):
            for loop in ((0, 1, 2, 65535, 65536) if suffix == "png" else (0, 1, 2, 65535)):
                source = work / f"loop-{loop}.{suffix}"
                frames[0].save(source, save_all=True, append_images=frames[1:], duration=[40, 90, 170], loop=loop, lossless=True)
                for strip in (False, True):
                    target = work / f"{suffix}-{loop}-{strip}.{args.format}"
                    supported = args.format == "gif" or (loop + (suffix == "gif" and loop > 0)) <= 65535
                    convert(source, target, {"preserveMetadata": not strip}, success=supported)
                    if not supported:
                        continue
                    check(source, target)

        for suffix in ("gif", "png"):
            source = work / f"single-frame.{suffix}"
            if suffix == "png":
                metadata = PngImagePlugin.PngInfo()
                metadata.add(b"acTL", struct.pack(">II", 1, 2))
                metadata.add(b"fcTL", struct.pack(">IIIIIHHBB", 0, 80, 60, 0, 0, 17, 100, 0, 0))
                frames[0].save(source, pnginfo=metadata)
            else:
                frames[0].save(source, duration=170, loop=2)
            target = work / f"single-frame-{suffix}.{args.format}"
            convert(source, target, {"preserveMetadata": False})
            check(source, target)
        source = work / "still.png"
        frames[0].save(source)
        convert(source, source.with_suffix("." + args.format))
        with Image.open(source.with_suffix("." + args.format)) as image:
            assert image.n_frames == 1

        for disposal in (0, 1, 2, 3):
            source = work / f"disposal-{disposal}.gif"
            frames[0].save(source, save_all=True, append_images=frames[1:], duration=[0, 10, 650], disposal=disposal)
            target = work / f"disposed-{disposal}.{args.format}"
            convert(source, target)
            check(source, target)

        for poster in (False, True):
            source = work / f"poster-{poster}.png"
            frames[0].save(source, save_all=True, append_images=frames[1:], duration=[40, 90, 170],
                           default_image=poster, disposal=[0, 1, 2], blend=[0, 1, 0], loop=2)
            target = source.with_suffix("." + args.format)
            convert(source, target)
            check(source, target)

        for mode in ("L", "LA", "P"):
            source = work / f"color-mode-{mode}.png"
            converted = [frame.convert(mode) for frame in frames]
            converted[0].save(source, save_all=True, append_images=converted[1:], duration=[40, 90, 170], loop=2)
            target = source.with_suffix("." + args.format)
            convert(source, target)
            check(source, target)

        for orientation in range(1, 9):
            exif = Image.Exif()
            exif[274] = orientation
            for suffix, animated in (("webp", True), ("png", True), ("png", False)):
                source = work / f"orientation-{orientation}-{animated}.{suffix}"
                frames[0].save(source, save_all=True, append_images=frames[1:] if animated else [],
                               duration=[40, 90, 170], loop=2, lossless=True, exif=exif)
                for strip in (False, True):
                    target = work / f"orientation-{orientation}-{suffix}-{animated}-{strip}.{args.format}"
                    convert(source, target, {"preserveMetadata": not strip})
                    check(source, target)

        source = work / "millisecond-delays.webp"
        frames[0].save(source, save_all=True, append_images=frames[1:], duration=[1, 45, 95], loop=2, lossless=True)
        target = work / f"millisecond-delays-output.{args.format}"
        convert(source, target)
        check(source, target)

        source = work / "too-many-plays.png"
        frames[0].save(source, save_all=True, append_images=frames[1:], duration=100, loop=65537)
        convert(source, source.with_suffix("." + args.format), success=False)
        source = work / "too-many-frames.png"
        tiny = [Image.new("RGB", (1, 1), color) for color in ("red", "blue")]
        tiny[0].save(source, save_all=True, append_images=(tiny[1:] + tiny * 5000)[:10000], duration=100, loop=0)
        with Image.open(source) as image:
            assert image.n_frames == 10001
        convert(source, source.with_suffix("." + args.format), success=False)

        p3 = ImageCms.getOpenProfile("/System/Library/ColorSync/Profiles/Display P3.icc")
        opaque = [frame.convert("RGB") for frame in frames]
        for suffix in ("webp", "png"):
            source = work / f"wide-color.{suffix}"
            opaque[0].save(source, save_all=True, append_images=opaque[1:], duration=[40, 90, 170], loop=2,
                           lossless=True, icc_profile=p3.tobytes())
            target = work / f"wide-color-{suffix}.{args.format}"
            convert(source, target, {"convertToSRGB": True})
            with Image.open(source) as before, Image.open(target) as after:
                for index in range(before.n_frames):
                    before.seek(index); after.seek(index)
                    expected = ImageCms.profileToProfile(before.convert("RGB"), p3, ImageCms.createProfile("sRGB"))
                    delta = ImageChops.difference(expected, after.convert("RGB"))
                    assert max(high for low, high in delta.getextrema()) <= 2, (source.name, index, delta.getextrema())

        if args.format == "webp":
            partial = []
            for index in range(3):
                frame = Image.new("RGBA", (80, 60), (0, 0, 0, 0))
                draw = ImageDraw.Draw(frame)
                for band, alpha in enumerate((0, 1, 64, 128, 254, 255)):
                    draw.rectangle((band * 12, 5, band * 12 + 11, 55), fill=(40 + index * 30, 90 + band * 20, 200, alpha))
                partial.append(frame)
            for suffix in ("webp", "png"):
                for orientation in (1, 6):
                    source = work / f"partial-{orientation}.{suffix}"
                    exif = Image.Exif()
                    exif[274] = orientation
                    partial[0].save(source, save_all=True, append_images=partial[1:], duration=[40, 90, 170], loop=2,
                                    lossless=True, exif=exif)
                    target = work / f"partial-{suffix}-{orientation}.webp"
                    convert(source, target, {"preserveMetadata": False})
                    check(source, target, tolerance=1, composite=True)
            xmp = ('<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
                   '<rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:description><rdf:Alt>'
                   '<rdf:li xml:lang="x-default">Animation café ✓</rdf:li></rdf:Alt></dc:description>'
                   '</rdf:Description></rdf:RDF></x:xmpmeta>')
            exif = Image.Exif()
            exif[274] = 6
            exif[315] = "Original animation artist"
            exif[34665] = {40962: 80, 40963: 60}
            png_info = PngImagePlugin.PngInfo()
            png_info.add_itxt("XML:com.adobe.xmp", xmp)
            for suffix in ("webp", "png"):
                source = work / f"metadata.{suffix}"
                opaque[0].save(source, save_all=True, append_images=opaque[1:], duration=[40, 90, 170], loop=2,
                               lossless=True, icc_profile=p3.tobytes(), exif=exif, xmp=xmp.encode(), pnginfo=png_info)
                for strip in (False, True):
                    for srgb in (False, True):
                        target = work / f"metadata-{suffix}-{strip}-{srgb}.webp"
                        convert(source, target, {"preserveMetadata": not strip, "convertToSRGB": srgb})
                        with Image.open(source) as before, Image.open(target) as after:
                            assert bool(after.info.get("exif")) == (not strip)
                            assert bool(after.info.get("xmp")) == (not strip)
                            if not strip:
                                saved = after.getexif()
                                assert saved[274] == 1 and saved[315] == "Original animation artist"
                                sizes = saved.get_ifd(34665)
                                assert sizes[40962] == 60 and sizes[40963] == 80, sizes
                                assert "Animation café ✓" in " ".join(ET.fromstring(after.info["xmp"]).itertext())
                            profile_data = after.info.get("icc_profile")
                            assert srgb or profile_data, (source.name, strip, srgb, "Missing color profile")
                            after_profile = ImageCms.getOpenProfile(io.BytesIO(profile_data)) if profile_data else ImageCms.createProfile("sRGB")
                            for index in range(before.n_frames):
                                before.seek(index); after.seek(index)
                                expected = ImageCms.profileToProfile(ImageOps.exif_transpose(before.copy()).convert("RGB"),
                                                                     p3, ImageCms.createProfile("sRGB"))
                                actual = ImageCms.profileToProfile(after.convert("RGB"), after_profile, ImageCms.createProfile("sRGB"))
                                delta = ImageChops.difference(expected, actual)
                                assert max(high for low, high in delta.getextrema()) <= 2, (source.name, strip, srgb, index, delta.getextrema())

        valid = (work / "disposal-2.gif").read_bytes()
        # Increase a frame's declared height without adding compressed rows.
        # The container still has complete blocks and a trailer.
        partial_rows = bytearray(valid)
        cursor = 13 + (3 << ((valid[10] & 7) + 1) if valid[10] & 128 else 0)
        descriptors = []
        while valid[cursor] != 0x3b:
            if valid[cursor] == 0x21:
                cursor += 2
            else:
                assert valid[cursor] == 0x2c
                descriptors.append(cursor)
                flags = valid[cursor + 9]
                cursor += 10 + (3 << ((flags & 7) + 1) if flags & 128 else 0) + 1
            while valid[cursor]:
                cursor += 1 + valid[cursor]
            cursor += 1
        descriptor = descriptors[-1]
        height = int.from_bytes(valid[descriptor + 7:descriptor + 9], "little")
        top = int.from_bytes(valid[descriptor + 3:descriptor + 5], "little")
        canvas_height = max(top + height + 1, int.from_bytes(valid[8:10], "little"))
        partial_rows[8:10] = canvas_height.to_bytes(2, "little")
        partial_rows[descriptor + 7:descriptor + 9] = (height + 1).to_bytes(2, "little")
        damaged = work / "incomplete-rows.gif"
        damaged.write_bytes(partial_rows)
        convert(damaged, work / f"incomplete-rows-output.{args.format}", success=False)
        for cut, trailer in ((1, b""), (20, b""), (60, b""), (20, b"\x00;")):
            damaged = work / f"damaged-{cut}-{bool(trailer)}.gif"
            damaged.write_bytes(valid[:-cut] + trailer)
            convert(damaged, work / f"damaged-output.{args.format}", success=False)
        source = work / "wrong.jpg"
        source.write_bytes((work / "loop-2.webp").read_bytes())
        convert(source, work / f"detected.{args.format}")
        check(source, work / f"detected.{args.format}")
        convert(source, work / "flattened.png", success=False)
        if args.benchmark:
            cases = []
            for suffix, count in (("gif", 30), ("gif", 120), ("webp", 120), ("png", 120)):
                frames = []
                for index in range(count):
                    frame = Image.new("RGB", (640, 360), (24, 40, 56))
                    draw = ImageDraw.Draw(frame)
                    for row in range(12):
                        draw.rectangle((20, row * 28, 600, row * 28 + 14), fill=(row * 16, 80, 160))
                    x = index * 7 % 520
                    draw.rectangle((x, 100, x + 100, 230), fill=(240, 160, index % 120))
                    frames.append(frame)
                source = work / f"benchmark-{count}.{suffix}"
                frames[0].save(source, save_all=True, append_images=frames[1:], loop=2,
                               duration=[40 + (index % 4) * 10 for index in range(count)], lossless=True)
                del frames
                runs = []
                for attempt in range(3):
                    target = work / f"benchmark-result-{attempt}.{args.format}"
                    result = convert(source, target, {"webpMode": args.benchmark_webp_mode}, timed=True)
                    lines = result.stderr.splitlines()
                    runs.append({"seconds": float(next(line for line in lines if " real " in line).split()[0]),
                                 "resident_bytes": int(next(line for line in lines if "maximum resident set size" in line).split()[0]),
                                 "output_bytes": target.stat().st_size})
                    if attempt == 0:
                        maximum_error = check(source, target, lossy=args.format == "webp" and args.benchmark_webp_mode == "lossy")
                    target.unlink()
                cases.append({"input_format": suffix, "frames": count, "width": 640, "height": 360,
                              "input_sha256": digest(source), "input_bytes": source.stat().st_size, "runs": runs,
                              "maximum_rgb_error": maximum_error,
                              "median_seconds": statistics.median(run["seconds"] for run in runs),
                              "median_resident_bytes": statistics.median(run["resident_bytes"] for run in runs)})
            libraries = (args.tools / "ffmpeg").resolve().parents[1] / "Frameworks/Media"
            report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                      "command_sha256": digest(command), "ffmpeg_sha256": digest(args.tools / "ffmpeg"),
                      "media_libraries": {file.name: digest(file) for file in libraries.glob("*.dylib") if not file.is_symlink()},
                      "cases": cases, "scope": "Three complete conversions per case. Original 640 by 360 animation with irregular delays. RSS can include a child helper's peak; it is not aggregate simultaneous process memory. GUI excluded."}
            if args.format == "webp":
                report["webpanim_sha256"] = digest(args.tools / "webpanim")
                report["compression"] = args.benchmark_webp_mode
                report["quality"] = 85
                report["effort"] = 4
            report_name = "animation-performance.json" if args.format == "gif" else "webp-animation-performance.json"
            if args.format == "webp" and args.benchmark_webp_mode == "lossy":
                report_name = "webp-animation-lossy-performance.json"
            (args.report or ROOT / "research" / report_name).write_text(json.dumps(report, indent=2) + "\n")
        print("Independent animation checks completed.")


if __name__ == "__main__":
    main()
