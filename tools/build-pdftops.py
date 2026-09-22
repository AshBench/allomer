#!/usr/bin/env python3
"""Build the local PDF-to-PostScript writer from pinned official sources."""
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
OUTPUT = ROOT / ".tools/poppler"
WORK = ROOT / ".tools/poppler-build"
CATALOG = json.loads((ROOT / "tools/native-sources.json").read_text())
SOURCES = CATALOG["poppler"] + [next(x for x in CATALOG["fonts"] if x["name"] == "freetype"),
                                dict(CATALOG["ghostscript"], name="ghostscript")]
PATCHES = [ROOT / "tools/poppler-local-resources.patch", ROOT / "tools/poppler-gradients.patch"]
FONTS = {
    "n022003l.pfb": "NimbusMonoPS-Regular", "n022004l.pfb": "NimbusMonoPS-Bold",
    "n022024l.pfb": "NimbusMonoPS-BoldItalic", "n022023l.pfb": "NimbusMonoPS-Italic",
    "n019003l.pfb": "NimbusSans-Regular", "n019004l.pfb": "NimbusSans-Bold",
    "n019024l.pfb": "NimbusSans-BoldItalic", "n019023l.pfb": "NimbusSans-Italic",
    "s050000l.pfb": "StandardSymbolsPS", "n021004l.pfb": "NimbusRoman-Bold",
    "n021024l.pfb": "NimbusRoman-BoldItalic", "n021023l.pfb": "NimbusRoman-Italic",
    "n021003l.pfb": "NimbusRoman-Regular", "d050000l.pfb": "D050000L",
}


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
    prefix = WORK / "prefix"
    path_flags = f"-ffile-prefix-map={ROOT}=. -fdebug-prefix-map={ROOT}=."
    common = ["-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_ARCHITECTURES=arm64", "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0",
              f"-DCMAKE_OSX_SYSROOT={sdk}", "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew", "-DBUILD_SHARED_LIBS=OFF",
              f"-DCMAKE_INSTALL_PREFIX={prefix}", f"-DCMAKE_PREFIX_PATH={prefix}",
              f"-DCMAKE_C_FLAGS={path_flags}", f"-DCMAKE_CXX_FLAGS={path_flags}",
              "-DPOPPLER_DATADIR=/opt/allomer/share/poppler",
              f"-DZLIB_LIBRARY={sdk}/usr/lib/libz.tbd", f"-DZLIB_INCLUDE_DIR={sdk}/usr/include"]
    inputs = {"sources": SOURCES, "cmake_flags": common, "script_sha256": digest(Path(__file__)),
              "patch_sha256": {file.name: digest(file) for file in PATCHES}, "launcher_sha256": digest(ROOT / "helpers/toolguard/main.c"),
              "compiler": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0],
              "cmake": subprocess.check_output([cmake, "--version"], text=True).splitlines()[0]}
    stamp = WORK / "build-inputs.json"
    if WORK.exists() and (not stamp.exists() or json.loads(stamp.read_text()) != inputs):
        shutil.rmtree(WORK)
    WORK.mkdir(parents=True, exist_ok=True)
    stamp.write_text(json.dumps(inputs, indent=2) + "\n")
    sources, notices = OUTPUT / "sources", OUTPUT / "licenses"
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
            if item["name"] == "poppler":
                for name in ("utils/pdftops.cc", "poppler/PSOutputDev.cc", "poppler/PSOutputDev.h"):
                    file.extract(f"{source.name}/{name}", WORK, filter="data")
        extracted[item["name"]] = source
        for file in source.iterdir():
            if file.is_file() and file.name.upper().startswith(("LICENSE", "COPYING", "COPYRIGHT", "NOTICE", "README.IJG")):
                shutil.copy2(file, notices / f"{item['name']}-{file.name}.txt")
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="14.0", ZERO_AR_DATE="1",
               PKG_CONFIG_LIBDIR=str(prefix / "lib/pkgconfig"), PKG_CONFIG_PATH="")
    with (OUTPUT / "build-commands.log").open("w") as log:
        def run(args):
            log.write(json.dumps(list(map(str, args))) + "\n")
            log.flush()
            subprocess.run(args, env=env, stdout=log, stderr=log, check=True)

        def dependency(name, options):
            source = extracted[name]
            build = source / "build"
            run([cmake, "-S", source, "-B", build, *common, *options])
            run([cmake, "--build", build, "-j", "4"])
            run([cmake, "--install", build])

        dependency("freetype", ["-DFT_DISABLE_HARFBUZZ=ON", "-DFT_DISABLE_PNG=ON", "-DFT_DISABLE_BZIP2=ON", "-DFT_DISABLE_BROTLI=ON"])
        dependency("libjpeg-turbo", ["-DENABLE_SHARED=OFF", "-DENABLE_STATIC=ON", "-DWITH_TURBOJPEG=OFF",
                   "-DWITH_TOOLS=OFF", "-DWITH_TESTS=OFF", "-DWITH_SIMD=ON", "-DREQUIRE_SIMD=ON"])
        dependency("lcms2", ["-DLCMS2_BUILD_SHARED=OFF", "-DLCMS2_BUILD_STATIC=ON", "-DLCMS2_BUILD_TOOLS=OFF", "-DLCMS2_BUILD_TESTS=OFF"])
        dependency("openjpeg", ["-DBUILD_CODEC=OFF", "-DBUILD_JPIP=OFF", "-DBUILD_VIEWER=OFF", "-DBUILD_JAVA=OFF",
                   "-DBUILD_TESTING=OFF", "-DBUILD_UNIT_TESTS=OFF", "-DBUILD_DOC=OFF", "-DOPJ_USE_THREAD=OFF"])
        source = extracted["poppler"]
        for patch in PATCHES:
            run(["patch", "--batch", "--forward", "-F0", "-d", source, "-p1", "-i", patch])
        options = ["-DFONT_CONFIGURATION=generic", "-DENABLE_UTILS=ON", "-DCMAKE_DISABLE_FIND_PACKAGE_PNG=ON",
                   "-DCMAKE_DISABLE_FIND_PACKAGE_Cairo=ON", "-DCMAKE_EXE_LINKER_FLAGS=-Wl,-dead_strip",
                   f"-DFREETYPE_LIBRARY_RELEASE={prefix}/lib/libfreetype.a",
                   f"-DFREETYPE_INCLUDE_DIR_ft2build={prefix}/include/freetype2",
                   f"-DFREETYPE_INCLUDE_DIR_freetype2={prefix}/include/freetype2",
                   f"-DJPEG_LIBRARY={prefix}/lib/libjpeg.a", f"-DJPEG_INCLUDE_DIR={prefix}/include",
                   f"-DLCMS2_LIBRARIES={prefix}/lib/liblcms2.a", f"-DLCMS2_INCLUDE_DIR={prefix}/include"]
        options += [f"-DENABLE_{name}=OFF" for name in ("BOOST", "CPP", "GLIB", "GOBJECT_INTROSPECTION", "GTK_DOC",
                    "QT5", "QT6", "LIBCURL", "LIBTIFF", "NSS3", "GPGME", "PGP_SIGNATURES")]
        options += [f"-DBUILD_{name}_TESTS=OFF" for name in ("GTK", "QT5", "QT6", "CPP", "MANUAL")]
        run([cmake, "-S", source, "-B", source / "build", *common, *options])
        run([cmake, "--build", source / "build", "--target", "pdftops", "-j", "4"])
        binary = OUTPUT / "bin/pdftops"
        binary.parent.mkdir(exist_ok=True)
        shutil.copy2(source / "build/utils/pdftops", binary)
        guard = binary.with_name("psguard")
        run(["clang", "-O2", "-arch", "arm64", "-mmacosx-version-min=14.0", "-Wno-deprecated-declarations",
             '-DCONVERTER_BINARY_NAME="pdftops"', "-DWEB_RESOURCE_DIRECTORY", ROOT / "helpers/toolguard/main.c", "-o", guard])
        for file in (binary, guard):
            run(["strip", "-S", "-x", file])
            if subprocess.check_output(["lipo", "-archs", file], text=True).strip() != "arm64":
                raise SystemExit(f"Not an ARM64 binary: {file.name}")
            for line in subprocess.check_output(["otool", "-L", file], text=True).splitlines()[1:]:
                if not line.strip().startswith(("/usr/lib/", "/System/Library/")):
                    raise SystemExit(f"Unbundled PostScript dependency: {line}")
    resources = OUTPUT / "Resources/Poppler"
    if resources.exists():
        shutil.rmtree(resources)
    resources.mkdir(parents=True)
    for name in ("cMap", "cidToUnicode", "nameToUnicode", "unicodeMap"):
        shutil.copytree(extracted["poppler-data"] / name, resources / name)
    (resources / "fonts").mkdir()
    font_notices = []
    for target, name in FONTS.items():
        file = extracted["ghostscript"] / "Resource/Font" / name
        shutil.copy2(file, resources / "fonts" / target)
        header = file.read_bytes().split(b"currentfile eexec", 1)[0].decode("latin1")
        font_notices.append(f"{name} → {target}\n{header}")
    (notices / "font-notices.txt").write_text("\n".join(font_notices))
    for name in ("docs/FTL.TXT", "docs/GPLv2.TXT", "src/bdf/README", "src/pcf/README"):
        shutil.copy2(extracted["freetype"] / name, notices / ("freetype-" + name.replace("/", "-")))
    for file in (Path(__file__), ROOT / "tools/native-sources.json", *PATCHES, ROOT / "helpers/toolguard/main.c", ROOT / "LICENSE"):
        target = sources / file.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(file, target)
    for file in (binary, guard):
        link = ROOT / ".tools/bin" / file.name
        link.parent.mkdir(exist_ok=True)
        link.unlink(missing_ok=True)
        link.symlink_to(f"../poppler/bin/{file.name}")
    inputs["binaries"] = {file.name: {"sha256": digest(file), "bytes": file.stat().st_size} for file in (binary, guard)}
    inputs["resources"] = {str(file.relative_to(resources)): {"sha256": digest(file), "bytes": file.stat().st_size}
                           for file in sorted(resources.rglob("*")) if file.is_file()}
    (OUTPUT / "build-inputs.json").write_text(json.dumps(inputs, indent=2) + "\n")
    (notices / "components.txt").write_text("Poppler: GPL-2.0-or-later. Poppler data: retained Adobe and GPL-2.0/GPL-3.0 notices.\n"
        "FreeType: FreeType License. libjpeg-turbo: IJG, BSD-3-Clause, and zlib notices.\n"
        "This software is based in part on the work of the Independent JPEG Group.\n"
        "Portions are copyright 2026 The FreeType Project (https://freetype.org). All rights reserved.\n"
        "Little CMS: MIT. OpenJPEG: BSD-2-Clause. zlib is supplied by macOS.\n"
        "The 14 fallback fonts come from Ghostscript under AGPL-3.0-or-later, with its document embedding exception.\n"
        "Original GPL-2.0-or-later source patches add local resources, strict errors, and native Level 3 gradients.\n"
        "Matching pinned sources, patch, build inputs, and notices are retained in the source bundle.\n")
    print(f"PDF-to-PostScript writer: {binary}")


if __name__ == "__main__":
    main()
