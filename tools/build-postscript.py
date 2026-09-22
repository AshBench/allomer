#!/usr/bin/env python3
"""Build the bundled PostScript/PDF tool from a pinned upstream release."""
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
OUTPUT = ROOT / ".tools/pdf"
WORK = ROOT / ".tools/pdf-build"
SOURCE = json.loads((ROOT / "tools/native-sources.json").read_text())["ghostscript"]
VERSION, DIGEST = SOURCE["version"], SOURCE["sha256"]


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("Build on an Apple Silicon Mac.")
    sources = OUTPUT / "sources"
    sources.mkdir(parents=True, exist_ok=True)
    archive = sources / f"ghostscript-{VERSION}.tar.gz"
    if not archive.exists():
        urllib.request.urlretrieve(SOURCE["url"], archive)
    with archive.open("rb") as file:
        if hashlib.file_digest(file, "sha256").hexdigest() != DIGEST:
            raise SystemExit("The PostScript source checksum does not match.")
    WORK.mkdir(exist_ok=True)
    source = WORK / f"ghostscript-{VERSION}"
    if not source.exists():
        with tarfile.open(archive) as file:
            file.extractall(WORK, filter="data")
    path_flags = f"-ffile-prefix-map={ROOT}=. -fdebug-prefix-map={ROOT}=."
    env = dict(os.environ, PATH="/usr/bin:/bin:/usr/sbin:/sbin", CC="clang", CXX="clang++",
        MACOSX_DEPLOYMENT_TARGET="14.0", CFLAGS=f"-O2 -arch arm64 -mmacosx-version-min=14.0 {path_flags}",
        CXXFLAGS=f"-O2 -arch arm64 -mmacosx-version-min=14.0 {path_flags}", LDFLAGS="-arch arm64 -mmacosx-version-min=14.0",
        PKG_CONFIG="/usr/bin/false", ZERO_AR_DATE="1")
    env["SDKROOT"] = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    configure = ["./configure", "--prefix=/opt/allomer", "--without-x", "--disable-cups", "--disable-gtk",
        "--disable-dbus", "--disable-fontconfig", "--disable-contrib", "--without-ijs", "--without-libidn",
        "--without-libpaper", "--without-tesseract", "--without-pdftoraster", "--without-so", "--without-cal",
        "--with-libiconv=native", "--with-drivers=pdfwrite,ps2write,eps2write", "--with-fontpath=",
        "--enable-mkromfs-quiet"]
    inputs = {"source_sha256": DIGEST, "configure": configure,
        "environment": {key: env[key] for key in ("CC", "CXX", "CFLAGS", "CXXFLAGS", "LDFLAGS", "SDKROOT")},
        "clang": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0]}
    stamp = source / "build-inputs.json"
    with (OUTPUT / "build-commands.log").open("w") as log:
        def run(args):
            log.write(json.dumps(list(map(str, args))) + "\n")
            log.flush()
            subprocess.run(args, cwd=source, env=env, stdout=log, stderr=log, check=True)
        if not stamp.exists() or json.loads(stamp.read_text()) != inputs:
            if (source / "Makefile").exists():
                run(["make", "clean"])
            run(configure)
            stamp.write_text(json.dumps(inputs, indent=2) + "\n")
        run(["make", "-j4"])
    binary = OUTPUT / "bin/gs"
    binary.parent.mkdir(exist_ok=True)
    shutil.copy2(source / "bin/gs", binary)
    launcher = binary.with_name("postscript")
    subprocess.run(["clang", "-O2", "-arch", "arm64", "-mmacosx-version-min=14.0",
        "-Wno-deprecated-declarations", '-DCONVERTER_BINARY_NAME="gs"',
        ROOT / "helpers/toolguard/main.c", "-o", launcher], env=env, check=True)
    for tool in (binary, launcher):
        if subprocess.check_output(["lipo", "-archs", tool], text=True).strip() != "arm64":
            raise SystemExit("The PostScript helper is not ARM64.")
        for line in subprocess.check_output(["otool", "-L", tool], text=True).splitlines()[1:]:
            if not line.strip().startswith(("/usr/lib/", "/System/Library/")):
                raise SystemExit(f"Unbundled PostScript dependency: {line}")
    notices = OUTPUT / "licenses"
    notices.mkdir(exist_ok=True)
    for file in source.rglob("*"):
        if file.is_file() and file.name.upper().startswith(("LICENSE", "COPYING", "NOTICE", "COPYRIGHT")):
            relative = file.relative_to(source)
            target = notices / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, target)
    for name in ("jpeg/README", "freetype/docs/FTL.TXT", "freetype/docs/GPLv2.TXT",
                 "freetype/src/bdf/README", "freetype/src/pcf/README"):
        target = notices / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / name, target)
    resource_notices = []
    for file in sorted((source / "Resource").rglob("*")):
        if file.is_file() and file.parent.name in ("CMap", "Font"):
            with file.open("rb") as handle:
                header = handle.read(16384).split(b"currentfile eexec", 1)[0].split(b"%%EndComments", 1)[0]
            lines = [line for line in header.decode("latin1").splitlines()
                     if line.startswith(("%%Copyright:", "% Copyright", "% (URW)"))]
            if lines:
                resource_notices.append(str(file.relative_to(source)) + "\n" + "\n".join(lines))
    (notices / "resource-notices.txt").write_text("\n\n".join(resource_notices) + "\n")
    (notices / "components.txt").write_text(f"Ghostscript {VERSION}, Copyright Artifex Software, Inc.\n"
        "https://github.com/ArtifexSoftware/ghostpdl-downloads\n"
        "GNU Affero General Public License, version 3 or later.\n"
        "Built-in resources and fonts retain the exceptions and notices in LICENSE.\n"
        "Portions are copyright 2025 The FreeType Project (https://freetype.org). All rights reserved.\n"
        "This software is based in part on the work of the Independent JPEG Group.\n"
        "The source archive does not include the incompatible optional jpegxr directory.\n"
        "Supply the matching source archive and build script with a distributed app.\n")
    bundle = sources / "tools"
    bundle.mkdir(exist_ok=True)
    shutil.copy2(Path(__file__), bundle / Path(__file__).name)
    shutil.copy2(ROOT / "tools/native-sources.json", bundle / "native-sources.json")
    helper_source = sources / "helpers/toolguard"
    helper_source.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "helpers/toolguard/main.c", helper_source / "main.c")
    inputs.update(binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), binary_bytes=binary.stat().st_size)
    inputs.update(launcher_sha256=hashlib.sha256(launcher.read_bytes()).hexdigest(),
        launcher_source_sha256=hashlib.sha256((ROOT / "helpers/toolguard/main.c").read_bytes()).hexdigest())
    (OUTPUT / "build-inputs.json").write_text(json.dumps(inputs, indent=2) + "\n")
    link = ROOT / ".tools/bin/gs"
    link.parent.mkdir(exist_ok=True)
    link.unlink(missing_ok=True)
    link.symlink_to("../pdf/bin/gs")
    link.with_name("postscript").unlink(missing_ok=True)
    link.with_name("postscript").symlink_to("../pdf/bin/postscript")
    print(f"PostScript helper: {binary}")


if __name__ == "__main__":
    main()
