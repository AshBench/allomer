#!/usr/bin/env python3
"""Check original Icon Composer artwork fixtures with independent pixel reads."""
import argparse
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import json
import platform
import random
import re
import statistics
from pathlib import Path
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageOps

ROOT = Path(__file__).resolve().parent.parent


def fingerprint(directory):
    return {str(path.relative_to(directory)): ("link", str(path.readlink())) if path.is_symlink()
            else ("file", hashlib.sha256(path.read_bytes()).hexdigest()) if path.is_file() else ("directory", "")
            for path in directory.rglob("*")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=ROOT / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=ROOT / ".tools/bin")
    parser.add_argument("--benchmark-only", action="store_true")
    parser.add_argument("--report", type=Path, default=ROOT / "research/icon-project-performance.json")
    args = parser.parse_args()
    command, tools = args.command.resolve(), args.tools.resolve()
    with tempfile.TemporaryDirectory(prefix="icon café 100%, ") as temporary:
        work = Path(temporary)
        source = work / "Artwork.icon"
        assets = source / "Assets"
        assets.mkdir(parents=True)
        for name, color in (("Red.png", (220, 40, 20, 255)), ("Blue.png", (20, 40, 230, 255))):
            image = Image.new("RGBA", (1024, 1024))
            ImageDraw.Draw(image).rectangle((256, 256, 767, 767), fill=color)
            image.save(assets / name)
        (assets / "Shape.svg").write_text('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024"><rect x="256" y="256" width="512" height="512" fill="#dc2814"/></svg>')
        sequence = 0

        def convert(document, extension="png", success=True, raw=None, timing=None, image_options=None):
            nonlocal sequence
            sequence += 1
            (source / "icon.json").write_text(raw if raw is not None else json.dumps(document))
            original = fingerprint(source)
            output = work / f"result-{sequence}.{extension}"
            invocation = [command, "convert", source, output]
            if image_options is not None:
                options = work / "image-options.json"
                options.write_text(json.dumps(image_options))
                invocation += ["--image-options", options]
            if timing is not None: invocation = ["/usr/bin/time", "-l", *invocation]
            result = subprocess.run(invocation, env={"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools)},
                capture_output=True, text=True, timeout=120)
            assert (result.returncode == 0) == success, (extension, result.stderr)
            assert fingerprint(source) == original, "The source package changed"
            assert not list(work.glob(".allomer-*")), "Private conversion files remain"
            assert output.exists() == success, "A failed conversion published output"
            if timing is not None:
                timing.update(seconds=float(re.search(r"([\d.]+)\s+real", result.stderr)[1]),
                    resident_bytes=int(re.search(r"(\d+)\s+maximum resident set size", result.stderr)[1]),
                    output_bytes=output.stat().st_size)
            if success:
                before = output.read_bytes()
                second = subprocess.run([command, "convert", source, output], env={"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools)},
                    capture_output=True, text=True, timeout=120)
                assert second.returncode != 0 and output.read_bytes() == before, "An existing output was replaced"
            return output

        base = {"groups": [{"layers": [{"image-name": "Red.png"}]}]}
        if args.benchmark_only:
            noise = Image.frombytes("RGB", (1024, 1024), random.Random(197).randbytes(1024 * 1024 * 3))
            noise.save(assets / "Noise.png", compress_level=1)
            vectors = []
            for index in range(4):
                name = f"Vector-{index}.svg"
                (assets / name).write_text(f'<svg xmlns="http://www.w3.org/2000/svg" width="256" height="256"><circle cx="128" cy="128" r="110" fill="rgb({40 + index * 50},100,200)"/></svg>')
                vectors.append({"image-name": name, "position": {"translation-in-points": [-192 + index * 128, 0]}})
            repeated = [{"image-name": "Red.png", "opacity": 0.05,
                "position": {"translation-in-points": [-64 + index % 8 * 16, -64 + index // 8 * 8]}} for index in range(128)]
            workloads = {"one-raster": base, "four-vectors": {"groups": [{"layers": vectors}]},
                "128-repeated-layers": {"groups": [{"layers": repeated}]},
                "one-megapixel-noise": {"groups": [{"layers": [{"image-name": "Noise.png"}]}]}}
            cases = []
            for name, document in workloads.items():
                runs = []
                for _ in range(3):
                    timing = {}
                    output = convert(document, timing=timing)
                    assert Image.open(output).size == (1024, 1024)
                    runs.append(timing)
                case = {"case": name, "runs": runs, "input_files": fingerprint(source),
                    "median_seconds": statistics.median(run["seconds"] for run in runs),
                    "median_resident_bytes": statistics.median(run["resident_bytes"] for run in runs)}
                if name == "one-megapixel-noise":
                    from PIL import ImageChops, ImageStat
                    case["rms_rgb_error"] = ImageStat.Stat(ImageChops.difference(noise, Image.open(output).convert("RGB"))).rms
                cases.append(case)
                print(name, case["median_seconds"], case["median_resident_bytes"], flush=True)
            digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
            args.report.write_text(json.dumps({"recorded_at_utc": datetime.now(timezone.utc).isoformat(),
                "macos": platform.mac_ver()[0], "chip": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
                "command_sha256": digest(command), "helper_sha256": {name: digest(tools / name) for name in ("webguard", "webconvert")},
                "cases": cases, "scope": "Three complete packaged command conversions per original workload. Includes package checks, preparation, rendering, and publication. RSS may include a child helper peak; it excludes aggregate simultaneous processes and may omit separate WebKit service memory. GUI excluded. Pixel reads and overwrite checks are untimed."}, indent=2) + "\n")
            return
        for extension in ("png", "jpg", "bmp", "tiff", "gif", "webp", "avif", "heic"):
            output = convert(base, extension)
            if extension == "heic":
                restored = work / "heic-roundtrip.png"
                subprocess.run([command, "convert", output, restored], env={"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools)},
                    capture_output=True, check=True, timeout=120)
                output = restored
            pixels = Image.open(output).convert("RGBA")
            assert pixels.size == (1024, 1024)
            assert max(abs(a-b) for a,b in zip(pixels.getpixel((512, 512))[:3], (220, 40, 20))) <= 8, extension
            if extension in ("png", "tiff", "gif", "webp"):
                assert pixels.getchannel("A").getbbox() == (256, 256, 768, 768), extension
        background = Image.open(convert(base, "jpg", image_options={"quality": 1, "alphaHandling": "custom", "alphaCustomColor": "#336699"})).convert("RGB")
        assert max(abs(a-b) for a,b in zip(background.getpixel((0, 0)), (51, 102, 153))) <= 2

        transformed = deepcopy(base)
        transformed["groups"][0]["layers"][0]["position"] = {"scale": 0.5, "translation-in-points": [120, 80]}
        pixels = Image.open(convert(transformed)).convert("RGBA")
        alpha = pixels.getchannel("A")
        assert alpha.point(lambda value: 255 if value >= 128 else 0).getbbox() == (504, 464, 760, 720)
        left, top, right, bottom = alpha.getbbox()
        assert 503 <= left <= 504 and 463 <= top <= 464 and 760 <= right <= 761 and 720 <= bottom <= 721
        vector = deepcopy(base)
        vector["groups"][0]["layers"][0]["image-name"] = "Shape.svg"
        pixels = Image.open(convert(vector)).convert("RGBA")
        assert pixels.getchannel("A").getbbox() == (256, 256, 768, 768)
        assert pixels.getpixel((512, 512)) == (220, 40, 20, 255)
        oriented = Image.new("RGBA", (40, 20), (220, 40, 20, 255))
        ImageDraw.Draw(oriented).rectangle((20, 0, 39, 19), fill=(20, 40, 230, 255))
        exif = Image.Exif(); exif[274] = 6
        oriented.save(assets / "Oriented.png", exif=exif)
        rotated = deepcopy(base)
        rotated["groups"][0]["layers"][0]["image-name"] = "Oriented.png"
        pixels = Image.open(convert(rotated)).convert("RGBA")
        expected = ImageOps.exif_transpose(Image.open(assets / "Oriented.png")).convert("RGBA")
        assert pixels.crop((502, 492, 522, 532)).tobytes() == expected.tobytes()
        for groups in ([{"layers": [{"image-name": "Red.png"}, {"image-name": "Blue.png"}]}],
                       [{"layers": [{"image-name": "Red.png"}]}, {"layers": [{"image-name": "Blue.png"}]}]):
            assert Image.open(convert({"groups": groups})).convert("RGBA").getpixel((512, 512)) == (220, 40, 20, 255)
        opacity = deepcopy(base)
        opacity["groups"][0]["layers"][0].update(opacity=0.9, **{"opacity-specializations": [{"value": 0.25}, {"appearance": "dark", "value": 0.8}]})
        assert Image.open(convert(opacity)).convert("RGBA").getpixel((512, 512))[3] == 64
        group = deepcopy(base)
        group["groups"][0].update(opacity=0.5)
        group["groups"][0]["layers"].append({"image-name": "Blue.png"})
        assert Image.open(convert(group)).convert("RGBA").getpixel((512, 512))[3] == 128
        hidden = deepcopy(base)
        hidden["groups"][0]["layers"][0].update(hidden=True, **{"image-name": "missing.png"})
        assert Image.open(convert(hidden)).convert("RGBA").getchannel("A").getbbox() is None
        for invalid in ({}, {"groups": None}, {"groups": [{"layers": [{"image-name": "../outside.png"}]}]},
                        {"groups": [{"layers": [{"image-name": "Red.png", "opacity": 1.1}]}]},
                        {"groups": [{"layers": [{"image-name": "Red.png", "position": {"translation-in-points": [1, 2, 3]}}]}]}):
            convert(invalid, success=False)
        convert(base, success=False, raw="{")
        link = assets / "Link.png"
        link.symlink_to(assets / "Red.png")
        convert(base, success=False)
        link.unlink()
        frames = [Image.new("RGB", (16, 16), color) for color in ("red", "blue")]
        frames[0].save(assets / "Animation.gif", save_all=True, append_images=frames[1:], duration=100, loop=0)
        convert({"groups": [{"layers": [{"image-name": "Animation.gif"}]}]}, success=False)
        print("Icon artwork formats, SVG assets, transforms, order, opacity, invalid input, source preservation, and cleanup checks passed.")


if __name__ == "__main__":
    main()
