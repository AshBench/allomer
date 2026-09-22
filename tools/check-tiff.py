#!/usr/bin/env python3
"""Check TIFF compression with independent Pillow and XML readers."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import platform
import random
import statistics
import struct
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zlib

from PIL import Image, ImageChops, ImageCms, ImageDraw, ImageStat, TiffImagePlugin

ROOT = Path(__file__).resolve().parent.parent
MODES = {"auto": 1, "none": 1, "lzw": 5, "deflate": 8, "jpeg": 7}


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def packet(value):
    return value if isinstance(value, bytes) else value[0]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=ROOT / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=ROOT / ".tools/bin")
    parser.add_argument("--benchmark", action="store_true")
    parser.add_argument("--benchmark-only", action="store_true")
    parser.add_argument("--report", type=Path, default=ROOT / "research/tiff-compression-performance.json")
    args = parser.parse_args()
    command, tools = args.command.resolve(), args.tools.resolve()
    environment = {"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools)}
    with tempfile.TemporaryDirectory(prefix="TIFF café, ") as temporary:
        work = Path(temporary)

        def convert(source, output, mode="jpeg", quality=0.85, preserve=True, measured=False, succeeds=True):
            settings = work / "options.json"
            settings.write_text(json.dumps({"tiffCompression": mode, "tiffJPEGQuality": quality, "preserveMetadata": preserve}))
            before = digest(source)
            arguments = [command, "convert", source, output, "--image-options", settings]
            if measured:
                arguments = ["/usr/bin/time", "-l", *arguments]
            result = subprocess.run(arguments, cwd=work, env=environment, capture_output=True, text=True)
            assert (result.returncode == 0) == succeeds, (source.name, mode, result.stderr)
            assert digest(source) == before, "Source changed"
            assert not list(work.glob(".allomer-*")), "Private output remains"
            if not succeeds:
                assert not output.exists()
            return result

        if not args.benchmark_only:
            rgb = Image.frombytes("RGB", (192, 128), random.Random(831).randbytes(192 * 128 * 3))
            alpha = rgb.convert("RGBA")
            alpha.putalpha(Image.frombytes("L", rgb.size, random.Random(832).randbytes(192 * 128)))
            gray16 = Image.frombytes("I;16", rgb.size, random.Random(833).randbytes(192 * 128 * 2))
            pictures = [rgb, alpha, rgb.convert("L"), alpha.convert("LA"), gray16, rgb.convert("CMYK"), rgb.quantize(colors=32)]
            for index, picture in enumerate(pictures):
                source = work / f"source-{index}.tiff"
                picture.save(source, compression="raw")
                baseline, baseline_profile = None, None
                for mode, code in MODES.items():
                    output = work / f"result-{index}-{mode}.tiff"
                    convert(source, output, mode)
                    with Image.open(output) as decoded:
                        decoded.load()
                        assert decoded.size == picture.size and decoded.tag_v2[259] == code
                        pixels = list(decoded.get_flattened_data())
                        if mode == "auto":
                            baseline, baseline_profile = pixels, decoded.info.get("icc_profile")
                        elif mode != "jpeg":
                            assert pixels == baseline, (picture.mode, mode)
                        else:
                            assert set(decoded.tag_v2[258]) == {8}, decoded.tag_v2[258]
                            if picture.mode in ("RGBA", "LA"):
                                assert decoded.mode == picture.mode
                        if picture.mode in ("RGB", "L", "CMYK", "I;16") and mode != "jpeg":
                            assert pixels == list(picture.get_flattened_data()), (picture.mode, mode)
                        if picture.mode != "P":
                            assert decoded.info.get("icc_profile") == baseline_profile, (picture.mode, mode)

            quality_source = work / "quality.png"
            rgb.save(quality_source)
            sizes, errors = [], []
            for quality in (0, 0.25, 0.5, 0.85, 1):
                output = work / f"quality-{quality}.tiff"
                convert(quality_source, output, quality=quality)
                with Image.open(output) as image:
                    errors.append(sum(ImageStat.Stat(ImageChops.difference(rgb, image.convert("RGB"))).mean))
                    sizes.append(sum(image.tag_v2[279]))
            assert sizes == sorted(sizes) and len(set(sizes)) == len(sizes), sizes
            assert errors[0] > errors[-1] and errors[-1] < 3, errors
            for quality in (-0.1, 1.1):
                convert(quality_source, work / f"invalid-{quality}.tiff", quality=quality, succeeds=False)

            def chunk(kind, payload):
                return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))

            rgba16 = work / "rgba16.png"
            rows = bytearray()
            for y in range(64):
                rows.append(0)
                for x in range(96):
                    rows.extend(struct.pack(">HHHH", x * 689, y * 1040, 20000, x * 689))
            rgba16.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 96, 64, 16, 6, 0, 0, 0))
                               + chunk(b"sRGB", b"\0") + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
            output = work / "rgba16.tiff"
            convert(rgba16, output, quality=1)
            with Image.open(rgba16) as before, Image.open(output) as after:
                assert after.mode == "RGBA" and set(after.tag_v2[258]) == {8}
                for color in ("black", "white"):
                    background = Image.new("RGBA", before.size, color)
                    expected = Image.alpha_composite(background, before.convert("RGBA")).convert("RGB")
                    actual = Image.alpha_composite(background, after.convert("RGBA")).convert("RGB")
                    assert max(ImageStat.Stat(ImageChops.difference(expected, actual)).mean) < 3

            source = work / "pages.tiff"
            profile = ImageCms.ImageCmsProfile(ImageCms.createProfile("sRGB")).tobytes()
            with TiffImagePlugin.AppendingTiffWriter(source, new=True) as writer:
                for index in range(8):
                    picture = Image.new("RGB", (120 + index * 8, 80 + index * 4), (20 + index * 20, 60, 180))
                    ImageDraw.Draw(picture).rectangle((0, 0, 30, 20), fill=(230, 160, 40))
                    xmp = ('<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
                           f'<rdf:Description rdf:about="" xmlns:check="urn:conversion-fixture"><check:Note>Page {index}</check:Note>'
                           '</rdf:Description></rdf:RDF></x:xmpmeta>').encode()
                    picture.save(writer, format="TIFF", compression="raw", dpi=(144, 144), icc_profile=profile,
                                 tiffinfo={274: index + 1, 270: f"Caption {index}", 700: xmp})
                    writer.newFrame()
            for mode, code in MODES.items():
                for preserve in (True, False):
                    output = work / f"pages-{mode}-{preserve}.tiff"
                    convert(source, output, mode, preserve=preserve)
                    with Image.open(source) as before, Image.open(output) as after:
                        assert after.n_frames == 8
                        for index in range(8):
                            before.seek(index)
                            after.seek(index)
                            assert after.tag_v2[259] == code and after.tag_v2.get(274, 1) == index + 1, (mode, index)
                            expected, actual = before.convert("RGB"), after.convert("RGB")
                            assert expected.size == actual.size
                            assert after.info["dpi"] == (144, 144)
                            assert after.info.get("icc_profile") == profile
                            delta = ImageChops.difference(expected, actual)
                            if mode != "jpeg":
                                assert delta.getbbox() is None, (mode, index)
                            else:
                                assert max(ImageStat.Stat(delta).mean) < 3, index
                            if preserve:
                                assert after.tag_v2[270] == f"Caption {index}"
                                xml = ET.fromstring(packet(after.tag_v2[700]))
                                assert xml.find(".//{urn:conversion-fixture}Note").text == f"Page {index}"
                            else:
                                assert 270 not in after.tag_v2 and 700 not in after.tag_v2
            old = digest(output)
            result = subprocess.run([command, "convert", source, output], cwd=work, env=environment, capture_output=True)
            assert result.returncode and digest(output) == old

            def metadata(path, page=0):
                with Image.open(path) as image:
                    image.seek(page)
                    exif = image.getexif()
                    fields = dict(exif.get_ifd(34665))
                    interop = exif.get_ifd(40965) if 40965 in fields else {}
                    fields.pop(40965, None)  # The directory address changes.
                    return fields, exif.get_ifd(34853), interop

            def equal_fields(actual, expected):
                for tag, value in expected.items():
                    assert tag in actual, (tag, actual)
                    left, right = actual[tag], value
                    if isinstance(right, dict):
                        equal_fields(left, right)
                    elif isinstance(right, (bytes, str)):
                        assert left == right, (tag, left, right)
                    else:
                        a = left if isinstance(left, tuple) else (left,)
                        b = right if isinstance(right, tuple) else (right,)
                        assert len(a) == len(b) and all(math.isclose(float(x), float(y), rel_tol=1e-6, abs_tol=1e-8)
                                                       for x, y in zip(a, b)), (tag, left, right)

            def copy_tiff(inputs, output, compression="jpeg:r:85", succeeds=True):
                result = subprocess.run([tools / "tiffcp", "-c", compression, "-r", "128",
                                         *[path.name for path in inputs], output.name],
                                        cwd=work, env=environment, capture_output=True)
                assert (result.returncode == 0) == succeeds, result.stderr

            fixtures = []
            for index in range(2):
                path = work / f"camera-{index}.tiff"
                rational = TiffImagePlugin.IFDRational
                exif = {36867: f"2024:03:0{index + 4} 05:06:07", 33434: rational(1, 125),
                        34855: (100, 200), 37385: 1, 40960: b"0100", 37380: rational(-1, 3),
                        40965: {1: "R98", 2: b"0100"}}
                gps = {0: b"\x02\x03\x00\x00", 1: "N", 2: (39, 45, rational(5, 2)),
                       3: "W", 4: (86, 9, 30), 5: b"\x00", 6: rational(250 + index, 1),
                       7: (12, 34, rational(5678, 100)), 29: "2024:03:04"}
                rgb.save(path, tiffinfo={34665: exif, 34853: gps})
                fixtures.append(path)
            combined = work / "camera-pages.tiff"
            copy_tiff(fixtures, combined, "lzw")
            for index, fixture in enumerate(fixtures):
                for actual, expected in zip(metadata(combined, index), metadata(fixture)):
                    equal_fields(actual, expected)

            # Removing the metadata links gives an independent JPEG payload control.
            control_source = work / "camera-without-links.tiff"
            data = bytearray(fixtures[0].read_bytes())
            endian = "<" if data[:2] == b"II" else ">"
            root = struct.unpack_from(endian + "I", data, 4)[0]
            exif_offset = None
            for entry in range(struct.unpack_from(endian + "H", data, root)[0]):
                position = root + 2 + entry * 12
                tag = struct.unpack_from(endian + "H", data, position)[0]
                if tag == 34665:
                    exif_offset = struct.unpack_from(endian + "I", data, position + 8)[0]
                if tag in (34665, 34853):
                    struct.pack_into(endian + "H", data, position, 65000 + (tag == 34853))
            control_source.write_bytes(data)
            control, copied = work / "camera-control.tiff", work / "camera-copied.tiff"
            copy_tiff([control_source], control)
            copy_tiff([fixtures[0]], copied)

            def jpeg_payload(path):
                data = path.read_bytes()
                with Image.open(path) as image:
                    return image.tag_v2.get(347), tuple(data[start:start + size]
                        for start, size in zip(image.tag_v2[273], image.tag_v2[279]))

            assert jpeg_payload(copied) == jpeg_payload(control), "Metadata changed JPEG payload"
            cyclic = bytearray(fixtures[0].read_bytes())
            for entry in range(struct.unpack_from(endian + "H", cyclic, exif_offset)[0]):
                position = exif_offset + 2 + entry * 12
                if struct.unpack_from(endian + "H", cyclic, position)[0] == 40965:
                    struct.pack_into(endian + "I", cyclic, position + 8, exif_offset)
                    break
            bad = work / "camera-cycle.tiff"
            bad.write_bytes(cyclic)
            copy_tiff([bad], work / "camera-cycle-result.tiff", succeeds=False)

            native = work / "camera-native.tiff"
            convert(combined, native, "auto")
            for mode in MODES:
                for preserve in (True, False):
                    output = work / f"camera-engine-{mode}-{preserve}.tiff"
                    convert(combined, output, mode, preserve=preserve)
                    for index in range(2):
                        actual = metadata(output, index)
                        if preserve:
                            expected = metadata(native, index)
                            for a, b in zip(actual, expected):
                                equal_fields(a, b)
                            assert actual[0][36867] == f"2024:03:0{index + 4} 05:06:07"
                            assert actual[1][6] == 250 + index
                        else:
                            assert 36867 not in actual[0] and not actual[1] and not actual[2]
            # The bundled launcher must deny a second file outside its allowed input and work folder.
            restricted = work / "restricted"
            restricted.mkdir()
            other = work / "source-0.tiff"
            control = subprocess.run([tools / "tiffcp", "-c", "jpeg:r:85", "-r", "128", other.name, "control.tiff"],
                                     cwd=work, env=environment, capture_output=True)
            assert control.returncode == 0, control.stderr
            result = subprocess.run([tools / "tiffguard", source, restricted, "-c", "jpeg:r:85", "-r", "128", "../" + other.name, "denied.tiff"],
                                    cwd=work, env=environment, capture_output=True)
            assert result.returncode, "The TIFF launcher read an unrelated file"
            print("TIFF modes, JPEG quality, alpha, 16-bit input, CMYK, palettes, eight orientations, page metadata, profiles, removal, source preservation, and sandbox checks passed.")

        if args.benchmark or args.benchmark_only:
            workloads = []
            for texture, count in (("noise", 1), ("noise", 12), ("flat", 1), ("flat", 12)):
                source = work / f"{texture}-{count}.tiff"
                generator = random.Random(834)
                with TiffImagePlugin.AppendingTiffWriter(source, new=True) as writer:
                    for index in range(count):
                        if texture == "noise":
                            image = Image.frombytes("RGB", (1024, 1024), generator.randbytes(1024 * 1024 * 3))
                        else:
                            image = Image.new("RGB", (1024, 1024), (40 + index * 8, 80, 180))
                            ImageDraw.Draw(image).rectangle((80, 120, 900, 250 + index * 8), fill=(220, 160, 40))
                        image.save(writer, format="TIFF", compression="raw", dpi=(144, 144))
                        writer.newFrame()
                for mode in ("none", "lzw", "deflate", "jpeg"):
                    samples = []
                    for run in range(3):
                        output = work / f"{texture}-{count}-{mode}-{run}.tiff"
                        result = convert(source, output, mode, measured=True)
                        lines = result.stderr.splitlines()
                        seconds = float(next(line for line in lines if " real " in line).split()[0])
                        resident = int(next(line for line in lines if "maximum resident set size" in line).split()[0])
                        with Image.open(output) as image:
                            assert image.n_frames == count
                            for index in range(count):
                                image.seek(index)
                                image.load()
                                assert image.size == (1024, 1024) and image.tag_v2[259] == MODES[mode]
                        samples.append({"seconds": seconds, "resident_bytes": resident, "output_bytes": output.stat().st_size})
                        output.unlink()
                    workloads.append({"texture": texture, "pages": count, "compression": mode, "jpeg_quality": 0.85,
                                      "input_bytes": source.stat().st_size, "input_sha256": digest(source), "runs": samples,
                                      "median_seconds": statistics.median(s["seconds"] for s in samples),
                                      "median_resident_bytes": statistics.median(s["resident_bytes"] for s in samples)})
            report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                      "architecture": platform.machine(), "command_sha256": digest(command),
                      "helpers": {name: digest(tools / name) for name in ("tiffcp", "tiffguard")},
                      "scope": "Three complete conversions of one or twelve distinct 1024-square RGB noise or flat-color pages. RSS can include a child helper peak; it is not aggregate simultaneous memory. GUI excluded.",
                      "workloads": workloads}
            args.report.write_text(json.dumps(report, indent=2) + "\n")
            print(f"TIFF benchmark written to {args.report}")


if __name__ == "__main__":
    main()
