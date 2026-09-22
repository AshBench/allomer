#!/usr/bin/env python3
"""Build the pinned JPEG XL command and sandbox launcher for ARM64 macOS."""
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
OUTPUT = ROOT / ".tools/jpegxl"
WORK = ROOT / ".tools/jpegxl-build"
CATALOG = json.loads((ROOT / "tools/native-sources.json").read_text())
SOURCES = CATALOG["jpegxl"] + [next(x for x in CATALOG[group] if x["name"] == name)
                              for group, name in (("fonts", "brotli"), ("webp", "libpng"))]


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
    options = ["-DJPEGXL_ENABLE_TOOLS=ON", "-DJPEGXL_ENABLE_SKCMS=ON", "-DBUILD_TESTING=OFF",
               "-DJPEGXL_STATIC=ON", "-DJPEGXL_BUNDLE_LIBPNG=OFF", f"-DJPEGXL_VERSION={CATALOG['jpegxl'][0]['version']}",
               "-DCMAKE_DISABLE_FIND_PACKAGE_JPEG=ON", "-DCMAKE_DISABLE_FIND_PACKAGE_GIF=ON",
               "-DCMAKE_EXE_LINKER_FLAGS=-Wl,-dead_strip"]
    options += [f"-DJPEGXL_ENABLE_{name}=OFF" for name in
                ("DEVTOOLS", "FUZZERS", "DOXYGEN", "MANPAGES", "BENCHMARK", "EXAMPLES", "JNI", "SJPEG",
                 "OPENEXR", "VIEWERS", "TCMALLOC", "PLUGINS")]
    inputs = {"sources": SOURCES, "cmake_flags": common + options, "script_sha256": digest(Path(__file__)),
              "compiler": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
              "cmake": subprocess.check_output([cmake, "--version"], text=True).splitlines()[0]}
    stamp = WORK / "build-inputs.json"
    if WORK.exists() and (not stamp.exists() or json.loads(stamp.read_text()) != inputs):
        shutil.rmtree(WORK)
    WORK.mkdir(parents=True, exist_ok=True)
    stamp.write_text(json.dumps(inputs, indent=2) + "\n")
    sources = OUTPUT / "sources"
    notices = OUTPUT / "licenses"
    for directory in (sources, notices):
        directory.mkdir(parents=True, exist_ok=True)
    extracted = {}
    for item in SOURCES:
        suffix = ".tar.xz" if item["url"].endswith(".xz") else ".tar.gz"
        archive = sources / f"{item['name']}-{item['version']}{suffix}"
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
        with tarfile.open(archive) as file:
            source = WORK / file.getnames()[0].split("/")[0]
            if not source.exists():
                file.extractall(WORK, filter="data")
        extracted[item["name"]] = source
        for name in ("LICENSE", "LICENSE-BSD3", "COPYING", "AUTHORS", "PATENTS", "NOTICE"):
            if (source / name).is_file():
                shutil.copy2(source / name, notices / f"{item['name']}-{name}.txt")
    source = extracted["libjxl"]
    for name in ("highway", "skcms", "brotli"):
        target = source / "third_party" / name
        if target.is_dir() and not target.is_symlink():
            target.rmdir()
        if not target.exists():
            target.symlink_to(extracted[name], target_is_directory=True)
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="14.0", ZERO_AR_DATE="1")
    with (OUTPUT / "build-commands.log").open("w") as log:
        def run(args):
            log.write(json.dumps(list(map(str, args))) + "\n")
            log.flush()
            subprocess.run(args, env=env, stdout=log, stderr=log, check=True)
        png = extracted["libpng"]
        run([cmake, "-S", png, "-B", png / "build", *common, "-DPNG_SHARED=OFF", "-DPNG_STATIC=ON",
             "-DPNG_TESTS=OFF", "-DPNG_TOOLS=OFF"])
        run([cmake, "--build", png / "build", "--target", "png_static", "-j", "4"])
        build = source / "build"
        run([cmake, "-S", source, "-B", build, *common, *options,
             f"-DPNG_LIBRARY={png}/build/libpng16.a", f"-DPNG_PNG_INCLUDE_DIR={png}",
             f"-DCMAKE_C_FLAGS=-I{png}/build", f"-DCMAKE_CXX_FLAGS=-I{png}/build"])
        run([cmake, "--build", build, "--target", "cjxl", "djxl", "-j", "4"])
        binary = OUTPUT / "bin/cjxl"
        binary.parent.mkdir(exist_ok=True)
        shutil.copy2(build / "tools/cjxl", binary)
        # The upstream decoder is retained for independent development checks, outside the app bundle.
        shutil.copy2(build / "tools/djxl", binary.with_name("djxl"))
        guard = binary.with_name("jxlguard")
        run(["clang", "-O2", "-arch", "arm64", "-mmacosx-version-min=14.0", "-Wno-deprecated-declarations",
             '-DCONVERTER_BINARY_NAME="cjxl"', ROOT / "helpers/toolguard/main.c", "-o", guard])
        for file in (binary, guard, binary.with_name("djxl")):
            run(["strip", "-x", file])
            if subprocess.check_output(["lipo", "-archs", file], text=True).strip() != "arm64":
                raise SystemExit(f"Not an ARM64 binary: {file.name}")
            for line in subprocess.check_output(["otool", "-L", file], text=True).splitlines()[1:]:
                if not line.strip().startswith(("/usr/lib/", "/System/Library/")):
                    raise SystemExit(f"Unbundled JPEG XL dependency: {line}")
        for file in (binary, guard):
            link = ROOT / ".tools/bin" / file.name
            link.parent.mkdir(exist_ok=True)
            link.unlink(missing_ok=True)
            link.symlink_to(f"../jpegxl/bin/{file.name}")
        run([binary, "--version"])
    shutil.copy2(source / "lib/extras/LICENSE.apngdis", notices / "apngdis-LICENSE.txt")
    for file in (Path(__file__), ROOT / "tools/native-sources.json", ROOT / "helpers/toolguard/main.c", ROOT / "LICENSE"):
        target = sources / file.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(file, target)
    inputs["helper_sha256"] = {"helpers/toolguard/main.c": digest(ROOT / "helpers/toolguard/main.c")}
    inputs["binaries"] = {f.name: {"sha256": digest(f), "bytes": f.stat().st_size} for f in (binary, guard)}
    (OUTPUT / "build-inputs.json").write_text(json.dumps(inputs, indent=2) + "\n")
    (notices / "components.txt").write_text("libjxl: BSD-3-Clause. Highway: Apache-2.0. skcms: BSD-3-Clause.\n"
        "Brotli: MIT. libpng: libpng-2.0. APNG reader: retained apngdis license. zlib is supplied by macOS.\n"
        "The original launcher uses the repository's MIT license. No third-party source patch is applied.\n"
        "Matching pinned sources, build inputs, and notices are retained in the source bundle.\n")
    print(f"JPEG XL encoder: {binary}")


if __name__ == "__main__":
    main()
