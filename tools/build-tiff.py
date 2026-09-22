#!/usr/bin/env python3
"""Build the TIFF JPEG encoder and its sandbox launcher for ARM64 macOS."""
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
OUTPUT = ROOT / ".tools/tiff"
WORK = ROOT / ".tools/tiff-build"
CATALOG = json.loads((ROOT / "tools/native-sources.json").read_text())
SOURCES = [next(item for item in CATALOG["poppler"] if item["name"] == "libjpeg-turbo"), CATALOG["tiff"]]
PATCH = ROOT / "tools/tiff-metadata.patch"
METADATA = ROOT / "helpers/tiff/metadata.h"


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
    path_flags = f"-ffile-prefix-map={ROOT}=. -fdebug-prefix-map={ROOT}=."
    common = ["-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0",
              f"-DCMAKE_OSX_SYSROOT={sdk}", "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew", "-DBUILD_SHARED_LIBS=OFF",
              f"-DCMAKE_C_FLAGS={path_flags}", f"-DCMAKE_CXX_FLAGS={path_flags}",
              "-DCMAKE_EXE_LINKER_FLAGS=-Wl,-dead_strip"]
    inputs = {"sources": SOURCES, "cmake_flags": common, "script_sha256": digest(Path(__file__)),
              "patch_sha256": digest(PATCH), "metadata_sha256": digest(METADATA),
              "launcher_sha256": digest(ROOT / "helpers/toolguard/main.c"),
              "compiler": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
              "cmake": subprocess.check_output([cmake, "--version"], text=True).splitlines()[0]}
    stamp = WORK / "build-inputs.json"
    if WORK.exists() and (not stamp.exists() or json.loads(stamp.read_text()) != inputs):
        shutil.rmtree(WORK)
    WORK.mkdir(parents=True, exist_ok=True)
    stamp.write_text(json.dumps(inputs, indent=2) + "\n")
    sources, notices = OUTPUT / "sources", OUTPUT / "licenses"
    sources.mkdir(parents=True, exist_ok=True)
    notices.mkdir(exist_ok=True)
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="14.0", ZERO_AR_DATE="1")
    extracted = {}
    for item in SOURCES:
        archive = sources / item["url"].rsplit("/", 1)[1]
        if not archive.exists():
            temporary = archive.with_suffix(".download")
            try:
                with urllib.request.urlopen(item["url"], timeout=60) as response, temporary.open("wb") as file:
                    shutil.copyfileobj(response, file)
                if digest(temporary) != item["sha256"]:
                    raise SystemExit(f"Source checksum mismatch: {item['name']}")
                temporary.replace(archive)
            finally:
                temporary.unlink(missing_ok=True)
        if digest(archive) != item["sha256"]:
            raise SystemExit(f"Source checksum mismatch: {item['name']}")
        source = WORK / f"{item['name']}-{item['version']}"
        if not source.exists():
            with tarfile.open(archive) as file:
                file.extractall(WORK, filter="data")
        extracted[item["name"]] = source
        for name in ("LICENSE.md", "LICENSE", "COPYRIGHT", "README.ijg", "README.md"):
            if (source / name).is_file():
                shutil.copy2(source / name, notices / f"{item['name']}-{name}")
        if item["name"] == "tiff":
            # Restore this source file before applying the retained patch on a repeat build.
            with tarfile.open(archive) as file:
                file.extract(f"tiff-{item['version']}/tools/tiffcp.c", WORK, filter="data")
    with (OUTPUT / "build-commands.log").open("w") as log:
        def run(arguments):
            log.write(json.dumps(list(map(str, arguments))) + "\n")
            log.flush()
            subprocess.run(arguments, env=env, stdout=log, stderr=log, check=True)

        jpeg = extracted["libjpeg-turbo"]
        run([cmake, "-S", jpeg, "-B", jpeg / "build", *common, "-DENABLE_SHARED=OFF", "-DENABLE_STATIC=ON",
             "-DWITH_TURBOJPEG=OFF", "-DWITH_TOOLS=OFF", "-DWITH_TESTS=OFF", "-DWITH_SIMD=ON", "-DREQUIRE_SIMD=ON"])
        run([cmake, "--build", jpeg / "build", "--target", "jpeg-static", "-j", "4"])
        tiff = extracted["tiff"]
        shutil.copy2(METADATA, tiff / "tools/metadata.h")
        run(["patch", "--batch", "--forward", "-F0", "-d", tiff, "-p1", "-i", PATCH])
        options = ["-Dtiff-tools=ON", "-Dtiff-static=ON", "-Dtiff-tests=OFF", "-Dtiff-contrib=OFF", "-Dtiff-docs=OFF",
                   "-Dtiff-install=OFF", "-Djpeg=ON", "-Djpeg-prefer-standard=ON", "-Dzlib=ON", "-Dlzw=ON",
                   f"-DJPEG_LIBRARY_RELEASE={jpeg}/build/libjpeg.a", f"-DJPEG_INCLUDE_DIR={jpeg}/src",
                   f"-DCMAKE_C_FLAGS={path_flags} -I{jpeg}/build", f"-DZLIB_LIBRARY={sdk}/usr/lib/libz.tbd",
                   f"-DZLIB_INCLUDE_DIR={sdk}/usr/include"]
        options += [f"-D{name}=OFF" for name in ("old-jpeg", "jbig", "lerc", "lzma", "zstd", "webp", "libdeflate",
                                                 "ccitt", "packbits", "thunder", "next", "logluv", "mdi", "pixarlog")]
        run([cmake, "-S", tiff, "-B", tiff / "build", *common, *options])
        run([cmake, "--build", tiff / "build", "--target", "tiffcp", "-j", "4"])
        binary = OUTPUT / "bin/tiffcp"
        binary.parent.mkdir(exist_ok=True)
        shutil.copy2(tiff / "build/tools/tiffcp", binary)
        launcher = binary.with_name("tiffguard")
        run(["clang", "-O2", "-arch", "arm64", "-mmacosx-version-min=14.0", "-Wno-deprecated-declarations",
             '-DCONVERTER_BINARY_NAME="tiffcp"', ROOT / "helpers/toolguard/main.c", "-Wl,-dead_strip", "-o", launcher])
        for file in (binary, launcher):
            run(["strip", "-S", "-x", file])
            if subprocess.check_output(["lipo", "-archs", file], text=True).strip() != "arm64":
                raise SystemExit(f"Not an ARM64 binary: {file.name}")
            for line in subprocess.check_output(["otool", "-L", file], text=True).splitlines()[1:]:
                if not line.strip().startswith(("/usr/lib/", "/System/Library/")):
                    raise SystemExit(f"Unbundled TIFF dependency: {line}")
            link = ROOT / ".tools/bin" / file.name
            link.parent.mkdir(exist_ok=True)
            link.unlink(missing_ok=True)
            link.symlink_to(f"../tiff/bin/{file.name}")
    for file in (Path(__file__), ROOT / "tools/native-sources.json", ROOT / "helpers/toolguard/main.c", METADATA, PATCH, ROOT / "LICENSE"):
        target = sources / file.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(file, target)
    inputs["binaries"] = {file.name: {"bytes": file.stat().st_size, "sha256": digest(file)} for file in (binary, launcher)}
    (OUTPUT / "build-inputs.json").write_text(json.dumps(inputs, indent=2) + "\n")
    (notices / "components.txt").write_text("LibTIFF: libtiff license. libjpeg-turbo: IJG, BSD-3-Clause, and Zlib licenses.\n"
        "The retained libtiff patch copies XMP, EXIF, and GPS metadata. System zlib is supplied by macOS.\n"
        "The original sandbox launcher uses the repository's MIT license. Versions, sources, and hashes are retained.\n")
    print(f"TIFF tools: {binary.parent}")


if __name__ == "__main__":
    main()
