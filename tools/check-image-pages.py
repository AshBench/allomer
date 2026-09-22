#!/usr/bin/env python3
"""Check native image pages with independent Pillow and PDFium readers."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import random
import statistics
import struct
import subprocess
import tempfile
import zlib

from PIL import Image, ImageChops, ImageDraw, ImageStat, TiffImagePlugin
import pypdfium2 as pdfium
from pypdf import PdfReader

ROOT = Path(__file__).resolve().parent.parent


def digest(file):
    with file.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=ROOT / ".build/debug/allomer")
    parser.add_argument("--benchmark", action="store_true")
    parser.add_argument("--report", type=Path, default=ROOT / "research/image-page-performance.json")
    args = parser.parse_args()
    command = args.command.resolve()
    # The command runs from a temporary directory, so a development build needs the tools named.
    # The packaged command must find tools inside the app, without a development override.
    environment = {"PATH": "/usr/bin:/bin"}
    if ".app/" not in str(command):
        environment["ALLOMER_TOOLS_DIR"] = str(ROOT / ".tools/bin")
    with tempfile.TemporaryDirectory(prefix="image-pages-") as temporary:
        work = Path(temporary)

        def convert(source, destination, succeeds=True, options=None):
            before = digest(source)
            arguments = [command, "convert", source, destination]
            if options is not None:
                settings = work / "image-options.json"
                settings.write_text(json.dumps(options))
                arguments += ["--image-options", settings]
            result = subprocess.run(arguments, cwd=work,
                                    env=environment, capture_output=True, text=True)
            assert digest(source) == before, "Source changed"
            assert (result.returncode == 0) == succeeds, result.stderr
            if not succeeds:
                assert not destination.exists()
            assert not list(work.glob(".allomer-*")), "Temporary conversion files remain"
            return result

        source = work / "pages café.tiff"
        expected = []
        transforms = [None, Image.Transpose.FLIP_LEFT_RIGHT, Image.Transpose.ROTATE_180,
                      Image.Transpose.FLIP_TOP_BOTTOM, Image.Transpose.TRANSPOSE,
                      Image.Transpose.ROTATE_270, Image.Transpose.TRANSVERSE, Image.Transpose.ROTATE_90]
        with TiffImagePlugin.AppendingTiffWriter(source, new=True) as writer:
            for index, transform in enumerate(transforms):
                width, height = 120 + index * 8, 80 + index * 4
                image = Image.new("RGB", (width, height), (30 + index * 20, 60, 180))
                draw = ImageDraw.Draw(image)
                draw.rectangle((0, 0, width // 3, height // 3), fill=(240, 180, 20))
                draw.rectangle((width // 2, height // 2, width - 1, height - 1), fill=(20, 190, 80))
                image.save(writer, format="TIFF", dpi=(144, 144), compression="tiff_lzw",
                           tiffinfo={274: index + 1, 270: "Original caption"})
                writer.newFrame()
                expected.append(image.transpose(transform) if transform is not None else image)

        def check_pdf(path, images, scale):
            with pdfium.PdfDocument(path) as document:
                assert len(document) == len(images)
                for index, reference in enumerate(images):
                    page = document[index]
                    try:
                        width, height = page.get_size()
                        assert abs(width * scale - reference.width) < .02
                        assert abs(height * scale - reference.height) < .02
                        bitmap = page.render(scale=scale)
                        try:
                            actual = bitmap.to_pil().convert("RGB")
                            assert actual.size == reference.size
                            delta = ImageChops.difference(reference.convert("RGB"), actual)
                            # ImageIO can embed lossy JPEG color data in PDF output.
                            assert max(ImageStat.Stat(delta).mean) < 5, (index, ImageStat.Stat(delta).mean)
                        finally:
                            bitmap.close()
                    finally:
                        page.close()

        pdf = work / "pages.pdf"
        convert(source, pdf)
        check_pdf(pdf, expected, 2)
        copied = work / "copied.tiff"
        convert(source, copied)
        with Image.open(copied) as image:
            assert image.n_frames == len(expected)
            for index, reference in enumerate(expected):
                image.seek(index)
                actual = image.convert("RGB")  # Pillow applies TIFF orientation when loading pixels.
                assert actual.size == reference.size
                assert ImageChops.difference(actual, reference).getbbox() is None, index
                assert image.tag_v2[270] == "Original caption"

        single = work / "transparent.png"
        transparent = Image.new("RGBA", (120, 80), (200, 40, 80, 90))
        ImageDraw.Draw(transparent).rectangle((10, 10, 49, 39), fill=(20, 190, 80, 255))
        transparent.save(single)
        single_pdf = work / "single.pdf"
        convert(single, single_pdf)
        white = Image.new("RGBA", transparent.size, "white")
        check_pdf(single_pdf, [Image.alpha_composite(white, transparent).convert("RGB")], 1)

        # Independent readers check the compressed bytes and the resulting pixels.
        noise = Image.frombytes("RGB", (256, 256), random.Random(619).randbytes(256 * 256 * 3))
        quality_source = work / "quality.png"
        noise.save(quality_source, dpi=(72, 72))
        qualities, sizes, errors, streams = (0, 0.5, 0.85, 1), [], [], []
        for quality in qualities:
            output = work / f"quality-{quality}.pdf"
            convert(quality_source, output, options={"quality": quality})
            reader = PdfReader(output)
            objects = reader.pages[0]["/Resources"]["/XObject"].get_object()
            raster = next(value.get_object() for value in objects.values()
                          if value.get_object().get("/Subtype") == "/Image")
            # The native writer can choose Flate at quality 1 for some image types.
            assert any(codec in str(raster["/Filter"]) for codec in ("/DCTDecode", "/FlateDecode")), raster["/Filter"]
            streams.append(hashlib.sha256(raster._data).hexdigest())
            sizes.append(len(raster._data))
            with pdfium.PdfDocument(output) as document:
                page = document[0]
                bitmap = page.render(scale=1)
                try:
                    image = bitmap.to_pil().convert("RGB")
                    assert image.size == noise.size
                    errors.append(sum(ImageStat.Stat(ImageChops.difference(noise, image)).mean))
                finally:
                    bitmap.close()
                    page.close()
        assert len(set(streams)) == len(qualities), streams
        assert sizes == sorted(sizes) and sizes[0] < sizes[-1], sizes
        assert errors[0] > errors[-1], errors

        original_output = digest(pdf)
        result = subprocess.run([command, "convert", source, pdf], capture_output=True)
        assert result.returncode and digest(pdf) == original_output

        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

        oversized = work / "oversized.png"
        oversized.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 100000, 100000, 8, 2, 0, 0, 0))
                              + chunk(b"IDAT", zlib.compress(b"\0\0\0\0")) + chunk(b"IEND", b""))
        result = convert(oversized, work / "too-large.jpg", succeeds=False)
        assert "32 million pixels" in result.stderr, result.stderr
        animated = work / "animated.gif"
        expected[0].save(animated, save_all=True, append_images=[expected[1].resize(expected[0].size)], duration=100, loop=0)
        convert(animated, work / "lost-frames.pdf", succeeds=False)

        if args.benchmark:
            reports = []
            for count in (1, 12):
                fixture = work / f"noise-{count}.tiff"
                generator = random.Random(613)
                with TiffImagePlugin.AppendingTiffWriter(fixture, new=True) as writer:
                    for _ in range(count):
                        picture = Image.frombytes("RGB", (1024, 1024), generator.randbytes(1024 * 1024 * 3))
                        picture.save(writer, format="TIFF", dpi=(144, 144))
                        writer.newFrame()
                samples = []
                for run in range(3):
                    output = work / f"noise-{count}-{run}.pdf"
                    result = subprocess.run(["/usr/bin/time", "-l", command, "convert", fixture, output],
                                            cwd=work, env=environment, capture_output=True, text=True)
                    assert result.returncode == 0, result.stderr
                    lines = result.stderr.splitlines()
                    seconds = float(next(line for line in lines if " real " in line).split()[0])
                    resident = int(next(line for line in lines if "maximum resident set size" in line).split()[0])
                    with pdfium.PdfDocument(output) as document:
                        assert len(document) == count
                    samples.append({"seconds": seconds, "resident_bytes": resident, "output_bytes": output.stat().st_size})
                    output.unlink()
                reports.append({"pages": count, "input_bytes": fixture.stat().st_size, "input_sha256": digest(fixture),
                                "median_seconds": statistics.median(item["seconds"] for item in samples),
                                "median_resident_bytes": statistics.median(item["resident_bytes"] for item in samples),
                                "runs": samples})
            report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(),
                      "macos": platform.mac_ver()[0], "architecture": platform.machine(),
                      "command_sha256": digest(command), "workload": "One or twelve TIFF pages with distinct deterministic 1024-square RGB noise at 144 DPI.",
                      "scope": "Three complete CLI conversions. Native ImageIO runs in this process. The GUI is excluded. No cross-app comparison.", "workloads": reports}
            args.report.write_text(json.dumps(report, indent=2) + "\n")
        print("Image PDF quality, eight TIFF orientations, page order, pixels, transparency, limits, source preservation, and cleanup checks passed.")


if __name__ == "__main__":
    main()
