#!/usr/bin/env python3
"""Check JPEG XL pixels, color, metadata, and failures with an independent decoder."""
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
import zlib

from PIL import Image, ImageChops, ImageCms, ImageDraw, ImageOps, ImageStat, PngImagePlugin

ROOT = Path(__file__).resolve().parent.parent


def digest(file):
    with file.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=ROOT / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=ROOT / ".tools/bin")
    parser.add_argument("--decoder", type=Path, default=ROOT / ".tools/jpegxl/bin/djxl")
    parser.add_argument("--benchmark", action="store_true")
    parser.add_argument("--benchmark-only", action="store_true")
    parser.add_argument("--report", type=Path, default=ROOT / "research/jpegxl-performance.json")
    parser.add_argument("--lossless-effort", type=int, choices=range(1, 11), default=4)
    parser.add_argument("--lossy-effort", type=int, choices=range(1, 11), default=7)
    args = parser.parse_args()
    command, tools, decoder = args.command.resolve(), args.tools.resolve(), args.decoder.resolve()
    with tempfile.TemporaryDirectory(prefix="jpegxl-check café 100%, ") as temporary:
        work = Path(temporary)

        def convert(source, target, options=None, success=True, timed=False, existing=False):
            settings = work / "options.json"
            settings.write_text(json.dumps({"quality": 1, "jpegXLMode": "lossless", "jpegXLEffort": args.lossless_effort, **(options or {})}))
            before = digest(source)
            saved = digest(target) if existing else None
            invocation = [command, "convert", source, target, "--image-options", settings]
            if timed:
                invocation = ["/usr/bin/time", "-l", *invocation]
            result = subprocess.run(invocation, cwd=work, capture_output=True, text=True,
                                    env={"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools)})
            assert (result.returncode == 0) == success, (source.name, target.name, result.stderr)
            assert digest(source) == before, "Source changed"
            if not success:
                assert digest(target) == saved if existing else not target.exists(), "Failed output published"
            assert not list(work.glob(".allomer-*")), "Private files remain"
            return result

        def decode(source, suffix="png", *flags):
            target = work / f"decoded.{suffix}"
            target.unlink(missing_ok=True)
            result = subprocess.run([decoder, source, target, "--quiet", "--num_threads=0", *flags],
                                    capture_output=True, text=True)
            assert result.returncode == 0, result.stderr
            return target

        def appearance(image):
            image = ImageOps.exif_transpose(image)
            profile = image.info.get("icc_profile")
            source_profile = ImageCms.ImageCmsProfile(io.BytesIO(profile)) if profile else ImageCms.createProfile("sRGB")
            rgb = ImageCms.profileToProfile(image.convert("RGB"), source_profile, ImageCms.createProfile("sRGB"), outputMode="RGB")
            rgb.putalpha(image.convert("RGBA").getchannel("A"))
            return rgb

        def compare(actual, expected, tolerance=0):
            assert actual.size == expected.size, (actual.size, expected.size)
            delta = ImageChops.difference(actual, expected)
            assert max(channel.getextrema()[1] for channel in delta.split()) <= tolerance, delta.getextrema()

        def benchmark():
            cases = []
            for width, height in ((1000, 1000), (6000, 4000)):
                pixels = random.Random(6718).randbytes(width * height * 3)
                fixture = work / f"benchmark-{width}.png"
                Image.frombytes("RGB", (width, height), pixels).save(fixture)
                del pixels
                for quality in (0.85, 1):
                    runs = []
                    for attempt in range(3):
                        target = work / f"benchmark-{width}-{quality}-{attempt}.jxl"
                        result = convert(fixture, target, {"quality": quality,
                            "jpegXLMode": "lossless" if quality == 1 else "lossy",
                            "jpegXLEffort": args.lossless_effort if quality == 1 else args.lossy_effort}, timed=True)
                        lines = result.stderr.splitlines()
                        runs.append({"seconds": float(next(x for x in lines if " real " in x).split()[0]),
                                     "resident_bytes": int(next(x for x in lines if "maximum resident set size" in x).split()[0]),
                                     "output_bytes": target.stat().st_size})
                        if attempt == 0:
                            actual = Image.open(decode(target)).convert("RGB")
                            expected = Image.open(fixture).convert("RGB")
                            error = ImageStat.Stat(ImageChops.difference(actual, expected))
                            mean_error, rms_error = error.mean, error.rms
                            if quality == 1:
                                compare(actual, expected)
                        target.unlink()
                    cases.append({"width": width, "height": height, "quality": quality,
                                  "effort": args.lossless_effort if quality == 1 else args.lossy_effort,
                                  "mean_rgb_error": mean_error, "rms_rgb_error": rms_error,
                                  "input_bytes": fixture.stat().st_size, "input_sha256": digest(fixture), "runs": runs,
                                  "median_seconds": statistics.median(x["seconds"] for x in runs),
                                  "median_resident_bytes": statistics.median(x["resident_bytes"] for x in runs)})
            report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                      "chip": subprocess.check_output(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
                      "command_sha256": digest(command), "cjxl_sha256": digest(tools / "cjxl"),
                      "decoder_sha256": digest(decoder), "lossy_effort": args.lossy_effort, "lossless_effort": args.lossless_effort,
                      "buffering": 2, "output_mode": 1,
                      "resampling": 1, "ec_resampling": 1, "cases": cases,
                      "scope": "Three complete command conversions per case. Seeded random RGB input. RSS can include a child helper's peak; it is not aggregate simultaneous process memory. GUI excluded."}
            args.report.write_text(json.dumps(report, indent=2) + "\n")

        if args.benchmark_only:
            benchmark()
            print("JPEG XL benchmark completed.")
            return

        original = Image.new("RGBA", (96, 64))
        original.putdata([(x * 255 // 95, y * 255 // 63, (x * 5 + y * 3) % 256,
                           (0, 1, 64, 128, 254, 255)[x // 16]) for y in range(64) for x in range(96)])
        source = work / "original ' pixels.png"
        original.save(source)
        sizes = []
        for quality in (0, 0.5, 0.85, 1):
            output = work / f"quality-{quality}.jxl"
            convert(source, output, {"quality": quality, "jpegXLMode": "lossless" if quality == 1 else "lossy", "jpegXLEffort": 7})
            decoded = Image.open(decode(output)).convert("RGBA")
            compare(decoded.getchannel("A"), original.getchannel("A"))
            if quality == 1:
                compare(decoded, original)
            else:
                assert max(ImageStat.Stat(ImageChops.difference(decoded, original)).rms[:3]) < (90 if quality == 0 else 30)
            sizes.append(output.stat().st_size)
            restored = work / f"native-{quality}.png"
            convert(output, restored)
            actual = Image.open(restored).convert("RGBA")
            for color in ("white", "black"):
                compare(Image.alpha_composite(Image.new("RGBA", actual.size, color), actual),
                        Image.alpha_composite(Image.new("RGBA", decoded.size, color), decoded), 2)
        assert len(set(sizes)) > 1, "Quality did not change encoding"
        convert(source, output, success=False, existing=True)

        for mode in ("lossless", "lossy"):
            effort_outputs = []
            for effort in range(1, 11):
                target = work / f"{mode}-effort-{effort}.jxl"
                convert(source, target, {"jpegXLMode": mode, "jpegXLEffort": effort})
                effort_outputs.append(digest(target))
                actual = Image.open(decode(target)).convert("RGBA")
                compare(actual.getchannel("A"), original.getchannel("A"))
                if mode == "lossless":
                    compare(actual, original)
                else:
                    error = ImageStat.Stat(ImageChops.difference(actual, original)).rms[:3]
                    lower = work / f"lossy-85-effort-{effort}.jxl"
                    convert(source, lower, {"quality": 0.85, "jpegXLMode": mode, "jpegXLEffort": effort})
                    baseline = ImageStat.Stat(ImageChops.difference(Image.open(decode(lower)).convert("RGBA"), original)).rms[:3]
                    assert 0 < sum(error) < sum(baseline), (mode, effort, error, baseline)
            assert len(set(effort_outputs)) > 1, (mode, "Effort did not change encoding")
            for effort in (0, 11):
                convert(source, work / f"invalid-{mode}-effort-{effort}.jxl",
                        {"jpegXLMode": mode, "jpegXLEffort": effort}, success=False)
        ignored_quality = work / "lossless-low-quality.jxl"
        convert(source, ignored_quality, {"quality": 0, "jpegXLMode": "lossless", "jpegXLEffort": 7})
        assert digest(ignored_quality) == digest(work / "lossless-effort-7.jxl")
        convert(source, work / "invalid-mode.jxl", {"jpegXLMode": "fast"}, success=False)

        opaque = original.convert("RGB")
        for orientation in range(1, 9):
            exif = Image.Exif()
            exif[274] = orientation
            exif[315] = "Original JPEG XL artist"
            path = work / f"orientation-{orientation}.png"
            opaque.save(path, exif=exif)
            for preserve in (True, False):
                target = work / f"orientation-{orientation}-{preserve}.jxl"
                convert(path, target, {"preserveMetadata": preserve})
                expected = ImageOps.exif_transpose(Image.open(path)).convert("RGB")
                compare(Image.open(decode(target)).convert("RGB"), expected)
                restored = work / f"orientation-native-{orientation}-{preserve}.png"
                convert(target, restored)
                compare(ImageOps.exif_transpose(Image.open(restored)).convert("RGB"), expected)
                data = decode(target, "exif").read_bytes()
                assert (b"Original JPEG XL artist" in data) == preserve

        p3 = ImageCms.getOpenProfile("/System/Library/ColorSync/Profiles/Display P3.icc").tobytes()
        xmp = '<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/" dc:title="JPEG XL café ✓"/></rdf:RDF></x:xmpmeta>'
        pnginfo = PngImagePlugin.PngInfo()
        pnginfo.add_itxt("XML:com.adobe.xmp", xmp)
        source_p3 = work / "profile.png"
        opaque.save(source_p3, icc_profile=p3, pnginfo=pnginfo)
        expected = appearance(Image.open(source_p3))
        for preserve in (True, False):
            for srgb in (True, False):
                target = work / f"profile-{preserve}-{srgb}.jxl"
                convert(source_p3, target, {"preserveMetadata": preserve, "convertToSRGB": srgb})
                decoded = Image.open(decode(target))
                compare(appearance(decoded), expected, 3)
                if preserve and not srgb:
                    assert decoded.info["icc_profile"] == p3
                data = decode(target, "xmp").read_bytes()
                assert ("JPEG XL café ✓".encode() in data) == preserve

        gamma = PngImagePlugin.PngInfo()
        gamma.add(b"gAMA", struct.pack(">I", 100000))
        linear = work / "linear.png"
        Image.new("RGB", (32, 24), (80, 120, 160)).save(linear, pnginfo=gamma)
        expected = Image.new("RGBA", (32, 24), tuple(round(255 * (1.055 * (v / 255) ** (1 / 2.4) - 0.055)) for v in (80, 120, 160)) + (255,))
        for srgb in (True, False):
            target = work / f"linear-{srgb}.jxl"
            convert(linear, target, {"convertToSRGB": srgb})
            compare(appearance(Image.open(decode(target))), expected, 2)

        grayscale = Image.frombytes("I;16", (96, 64), b"".join(struct.pack("<H", (i * 103) % 65536) for i in range(96 * 64)))
        gray = work / "gray16.png"
        grayscale.save(gray)
        target = work / "gray16.jxl"
        convert(gray, target)
        assert list(Image.open(decode(target)).get_flattened_data()) == list(grayscale.get_flattened_data())
        for suffix in ("jpg", "bmp", "tiff", "webp", "gif"):
            path = work / f"bridge.{suffix}"
            opaque.save(path, lossless=True, **({"quality": 95, "subsampling": 0} if suffix == "jpg" else {}))
            target = work / f"bridge-{suffix}.jxl"
            convert(path, target)
            decoded = Image.open(decode(target)).convert("RGB")
            compare(decoded, Image.open(path).convert("RGB"), 3 if suffix == "jpg" else 1)
            if suffix == "jpg":
                # Check exact preservation of native JPEG decoding separately from IJG rounding differences.
                native = work / "jpeg-native.png"
                convert(path, native)
                compare(decoded, Image.open(native).convert("RGB"))
        psd = work / "original.psd"
        psd.write_bytes(b"8BPS" + struct.pack(">H6sHIIHH", 1, bytes(6), 3, 64, 96, 8, 3)
                        + bytes(12) + bytes(2) + b"".join(c.tobytes() for c in opaque.split()))
        target = work / "photoshop.jxl"
        convert(psd, target)
        compare(Image.open(decode(target)).convert("RGB"), opaque)
        icon = work / "original.ico"
        opaque.resize((32, 32)).save(icon, sizes=[(32, 32)])
        target = work / "icon.jxl"
        convert(icon, target)
        compare(Image.open(decode(target)).convert("RGB"), Image.open(icon).convert("RGB"))
        misleading = work / "misleading.jpg"
        misleading.write_bytes(source.read_bytes())
        convert(misleading, work / "misleading.jxl")
        for value in (-0.1, 1.1):
            convert(source, work / f"bad-quality-{value}.jxl", {"quality": value}, success=False)
        bad = work / "damaged.png"
        bad.write_bytes(source.read_bytes()[:source.stat().st_size // 2])
        convert(bad, work / "damaged.jxl", success=False)
        oversized = bytearray(source.read_bytes())
        struct.pack_into(">II", oversized, 16, 10000, 10000)
        struct.pack_into(">I", oversized, 29, zlib.crc32(oversized[12:29]))
        big = work / "oversized.png"
        big.write_bytes(oversized)
        convert(big, work / "oversized.jxl", success=False)
        for count in (1, 2):
            animation = work / f"animation-{count}.png"
            if count == 1:
                def chunk(kind, data):
                    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
                pixels = opaque.tobytes()
                rows = b"".join(b"\0" + pixels[y * 288:(y + 1) * 288] for y in range(64))
                animation.write_bytes(b"\x89PNG\r\n\x1a\n"
                    + chunk(b"IHDR", struct.pack(">IIBBBBB", 96, 64, 8, 2, 0, 0, 0))
                    + chunk(b"acTL", struct.pack(">II", 1, 2))
                    + chunk(b"fcTL", struct.pack(">IIIIIHHBB", 0, 96, 64, 0, 0, 90, 1000, 0, 0))
                    + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
            else:
                opaque.save(animation, save_all=True, append_images=[ImageOps.mirror(opaque)], duration=90, loop=2)
            convert(animation, work / f"animation-{count}.jxl", success=False)
        coded = (work / "bridge.webp").read_bytes()[12:]
        vp8x = b"VP8X" + struct.pack("<I", 10) + bytes([2, 0, 0, 0]) + (95).to_bytes(3, "little") + (63).to_bytes(3, "little")
        anim = b"ANIM" + struct.pack("<I", 6) + bytes(4) + struct.pack("<H", 1)
        frame = bytes(6) + (95).to_bytes(3, "little") + (63).to_bytes(3, "little") + bytes(3) + bytes([2]) + coded
        payload = b"WEBP" + vp8x + anim + b"ANMF" + struct.pack("<I", len(frame)) + frame
        zero = work / "zero-delay.webp"
        zero.write_bytes(b"RIFF" + struct.pack("<I", len(payload)) + payload)
        convert(zero, work / "zero-delay.jxl", success=False)

        if args.benchmark:
            benchmark()
        print("Independent JPEG XL checks passed.")


if __name__ == "__main__":
    main()
