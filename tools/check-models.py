#!/usr/bin/env python3
"""Check model routes with original fixtures and independent file readers."""
import base64
import hashlib
import json
import math
import os
import platform
import re
import statistics
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import zlib
import urllib.request
import zipfile
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parent.parent
ROUTES = {
    "3ds": ["fbx", "glb", "ply", "stl"], "dae": ["fbx", "glb", "ply", "stl"],
    "fbx": ["glb", "ply", "stl"], "glb": ["fbx", "ply", "stl"], "gltf": ["fbx", "glb", "ply", "stl"],
    "obj": ["fbx", "glb", "ply", "stl", "usdz"], "ply": ["fbx", "glb", "stl", "usdz"],
    "stl": ["fbx", "glb", "ply", "usdz"], "usda": ["ply", "stl", "usdz"],
    "usdc": ["ply", "stl", "usdz"], "usdz": ["ply", "stl"],
}
POSITIONS = [(0, 0, 0), (2, 0, 0), (0, 3, 0), (0, 0, 4)]
FACES = [(0, 2, 1), (0, 1, 3), (1, 2, 3), (2, 0, 3)]


def fbx_reader():
    cache = ROOT / ".tools/model-check/ufbx-0.23.0"
    cache.mkdir(parents=True, exist_ok=True)
    for name, checksum in {
        "ufbx.h": "942481725372d2ac4da5e77a062b47c20054a3440e7ee09a6043f99fe1f130ed",
        "ufbx.c": "7d8d6ae4373f71692f295ff49ee0826466306ebcaa80b0e587c13ed047b98cea",
        "LICENSE": "0dd48ebadf52273c736256325c8f078c03c8bb4facee22a4122de0ad3f615391",
    }.items():
        file = cache / name
        if not file.exists():
            urllib.request.urlretrieve("https://raw.githubusercontent.com/ufbx/ufbx/fcc5d6ba444cfd3eb80677dba5e37e493941abe5/" + name, file)
        assert hashlib.sha256(file.read_bytes()).hexdigest() == checksum
    tool = cache.parent / "fbx-check"
    implementation = ROOT / "tools/model-fbx-check.c"
    if not tool.exists() or tool.stat().st_mtime < implementation.stat().st_mtime:
        subprocess.run(["xcrun", "clang", "-std=c99", "-O2", "-I", cache, implementation, cache / "ufbx.c", "-o", tool], check=True)
    return tool


def png():
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"\0\xff\0\0\xff\0\xff\0\xff\0\0\0\xff\xff\xff\xff\xff\xff"))
            + chunk(b"IEND", b""))


def fixtures(folder):
    folder.mkdir()
    (folder / "colors.png").write_bytes(png())
    (folder / "shape.mtl").write_text("newmtl colors\nKd 1 1 1\nmap_Kd colors.png\n")
    obj = "mtllib shape.mtl\no OriginalTetrahedron\n" + "".join(f"v {x} {y} {z}\n" for x, y, z in POSITIONS)
    obj += "vt 0 0\nvt 1 0\nvt 0 1\nvt 1 1\nusemtl colors\n"
    obj += "".join("f " + " ".join(f"{i+1}/{i+1}" for i in face) + "\n" for face in FACES)
    (folder / "shape.obj").write_text(obj)
    coordinates = " ".join(str(c) for p in POSITIONS for c in p)
    indices = " ".join(str(i) for face in FACES for i in face)
    (folder / "shape.dae").write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema" version="1.4.1">
