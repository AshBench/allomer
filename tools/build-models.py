#!/usr/bin/env python3
"""Build the model helper with a pinned, static Assimp library."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / ".tools/models"
WORK = ROOT / ".tools/model-build"
SOURCE = json.loads((ROOT / "tools/native-sources.json").read_text())["assimp"]
VERSION, DIGEST = SOURCE["version"], SOURCE["sha256"]


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("Build on an Apple Silicon Mac.")
    sources = OUTPUT / "sources"
    sources.mkdir(parents=True, exist_ok=True)
    archive = sources / f"assimp-{VERSION}.tar.gz"
    if not archive.exists():
        urllib.request.urlretrieve(SOURCE["url"], archive)
    with archive.open("rb") as file:
        if hashlib.file_digest(file, "sha256").hexdigest() != DIGEST:
            raise SystemExit("The model library source checksum does not match.")
    WORK.mkdir(exist_ok=True)
    source = WORK / f"assimp-{VERSION}"
    if not source.exists():
        with tarfile.open(archive) as file:
            file.extractall(WORK, filter="data")
    patch = ROOT / "tools/assimp-ply.patch"
    ply_source = source / "code/AssetLib/Ply/PlyExporter.cpp"
    # Start from the pinned file so repeated builds cannot apply a patch twice.
    with tarfile.open(archive) as file:
        ply_source.write_bytes(file.extractfile(f"assimp-{VERSION}/code/AssetLib/Ply/PlyExporter.cpp").read())
    subprocess.run(["patch", "--batch", "--forward", "-F", "0", "-p1", "-i", patch], cwd=source, check=True)
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    build = WORK / "build"
    cmake = shutil.which("cmake")
    if not cmake:
        raise SystemExit("Install CMake to build the model library.")
    options = {
        "CMAKE_BUILD_TYPE": "Release", "CMAKE_OSX_ARCHITECTURES": "arm64",
        "CMAKE_OSX_DEPLOYMENT_TARGET": "14.0", "CMAKE_IGNORE_PREFIX_PATH": "/opt/homebrew",
        "BUILD_SHARED_LIBS": "OFF", "ASSIMP_BUILD_TESTS": "OFF", "ASSIMP_BUILD_ASSIMP_TOOLS": "OFF",
        "ASSIMP_BUILD_SAMPLES": "OFF", "ASSIMP_INSTALL": "OFF", "ASSIMP_WARNINGS_AS_ERRORS": "OFF",
        "ASSIMP_IGNORE_GIT_HASH": "ON", "ASSIMP_BUILD_ZLIB": "OFF",
        "ZLIB_LIBRARY": f"{sdk}/usr/lib/libz.tbd", "ZLIB_INCLUDE_DIR": f"{sdk}/usr/include",
        "ASSIMP_BUILD_ALL_IMPORTERS_BY_DEFAULT": "OFF", "ASSIMP_BUILD_ALL_EXPORTERS_BY_DEFAULT": "OFF",
        "ASSIMP_BUILD_DRACO_STATIC": "ON", "ASSIMP_BUILD_USE_CCACHE": "OFF",
        "CMAKE_EXPORT_COMPILE_COMMANDS": "ON",
    }
    for name in ("OBJ", "GLTF", "FBX", "COLLADA", "3DS", "PLY", "STL"):
        options[f"ASSIMP_BUILD_{name}_IMPORTER"] = "ON"
    # OBJ is an internal bridge to the native USDZ writer.
    for name in ("OBJ", "GLTF", "FBX", "PLY", "STL"):
        options[f"ASSIMP_BUILD_{name}_EXPORTER"] = "ON"
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="14.0", ZERO_AR_DATE="1")
    binary = OUTPUT / "bin/modeltool"
    binary.parent.mkdir(exist_ok=True)
    log_path = OUTPUT / "build-commands.log"
    with log_path.open("w") as log:
        def run(args):
            args = list(map(str, args))
            log.write(json.dumps(args) + "\n")
            log.flush()
            subprocess.run(args, cwd=ROOT, env=env, stdout=log, stderr=log, check=True)
        run([cmake, "-S", source, "-B", build, *[f"-D{k}={v}" for k, v in options.items()]])
        run([cmake, "--build", build, "--target", "assimp", "-j", "4"])
        run(["xcrun", "clang++", "-std=c++17", "-O2", "-arch", "arm64", "-mmacosx-version-min=14.0",
             "-fobjc-arc", "-Wno-deprecated-declarations", "-I", source / "include", "-I", build / "include",
             ROOT / "helpers/modeltool/main.mm", build / "lib/libassimp.a", build / "lib/libdraco.a",
             "-lz", "-lsandbox", "-framework", "Foundation", "-framework", "ModelIO", "-framework", "SceneKit",
             "-framework", "ImageIO", "-framework", "CoreGraphics", "-o", binary])
        run(["strip", "-x", binary])
    if subprocess.check_output(["lipo", "-archs", binary], text=True).strip() != "arm64":
        raise SystemExit("The model helper is not ARM64.")
    for line in subprocess.check_output(["otool", "-L", binary], text=True).splitlines()[1:]:
        if not line.strip().startswith(("/usr/lib/", "/System/Library/")):
            raise SystemExit(f"Unbundled model dependency: {line}")
    notices = OUTPUT / "licenses"
    notices.mkdir(exist_ok=True)
    for name, relative in {
        "Assimp-BSD-3-Clause.txt": "LICENSE", "Draco-Apache-2.0.txt": "contrib/draco/LICENSE",
        "Draco-AUTHORS.txt": "contrib/draco/AUTHORS",
        "Poly2Tri-BSD.txt": "contrib/poly2tri/LICENSE", "Pugixml-MIT.txt": "contrib/pugixml/LICENSE.md",
        "OpenDDL-MIT.txt": "contrib/openddlparser/LICENSE", "UTF8-CPP.txt": "contrib/utf8cpp/doc/LICENSE",
        "RapidJSON.txt": "contrib/rapidjson/license.txt", "Earcut-ISC.txt": "contrib/earcut-hpp/LICENSE",
    }.items():
        shutil.copy2(source / relative, notices / name)
    unzip = (source / "contrib/unzip/unzip.h").read_text()
    (notices / "Minizip-zlib.txt").write_text(unzip[:unzip.index("*/") + 2] + "\n")
    clipper = (source / "contrib/clipper/clipper.hpp").read_text()
    boost = (source / "contrib/zlib/contrib/dotzlib/LICENSE_1_0.txt").read_text()
    (notices / "Clipper-Boost-1.0.txt").write_text(clipper[:clipper.index("*/") + 2] + "\n\n" + boost)
    (notices / "components.txt").write_text(f"Assimp {VERSION} (BSD-3-Clause), https://github.com/assimp/assimp\n"
        "Draco 1.5.7 (Apache-2.0), Copyright 2016 The Draco Authors, https://github.com/google/draco\n"
        "Includes Poly2Tri, Pugixml, OpenDDL Parser, UTF8-CPP, RapidJSON, Earcut, Minizip, and Clipper.\n"
        "RapidJSON's JSON_checker tests and Assimp's test models are not included in the app.\n"
        "The PLY writer is patched to match its UV and color declarations to the stored values.\n"
        "ModelIO, SceneKit, ImageIO, CoreGraphics, Foundation, and zlib are supplied by macOS.\n")
    report = {"assimp_version": VERSION, "source_sha256": DIGEST, "cmake_options": options,
              "ply_patch_sha256": hashlib.sha256(patch.read_bytes()).hexdigest(),
              "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "binary_bytes": binary.stat().st_size,
              "clang": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0]}
    (OUTPUT / "build-inputs.json").write_text(json.dumps(report, indent=2) + "\n")
    for file in (Path(__file__), patch, ROOT / "tools/native-sources.json", ROOT / "helpers/modeltool/main.mm", ROOT / "LICENSE"):
        target = sources / file.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(file, target)
    link = ROOT / ".tools/bin/modeltool"
    link.parent.mkdir(exist_ok=True)
    link.unlink(missing_ok=True)
    link.symlink_to("../models/bin/modeltool")
    print(f"Model helper: {binary}")


if __name__ == "__main__":
    main()
