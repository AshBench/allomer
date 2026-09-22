#!/usr/bin/env python3
"""Build the static font libraries the fontconvert helper links, for Apple Silicon.

This produces no executable. It installs a prefix holding the pinned HarfBuzz subsetter and the
pinned Google WOFF2 codec, which tools/build-rust.py then links into the helper.
"""

import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / ".tools/fonts"
WORK = ROOT / ".tools/font-build/production"
PREFIX = OUTPUT / "prefix"
PINS = json.loads((ROOT / "tools/native-sources.json").read_text())
# freetype is pinned in this group for the PostScript writer and is not part of this build.
BUILT = ("brotli", "woff2", "harfbuzz")
SOURCES = [item for item in PINS["fonts"] if item["name"] in BUILT]


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("Build on an Apple Silicon Mac.")
    sources = OUTPUT / "sources"
    sources.mkdir(parents=True, exist_ok=True)

    def fetch(name, url, digest):
        archive = sources / name
        supplied = ROOT / name
        if not archive.exists():
            if supplied.exists():
                shutil.copy2(supplied, archive)
            else:
                urllib.request.urlretrieve(url, archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
            raise SystemExit(f"Source checksum mismatch: {name}")
        return archive

    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    cmake = shutil.which("cmake")
    if not cmake:
        raise SystemExit("Install CMake first.")
    env = dict(os.environ, CC="/usr/bin/clang", CXX="/usr/bin/clang++", SDKROOT=sdk,
        MACOSX_DEPLOYMENT_TARGET="14.0", SOURCE_DATE_EPOCH="1759996800", ZERO_AR_DATE="1",
        CFLAGS="-O2 -arch arm64 -mmacosx-version-min=14.0",
        CXXFLAGS="-O2 -arch arm64 -mmacosx-version-min=14.0",
        CPPFLAGS=f"-I{PREFIX}/include", LDFLAGS=f"-arch arm64 -mmacosx-version-min=14.0 -L{PREFIX}/lib")
    inputs = {"sources": SOURCES, "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "root": str(ROOT), "sdk": sdk, "compiler": subprocess.check_output(["clang", "--version"], text=True),
              "cmake": subprocess.check_output([cmake, "--version"], text=True).splitlines()[0],
              "python": sys.version}
    identity = WORK / "build-inputs.json"
    if WORK.exists() and (not identity.exists() or json.loads(identity.read_text()) != inputs):
        shutil.rmtree(WORK)
        if PREFIX.exists():
            shutil.rmtree(PREFIX)
    WORK.mkdir(parents=True, exist_ok=True)
    PREFIX.mkdir(parents=True, exist_ok=True)
    identity.write_text(json.dumps(inputs, indent=2) + "\n")
    notices = OUTPUT / "licenses"
    if notices.exists():
        shutil.rmtree(notices)
    notices.mkdir()
    with (OUTPUT / "build-commands.log").open("a") as log:
        def run(args, cwd):
            args = list(map(str, args))
            log.write(json.dumps(args) + "\n")
            log.flush()
            subprocess.run(args, cwd=cwd, env=env, stdout=log, stderr=log, check=True)

        def build_cmake(source, *options):
            build = source / "build"
            run([cmake, "-S", source, "-B", build, "-G", "Unix Makefiles",
                 "-DCMAKE_POLICY_VERSION_MINIMUM=3.5", "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF",
                 "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0",
                 f"-DCMAKE_OSX_SYSROOT={sdk}", f"-DCMAKE_INSTALL_PREFIX={PREFIX}",
                 f"-DCMAKE_PREFIX_PATH={PREFIX}", "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew", *options], WORK)
            run([cmake, "--build", build, "--parallel", "4"], WORK)
            run([cmake, "--install", build], WORK)

        for item in SOURCES:
            name = item["name"]
            suffix = ".tar.xz" if item["url"].endswith(".tar.xz") else ".tar.bz2" if item["url"].endswith(".tar.bz2") else ".tar.gz"
            archive = fetch(f"{name}-{item['version']}{suffix}", item["url"], item["sha256"])
            with tarfile.open(archive) as file:
                source = WORK / file.getnames()[0].split("/")[0]
                if not source.exists():
                    file.extractall(WORK, filter="data")
            stamp = WORK / f"{name}.complete"
            if not stamp.exists():
                print(f"Building {name} {item['version']}", flush=True)
                if name == "brotli":
                    build_cmake(source, "-DBROTLI_BUILD_TOOLS=OFF", "-DBROTLI_DISABLE_TESTS=ON")
                elif name == "woff2":
                    build_cmake(source, "-DNOISY_LOGGING=OFF",
                                f"-DCMAKE_CXX_STANDARD_LIBRARIES={PREFIX}/lib/libbrotlicommon.a")
                else:
                    # Only the subsetter is used. The shapers, rasterisers and platform
                    # integrations are off so nothing pulls in a system or Homebrew library.
                    build_cmake(source, "-DHB_BUILD_SUBSET=ON", "-DHB_BUILD_UTILS=OFF", "-DHB_BUILD_TESTS=OFF",
                                "-DHB_BUILD_RASTER=OFF", "-DHB_BUILD_VECTOR=OFF", "-DHB_BUILD_GPU=OFF",
                                "-DHB_HAVE_CORETEXT=OFF", "-DHB_HAVE_FREETYPE=OFF", "-DHB_HAVE_GLIB=OFF",
                                "-DHB_HAVE_ICU=OFF", "-DHB_HAVE_CAIRO=OFF", "-DHB_HAVE_GRAPHITE2=OFF",
                                "-DHB_HAVE_GOBJECT=OFF", "-DHB_HAVE_INTROSPECTION=OFF")
                    # hb-subset.h includes this header, but HarfBuzz 14.4.0 leaves it out of the
                    # CMake install list. Copying the released file keeps the prefix usable
                    # without changing any upstream source.
                    shutil.copy2(source / "src/hb-subset-depend.h", PREFIX / "include/harfbuzz")
                stamp.write_text(item["sha256"] + "\n")
            for file in source.rglob("*"):
                if file.is_file() and file.name.upper().startswith(("LICENSE", "COPYING", "COPYRIGHT", "NOTICE", "AUTHORS")):
                    destination = notices / name / file.relative_to(source)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(file, destination)
    required = ["libharfbuzz-subset.a", "libharfbuzz.a", "libwoff2enc.a", "libwoff2dec.a",
                "libwoff2common.a", "libbrotlienc.a", "libbrotlidec.a", "libbrotlicommon.a"]
    missing = [name for name in required if not (PREFIX / "lib" / name).is_file()]
    if missing:
        raise SystemExit(f"The font library prefix is incomplete: {', '.join(missing)}")
    for name in required:
        if subprocess.check_output(["lipo", "-archs", PREFIX / "lib" / name], text=True).strip() != "arm64":
            raise SystemExit(f"The font library is not ARM64: {name}")
    (sources / "tools").mkdir(exist_ok=True)
    for name in ("build-fonts.py", "native-sources.json"):
        shutil.copy2(ROOT / "tools" / name, sources / "tools" / name)
    inputs["libraries"] = {name: hashlib.sha256((PREFIX / "lib" / name).read_bytes()).hexdigest()
                           for name in required}
    (OUTPUT / "build-inputs.json").write_text(json.dumps(inputs, indent=2) + "\n")
    (notices / "sources.json").write_text(json.dumps(SOURCES, indent=2) + "\n")
    print(f"Font libraries: {PREFIX}")
    print("Run tools/build-rust.py fontconvert to build the helper that links them.")


if __name__ == "__main__":
    main()
