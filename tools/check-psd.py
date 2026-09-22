#!/usr/bin/env python3
"""Check original PSD composite fixtures with independent compression and pixel readers."""
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
import struct
import subprocess
import sys
import tempfile
import zipfile

from PIL import Image, ImageCms

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=ROOT / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=ROOT / ".tools/bin")
    parser.add_argument("--oracle-path", type=Path)
    parser.add_argument("--benchmark-only", action="store_true")
    parser.add_argument("--report", type=Path, default=ROOT / "research/psd-performance.json")
    args = parser.parse_args()
    if args.oracle_path: sys.path.insert(0, str(args.oracle_path.resolve()))
    from psd_tools import PSDImage
    from psd_tools.compression import compress
    from psd_tools.constants import Compression
    command, tools = args.command.resolve(), args.tools.resolve()
    environment = {"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools)}

    def resource(identifier, data):
        return b"8BIM" + struct.pack(">H2sI", identifier, b"\0\0", len(data)) + data + b"\0" * (len(data) % 2)

    def psd(width, height, planes, depth, mode, compression, palette=b"", resources=b"", layer=False):
        layer_section = b""
        if layer:
            channel_data = [struct.pack(">H", 3) + compress(plane, Compression.ZIP_WITH_PREDICTION, width, height, depth) for plane in planes]
            ids = [0, 1, 2, -1] if len(planes) == 4 else list(range(len(planes)))
            record = struct.pack(">iiiiH", 0, 0, height, width, len(planes))
            record += b"".join(struct.pack(">hI", identifier, len(data)) for identifier, data in zip(ids, channel_data))
            extra = b"\0" * 8 + b"\x05Layer\0\0"
            record += b"8BIMnorm" + bytes([255, 0, 0, 0]) + struct.pack(">I", len(extra)) + extra
            info = struct.pack(">h", -1 if len(planes) == 4 else 1) + record + b"".join(channel_data)
            info += b"\0" * (len(info) % 2)
            layer_section = struct.pack(">I", len(info)) + info + b"\0" * 4
        header = b"8BPS" + struct.pack(">H6sHIIHH", 1, b"\0" * 6, len(planes), height, width, depth, mode)
        sections = b"".join(struct.pack(">I", len(data)) + data for data in (palette, resources, layer_section))
        raw = b"".join(planes)
        payload = compress(raw, Compression(compression), width, height * len(planes), depth)
        return header + sections + struct.pack(">H", compression) + payload

    with tempfile.TemporaryDirectory(prefix="PSD café 100%, ") as temporary:
        work = Path(temporary)
        sequence = 0

        def convert(source, extension="png", success=True, options=None, timing=None):
            nonlocal sequence
            sequence += 1
            output = work / f"result-{sequence}.{extension}"
            original = source.read_bytes()
            invocation = [command, "convert", source, output]
            if options is not None:
                settings = work / "options.json"; settings.write_text(json.dumps(options))
                invocation += ["--image-options", settings]
            if timing is not None: invocation = ["/usr/bin/time", "-l", *invocation]
            result = subprocess.run(invocation, env=environment, capture_output=True, text=True, timeout=120)
            assert (result.returncode == 0) == success, (source.name, extension, result.stderr)
            assert source.read_bytes() == original and output.exists() == success
            assert not list(work.glob(".allomer-*"))
            if timing is not None:
                timing.update(seconds=float(re.search(r"([\d.]+)\s+real", result.stderr)[1]),
                    resident_bytes=int(re.search(r"(\d+)\s+maximum resident set size", result.stderr)[1]),
                    output_bytes=output.stat().st_size)
            return output

        if args.benchmark_only:
            records=[]
            for name,width,height,depth in [("rgb8-noise",1024,1024,8),("rgb16-gradient",1024,1024,16),("rgb8-flat-24mp",6000,4000,8)]:
                rng=random.Random(173)
                planes=[rng.randbytes(width*height) for _ in range(3)] if name=="rgb8-noise" else [
                    b"".join(struct.pack(">H",(x*61+channel*1901)%65536) for x in range(width))*height for channel in range(3)] if depth==16 else [
                    bytes([value])*(width*height) for value in (30,100,200)]
                for compression in (0,1,2,3):
                    source=work/f"{name}-{compression}.psd"
                    source.write_bytes(psd(width,height,planes,depth,3,compression))
                    runs=[]
                    for _ in range(3):
                        timing={}; output=convert(source,timing=timing); runs.append(timing)
                        assert Image.open(output).size==(width,height)
                    record={"case":name,"compression":compression,"input_bytes":source.stat().st_size,
                        "input_sha256":hashlib.sha256(source.read_bytes()).hexdigest(),"runs":runs,
                        "median_seconds":statistics.median(run["seconds"] for run in runs),
                        "median_resident_bytes":statistics.median(run["resident_bytes"] for run in runs)}
                    records.append(record); print(name,compression,record["median_seconds"],record["median_resident_bytes"],flush=True)
            import importlib.metadata
            args.report.write_text(json.dumps({"recorded_at_utc":datetime.now(timezone.utc).isoformat(),
                "macos":platform.mac_ver()[0],"chip":subprocess.check_output(["sysctl","-n","machdep.cpu.brand_string"],text=True).strip(),
                "command_sha256":hashlib.sha256(command.read_bytes()).hexdigest(),
                "oracle":{name:importlib.metadata.version(name) for name in ("psd-tools","Pillow","numpy","attrs","typing_extensions")},
                "cases":records,"scope":"Three complete command conversions per original workload/compression. Includes PSD preparation, native image encoding, PNG recompression, validation, and publication. Source integrity reads warm the file cache. Python fixture/pixel work and GUI are excluded. RSS is per-process high-water memory, not aggregate simultaneous memory."},indent=2)+"\n")
            return

        cases = []
        for depth in (8, 16, 32):
            width, height = 257, 129
            rng = random.Random(173)
            planes = [rng.randbytes(width * height) if depth == 8 else
                b"".join(struct.pack(">H", rng.randrange(65536)) for _ in range(width * height)) if depth == 16 else
                b"".join(struct.pack(">f", rng.random()) for _ in range(width * height)) for _ in range(3)]
            cases.append((f"rgb-{depth}", width, height, planes, depth, 3, b"", b"", False))
        for name, mode, channels in (("gray", 1, 1), ("indexed", 2, 1), ("cmyk", 4, 4), ("lab", 9, 3)):
            width, height = 13, 7
            planes = [bytes((i * 37 + channel * 41) % 256 for i in range(width * height)) for channel in range(channels)]
            palette = bytes(i % 256 for i in range(768)) if mode == 2 else b""
            cases.append((name, width, height, planes, 8, mode, palette, b"", False))
        width, height = 16, 8
        cases.append(("bitmap", width, height, [bytes(i * 37 % 256 for i in range(width * height // 8))], 1, 0, b"", b"", False))
        p3 = Path("/System/Library/ColorSync/Profiles/Display P3.icc").read_bytes()
        resources = resource(1039, p3) + resource(4000, b"Original private fixture data\0" * 40_000)
        cases.append(("resources", 64, 32, [bytes([value]) * 2048 for value in (180, 100, 80)], 8, 3, b"", resources, False))
        planes = [bytes(255 if x < 32 else value for y in range(32) for x in range(64)) for value in (20, 40, 220)]
        planes.append(bytes(0 if x < 32 else 255 for y in range(32) for x in range(64)))
        cases.append(("layered-mask", 64, 32, planes, 8, 3, b"", b"", True))
        for name, width, height, planes, depth, mode, palette, resources, layer in cases:
            baseline = None
            compressions = (1, 0, 2) if depth == 1 else (0, 1, 2, 3)
            for compression in compressions:
                source = work / f"{name}-{compression}.psd"
                source.write_bytes(psd(width, height, planes, depth, mode, compression, palette, resources, layer))
                independent = PSDImage.open(source)
                assert independent._record.image_data.get_data(independent._record.header, split=False) == b"".join(planes)
                if layer:
                    assert len(independent) == 1 and independent[0].is_visible()
                    assert independent[0].topil().size == (width, height)
                output = convert(source)
                pixels = Image.open(output).convert("RGBA")
                assert pixels.size == (width, height)
                if baseline is None: baseline = pixels.tobytes()
                else: assert pixels.tobytes() == baseline, (name, compression, "Native sample baseline changed")
                if name == "rgb-8":
                    expected = bytes(value for pixel in zip(*planes) for value in (*pixel, 255))
                    assert pixels.tobytes() == expected
                if name == "layered-mask":
                    assert pixels.getpixel((16,16))[3] == 0 and pixels.getpixel((48,16)) == (20,40,220,255)
                if name == "resources":
                    profile = Image.open(output).info["icc_profile"]
                    srgb = ImageCms.createProfile("sRGB")
                    viewed = ImageCms.profileToProfile(pixels, ImageCms.ImageCmsProfile(io.BytesIO(profile)), srgb, outputMode="RGB")
                    expected = ImageCms.profileToProfile(Image.new("RGB",(1,1),(180,100,80)), ImageCms.ImageCmsProfile(io.BytesIO(p3)), srgb, outputMode="RGB")
                    assert max(abs(a-b) for a,b in zip(viewed.getpixel((0,0)),expected.getpixel((0,0)))) <= 2
            print(name, "passed", flush=True)

        source = work / "routes.psd"
        planes = [bytes([value]) * 2048 for value in (220,40,20)]
        source.write_bytes(psd(64,32,planes,8,3,3,layer=True))
        for ext in ("jpg","bmp","tiff","gif","webp","jxl","heic","avif","ico","icns","pdf","svg"):
            output=convert(source,ext)
            assert output.stat().st_size>0
        output=convert(source)
        before=output.read_bytes()
        assert subprocess.run([command,"convert",source,output],env=environment,capture_output=True).returncode != 0
        assert output.read_bytes()==before
        original=source.read_bytes()
        for damaged in (original[:-1],original+b"\0",original+b"extra"):
            source.write_bytes(damaged); convert(source,success=False)
        archive=convert(source,"zip")
        with zipfile.ZipFile(archive) as file: assert file.read(source.name)==source.read_bytes()
        source.write_bytes(original)
        linked=work/"linked.psd"; linked.symlink_to(source); convert(linked,success=False)
        renamed=work/"wrong-extension.jpg"; renamed.write_bytes(original)
        assert Image.open(convert(renamed)).size==(64,32)
    print("PSD compression, color modes, layers, resources, precision baselines, routes, source preservation, archive passthrough, invalid input, and cleanup checks passed.")


if __name__ == "__main__":
    main()