<asset><created>2026-09-08T00:00:00Z</created><modified>2026-09-08T00:00:00Z</modified><unit meter="1"/><up_axis>Y_UP</up_axis></asset>
<library_geometries><geometry id="shape"><mesh><source id="positions"><float_array id="array" count="12">{coordinates}</float_array>
<technique_common><accessor source="#array" count="4" stride="3"><param name="X" type="float"/><param name="Y" type="float"/><param name="Z" type="float"/></accessor></technique_common></source>
<vertices id="vertices"><input semantic="POSITION" source="#positions"/></vertices><triangles count="4"><input semantic="VERTEX" source="#vertices" offset="0"/><p>{indices}</p></triangles>
</mesh></geometry></library_geometries><library_visual_scenes><visual_scene id="scene"><node id="root"><instance_geometry url="#shape"/></node></visual_scene></library_visual_scenes>
<scene><instance_visual_scene url="#scene"/></scene></COLLADA>''')
    def chunk(kind, data):
        return struct.pack("<HI", kind, len(data) + 6) + data
    vertices = chunk(0x4110, struct.pack("<H12f", 4, *[c for p in POSITIONS for c in p]))
    faces = chunk(0x4120, struct.pack("<H", 4) + b"".join(struct.pack("<4H", *face, 7) for face in FACES))
    (folder / "shape.3ds").write_bytes(chunk(0x4d4d, chunk(0x3d3d, chunk(0x4000, b"shape\0" + chunk(0x4100, vertices + faces)))))
    (folder / "shape.ply").write_text("ply\nformat ascii 1.0\nelement vertex 4\nproperty float x\nproperty float y\nproperty float z\n"
        "element face 4\nproperty list uchar int vertex_indices\nend_header\n"
        + "".join(" ".join(map(str, p)) + "\n" for p in POSITIONS)
        + "".join("3 " + " ".join(map(str, f)) + "\n" for f in FACES))
    stl = bytearray(b"Original tetrahedron".ljust(80, b"\0") + struct.pack("<I", 4))
    for face in FACES:
        stl += struct.pack("<12fH", 0, 0, 0, *[c for i in face for c in POSITIONS[i]], 0)
    (folder / "shape.stl").write_bytes(stl)
    data = struct.pack("<12f12H8f", *[c for p in POSITIONS for c in p], *[i for f in FACES for i in f], 0, 0, 1, 0, 0, 1, 1, 1)
    gltf = {"asset": {"version": "2.0", "generator": "Original test fixture"}, "scene": 0,
        "scenes": [{"nodes": [0]}], "nodes": [{"mesh": 0, "name": "OriginalTetrahedron"}],
        "meshes": [{"primitives": [{"attributes": {"POSITION": 0, "TEXCOORD_0": 2}, "indices": 1, "material": 0}]}],
        "buffers": [{"uri": "shape.bin", "byteLength": len(data)}],
        "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 48},
                        {"buffer": 0, "byteOffset": 48, "byteLength": 24}, {"buffer": 0, "byteOffset": 72, "byteLength": 32}],
        "accessors": [{"bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3", "min": [0, 0, 0], "max": [2, 3, 4]},
                      {"bufferView": 1, "componentType": 5123, "count": 12, "type": "SCALAR"},
                      {"bufferView": 2, "componentType": 5126, "count": 4, "type": "VEC2"}],
        "images": [{"uri": "colors.png"}], "textures": [{"source": 0}],
        "materials": [{"name": "colors", "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}, "metallicFactor": 0}}]}
    (folder / "shape.bin").write_bytes(data)
    (folder / "shape.gltf").write_text(json.dumps(gltf))
    (folder / "shape.usda").write_text('#usda 1.0\n( defaultPrim = "Shape"\n upAxis = "Y"\n metersPerUnit = 1 )\n'
        'def Xform "Shape" {\n def Mesh "Tetrahedron" {\n int[] faceVertexCounts = [3,3,3,3]\n'
        f' int[] faceVertexIndices = [{",".join(map(str, [i for f in FACES for i in f]))}]\n'
        f' point3f[] points = [{",".join(str(p) for p in POSITIONS)}]\n'
        ' uniform token subdivisionScheme = "none"\n }\n}\n')
    subprocess.run(["swift", "-e", 'import ModelIO; import Foundation; let a = MDLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1])); '
        'try a.export(to: URL(fileURLWithPath: CommandLine.arguments[2]))', folder / "shape.usda", folder / "shape.usdc"],
        check=True, capture_output=True, timeout=60)


def stl_points(path):
    data = path.read_bytes()
    count = struct.unpack_from("<I", data, 80)[0] if len(data) >= 84 else 0
    if len(data) == 84 + count * 50:
        return [tuple(struct.unpack_from("<3f", data, 84 + i * 50 + 12 + v * 12)) for i in range(count) for v in range(3)]
    return [tuple(map(float, line.split()[1:])) for line in data.decode().splitlines() if line.strip().startswith("vertex ")]


def check_points(actual, expected=POSITIONS):
    points = {tuple(round(c, 4) for c in p) for p in actual}
    wanted = {tuple(round(c, 4) for c in p) for p in expected}
    assert points == wanted, (points, wanted)


def ply(path):
    data = path.read_bytes()
    header, body = data.split(b"end_header\n", 1)
    binary = b"format binary_little_endian" in header
    types = {"char": "b", "uchar": "B", "short": "h", "ushort": "H", "int": "i", "uint": "I", "float": "f", "double": "d"}
    elements = []
    for line in header.decode().splitlines():
        parts = line.split()
        if parts[0] == "element": elements.append((parts[1], int(parts[2]), []))
        elif parts[0] == "property": elements[-1][2].append(parts[1:])
    offset = 0
    lines = iter(body.decode().splitlines()) if not binary else None
    result = {}
    for name, count, properties in elements:
        rows = []
        for _ in range(count):
            values = iter(next(lines).split()) if lines else None
            def scalar(kind):
                nonlocal offset
                if binary:
                    value = struct.unpack_from("<" + types[kind], body, offset)[0]
                    offset += struct.calcsize(types[kind])
                    return value
                return float(next(values)) if kind in ("float", "double") else int(next(values))
            row = {}
            for prop in properties:
                row[prop[-1]] = [scalar(prop[2]) for _ in range(scalar(prop[1]))] if prop[0] == "list" else scalar(prop[0])
            if values is not None: assert list(values) == [], (path.name, row)
            rows.append(row)
        result[name] = rows
    if binary: assert offset == len(body), (offset, len(body))
    else: assert not [line for line in lines if line.strip()]
    return result


def glb(path):
    data = path.read_bytes()
    assert struct.unpack_from("<4sII", data) == (b"glTF", 2, len(data))
    length, kind = struct.unpack_from("<II", data, 12)
    assert kind == 0x4e4f534a
    document = json.loads(data[20:20 + length])
    offset = 20 + length
    size, kind = struct.unpack_from("<II", data, offset)
    assert kind == 0x004e4942 and offset + 8 + size == len(data)
    return document, data[offset + 8:]


def check_texture(path, embedded):
    document, binary = glb(path)
    images = document.get("images", [])
    assert images, document
    for image in images:
        if embedded:
            assert "uri" not in image, image
            view = document["bufferViews"][image["bufferView"]]
            offset = view.get("byteOffset", 0)
            image_data = binary[offset:offset + view["byteLength"]]
        else:
            assert "bufferView" not in image, image
            image_data = (path.parent / image["uri"]).read_bytes()
        assert image_data == png()


def performance(tool):
    with tempfile.TemporaryDirectory(prefix="model-performance-") as directory:
        work = Path(directory).resolve()
        source = work / "grid.obj"
        side = 200
        with source.open("w") as file:
            file.write("o OriginalGrid\n")
            for y in range(side + 1):
                for x in range(side + 1):
                    file.write(f"v {x} {y} {math.sin(x / 20) * math.cos(y / 20):.6f}\n")
            for y in range(side):
                for x in range(side):
                    a = y * (side + 1) + x + 1
                    b, c, d = a + 1, a + side + 1, a + side + 2
                    file.write(f"f {a} {b} {d}\nf {a} {d} {c}\n")
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        samples = []
        for i in range(3):
            output = work / f"grid-{i}.glb"
            measured = subprocess.run(["/usr/bin/time", "-l", tool, source, output, "obj", "glb", work,
                "true", "true", "true", f"assets-{i}"], capture_output=True, text=True, check=True,
                env={"PATH": "/usr/bin:/bin"}, timeout=120)
            seconds = float(re.search(r"([\d.]+) real", measured.stderr)[1])
            peak = int(re.search(r"(\d+)\s+maximum resident set size", measured.stderr)[1])
            document, data = glb(output)
            primitive = document["meshes"][0]["primitives"][0]
            assert document["accessors"][primitive["indices"]]["count"] == side * side * 6
            assert document["accessors"][primitive["attributes"]["POSITION"]]["count"] == (side + 1) ** 2
            samples.append({"seconds": seconds, "peak_rss_bytes": peak, "output_bytes": output.stat().st_size})
        assert hashlib.sha256(source.read_bytes()).hexdigest() == digest
        report = {"measured_at": datetime.now(timezone.utc).isoformat(), "platform": platform.platform(),
            "scope": "Model helper only, including output geometry validation. App memory is excluded.",
            "operation": "OBJ to GLB", "triangles": side * side * 2, "vertices": (side + 1) ** 2,
            "input_bytes": source.stat().st_size, "input_sha256": digest,
            "helper_sha256": hashlib.sha256(tool.read_bytes()).hexdigest(), "samples": samples,
            "median_seconds": statistics.median(s["seconds"] for s in samples),
            "median_peak_rss_bytes": statistics.median(s["peak_rss_bytes"] for s in samples)}
        (ROOT / "research/model-performance.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--performance":
        performance(Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else ROOT / ".tools/models/bin/modeltool")
        return
    tool = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / ".tools/models/bin/modeltool"
    independent_fbx = fbx_reader()
    with tempfile.TemporaryDirectory(prefix="model-check-") as directory:
        work = Path(directory).resolve()
        sources, outputs = work / "source", work / "output"
        outputs.mkdir()
        fixtures(sources)
        def convert(src, name, *, binary=True, embed=True, resources=None, fails=False):
            output = outputs / name
            assets = name.replace(".", "-") + "-assets"
            result = subprocess.run([tool, src, output, src.suffix[1:], output.suffix[1:], resources or src.parent,
                str(binary).lower(), str(binary).lower(), str(embed).lower(), assets], capture_output=True, timeout=30)
            if fails:
                assert result.returncode != 0 and not output.exists(), result.stderr.decode()
                assert not (outputs / assets).exists()
            else:
                assert result.returncode == 0, (name, result.returncode, result.stderr.decode())
                assert output.stat().st_size
            return output
        for extension in ("glb", "fbx", "usdz"):
            initial = convert(sources / "shape.obj", "initial." + extension)
            (sources / ("shape." + extension)).write_bytes(initial.read_bytes())
        count = 0
        for source, targets in ROUTES.items():
            for target in targets:
                output = convert(sources / ("shape." + source), source + "-to." + target)
                expected = [(x, z, -y) for x, y, z in POSITIONS] if source == "3ds" else POSITIONS
                if target == "ply":
                    parsed = ply(output)
                    check_points([(p["x"], p["y"], p["z"]) for p in parsed["vertex"]], expected)
                    assert len(parsed["face"]) == 4
                if target == "fbx":
                    inspected = subprocess.check_output([independent_fbx, output], text=True).splitlines()
                    expected = [(x, z, -y) for x, y, z in POSITIONS] if source == "3ds" else POSITIONS
                    check_points([tuple(map(float, line.split()[1:])) for line in inspected if line.startswith("v ")], expected)
                if target == "usdz":
                    with zipfile.ZipFile(output) as archive:
                        assert archive.testzip() is None
                        assert all(info.compress_type == zipfile.ZIP_STORED for info in archive.infolist())
                        if source == "obj": assert any(info.filename.endswith(".png") for info in archive.infolist())
                if target == "stl":
                    actual = stl_points(output)
                    # The 3DS reader converts its Z-up coordinates to Y-up.
                    expected = [(x, z, -y) for x, y, z in POSITIONS] if source == "3ds" else POSITIONS
                    assert len(actual) == 12
                    check_points(actual, expected)
                count += 1
        for binary in (False, True):
            for target in ("ply", "stl"):
                output = convert(sources / "shape.obj", f"binary-{binary}.{target}", binary=binary)
                if target == "ply":
                    assert (b"format binary_little_endian 1.0" in output.read_bytes()[:80]) == binary
                    parsed = ply(output)
                    assert {(p["s"], p["t"]) for p in parsed["vertex"]} == {(0, 0), (1, 0), (0, 1), (1, 1)}
                    check_points([(p["x"], p["y"], p["z"]) for p in parsed["vertex"]])
                else:
                    assert (len(output.read_bytes()) == 284) == binary
                    check_points(stl_points(output))
        for embed in (False, True):
            for source in ("obj", "gltf", "glb", "fbx"):
                target = "fbx" if source == "glb" else "glb"
                output = convert(sources / ("shape." + source), f"textures-{source}-{embed}.{target}", embed=embed)
                if target == "glb": check_texture(output, embed)
                else:
                    inspected = subprocess.check_output([independent_fbx, output], text=True).splitlines()
                    if embed: assert "embedded " + png().hex() in inspected
                    else:
                        paths = [line.removeprefix("external ") for line in inspected if line.startswith("external ")]
                        assert paths and all((output.parent / p).read_bytes() == png() for p in paths)
        snapshot = work / "snapshot"
        snapshot.mkdir()
        (snapshot / "renamed.obj").write_bytes((sources / "shape.obj").read_bytes())
        check_texture(convert(snapshot / "renamed.obj", "snapshot.glb", resources=sources), True)
        convert(snapshot / "renamed.obj", "missing.glb", fails=True)
        transformed = json.loads((sources / "shape.gltf").read_text())
        transformed["nodes"][0].update(translation=[5, 7, 11], scale=[2, 3, 4], rotation=[0, 0, math.sqrt(0.5), math.sqrt(0.5)])
        (sources / "transformed.gltf").write_text(json.dumps(transformed))
        expected = [(5-y*3, 7+x*2, 11+z*4) for x, y, z in POSITIONS]
        for target in ("fbx", "glb", "ply", "stl"):
            output = convert(sources / "transformed.gltf", "transformed." + target)
            if target == "stl": check_points(stl_points(output), expected)
            if target == "fbx":
                inspected = subprocess.check_output([independent_fbx, output], text=True).splitlines()
                check_points([tuple(map(float, line.split()[1:])) for line in inspected if line.startswith("v ")], expected)
        # A source texture cannot read a file outside the selected resource folder.
        external = work / "outside.png"
        external.write_bytes(png())
        (sources / "colors.png").unlink()
        (sources / "colors.png").symlink_to(external)
        convert(sources / "shape.obj", "escaped.glb", fails=True)
        (sources / "colors.png").unlink()
        (sources / "colors.png").write_bytes(png())
        (sources / "broken.gltf").write_text('{"asset":{"version":"2.0"},"broken":')
        convert(sources / "broken.gltf", "broken.glb", fails=True)
        assert not list(outputs.glob(".model-*"))
        print(f"Model routes: {count}; binary options, embedded/external textures, renamed resources, and failure cleanup passed.")


if __name__ == "__main__":
    main()
