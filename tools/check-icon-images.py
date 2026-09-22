#!/usr/bin/env python3
"""Check ICO and ICNS files with independent container and pixel readers."""
import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import random
import re
import statistics
import struct
import subprocess
import tempfile

from PIL import Image, ImageCms, ImageDraw, ImageOps

ROOT = Path(__file__).resolve().parent.parent


def png(image):
    stream = io.BytesIO()
    image.save(stream, format="PNG")
    return stream.getvalue()


def ico(images):
    payloads = [png(image) for image in images]
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    for image, data in zip(images, payloads):
        header += struct.pack("<BBBBHHII", image.width % 256, image.height % 256, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    return header + b"".join(payloads)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=ROOT / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=ROOT / ".tools/bin")
    parser.add_argument("--benchmark-only", action="store_true")
    parser.add_argument("--report", type=Path, default=ROOT / "research/icon-image-performance.json")
    args = parser.parse_args()
    command, tools = args.command.resolve(), args.tools.resolve()
    environment = {"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools)}
    with tempfile.TemporaryDirectory(prefix="icon sizes café 100%, ") as temporary:
        work = Path(temporary)
        sequence = 0

        def convert(source, ext, success=True, timing=None, image_options=None):
            nonlocal sequence
            sequence += 1
            output = work / f"output-{sequence}.{ext}"
            original = hashlib.sha256(source.read_bytes()).hexdigest()
            invocation = [command, "convert", source, output]
            if image_options is not None:
                options=work/"image-options.json"; options.write_text(json.dumps(image_options))
                invocation += ["--image-options",options]
            if timing is not None: invocation = ["/usr/bin/time", "-l", *invocation]
            result = subprocess.run(invocation, env=environment, capture_output=True, text=True, timeout=120)
            assert (result.returncode == 0) == success, (source.name, ext, result.stderr)
            assert hashlib.sha256(source.read_bytes()).hexdigest() == original
            assert output.exists() == success
            assert not list(work.glob(".allomer-*"))
            if timing is not None:
                timing.update(seconds=float(re.search(r"([\d.]+)\s+real", result.stderr)[1]),
                    resident_bytes=int(re.search(r"(\d+)\s+maximum resident set size", result.stderr)[1]), output_bytes=output.stat().st_size)
            return output

        if args.benchmark_only:
            cases = []
            for name, size, noise in [("small-artwork", (256, 256), False), ("noise-one-megapixel", (1024, 1024), True), ("flat-24-megapixels", (6000, 4000), False)]:
                source = work / f"{name}.png"
                image = Image.frombytes("RGB", size, random.Random(193).randbytes(size[0] * size[1] * 3)) if noise else Image.new("RGBA", size, (30, 100, 200, 180))
                image.save(source, compress_level=1)
                for ext in ("ico", "icns"):
                    runs = []
                    for _ in range(3):
                        timing = {}; output = convert(source, ext, timing=timing); runs.append(timing)
                        assert Image.open(output).size == ((256, 256) if ext == "ico" else (1024, 1024))
                    case = {"case": name, "output": ext, "input_bytes": source.stat().st_size,
                        "input_sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "runs": runs,
                        "median_seconds": statistics.median(run["seconds"] for run in runs),
                        "median_resident_bytes": statistics.median(run["resident_bytes"] for run in runs)}
                    cases.append(case); print(name, ext, case["median_seconds"], case["median_resident_bytes"], flush=True)
            args.report.write_text(json.dumps({"recorded_at_utc": datetime.now(timezone.utc).isoformat(),
                "macos": platform.mac_ver()[0], "chip": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
                "command_sha256": hashlib.sha256(command.read_bytes()).hexdigest(), "cases": cases,
                "scope": "Three complete command conversions per original workload and output format. Includes thumbnail preparation, every output size, native decode validation, and publication. GUI and Python fixture/pixel work excluded. RSS is per-process high-water memory, not aggregate simultaneous memory."}, indent=2) + "\n")
            return

        source = work / "rectangle.png"
        Image.new("RGBA", (300, 180), (20, 40, 220, 180)).save(source)
        for ext in ("ico", "icns"):
            output = convert(source, ext)
            container = Image.open(output)
            if ext == "ico":
                data = output.read_bytes()
                assert struct.unpack_from("<HHH", data) == (0, 1, 7)
                end = 6 + 16 * 7
                for i, size in enumerate([16, 24, 32, 48, 64, 128, 256]):
                    w, h, colors, reserved, planes, bits, length, offset = struct.unpack_from("<BBBBHHII", data, 6 + i * 16)
                    assert (w or 256, h or 256, colors, reserved, planes, bits, offset) == (size, size, 0, 0, 1, 32, end)
                    assert data[offset:offset+8] == b"\x89PNG\r\n\x1a\n"
                    assert data[offset+24:offset+26] == bytes([8, 6]), "ICO PNG must be 8-bit RGBA"
                    end += length
                assert end == len(data)
                variants = [container.ico.getimage(size).convert("RGBA") for size in sorted(container.ico.sizes())]
            else:
                assert len(container.info["sizes"]) == 10
                variants = [container.icns.getimage(size).convert("RGBA") for size in container.info["sizes"]]
                data=output.read_bytes(); offset=8; legacy=b""
                while offset<len(data):
                    tag,length=struct.unpack_from(">4sI",data,offset)
                    assert length>=8 and offset+length<=len(data)
                    if tag in (b"is32",b"s8mk"): legacy+=data[offset:offset+length]
                    offset+=length
                assert legacy and offset==len(data)
                old_icon=work/"legacy.icns"
                old_icon.write_bytes(b"icns"+struct.pack(">I",len(legacy)+8)+legacy)
                old_pixels=Image.open(convert(old_icon,"png")).convert("RGBA")
                assert old_pixels.size==(16,16) and old_pixels.getpixel((8,8))==(20,40,220,180)
            for variant in variants:
                size = variant.width
                assert variant.height == size
                assert variant.getpixel((0, 0))[3] == 0
                assert max(abs(a-b) for a,b in zip(variant.getpixel((size//2, size//2)), (20,40,220,180))) <= 2
            restored = Image.open(convert(output, "png"))
            assert restored.size == ((256,256) if ext == "ico" else (1024,1024))
            before = output.read_bytes()
            collision = subprocess.run([command,"convert",source,output],env=environment,capture_output=True)
            assert collision.returncode != 0 and output.read_bytes() == before

        old_icon=work/"legacy.ico"
        old_pixels=Image.new("RGBA",(64,64))
        ImageDraw.Draw(old_pixels).rectangle((16,16,47,47),fill=(20,40,220,180))
        old_pixels.save(old_icon,bitmap_format="bmp",sizes=[(16,16),(32,32),(64,64)])
        restored=Image.open(convert(old_icon,"png")).convert("RGBA")
        assert restored.tobytes()==old_pixels.tobytes(),"Legacy ICO bitmap and alpha changed"

        different = work / "variants.ico"
        different.write_bytes(ico([Image.new("RGBA", (32,32), "green"), Image.new("RGBA", (256,256), "blue"), Image.new("RGBA", (16,16), "red")]))
        largest = Image.open(convert(different, "png")).convert("RGBA")
        assert largest.size == (256,256) and largest.getpixel((128,128)) == (0,0,255,255)
        chunks = b"".join(tag + struct.pack(">I", len(data)+8) + data for tag,data in [
            (b"icp4",png(Image.new("RGBA",(16,16),"red"))), (b"ic10",png(Image.new("RGBA",(1024,1024),"blue"))),
            (b"ic07",png(Image.new("RGBA",(128,128),"green")))])
        different = work / "wrong-extension.jpg"
        different.write_bytes(b"icns" + struct.pack(">I",len(chunks)+8) + chunks)
        largest = Image.open(convert(different,"png")).convert("RGBA")
        assert largest.size == (1024,1024) and largest.getpixel((512,512)) == (0,0,255,255)
        document = convert(different,"pdf")
        page = work / "icon-pdf-page.png"
        subprocess.run([tools / "mutool","draw","-q","-r","18","-F","png","-o",page,document],
            env=environment,capture_output=True,check=True,timeout=120)
        rendered=Image.open(page).convert("RGB")
        assert max(abs(a-b) for a,b in zip(rendered.getpixel((rendered.width//2,rendered.height//2)),(0,0,255))) <= 3
        for orientation in range(1,9):
            image = Image.new("RGB",(256,128),"red")
            ImageDraw.Draw(image).rectangle((128,0,255,127),fill="blue")
            exif=Image.Exif(); exif[274]=orientation
            image.save(source,exif=exif)
            expected=ImageOps.exif_transpose(Image.open(source)).convert("RGBA")
            output=Image.open(convert(source,"ico")).convert("RGBA")
            x,y=(256-expected.width)//2,(256-expected.height)//2
            assert output.getchannel("A").getbbox()==(x,y,x+expected.width,y+expected.height),orientation
            assert output.crop((x,y,x+expected.width,y+expected.height)).tobytes()==expected.tobytes(),orientation
        damaged=work/"damaged.icns"; damaged.write_bytes(different.read_bytes()[:30]); convert(damaged,"png",success=False)
        oversized=work/"too-many.ico"
        oversized.write_bytes(ico([Image.new("RGBA",(16,16),"red")]*257)); convert(oversized,"png",success=False)
        link=work/"linked.ico"; os.symlink(oversized,link); convert(link,"png",success=False)
        vector=work/"vector.svg"
        vector.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="64" height="32"><rect width="64" height="32" fill="red"/></svg>')
        assert Image.open(convert(vector,"icns")).size==(1024,1024)
        p3=Path("/System/Library/ColorSync/Profiles/Display P3.icc").read_bytes()
        colors=Image.new("RGB",(256,256),(180,100,80)); colors.save(source,icc_profile=p3)
        srgb=ImageCms.createProfile("sRGB")
        expected=ImageCms.profileToProfile(colors,ImageCms.ImageCmsProfile(io.BytesIO(p3)),srgb,outputMode="RGB").getpixel((0,0))
        for ext,settings in [("ico",None),("icns",None),
                ("ico",{"convertToSRGB":True,"preserveMetadata":False}),
                ("icns",{"convertToSRGB":True,"preserveMetadata":False})]:
            icon=Image.open(convert(source,ext,image_options=settings))
            variants=[icon.ico.getimage(size) for size in icon.ico.sizes()] if ext=="ico" else [icon.icns.getimage(size) for size in icon.info["sizes"]]
            for variant in variants:
                profile=variant.info.get("icc_profile")
                viewed=ImageCms.profileToProfile(variant,ImageCms.ImageCmsProfile(io.BytesIO(profile)),srgb,outputMode="RGB") if profile else variant.convert("RGB")
                actual=viewed.getpixel((viewed.width//2,viewed.height//2))
                assert max(abs(a-b) for a,b in zip(actual,expected))<=3,(ext,variant.size,actual,expected,bool(profile))
        project=work/"Nested.icon"; (project/"Assets").mkdir(parents=True)
        (project/"Assets/Content.ico").write_bytes((work/"variants.ico").read_bytes())
        (project/"icon.json").write_text('{"groups":[{"layers":[{"image-name":"Content.ico"}]}]}')
        rendered=work/"nested.png"
        subprocess.run([command,"convert",project,rendered],env=environment,capture_output=True,check=True,timeout=120)
        pixels=Image.open(rendered).convert("RGBA")
        assert pixels.getpixel((512,512))==(0,0,255,255) and pixels.getchannel("A").getbbox()==(384,384,640,640)
    print("Icon sizes, ICO container fields, independent pixels, orientation, largest-image selection, SVG input, invalid input, source preservation, and cleanup checks passed.")


if __name__ == "__main__":
    main()
