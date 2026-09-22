#!/usr/bin/env python3
"""Check image-to-video routes, pixels, timing, and source preservation."""
import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import platform
import random
import re
import statistics
import subprocess
import tempfile

from PIL import Image, ImageCms, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
FORMATS = ("mp4", "mov", "webm", "mkv", "avi", "3gp", "mxf", "mpeg", "m2ts", "vob", "wmv", "flv", "ts")
PADDED = {"mp4", "mov", "mkv", "3gp", "m2ts", "wmv", "flv", "ts"}


def profile_application(data):
    result = b"!\xff\x0bICCRGBG1012"
    for index in range(0, len(data), 255):
        part = data[index:index + 255]
        result += bytes([len(part)]) + part
    return result + b"\0"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=ROOT / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=ROOT / ".tools/bin")
    parser.add_argument("--native-decoder", type=Path, help="Optional compiled check-image-video-native.swift for macOS playback color checks.")
    parser.add_argument("--benchmark-only", action="store_true")
    parser.add_argument("--report", type=Path, default=ROOT / "research/image-video-performance.json")
    args = parser.parse_args()
    command, tools = args.command.resolve(), args.tools.resolve()
    environment = {"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools)}
    records = []
    with tempfile.TemporaryDirectory(prefix="Image video café 100%, ") as temporary:
        work = Path(temporary)
        sequence = 0

        def convert(source, extension, size, expected=None, measured=False, media_options=None):
            nonlocal sequence
            sequence += 1
            output = work / f"result-{sequence}.{extension}"
            original = hashlib.sha256(source.read_bytes()).hexdigest()
            invocation = [command, "convert", source, output]
            if media_options:
                settings = work / f"media-options-{sequence}.json"
                settings.write_text(json.dumps(media_options))
                invocation += ["--media-options", settings]
            if measured: invocation = ["/usr/bin/time", "-l", *invocation]
            result = subprocess.run(invocation, env=environment, capture_output=True, text=True, timeout=120)
            assert hashlib.sha256(source.read_bytes()).hexdigest() == original
            assert not list(work.glob(".allomer-*"))
            timing = {}
            if measured:
                timing.update(seconds=float(re.search(r"([\d.]+)\s+real", result.stderr)[1]),
                    resident_bytes=int(re.search(r"(\d+)\s+maximum resident set size", result.stderr)[1]))
                if result.returncode != 0:
                    assert not output.exists()
                    return output, {**timing, "error": result.stderr.splitlines()[0]}
            assert result.returncode == 0, (source.name, extension, result.stderr)
            info = json.loads(subprocess.check_output([tools / "ffprobe", "-v", "error", "-show_entries",
                "stream=codec_type,width,height:format=duration", "-of", "json", output]))
            assert len(info["streams"]) == 1 and info["streams"][0]["codec_type"] == "video"
            width, height = size
            if extension in PADDED: width += width % 2; height += height % 2
            assert (info["streams"][0]["width"], info["streams"][0]["height"]) == (width, height)
            pixels = subprocess.run([tools / "ffmpeg", "-v", "error", "-xerror", "-i", output,
                "-map", "0:v:0", "-vf", "format=rgb24,scale=2:2:flags=neighbor,fps=100", "-fps_mode", "passthrough",
                "-pix_fmt", "rgb24", "-f", "rawvideo", "-"], capture_output=True, check=True).stdout
            frame_count = len(expected) if expected is not None else 10
            assert len(pixels) == frame_count * 12, (source.name, extension, "Frame count", len(pixels) // 12, frame_count)
            if expected is not None:
                for frame in range(frame_count):
                    actual = pixels[frame * 12:(frame + 1) * 12]
                    assert max(abs(a - b) for a, b in zip(actual, expected[frame])) <= 12, (source.name, extension, frame, list(actual), list(expected[frame]))
                if args.native_decoder and extension in ("mp4", "mov"):
                    frame = work / f"native-frame-{sequence}.png"
                    subprocess.run([args.native_decoder.resolve(), output, frame], check=True, capture_output=True, timeout=30)
                    with Image.open(frame) as image:
                        image = image.convert("RGB")
                        points = [(width // 4, height // 4), (width * 3 // 4, height // 4),
                                  (width // 4, height * 3 // 4), (width * 3 // 4, height * 3 // 4)]
                        actual = bytes(value for point in points for value in image.getpixel(point))
                        assert max(abs(a - b) for a, b in zip(actual, expected[0])) <= 8, (source.name, extension, "Native playback", list(actual))
            timing["output_bytes"] = output.stat().st_size
            return output, timing

        def artwork(size):
            width, height = size
            image = Image.new("RGBA", size, (20, 250, 40, 0))
            draw = ImageDraw.Draw(image)
            draw.rectangle((width // 2, 0, width - 1, height // 2 - 1), fill=(220, 30, 20, 255))
            draw.rectangle((width // 2, height // 2, width - 1, height - 1), fill=(20, 40, 220, 255))
            return image

        if args.benchmark_only:
            for name, size in [("artwork", (512, 512)), ("noise", (1024, 1024)), ("flat-24mp", (6000, 4000)),
                               ("profiled-gif-24mp", (6000, 4000))]:
                profiled = name == "profiled-gif-24mp"
                source = work / (name + (".gif" if profiled else ".png"))
                expected = None
                if profiled:
                    image = Image.new("P", size, 0)
                    image.putpalette([210, 95, 75] + [0] * 765)
                    image.save(source, duration=100, loop=0, optimize=False)
                    raw = source.read_bytes()
                    profile = Path("/System/Library/ColorSync/Profiles/Display P3.icc").read_bytes()
                    source.write_bytes(raw[:-1] + profile_application(profile) + raw[-1:])
                    color = ImageCms.profileToProfile(Image.new("RGB", (1, 1), (210, 95, 75)),
                        ImageCms.ImageCmsProfile(io.BytesIO(profile)), ImageCms.createProfile("sRGB"), outputMode="RGB").getpixel((0, 0))
                    expected = [bytes(color) * 4] * 10
                else:
                    image = Image.frombytes("RGB", size, random.Random(173).randbytes(size[0] * size[1] * 3)) if name == "noise" else (
                        Image.new("RGB", size, (30, 100, 200)) if name == "flat-24mp" else artwork(size))
                    image.save(source)
                runs = [convert(source, "mp4", size, expected, measured=True)[1] for _ in range(3)]
                failed = any("error" in run for run in runs)
                records.append({"case": name, "pixels": size, "input_format": source.suffix[1:], "input_bytes": source.stat().st_size,
                    "input_sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "runs": runs,
                    "status": "failed" if failed else "passed",
                    **({} if failed else {"median_seconds": statistics.median(run["seconds"] for run in runs),
                    "median_resident_bytes": statistics.median(run["resident_bytes"] for run in runs)})})
                print(name, records[-1], flush=True)
            args.report.write_text(json.dumps({"recorded_at_utc": datetime.now(timezone.utc).isoformat(),
                "macos": platform.mac_ver()[0], "chip": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
                "command_sha256": hashlib.sha256(command.read_bytes()).hexdigest(), "cases": records,
                "scope": "Three image-to-MP4 attempts per original workload: three PNGs and one profiled GIF. Successful runs include GIF preparation, video encoding, validation, and publication. Failed attempts are marked and have no completed-conversion median. Inputs warm the file cache. Python work and external frame checks are excluded. RSS is per-process high-water memory, not aggregate simultaneous memory or native service memory. GUI memory is excluded."}, indent=2) + "\n")
            if any(record["status"] == "failed" for record in records):
                raise SystemExit("Some benchmark conversions failed. Their errors are retained in the report.")
            return

        expected_still = [bytes([0, 0, 0, 220, 30, 20, 0, 0, 0, 20, 40, 220])] * 10
        cases = []
        for size in [(256, 160), (255, 159)]:
            source = work / f"still-{size[0]}.png"; artwork(size).save(source)
            cases.append((source, size, expected_still))
        colors = [(220, 30, 20), (20, 210, 40), (20, 40, 220)]
        frames = [Image.new("RGBA", (64, 40), (*color, 255)) for color in colors]
        expected_animation = [bytes(colors[0]) * 4] + [bytes(colors[1]) * 4] * 3 + [bytes(colors[2]) * 4] * 6
        for extension in ("gif", "png", "webp"):
            source = work / ("animation." + extension)
            if extension == "png":
                Image.new("RGBA", (64, 40), (255, 255, 255, 255)).save(source, save_all=True, append_images=frames,
                    duration=[10, 30, 60], loop=0, default_image=True)
            else:
                frames[0].save(source, save_all=True, append_images=frames[1:], duration=[10, 30, 60], loop=0,
                    optimize=False, lossless=True)
            cases.append((source, (64, 40), expected_animation))
        for source, size, expected in cases:
            for extension in FORMATS: convert(source, extension, size, expected)
            print(source.name, "all 13 containers passed", flush=True)

        for rate in (1, 2, 4, 5, 20, 25, 50):
            source = work / f"rate-{rate}.gif"
            frames[0].save(source, save_all=True, append_images=[frames[1]],
                duration=[1000 // rate, 2000 // rate], loop=0, optimize=False)
            ticks = 100 // rate
            expected = [bytes(colors[0]) * 4] * ticks + [bytes(colors[1]) * 4] * (ticks * 2)
            for extension in FORMATS:
                # Keep the short input below the format probe threshold regardless of app defaults.
                options = {"videoMode": "bitrate", "videoBitrateKbps": 2500} if rate == 20 and extension == "ts" else None
                output, _ = convert(source, extension, (64, 40), expected, media_options=options)
                if rate == 20 and extension == "ts":
                    data = output.read_bytes()
                    packets = [data[index:index + 188] for index in range(0, len(data), 188)]
                    short = work / "short-input.ts"
                    short.write_bytes(b"".join(packet for packet in packets if ((packet[1] & 31) << 8 | packet[2]) != 8191))
                    assert short.stat().st_size < 12 * 188, "The short transport-stream fixture grew past the probe threshold."
                    convert(short, "mp4", (64, 40), expected)
                    settings = work / "short-options.json"
                    settings.write_text(json.dumps({"videoFrameRate": 20, "webpMode": "lossless"}))
                    original = short.read_bytes()
                    for animation in ("gif", "webp"):
                        target = work / ("short-input." + animation)
                        subprocess.run([command, "convert", short, target, "--image-options", settings],
                            env=environment, check=True, capture_output=True, timeout=120)
                        with Image.open(target) as image:
                            assert image.n_frames == 3
                            for index in range(3):
                                image.seek(index)
                                pixel = image.convert("RGB").getpixel((32, 20))
                                assert max(abs(a - b) for a, b in zip(pixel, colors[min(index, 1)])) <= 12, (animation, index, pixel)
                                assert abs(image.info["duration"] - 50) <= 1
                        assert short.read_bytes() == original
                    assert not list(work.glob(".allomer-*"))
            print(1000 // rate, "ms base delay: all 13 containers passed", flush=True)

        for delay in (0, 200):
            source = work / f"delay-{delay}.gif"
            frames[0].save(source, duration=delay, loop=0, disposal=2)
            convert(source, "mp4", (64, 40), [bytes(colors[0]) * 4] * (10 if delay == 0 else 20))
        source = work / "mixed-zero.gif"
        frames[0].save(source, save_all=True, append_images=frames[1:], duration=[0, 10, 0], loop=0, disposal=2)
        convert(source, "mp4", (64, 40), [bytes(colors[0]) * 4] * 10 + [bytes(colors[1]) * 4]
                + [bytes(colors[2]) * 4] * 10)

        source = work / "short.gif"
        frames[0].save(source, duration=10, loop=0, disposal=2)
        for extension in FORMATS: convert(source, extension, (64, 40), [bytes(colors[0]) * 4])

        profile = Path("/System/Library/ColorSync/Profiles/Display P3.icc").read_bytes()
        profiled = work / "profile-colors.gif"
        profile_colors = [(210, 95, 75), (60, 185, 95), (80, 100, 205)]
        profile_frames = [Image.new("RGBA", (64, 40), (*color, 255)) for color in profile_colors]
        ImageDraw.Draw(profile_frames[2]).rectangle((0, 0, 31, 19), fill=(0, 0, 0, 0))
        profile_frames[0].save(profiled, save_all=True, append_images=profile_frames[1:],
            duration=[40, 90, 170], loop=2, disposal=2, optimize=False)
        raw = profiled.read_bytes()
        palette_end = 13 + (3 << ((raw[10] & 7) + 1))
        transformed = [ImageCms.profileToProfile(Image.new("RGB", (1, 1), color),
            ImageCms.ImageCmsProfile(io.BytesIO(profile)), ImageCms.createProfile("sRGB"), outputMode="RGB")
            .getpixel((0, 0)) for color in profile_colors]
        expected = [bytes(transformed[0]) * 4] * 4 + [bytes(transformed[1]) * 4] * 9
        expected += [bytes([0, 0, 0]) + bytes(transformed[2]) * 3] * 17
        for position in (palette_end, len(raw) - 1):
            profiled.write_bytes(raw[:position] + profile_application(profile) + raw[position:])
            if position == len(raw) - 1: profiled.chmod(0o444)
            for extension in FORMATS: convert(profiled, extension, (64, 40), expected)
            if position == len(raw) - 1: assert profiled.stat().st_mode & 0o777 == 0o444
        print("Embedded P3 before and after frames: all 13 containers passed", flush=True)
        invalid_profile = work / "invalid-profile.gif"
        invalid_profile.write_bytes(raw[:palette_end] + profile_application(b"Invalid RGB profile") + raw[palette_end:])
        original = invalid_profile.read_bytes()
        refused = work / "invalid-profile.mp4"
        result = subprocess.run([command, "convert", invalid_profile, refused], env=environment, capture_output=True, timeout=120)
        assert result.returncode != 0 and not refused.exists() and invalid_profile.read_bytes() == original

        source = cases[0][0]
        occupied = work / "occupied.mp4"; occupied.write_bytes(b"Existing destination")
        result = subprocess.run([command, "convert", source, occupied], env=environment, capture_output=True)
        assert result.returncode != 0 and occupied.read_bytes() == b"Existing destination"
        linked = work / "linked.png"; linked.symlink_to(source)
        damaged = work / "damaged.png"; damaged.write_bytes(source.read_bytes()[:32])
        for invalid in (linked, damaged):
            output = work / (invalid.name + ".mp4")
            result = subprocess.run([command, "convert", invalid, output], env=environment, capture_output=True, timeout=120)
            assert result.returncode != 0 and not output.exists()
        assert not list(work.glob(".allomer-*"))
    print("201 image/video cases, ICC colors, alpha background, padding, timing, short transport input, source preservation, invalid input, and cleanup passed.")


if __name__ == "__main__":
    main()
