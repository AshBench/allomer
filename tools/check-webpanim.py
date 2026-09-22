#!/usr/bin/env python3
"""Check the bounded WebP animation writer with original PNG frames."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

from PIL import Image, ImageChops, ImageCms, ImageDraw, ImageStat, PngImagePlugin

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tool", type=Path, default=ROOT / ".tools/bin/webpanimguard")
    args = parser.parse_args()
    tool = args.tool.resolve()
    with tempfile.TemporaryDirectory(prefix="webpanim-check-") as temporary:
        work = Path(temporary)
        manifest = work / "frames.txt"
        output = work / "result.webp"
        frames = []
        profile = ImageCms.getOpenProfile("/System/Library/ColorSync/Profiles/Display P3.icc").tobytes()
        xmp = '<x:xmpmeta xmlns:x="adobe:ns:meta/">Original animation</x:xmpmeta>'
        for index in range(3):
            frame = Image.new("RGBA", (96, 64), (12, 34, 56, 0))
            draw = ImageDraw.Draw(frame)
            draw.rectangle((5 + index * 10, 8, 50 + index * 10, 50), fill=(240, 80, 40 + index * 30, 128))
            draw.rectangle((80, 10, 90, 55), fill=(20, 180, 220, 255))
            frames.append(frame)
            exif = Image.Exif()
            exif[274] = 1
            exif[315] = "Original animation check"
            metadata = PngImagePlugin.PngInfo()
            metadata.add_itxt("XML:com.adobe.xmp", xmp)
            frame.save(work / f"frame-{index + 1:06d}.png", icc_profile=profile, exif=exif, pnginfo=metadata)
        originals = {file.name: hashlib.sha256(file.read_bytes()).digest() for file in work.glob("*.png")}

        def run(values, success=True):
            manifest.write_text("\n".join(map(str, values)) + "\n")
            result = subprocess.run([tool, manifest, work, manifest.name, output.name], cwd=work,
                                    env={"PATH": "/usr/bin:/bin"}, capture_output=True, text=True)
            assert (result.returncode == 0) == success, result.stderr
            for name, digest in originals.items():
                assert hashlib.sha256((work / name).read_bytes()).digest() == digest
            return result

        for lossless in (0, 1):
            for quality, effort in ((0, 0), (85, 4), (100, 6)):
                for loops in (0, 1, 65535):
                    for preserve in (0, 1):
                        durations = [170] if loops == 1 else [0, 1, 0xffffff]
                        values = [1, 96, 64, len(durations), loops, lossless, quality, effort, preserve, *durations]
                        run(values)
                        with Image.open(output) as image:
                            assert image.n_frames == len(durations)
                            assert image.info["loop"] == loops
                            assert image.info["icc_profile"] == profile
                            assert ("exif" in image.info) == bool(preserve)
                            assert ("xmp" in image.info) == bool(preserve)
                            if preserve:
                                assert image.getexif()[315] == "Original animation check"
                                assert image.info["xmp"] == xmp.encode()
                            for index, duration in enumerate(durations):
                                image.seek(index)
                                actual = image.convert("RGBA")
                                assert image.info["duration"] == duration
                                assert actual.getchannel("A").tobytes() == frames[index].getchannel("A").tobytes()
                                delta = ImageChops.difference(actual, frames[index])
                                if lossless:
                                    assert not delta.getbbox(alpha_only=False), (index, delta.getextrema())
                                else:
                                    mask = frames[index].getchannel("A").point(lambda value: 255 if value else 0)
                                    for channel in delta.split()[:3]:
                                        assert ImageStat.Stat(channel, mask).rms[0] < 50
                        assert (b"VP8L" in output.read_bytes()) == bool(lossless)
                        output.unlink()

        valid = [1, 96, 64, 3, 2, 1, 85, 4, 1, 40, 90, 170]
        for index, value in ((0, 2), (1, 0), (1, 16384), (3, 10001), (4, 65536), (5, 2),
                             (6, "nan"), (6, 101), (7, 7), (8, 2), (9, -1), (9, 0x1000000)):
            values = valid.copy()
            values[index] = value
            run(values, success=False)
            assert not output.exists()
        for values in (valid[:-1], valid + [0]):
            run(values, success=False)
            assert not output.exists()
        run(valid)
        saved = output.read_bytes()
        run(valid, success=False)
        assert output.read_bytes() == saved
        output.unlink()
        frame = work / "frame-000002.png"
        original = frame.read_bytes()
        frame.unlink()
        frame.symlink_to(work / "frame-000001.png")
        manifest.write_text("\n".join(map(str, valid)) + "\n")
        result = subprocess.run([tool, manifest, work, manifest.name, output.name], cwd=work, capture_output=True)
        assert result.returncode != 0 and not output.exists()
        frame.unlink()
        frame.write_bytes(original)
        print("WebP animation writer checks passed.")


if __name__ == "__main__":
    main()
