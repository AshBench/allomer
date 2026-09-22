#!/usr/bin/env python3
"""Build the pinned upstream PDF reader and document writer for ARM64 macOS."""
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
OUTPUT = ROOT / ".tools/mupdf"
WORK = ROOT / ".tools/mupdf-build"
SOURCE = json.loads((ROOT / "tools/native-sources.json").read_text())["mupdf"]
VERSION, DIGEST = SOURCE["version"], SOURCE["sha256"]


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("Build on an Apple Silicon Mac.")
    sources = OUTPUT / "sources"
    sources.mkdir(parents=True, exist_ok=True)
    archive = sources / f"mupdf-{VERSION}-source.tar.gz"
    if not archive.exists():
        urllib.request.urlretrieve(SOURCE["url"], archive)
    with archive.open("rb") as file:
        if hashlib.file_digest(file, "sha256").hexdigest() != DIGEST:
            raise SystemExit("The PDF source checksum does not match.")
    WORK.mkdir(exist_ok=True)
    source = WORK / f"mupdf-{VERSION}-source"
    if not source.exists():
        with tarfile.open(archive) as file:
            file.extractall(WORK, filter="data")
    patch = ROOT / "tools/mupdf-docx.patch"
    overlay_patch = ROOT / "tools/mupdf-overlay.patch"
    overlay_source = ROOT / "helpers/pdf-overlay/main.c"
    jpeg_source = ROOT / "helpers/jpeg-check/main.c"
    with tarfile.open(archive) as file:
        for name in ("source/fitz/output-docx.c", "thirdparty/extract/src/extract.c", "thirdparty/extract/src/docx.c", "source/tools/mutool.c"):
            (source / name).write_bytes(file.extractfile(f"mupdf-{VERSION}-source/{name}").read())
    subprocess.run(["patch", "--batch", "--forward", "-F", "0", "-p1", "-i", patch], cwd=source, check=True)
    subprocess.run(["patch", "--batch", "--forward", "-F", "0", "-p1", "-i", overlay_patch], cwd=source, check=True)
    shutil.copy2(overlay_source, source / "source/tools/pdfoverlay.c")
    shutil.copy2(jpeg_source, source / "source/tools/pdfjpegcheck.c")
    env = dict(os.environ, PATH="/usr/bin:/bin:/usr/sbin:/sbin", MACOSX_DEPLOYMENT_TARGET="14.0", ZERO_AR_DATE="1")
    env["SDKROOT"] = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    flags = ["build=release", "CC=clang", "CXX=clang++", "ARCHFLAGS=-arch arm64",
        "XCFLAGS=-arch arm64 -mmacosx-version-min=14.0", "XLDFLAGS=-arch arm64 -mmacosx-version-min=14.0",
        "HAVE_GLUT=no", "HAVE_X11=no", "HAVE_CURL=no", "HAVE_LIBCRYPTO=no", "USE_SYSTEM_LIBS=no", "HAVE_PTHREAD=yes",
        "mujs=no", "tesseract=no", "barcode=no", "xps=no"]
    inputs = {"source_sha256": DIGEST, "docx_patch_sha256": hashlib.sha256(patch.read_bytes()).hexdigest(),
        "overlay_patch_sha256": hashlib.sha256(overlay_patch.read_bytes()).hexdigest(),
        "overlay_source_sha256": hashlib.sha256(overlay_source.read_bytes()).hexdigest(),
        "jpeg_source_sha256": hashlib.sha256(jpeg_source.read_bytes()).hexdigest(), "flags": flags, "sdk": env["SDKROOT"],
        "clang": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0]}
    stamp = source / "build-inputs.json"
    with (OUTPUT / "build-commands.log").open("w") as log:
        def run(args):
            log.write(json.dumps(list(map(str, args))) + "\n")
            log.flush()
            subprocess.run(args, cwd=source, env=env, stdout=log, stderr=log, check=True)
        prior = json.loads(stamp.read_text()) if stamp.exists() else None
        if prior is not None and any(prior.get(key) != value for key, value in inputs.items()
                                    if key not in ("docx_patch_sha256", "overlay_patch_sha256", "overlay_source_sha256", "jpeg_source_sha256")):
            run(["make", "clean"] + flags)
        stamp.write_text(json.dumps(inputs, indent=2) + "\n")
        run(["make", "-j4", "build/release/mutool"] + flags)
    binary = OUTPUT / "bin/mutool"
    binary.parent.mkdir(exist_ok=True)
    shutil.copy2(source / "build/release/mutool", binary)
    launcher = binary.with_name("pdfguard")
    subprocess.run(["clang", "-O2", "-arch", "arm64", "-mmacosx-version-min=14.0", "-Wno-deprecated-declarations",
        '-DCONVERTER_BINARY_NAME="mutool"', ROOT / "helpers/toolguard/main.c", "-o", launcher], env=env, check=True)
    for tool in (binary, launcher):
        if subprocess.check_output(["lipo", "-archs", tool], text=True).strip() != "arm64":
            raise SystemExit(f"The PDF tool is not ARM64: {tool.name}")
        for line in subprocess.check_output(["otool", "-L", tool], text=True).splitlines()[1:]:
            if not line.strip().startswith(("/usr/lib/", "/System/Library/")):
                raise SystemExit(f"Unbundled PDF dependency in {tool.name}: {line}")
    notices = OUTPUT / "licenses"
    notices.mkdir(exist_ok=True)
    for file in source.rglob("*"):
        if file.is_file() and file.name.upper().startswith(("LICENSE", "COPYING", "NOTICE", "COPYRIGHT", "OFL", "FTL.")):
            target = notices / file.relative_to(source)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, target)
    for name in ("thirdparty/libjpeg/README", "thirdparty/freetype/docs/GPLv2.TXT",
                 "thirdparty/freetype/src/bdf/README", "thirdparty/freetype/src/pcf/README",
                 "resources/fonts/han/README.txt", "resources/fonts/sil/README.txt"):
        target = notices / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / name, target)
    (notices / "components.txt").write_text(f"MuPDF {VERSION}, Artifex Software, Inc.\n"
        "https://github.com/ArtifexSoftware/mupdf\n"
        "GNU Affero General Public License, version 3 or later.\n"
        "Third-party engines and built-in fonts retain their individual notices.\n"
        "The retained DOCX patch preserves image pixels, transforms, displayed size, and invisible text.\n"
        "The changes in that patch are released under AGPL-3.0-or-later.\n"
        "The original overlay command adds a text layer to an existing PDF.\n"
        "The original JPEG check uses the bundled IJG decoder and rejects corrupt-data warnings.\n"
        "Its source uses the MIT license. The combined executable uses AGPL-3.0-or-later.\n"
        "The retained command-registration patch uses AGPL-3.0-or-later.\n"
        "Portions are copyright 2026 The FreeType Project (https://freetype.org). All rights reserved.\n"
        "This software is based in part on the work of the Independent JPEG Group.\n"
        "Supply this matching source archive and build script with a distributed app.\n")
    scripts = sources / "tools"
    scripts.mkdir(exist_ok=True)
    shutil.copy2(Path(__file__), scripts / Path(__file__).name)
    shutil.copy2(ROOT / "tools/native-sources.json", scripts / "native-sources.json")
    shutil.copy2(patch, scripts / patch.name)
    shutil.copy2(overlay_patch, scripts / overlay_patch.name)
    overlay_copy = sources / "helpers/pdf-overlay/main.c"
    overlay_copy.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(overlay_source, overlay_copy)
    jpeg_copy = sources / "helpers/jpeg-check/main.c"
    jpeg_copy.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(jpeg_source, jpeg_copy)
    shutil.copy2(ROOT / "LICENSE", sources / "LICENSE")
    helper = sources / "helpers/toolguard"
    helper.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "helpers/toolguard/main.c", helper / "main.c")
    inputs.update(binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), binary_bytes=binary.stat().st_size,
        launcher_sha256=hashlib.sha256(launcher.read_bytes()).hexdigest(), launcher_bytes=launcher.stat().st_size,
        launcher_source_sha256=hashlib.sha256((ROOT / "helpers/toolguard/main.c").read_bytes()).hexdigest())
    (OUTPUT / "build-inputs.json").write_text(json.dumps(inputs, indent=2) + "\n")
    link = ROOT / ".tools/bin/mutool"
    link.parent.mkdir(exist_ok=True)
    link.unlink(missing_ok=True)
    link.symlink_to("../mupdf/bin/mutool")
    link.with_name("pdfguard").unlink(missing_ok=True)
    link.with_name("pdfguard").symlink_to("../mupdf/bin/pdfguard")
    print(f"PDF tool: {binary}")


if __name__ == "__main__":
    main()
