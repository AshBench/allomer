#!/usr/bin/env python3
"""Check video-to-GIF/WebP output with original lossless video fixtures."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile

from PIL import Image, ImageChops, ImageDraw

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
    with tempfile.TemporaryDirectory(prefix="video-animation café 100%, ") as temporary:
        work = Path(temporary)

        def ffmpeg(arguments):
            result = subprocess.run([tools / "ffmpeg", "-v", "error", "-nostdin", "-n", *arguments],
                                    cwd=work, capture_output=True, text=True)
            assert result.returncode == 0, result.stderr

        def fixture(name, count=12, size=(96, 64), fps=12, alpha=False, gradient=False):
            raw = work / f"{name}.rgba"
            frames = []
            with raw.open("wb") as stream:
                for index in range(count):
                    frame = Image.new("RGBA", size, (25, 50, 100, 0 if alpha else 255))
                    draw = ImageDraw.Draw(frame)
                    x = index * 7 % (size[0] - 22)
                    draw.rectangle((x, 12, x + 20, 40), fill=(240, 80, 40, 128 if alpha else 255))
                    draw.rectangle((size[0] - 12, 4, size[0] - 4, 20), fill=(40, 180, 220, 255))
                    if gradient:
                        frame.putdata([(x * 255 // (size[0] - 1), y * 255 // (size[1] - 1),
                                        (x + y + index) % 256, 255)
                                       for y in range(size[1]) for x in range(size[0])])
                    stream.write(frame.tobytes())
                    if count <= 12:
                        frames.append(frame)
            output = work / f"{name}.mkv"
            ffmpeg(["-f", "rawvideo", "-pixel_format", "rgba", "-video_size", f"{size[0]}x{size[1]}",
                    "-framerate", str(fps), "-i", raw, "-c:v", "ffv1", "-level", "3", "-threads", "1", output])
            raw.unlink()
            return output, frames

        def convert(source, target, options=None, success=True, timed=False, existing=False):
            settings = work / "options.json"
            settings.write_text(json.dumps({"videoFrameRate": 12, "webpMode": "lossless", **(options or {})}))
            before = digest(source)
            old_output = digest(target) if existing else None
            invocation = [command, "convert", source, target, "--image-options", settings]
            if timed:
                invocation = ["/usr/bin/time", "-l", *invocation]
            result = subprocess.run(invocation, cwd=work, capture_output=True, text=True,
                                    env={"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools)})
            assert (result.returncode == 0) == success, (source.name, target.name, result.stderr)
            assert digest(source) == before, "Source changed"
            if not success:
                assert digest(target) == old_output if existing else not target.exists(), "Failed output published"
            assert not list(work.glob(".allomer-*")), "Private conversion files remain"
            return result

        def check(target, count, size, rate, plays, frames=None, colors=256):
            with Image.open(target) as image:
                gif = image.format == "GIF"
                assert image.n_frames == count, (target.name, image.n_frames, count)
                assert image.size == size, (target.name, image.size, size)
                expected_loop = (None if plays == 1 else max(0, plays - 1)) if gif else plays
                assert image.info.get("loop") == expected_loop, (target.name, image.info)
                duration = 0
                for index in range(count):
                    image.seek(index)
                    actual = image.convert("RGBA")
                    duration += image.info["duration"]
                    if gif:
                        assert len(actual.getcolors(maxcolors=257)) <= colors
                    if frames:
                        expected = frames[index]
                        for background in ("white", "black"):
                            delta = ImageChops.difference(
                                Image.alpha_composite(Image.new("RGBA", size, background), actual),
                                Image.alpha_composite(Image.new("RGBA", size, background), expected))
                            assert max(x[1] for x in delta.getextrema()) <= 1, (target.name, index, delta.getextrema())
                assert abs(duration - count * 1000 / rate) <= (21 if gif else 1), (target.name, duration)

        source, frames = fixture("moving ' original")
        for suffix in ("gif", "webp"):
            for plays in (0, 1, 2, 65535):
                target = work / f"loop-{plays}.{suffix}"
                convert(source, target, {"videoLoopCount": plays})
                check(target, 12, (96, 64), 12, plays, frames)
            for rate in (1, 12.5, 15, 100):
                target = work / f"rate-{rate}.{suffix}"
                convert(source, target, {"videoFrameRate": rate, "videoMaxWidth": 48})
                check(target, int(rate + 0.999), (48, 32), rate, 0)
            target = work / f"no-upscale.{suffix}"
            convert(source, target, {"videoMaxWidth": 192})
            check(target, 12, (96, 64), 12, 0, frames)
            convert(source, target, success=False, existing=True)
            for key, value in (("videoFrameRate", 0), ("videoFrameRate", 101), ("videoMaxWidth", -1),
                               ("videoMaxWidth", 65536), ("videoLoopCount", -1), ("videoLoopCount", 65536),
                               ("videoGIFColors", 1), ("videoGIFColors", 257)):
                convert(source, work / f"bad-{key}-{value}.{suffix}", {key: value}, success=False)
        target = work / "two-colors.gif"
        convert(source, target, {"videoGIFColors": 2})
        with Image.open(target) as image:
            for index in range(image.n_frames):
                image.seek(index)
                assert len(set(image.convert("RGBA").get_flattened_data())) <= 2
        tiny, tiny_frames = fixture("one-frame", count=1, fps=100)
        for suffix in ("gif", "webp"):
            target = work / f"one-frame.{suffix}"
            convert(tiny, target, {"videoFrameRate": 1, "videoLoopCount": 2})
            check(target, 1, (96, 64), 1, 2, tiny_frames)
        alpha, alpha_frames = fixture("alpha", alpha=True)
        target = work / "alpha.webp"
        convert(alpha, target)
        check(target, 12, (96, 64), 12, 0, alpha_frames)
        target = work / "alpha.gif"
        convert(alpha, target)
        binary_alpha = []
        for frame in alpha_frames:
            expected = frame.copy()
            expected.putalpha(frame.getchannel("A").point(lambda value: 0 if value < 128 else 255))
            binary_alpha.append(expected)
        check(target, 12, (96, 64), 12, 0, binary_alpha)
        gradient, _ = fixture("gradient", gradient=True)
        for colors in (3, 16, 256):
            outputs = []
            for dither in (False, True):
                target = work / f"palette-{colors}-{dither}.gif"
                convert(gradient, target, {"videoGIFColors": colors, "videoGIFDither": dither})
                check(target, 12, (96, 64), 12, 0, colors=colors)
                outputs.append(target.read_bytes())
            assert outputs[0] != outputs[1], "Dithering setting had no effect"
        stretched = work / "stretched.mkv"
        ffmpeg(["-i", source, "-vf", "setsar=2", "-c:v", "ffv1", stretched])
        for suffix in ("gif", "webp"):
            target = work / f"stretched.{suffix}"
            convert(stretched, target)
            check(target, 12, (192, 64), 12, 0)
        movie = work / "original.mov"
        rotated = work / "rotated.mov"
        ffmpeg(["-i", source, "-c:v", "png", movie])
        ffmpeg(["-display_rotation", "90", "-i", movie, "-c", "copy", rotated])
        for suffix in ("gif", "webp"):
            target = work / f"rotated.{suffix}"
            convert(rotated, target)
            check(target, 12, (64, 96), 12, 0, [f.transpose(Image.Transpose.ROTATE_90) for f in frames])
        linear = work / "linear.mkv"
        ffmpeg(["-i", source, "-c", "copy", "-color_trc", "linear", "-color_primaries", "bt709", linear])
        lookup = [round(255 * (12.92 * (v / 255) if v / 255 <= 0.0031308 else 1.055 * (v / 255) ** (1 / 2.4) - 0.055))
                  for v in range(256)]
        for suffix in ("gif", "webp"):
            target = work / f"linear.{suffix}"
            convert(linear, target)
            expected = [Image.merge("RGBA", [c.point(lookup) for c in frame.split()[:3]] + [frame.getchannel("A")]) for frame in frames]
            check(target, 12, (96, 64), 12, 0, expected)
        hdr = work / "hdr.mkv"
        ffmpeg(["-i", source, "-c", "copy", "-color_trc", "smpte2084", hdr])
        multiple = work / "multiple.mkv"
        ffmpeg(["-i", source, "-map", "0:v:0", "-map", "0:v:0", "-c", "copy", multiple])
        excessive, _ = fixture("too-many", count=10001, size=(32, 32), fps=100)
        for suffix in ("gif", "webp"):
            for video in (hdr, multiple, excessive):
                convert(video, work / f"{video.stem}-refused.{suffix}", {"videoFrameRate": 100}, success=False)
        damaged = work / "damaged.mkv"
        damaged.write_bytes(source.read_bytes()[:source.stat().st_size // 2])
        for suffix in ("gif", "webp"):
            convert(damaged, work / f"damaged.{suffix}", success=False)
        if args.benchmark:
            cases = []
            for count in (30, 120):
                video, _ = fixture(f"benchmark-{count}", count=count, size=(640, 360), fps=15)
                for suffix, mode in (("gif", "lossless"), ("webp", "lossless"), ("webp", "lossy")):
                    runs = []
                    for attempt in range(3):
                        target = work / f"benchmark-{count}-{mode}-{attempt}.{suffix}"
                        result = convert(video, target, {"videoFrameRate": 15, "webpMode": mode}, timed=True)
                        lines = result.stderr.splitlines()
                        runs.append({"seconds": float(next(x for x in lines if " real " in x).split()[0]),
                                     "resident_bytes": int(next(x for x in lines if "maximum resident set size" in x).split()[0]),
                                     "output_bytes": target.stat().st_size})
                        check(target, count, (640, 360), 15, 0)
                    cases.append({"frames": count, "output_format": suffix, "compression": mode if suffix == "webp" else "palette",
                                  "input_bytes": video.stat().st_size, "input_sha256": digest(video), "runs": runs,
                                  "median_seconds": statistics.median(x["seconds"] for x in runs),
                                  "median_resident_bytes": statistics.median(x["resident_bytes"] for x in runs)})
            libraries = (tools / "ffmpeg").resolve().parents[1] / "Frameworks/Media"
            report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                      "command_sha256": digest(command), "ffmpeg_sha256": digest(tools / "ffmpeg"),
                      "webpanim_sha256": digest(tools / "webpanim"), "width": 640, "height": 360, "frame_rate": 15,
                      "quality": 85, "effort": 4, "gif_colors": 256, "gif_dither": True, "cases": cases,
                      "media_libraries": {f.name: digest(f) for f in libraries.glob("*.dylib") if not f.is_symlink()},
                      "scope": "Three complete command conversions. Original lossless FFV1 flat-color video. RSS can include a child helper's peak; it is not aggregate simultaneous process memory. GUI excluded."}
            (ROOT / "research/video-animation-performance.json").write_text(json.dumps(report, indent=2) + "\n")
        print("Independent video animation checks passed.")


if __name__ == "__main__":
    main()
