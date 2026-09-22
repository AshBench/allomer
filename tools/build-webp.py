#!/usr/bin/env python3
"""Build a local WebP encoder with pinned PNG input support for ARM64 macOS."""
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
OUTPUT = ROOT / ".tools/webp"
WORK = ROOT / ".tools/webp-build"
SOURCES = json.loads((ROOT / "tools/native-sources.json").read_text())["webp"]


def digest(file):
    with file.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("Build on an Apple Silicon Mac.")
    cmake = shutil.which("cmake")
    if not cmake:
        raise SystemExit("Install CMake for the development build.")
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    common = ["-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0",
              f"-DCMAKE_OSX_SYSROOT={sdk}", "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew", "-DBUILD_SHARED_LIBS=OFF",
              f"-DZLIB_LIBRARY={sdk}/usr/lib/libz.tbd", f"-DZLIB_INCLUDE_DIR={sdk}/usr/include"]
    inputs = {"sources": SOURCES, "cmake_flags": common, "script_sha256": digest(Path(__file__)),
              "compiler": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
              "cmake": subprocess.check_output([cmake, "--version"], text=True).splitlines()[0]}
    stamp = WORK / "build-inputs.json"
    if WORK.exists() and (not stamp.exists() or json.loads(stamp.read_text()) != inputs):
        shutil.rmtree(WORK)
    WORK.mkdir(parents=True, exist_ok=True)
    stamp.write_text(json.dumps(inputs, indent=2) + "\n")
    inputs["helper_sha256"] = {name: digest(ROOT / name) for name in
                               ("helpers/toolguard/main.c", "helpers/webpanim/main.c")}
    sources = OUTPUT / "sources"
    sources.mkdir(parents=True, exist_ok=True)
    notices = OUTPUT / "licenses"
    notices.mkdir(exist_ok=True)
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="14.0", ZERO_AR_DATE="1")
    with (OUTPUT / "build-commands.log").open("w") as log:
        def run(args):
            log.write(json.dumps(list(map(str, args))) + "\n")
            log.flush()
            subprocess.run(args, env=env, stdout=log, stderr=log, check=True)

        png = None
        for item in SOURCES:
            archive = sources / item["url"].rsplit("/", 1)[1]
            if not archive.exists():
                partial = archive.with_suffix(".download")
                try:
                    with urllib.request.urlopen(item["url"], timeout=60) as response, partial.open("wb") as file:
                        shutil.copyfileobj(response, file)
                    if digest(partial) != item["sha256"]:
                        raise SystemExit(f"Source checksum mismatch: {item['name']}")
                    partial.replace(archive)
                finally:
                    partial.unlink(missing_ok=True)
            if digest(archive) != item["sha256"]:
                raise SystemExit(f"Source checksum mismatch: {item['name']}")
            source = WORK / f"{item['name']}-{item['version']}"
            if not source.exists():
                with tarfile.open(archive) as file:
                    file.extractall(WORK, filter="data")
            build = source / "build"
            if item["name"] == "libpng":
                options = ["-DPNG_SHARED=OFF", "-DPNG_STATIC=ON", "-DPNG_TESTS=OFF", "-DPNG_TOOLS=OFF"]
                target = "png_static"
                png = source
            else:
                options = ["-DWEBP_BUILD_CWEBP=ON", "-DWEBP_LINK_STATIC=ON", "-DWEBP_USE_THREAD=OFF",
                           f"-DPNG_LIBRARY={png}/build/libpng16.a", f"-DPNG_PNG_INCLUDE_DIR={png}",
                           f"-DCMAKE_C_FLAGS=-I{png}/build -DWEBP_MAX_ALLOCABLE_MEMORY=536870912",
                           "-DCMAKE_DISABLE_FIND_PACKAGE_JPEG=ON", "-DCMAKE_DISABLE_FIND_PACKAGE_TIFF=ON",
                           "-DCMAKE_DISABLE_FIND_PACKAGE_GIF=ON", "-DCMAKE_DISABLE_FIND_PACKAGE_OpenGL=ON"]
                options += [f"-DWEBP_BUILD_{name}=OFF" for name in
                            ("ANIM_UTILS", "DWEBP", "GIF2WEBP", "IMG2WEBP", "VWEBP", "WEBPINFO", "LIBWEBPMUX", "WEBPMUX", "EXTRAS")]
                target = "cwebp"
            run([cmake, "-S", source, "-B", build, *common, *options])
            run([cmake, "--build", build, "--target", target, "-j", "4"])
            for name in ("LICENSE", "COPYING", "AUTHORS", "PATENTS"):
                if (source / name).is_file():
                    shutil.copy2(source / name, notices / f"{item['name']}-{name}.txt")
        binary = OUTPUT / "bin/cwebp"
        binary.parent.mkdir(exist_ok=True)
        shutil.copy2(build / "cwebp", binary)
        guard = binary.with_name("webpguard")
        animation = binary.with_name("webpanim")
        animation_guard = binary.with_name("webpanimguard")
        run(["clang", "-O2", "-Wall", "-Wextra", "-Werror", "-arch", "arm64", "-mmacosx-version-min=14.0",
             f"-I{source}/src", f"-I{source}", ROOT / "helpers/webpanim/main.c",
             build / "libimagedec.a", build / "libimageioutil.a", build / "libwebp.a", build / "libsharpyuv.a",
             png / "build/libpng16.a", f"{sdk}/usr/lib/libz.tbd", "-Wl,-dead_strip", "-o", animation])
        for launcher, target in ((guard, binary), (animation_guard, animation)):
            run(["clang", "-O2", "-arch", "arm64", "-mmacosx-version-min=14.0", "-Wno-deprecated-declarations",
                 f'-DCONVERTER_BINARY_NAME="{target.name}"', ROOT / "helpers/toolguard/main.c", "-o", launcher])
        binaries = (binary, guard, animation, animation_guard)
        for file in binaries:
            run(["strip", "-x", file])
            if subprocess.check_output(["lipo", "-archs", file], text=True).strip() != "arm64":
                raise SystemExit(f"Not an ARM64 binary: {file.name}")
            for line in subprocess.check_output(["otool", "-L", file], text=True).splitlines()[1:]:
                if not line.strip().startswith(("/usr/lib/", "/System/Library/")):
                    raise SystemExit(f"Unbundled WebP dependency: {line}")
            link = ROOT / ".tools/bin" / file.name
            link.parent.mkdir(exist_ok=True)
            link.unlink(missing_ok=True)
            link.symlink_to(f"../webp/bin/{file.name}")
        run([binary, "-version"])
    for file in (Path(__file__), ROOT / "tools/native-sources.json", ROOT / "helpers/toolguard/main.c",
                 ROOT / "helpers/webpanim/main.c", ROOT / "LICENSE"):
        target = sources / file.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(file, target)
    inputs["binaries"] = {file.name: {"sha256": digest(file), "bytes": file.stat().st_size} for file in binaries}
    (OUTPUT / "build-inputs.json").write_text(json.dumps(inputs, indent=2) + "\n")
    (notices / "components.txt").write_text("libwebp with SharpYUV: BSD-3-Clause. libpng: libpng-2.0.\n"
        "Versions and source hashes are retained in the matching source manifest. zlib is supplied by macOS.\n"
        "The original launchers and animation writer use the repository's MIT license. No third-party source patch is applied.\n")
    print(f"WebP encoder: {binary}")


if __name__ == "__main__":
    main()
