#!/usr/bin/env python3
"""Check large, highly compressed GIFs with original fixtures and independent image reading."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
import zipfile

from PIL import Image, ImageChops, ImageCms, ImageDraw, ImageStat

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=ROOT / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=ROOT / ".tools/bin")
    args = parser.parse_args()
    command, tools = args.command.resolve(), args.tools.resolve()
    environment = {"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools)}
    with tempfile.TemporaryDirectory(prefix="GIF reader café 100%, ") as temporary:
        work = Path(temporary)
        sequence = 0

        def convert(source, extension, options=None):
            nonlocal sequence
            sequence += 1
            output = work / f"converted-{sequence}.{extension}"
            before = hashlib.sha256(source.read_bytes()).digest()
            invocation = [command, "convert", source, output]
            if options is not None:
                settings = work / "options.json"; settings.write_text(json.dumps(options))
                invocation += ["--image-options", settings]
            result = subprocess.run(invocation, env=environment, capture_output=True, text=True, timeout=120)
            assert result.returncode == 0, (source.name, extension, result.stderr)
            assert hashlib.sha256(source.read_bytes()).digest() == before
            assert not list(work.glob(".allomer-*"))
            return output

        def palette(index=0):
            image = Image.new("P", (3072, 3072), index)
            image.putpalette([30, 100, 200, 220, 30, 20, 20, 210, 40, 0, 0, 0] + [0] * 756)
            return image

        source = work / "flat.gif"
        palette().save(source, duration=0, disposal=2, optimize=False)
        for extension in ("png", "jpg", "tiff", "webp", "jxl", "gif", "pdf", "svg"):
            output = convert(source, extension)
            if extension in ("jxl", "pdf", "svg"):
                output = convert(output, "png")
            with Image.open(output) as image:
                image.load()
                # The PDF route renders the page at the 300 DPI default; the page itself is 72 DPI.
                side = 3072 * 300 // 72 if extension == "pdf" else 3072
                expected_size = (side, side)
                assert image.size == expected_size, (extension, image.size)
                color = image.convert("RGB").getpixel((1500, 1500))
                assert max(abs(a - b) for a, b in zip(color, (30, 100, 200))) <= 6, (extension, color)
        print("Large still GIF: eight image/document routes passed", flush=True)

        frames = [palette(index) for index in (0, 1, 2)]
        # Exact palette colors avoid a quantizer in the input oracle.
        animated = work / "animated.gif"
        frames[0].save(animated, save_all=True, append_images=frames[1:], duration=[0, 10, 170],
            loop=2, disposal=2, optimize=False)
        def check_animation(source):
            with Image.open(source) as original:
                expected, delays = [], []
                plays = original.info["loop"] + 1 if original.info["loop"] else 0
                for index in range(original.n_frames):
                    original.seek(index); expected.append(original.convert("RGBA")); delays.append(original.info["duration"])
            for extension in ("gif", "webp"):
                output = convert(source, extension, {"webpMode": "lossless"})
                with Image.open(output) as image:
                    assert image.n_frames == len(expected)
                    assert image.info["loop"] == (plays - 1 if extension == "gif" and plays else plays)
                    for index, frame in enumerate(expected):
                        image.seek(index); image.load()
                        assert abs(image.info["duration"] - delays[index]) < 0.001
                        actual = image.convert("RGBA")
                        assert ImageChops.difference(actual.getchannel("A"), frame.getchannel("A")).getbbox() is None
                        background = Image.new("RGBA", frame.size, (200, 10, 130, 255))
                        difference = ImageChops.difference(Image.alpha_composite(background, actual), Image.alpha_composite(background, frame))
                        assert difference.getbbox(alpha_only=False) is None
        check_animation(animated)
        single = work / "single-timed.gif"
        palette().save(single, duration=170, loop=2, disposal=2, optimize=False)
        check_animation(single)
        transparent = [palette(3) for _ in range(3)]
        ImageDraw.Draw(transparent[1]).rectangle((300, 300, 700, 700), fill=1)
        ImageDraw.Draw(transparent[2]).rectangle((1000, 300, 1400, 700), fill=2)
        disposed = work / "disposal.gif"
        transparent[0].save(disposed, save_all=True, append_images=transparent[1:], transparency=3,
            duration=[40, 90, 170], loop=1, disposal=[1, 2, 3], optimize=False)
        check_animation(disposed)
        print("Large animations: GIF/WebP appearance, alpha, disposal, delays, and plays passed", flush=True)

        profile = Path("/System/Library/ColorSync/Profiles/Display P3.icc").read_bytes()
        application = b"!\xff\x0bICCRGBG1012"
        for offset in range(0, len(profile), 255):
            part = profile[offset:offset + 255]; application += bytes([len(part)]) + part
        application += b"\0"
        tagged = work / "profile.gif"
        raw = source.read_bytes()
        palette_end = 13 + (3 << ((raw[10] & 7) + 1))
        tagged.write_bytes(raw[:palette_end] + application + raw[palette_end:])
        expected = ImageCms.profileToProfile(palette().convert("RGB"), ImageCms.ImageCmsProfile(io.BytesIO(profile)),
            ImageCms.createProfile("sRGB"), outputMode="RGB")
        for strip in (False, True):
            output = convert(tagged, "png", {"preserveMetadata": not strip, "convertToSRGB": True})
            with Image.open(output) as image:
                difference = ImageChops.difference(image.convert("RGB"), expected)
                assert max(ImageStat.Stat(difference).rms) <= 2
        print("Embedded Display P3: independent sRGB appearance check passed", flush=True)

        archive = convert(source, "zip")
        with zipfile.ZipFile(archive) as zipped:
            assert zipped.read(source.name) == source.read_bytes()

        occupied = work / "occupied.png"; occupied.write_bytes(b"Keep existing destination")
        result = subprocess.run([command, "convert", source, occupied], env=environment, capture_output=True)
        assert result.returncode != 0 and occupied.read_bytes() == b"Keep existing destination"
        linked = work / "linked.gif"; linked.symlink_to(source)
        malformed = work / "bad.gif"; malformed.write_bytes(source.read_bytes()[:-4])
        for invalid in (linked, malformed):
            output = work / (invalid.name + ".png")
            result = subprocess.run([command, "convert", invalid, output], env=environment, capture_output=True, timeout=120)
            assert result.returncode != 0 and not output.exists()
        assert not list(work.glob(".allomer-*"))
    print("Large GIF source preservation, collisions, links, malformed input, and cleanup passed.")


if __name__ == "__main__":
    main()
