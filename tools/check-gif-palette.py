#!/usr/bin/env python3
"""Check GIF palette limits, dithering, and transparency with original images."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import random
import statistics
import subprocess
import tempfile

from PIL import Image, ImageChops, ImageDraw, ImageStat

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=ROOT / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=ROOT / ".tools/bin")
    parser.add_argument("--benchmark-only", action="store_true")
    parser.add_argument("--report", type=Path, default=ROOT / "research/gif-palette-performance.json")
    args = parser.parse_args()
    environment = {"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(args.tools.resolve())}
    with tempfile.TemporaryDirectory(prefix="GIF café 100%, ") as temporary:
        work = Path(temporary)

        def codec_palette(source, name, cache=32, bounded=True, dither="none"):
            output = work / (name + ".gif")
            palette = f"split[p][c];[c]palettegen=alpha_threshold=128:bounded_histogram={int(bounded)}:stats_mode=single[map];"
            palette += f"[p][map]paletteuse=new=1:cache_limit={cache}:dither={dither}"
            result = subprocess.run([args.tools.resolve() / "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin",
                "-threads", "1", "-filter_complex_threads", "1", "-i", source, "-filter_complex", palette,
                "-frames:v", "1", "-gifflags", "0", "-map_metadata", "-1", "-f", "gif", output],
                cwd=work, env=environment, capture_output=True, text=True)
            assert result.returncode == 0, result.stderr
            return output

        def convert(source, name, colors=256, dither=True, succeeds=True, measured=False):
            options = work / "options.json"
            options.write_text(json.dumps({"gifMaxColors": colors, "gifDither": dither}))
            output = work / (name + ".gif")
            before = hashlib.sha256(source.read_bytes()).digest()
            arguments = [args.command.resolve(), "convert", source, output, "--image-options", options]
            if measured:
                arguments = ["/usr/bin/time", "-l", *arguments]
            result = subprocess.run(arguments,
                                    cwd=work, env=environment, capture_output=True, text=True)
            assert (result.returncode == 0) == succeeds, (name, result.stderr)
            assert hashlib.sha256(source.read_bytes()).digest() == before
            assert not list(work.glob(".allomer-*")), "Private files remain"
            if not succeeds:
                assert not output.exists(), "Failed conversion published output"
            return (output, result) if measured else output

        if args.benchmark_only:
            source = work / "noise-24m.png"
            expected = Image.frombytes("RGB", (6000, 4000), random.Random(816).randbytes(72000000))
            expected.save(source)
            samples = []
            for index in range(3):
                output, result = convert(source, f"measured-{index}", measured=True)
                lines = result.stderr.splitlines()
                with Image.open(output) as image:
                    actual = image.convert("RGB")
                    assert actual.size == expected.size
                    error = ImageStat.Stat(ImageChops.difference(actual, expected))
                    samples.append({"seconds": float(next(line for line in lines if " real " in line).split()[0]),
                        "resident_bytes": int(next(line for line in lines if "maximum resident set size" in line).split()[0]),
                        "output_bytes": output.stat().st_size, "output_sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
                        "mean_rgb_error": error.mean, "rms_rgb_error": error.rms})
                output.unlink()
            libraries = (args.tools / "ffmpeg").resolve().parents[1] / "Frameworks/Media"
            report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                "architecture": platform.machine(), "command_sha256": hashlib.sha256(args.command.read_bytes()).hexdigest(),
                "ffmpeg_sha256": hashlib.sha256((args.tools / "ffmpeg").read_bytes()).hexdigest(),
                "media_libraries": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in libraries.glob("*.dylib") if not p.is_symlink()},
                "input_sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "input_bytes": source.stat().st_size,
                "width": 6000, "height": 4000, "gif_max_colors": 256, "gif_dither": True, "samples": samples,
                "median_seconds": statistics.median(s["seconds"] for s in samples),
                "median_resident_bytes": statistics.median(s["resident_bytes"] for s in samples),
                "scope": "Three complete conversions of one original 24-megapixel RGB noise PNG. Input generation and verification are not timed. RSS can include a child helper peak; it is not aggregate simultaneous process memory. GUI excluded. Older commands can ignore the palette settings."}
            args.report.write_text(json.dumps(report, indent=2) + "\n")
            print("GIF palette benchmark completed.")
            return

        gradient = Image.new("RGBA", (128, 96))
        gradient.putdata([(x * 2, y * 2, (x + y) % 256, 0 if x < 16 else 255)
                          for y in range(96) for x in range(128)])
        source = work / "gradient.png"
        gradient.save(source)
        for colors in (2, 3, 16, 256):
            for dither in (False, True):
                output = convert(source, f"palette-{colors}-{dither}", colors, dither)
                with Image.open(output) as image:
                    rgba = image.convert("RGBA")
                    assert len(set(rgba.get_flattened_data())) <= colors, (colors, dither)
                    assert rgba.getchannel("A").tobytes() == gradient.getchannel("A").tobytes()
        assert (work / "palette-16-False.gif").read_bytes() != (work / "palette-16-True.gif").read_bytes()
        repeat = convert(source, "repeat", 16, True)
        assert repeat.read_bytes() == (work / "palette-16-True.gif").read_bytes(), "Dithering changed between runs"
        cache_outputs = []
        for limit in (0, 1):
            output = codec_palette(source, f"cache-{limit}", cache=limit, dither="bayer")
            cache_outputs.append(output.read_bytes())
        assert cache_outputs[0] == cache_outputs[1], "The cache limit changed the encoded GIF"
        for colors in (-1, 0, 1, 257):
            convert(source, f"invalid-{colors}", colors, succeeds=False)
        occupied = work / "occupied.gif"
        occupied.write_bytes(b"Keep this file")
        options = work / "options.json"
        options.write_text("{}")
        result = subprocess.run([args.command.resolve(), "convert", source, occupied], cwd=work,
                                env=environment, capture_output=True)
        assert result.returncode != 0 and occupied.read_bytes() == b"Keep this file"

        threshold = Image.new("RGBA", (60, 10))
        threshold.putdata([(255, 0, 0, (0, 1, 127, 128, 254, 255)[x // 10])
                           for y in range(10) for x in range(60)])
        source = work / "threshold.png"
        threshold.save(source)
        for dither in (False, True):
            with Image.open(convert(source, f"threshold-{dither}", 2, dither)) as image:
                pixels = image.convert("RGBA")
                for x in range(60):
                    color = pixels.getpixel((x, 5))
                    assert color[3] == (0 if x < 30 else 255), (x, color)
                    if x >= 30:
                        assert color[:3] == (255, 0, 0), (x, color)

        frames = [Image.new("RGBA", (32, 24)) for _ in range(3)]
        ImageDraw.Draw(frames[0]).rectangle((2, 2, 10, 10), fill="red")
        ImageDraw.Draw(frames[2]).rectangle((20, 10, 29, 20), fill="blue")
        source = work / "blank-frame.png"
        frames[0].save(source, save_all=True, append_images=frames[1:], duration=[0, 10, 170], loop=2)
        with Image.open(convert(source, "blank-frame", 2)) as image:
            assert image.n_frames == 3 and image.info["loop"] == 1
            for index, expected in enumerate(frames):
                image.seek(index)
                actual = image.convert("RGBA")
                assert image.info["duration"] == [0, 10, 170][index]
                assert actual.getchannel("A").tobytes() == expected.getchannel("A").tobytes(), index
                for actual_color, expected_color in zip(actual.get_flattened_data(), expected.get_flattened_data()):
                    if expected_color[3]:
                        assert actual_color == expected_color, (index, actual_color, expected_color)
        source = work / "all-transparent.png"
        frames[1].save(source)
        with Image.open(convert(source, "all-transparent", 2)) as image:
            assert image.convert("RGBA").getchannel("A").getextrema() == (0, 0)
        source = work / "long-delay.gif"
        frames[0].save(source, duration=655350)
        with Image.open(convert(source, "long-delay-output", 2)) as image:
            assert image.info["duration"] == 655350
        close_colors = Image.new("RGB", (192, 16))
        close_colors.putdata([(x // 16 * 16, 80, 160) for y in range(16) for x in range(192)])
        source = work / "close-colors.png"
        close_colors.save(source)
        with Image.open(convert(source, "close-colors")) as image:
            assert image.convert("RGB").tobytes() == close_colors.tobytes(), "Dithering changed an unreduced palette"
        many = Image.new("RGB", (512, 512))
        many.putdata([(x % 256, y % 256, (x // 256 + 2 * (y // 256)) * 85)
                      for y in range(512) for x in range(512)])
        source = work / "many-colors.png"
        many.save(source)
        with Image.open(codec_palette(source, "full-histogram", bounded=False)) as image:
            baseline = ImageStat.Stat(ImageChops.difference(image.convert("RGB"), many)).rms
        with Image.open(convert(source, "many-colors", dither=False)) as image:
            actual = image.convert("RGB")
            assert len(set(actual.get_flattened_data())) <= 256
            error = ImageStat.Stat(ImageChops.difference(actual, many)).rms
            assert all(after <= before + 2 for after, before in zip(error, baseline)), (error, baseline)
            print("Many-color RMS error, bounded and full histograms:", error, baseline)
        print("Independent GIF palette checks completed.")


if __name__ == "__main__":
    main()
