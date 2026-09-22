#!/usr/bin/env python3
"""Build the upstream ebook reader for Apple Silicon Macs."""

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
OUTPUT = ROOT / ".tools/ebook"
WORK = ROOT / ".tools/ebook-build"
SOURCE = json.loads((ROOT / "tools/native-sources.json").read_text())["libmobi"]
VERSION, DIGEST = SOURCE["version"], SOURCE["sha256"]


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("Build on an Apple Silicon Mac.")
    sources = OUTPUT / "sources"
    sources.mkdir(parents=True, exist_ok=True)
    archive_name = f"libmobi-{VERSION}.tar.gz"
    archive = ROOT / archive_name if (ROOT / archive_name).exists() else sources / archive_name
    if not archive.exists():
        urllib.request.urlretrieve(SOURCE["url"], archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != DIGEST:
        raise SystemExit("The ebook source checksum does not match.")
    env = dict(os.environ, PATH="/usr/bin:/bin:/usr/sbin:/sbin", CC="clang", MACOSX_DEPLOYMENT_TARGET="14.0",
               CFLAGS="-O2 -arch arm64 -mmacosx-version-min=14.0", LDFLAGS="-arch arm64 -mmacosx-version-min=14.0",
               XML2_CONFIG="/usr/bin/xml2-config", PKG_CONFIG="/usr/bin/false", SOURCE_DATE_EPOCH="1718607600")
    env["SDKROOT"] = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    inputs = {"source_sha256": DIGEST, "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "environment": {key: env[key] for key in ("CC", "CFLAGS", "LDFLAGS", "SDKROOT", "SOURCE_DATE_EPOCH")},
              "clang": subprocess.check_output(["clang", "--version"], text=True).splitlines()[0]}
    stamp = WORK / "build-inputs.json"
    if WORK.exists() and (not stamp.exists() or json.loads(stamp.read_text()) != inputs):
        shutil.rmtree(WORK)
    WORK.mkdir(exist_ok=True)
    source = WORK / f"libmobi-{VERSION}"
    if not source.exists():
        with tarfile.open(archive) as file:
            file.extractall(WORK, filter="data")
    stamp.write_text(json.dumps(inputs, indent=2) + "\n")
    log_path = OUTPUT / "build-commands.log"
    with log_path.open("w") as log:
        def run(args):
            log.write(json.dumps(list(map(str, args))) + "\n")
            log.flush()
            subprocess.run(args, cwd=source, env=env, stdout=log, stderr=log, check=True)
        if not (source / "Makefile").exists():
            run(["./configure", f"--prefix={OUTPUT}", "--enable-static", "--disable-shared",
                 "--enable-tools-static", "--disable-encryption", "--enable-xmlwriter", "--with-libxml2", "--with-zlib"])
        run(["make", "-j4"])
        run(["make", "install"])
    binary = OUTPUT / "bin/mobitool"
    if subprocess.check_output(["lipo", "-archs", binary], text=True).strip() != "arm64":
        raise SystemExit("The ebook reader is not ARM64.")
    for line in subprocess.check_output(["otool", "-L", binary], text=True).splitlines()[1:]:
        if not line.strip().startswith(("/usr/lib/", "/System/Library/")):
            raise SystemExit(f"Unbundled ebook dependency: {line}")
    notices = OUTPUT / "licenses"
    notices.mkdir(exist_ok=True)
    shutil.copy2(source / "COPYING", notices / "libmobi-LGPL-3.0.txt")
    shutil.copy2(ROOT / "licenses/GPL-3.0.txt", notices / "GPL-3.0.txt")
    miniz = (source / "src/miniz.c").read_text()
    (notices / "miniz-Unlicense.txt").write_text("miniz 1.15, Rich Geldreich\n\n" + miniz[miniz.rfind("/*\n This is free"):])
    (notices / "components.txt").write_text(f"libmobi {VERSION}, LGPL-3.0-or-later, Bartek Fabiszewski.\n"
        "https://github.com/bfabiszewski/libmobi\nIncludes miniz 1.15 under the Unlicense.\n"
        "libxml2 and zlib are supplied by macOS.\nEncryption support is disabled in this build.\n")
    (sources / "tools").mkdir(exist_ok=True)
    (sources / "licenses").mkdir(exist_ok=True)
    shutil.copy2(Path(__file__), sources / "tools/build-ebook.py")
    shutil.copy2(ROOT / "tools/native-sources.json", sources / "tools/native-sources.json")
    shutil.copy2(ROOT / "licenses/GPL-3.0.txt", sources / "licenses/GPL-3.0.txt")
    if archive.parent != sources:
        shutil.copy2(archive, sources / archive.name)
    (sources / "build-ebook.py").unlink(missing_ok=True)
    shutil.copy2(stamp, OUTPUT / "build-inputs.json")
    link = ROOT / ".tools/bin/mobitool"
    link.parent.mkdir(exist_ok=True)
    link.unlink(missing_ok=True)
    link.symlink_to("../ebook/bin/mobitool")
    print(f"Ebook reader: {binary}")


if __name__ == "__main__":
    main()
