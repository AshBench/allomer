#!/usr/bin/env python3
"""Check JPEG background colors with Pillow and measure complete conversions."""
import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import platform
import random
import statistics
import subprocess
import tempfile

from PIL import Image, ImageChops, ImageCms, ImageStat

ROOT = Path(__file__).resolve().parent.parent


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=ROOT / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=ROOT / ".tools/bin")
    parser.add_argument("--benchmark-only", action="store_true")
    parser.add_argument("--report", type=Path, default=ROOT / "research/image-background-performance.json")
    args = parser.parse_args()
    command = args.command.resolve()
    environment = {"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(args.tools.resolve())}
    with tempfile.TemporaryDirectory(prefix="Image background café, ") as temporary:
        work = Path(temporary)

        def convert(source, output, mode, color="#336699", succeeds=True, measured=False, quality=1):
            settings = work / "options.json"
            settings.write_text(json.dumps({"alphaHandling": mode, "alphaCustomColor": color, "quality": quality}))
            before = digest(source)
            arguments = [command, "convert", source, output, "--image-options", settings]
            if measured:
                arguments = ["/usr/bin/time", "-l", *arguments]
            result = subprocess.run(arguments, cwd=work, env=environment, capture_output=True, text=True)
            assert (result.returncode == 0) == succeeds, (output.name, result.stderr)
            assert digest(source) == before and not list(work.glob(".allomer-*"))
            if not succeeds:
                assert not output.exists()
            return result

        if args.benchmark_only:
            source = work / "alpha-noise.png"
            picture = Image.frombytes("RGBA", (6000, 4000), random.Random(935).randbytes(6000 * 4000 * 4))
            picture.save(source)
            del picture
            samples = []
            for index in range(3):
                output = work / f"measured-{index}.jpg"
                result = convert(source, output, "white", measured=True)
                lines = result.stderr.splitlines()
                with Image.open(output) as image:
                    image.load()
                    assert image.size == (6000, 4000) and image.mode == "RGB"
                samples.append({"seconds": float(next(line for line in lines if " real " in line).split()[0]),
                    "resident_bytes": int(next(line for line in lines if "maximum resident set size" in line).split()[0]),
                    "output_bytes": output.stat().st_size, "output_sha256": digest(output)})
                output.unlink()
            report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                "architecture": platform.machine(), "command_sha256": digest(command),
                "scope": "Three complete conversions of the same 24-megapixel RGBA noise PNG to JPEG at quality 100 with white background. Source generation and verification are not timed. RSS is command process memory; GUI excluded.",
                "input_bytes": source.stat().st_size, "input_sha256": digest(source), "runs": samples,
                "median_seconds": statistics.median(row["seconds"] for row in samples),
                "median_resident_bytes": statistics.median(row["resident_bytes"] for row in samples)}
            args.report.write_text(json.dumps(report, indent=2) + "\n")
            print(f"Background benchmark written to {args.report}")
            return

        picture = Image.new("RGBA", (256, 256), (220, 30, 60, 255))
        picture.paste((220, 30, 60, 0), (0, 0, 80, 256))
        picture.paste((220, 30, 60, 128), (80, 0, 176, 256))
        source = work / "source.png"
        picture.save(source)
        choices = {"preserve": (255, 255, 255), "white": (255, 255, 255),
                   "black": (0, 0, 0), "custom": (51, 102, 153)}
        for mode, background in choices.items():
            output = work / f"{mode}.jpg"
            convert(source, output, mode)
            expected = Image.alpha_composite(Image.new("RGBA", picture.size, background + (255,)), picture).convert("RGB")
            with Image.open(output) as actual:
                for x in (40, 128, 216):
                    assert max(abs(a - b) for a, b in zip(actual.getpixel((x, 128)), expected.getpixel((x, 128)))) <= 3
            for suffix in ("png", "tiff", "bmp", "gif", "ico", "avif", "webp"):
                output = work / f"{mode}.{suffix}"
                convert(source, output, mode)
                with Image.open(output) as actual:
                    rgba = actual.convert("RGBA")
                    if mode == "preserve":
                        rgba.save(work / f"baseline-{suffix}.png")
                    else:
                        with Image.open(work / f"baseline-{suffix}.png") as baseline:
                            assert ImageChops.difference(rgba, baseline).getbbox(alpha_only=False) is None, (mode, suffix)
        for index, color in enumerate(("336699", "#AaBbCc")):
            convert(source, work / f"valid-{index}.jpg", "custom", color)
        for index, color in enumerate(("", "#fff", "##FFFFFF", "+12345", "12345g", "ffffff\n", "#FFFFFFFF", "１２３４５６")):
            convert(source, work / f"invalid-{index}.jpg", "custom", color, succeeds=False)

        for label, variant in (("gray", picture.convert("LA")), ("palette", picture.quantize(colors=16))):
            variant.save(source)
            for mode, background in choices.items():
                output = work / f"{label}-{mode}.jpg"
                convert(source, output, mode)
                expected = Image.alpha_composite(Image.new("RGBA", picture.size, background + (255,)), variant.convert("RGBA")).convert("RGB")
                with Image.open(output) as actual:
                    actual = actual.convert("RGB")
                    for x in (40, 128, 216):
                        assert max(abs(a - b) for a, b in zip(actual.getpixel((x, 128)), expected.getpixel((x, 128)))) <= 3, (label, mode, x)

        # A tagged wide-gamut source must still interpret the chosen color as sRGB.
        p3 = Path("/System/Library/ColorSync/Profiles/Display P3.icc").read_bytes()
        picture.save(source, icc_profile=p3)
        output = work / "p3.jpg"
        convert(source, output, "custom")
        with Image.open(output) as actual:
            converted = ImageCms.profileToProfile(actual, io.BytesIO(actual.info["icc_profile"]),
                                                 ImageCms.createProfile("sRGB"), outputMode="RGB")
            assert max(abs(a - b) for a, b in zip(converted.getpixel((40, 128)), (51, 102, 153))) <= 3
        before = digest(output)
        result = subprocess.run([command, "convert", source, output], cwd=work, env=environment, capture_output=True)
        assert result.returncode and digest(output) == before

        noise = Image.frombytes("RGBA", (128, 128), random.Random(936).randbytes(128 * 128 * 4))
        noise.save(source)
        white = Image.new("RGBA", noise.size, "white")
        expected = Image.alpha_composite(white, noise).convert("RGB")
        errors, sizes, alpha_errors, alpha_max = [], [], [], []
        for quality in (0, 0.5, 1):
            output = work / f"avif-quality-{quality}.avif"
            convert(source, output, "preserve", quality=quality)
            sizes.append(output.stat().st_size)
            with Image.open(output) as actual:
                assert "A" in actual.getbands()
                rgba = actual.convert("RGBA")
                alpha_difference = ImageChops.difference(rgba.getchannel("A"), noise.getchannel("A"))
                alpha_errors.append(ImageStat.Stat(alpha_difference).mean[0])
                alpha_max.append(alpha_difference.getextrema()[1])
                flattened = Image.alpha_composite(white, rgba).convert("RGB")
                errors.append(sum(ImageStat.Stat(ImageChops.difference(expected, flattened)).mean))
        assert errors[0] > errors[-1] and sizes[0] < sizes[-1], (errors, sizes)
        # Native AVIF uses separate alpha encoding; image quality does not make it exact.
        assert max(alpha_errors) < 2, alpha_errors
        print(f"AVIF quality 0/50/100: RGB mean-error sums {errors}, alpha mean errors {alpha_errors}, alpha max errors {alpha_max}, bytes {sizes}.")
        print("JPEG backgrounds, partial alpha, color profiles, preserved alpha formats, invalid colors, source preservation, and overwrite checks passed.")


if __name__ == "__main__":
    main()
