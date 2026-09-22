#!/usr/bin/env python3
"""Build local-only ARM64 media tools from checksum-pinned upstream sources."""

import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import zipfile


ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / ".tools/media-build"
PREFIX = WORK / "prefix"
OUTPUT = ROOT / ".tools/media"
ALIAS = Path("/private/tmp/com.ashbench.allomer-media")
PINS = json.loads((ROOT / "tools/native-sources.json").read_text())
SOURCES = PINS["media"]
BUILD_TOOLS = PINS["font-build-tools"]
JPEG_PATCH = ROOT / "tools/ffmpeg-jpeg-validation.patch"
GIF_PATCH = ROOT / "tools/ffmpeg-gif-validation.patch"
PALETTE_PATCH = ROOT / "tools/ffmpeg-gif-palette.patch"
VORBIS_PATCH = ROOT / "tools/ffmpeg-vorbis-timing.patch"
CHAINS_PATCH = ROOT / "tools/ffmpeg-vorbis-chains.patch"


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("Build on an Apple Silicon Mac.")
    env = dict(os.environ)
    env["PATH"] = f"/opt/homebrew/bin:{env['PATH']}"
    for tool in ("cmake", "pkg-config", "make", "clang", "curl"):
        if not shutil.which(tool, path=env["PATH"]):
            raise SystemExit(f"Missing build tool: {tool}")
    base_flags = "-O2 -arch arm64 -mmacosx-version-min=14.0"
    path_flags = f"-ffile-prefix-map={ROOT}=. -fdebug-prefix-map={ROOT}=."
    build_prefix = ALIAS / "prefix"
    build_output = ALIAS / "output"
    env.update(MACOSX_DEPLOYMENT_TARGET="14.0", CC="clang", CXX="clang++",
               CFLAGS=f"{base_flags} {path_flags}", CXXFLAGS=f"{base_flags} {path_flags}",
               CPPFLAGS=f"-I{build_prefix / 'include'}", LDFLAGS=f"-L{build_prefix / 'lib'}",
               PKG_CONFIG_LIBDIR=str(build_prefix / "lib/pkgconfig"), PKG_CONFIG_PATH="")
    env["SDKROOT"] = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    inputs = {
        "script_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "jpeg_patch_sha256": hashlib.sha256(JPEG_PATCH.read_bytes()).hexdigest(),
        "gif_patch_sha256": hashlib.sha256(GIF_PATCH.read_bytes()).hexdigest(),
        "palette_patch_sha256": hashlib.sha256(PALETTE_PATCH.read_bytes()).hexdigest(),
        "vorbis_patch_sha256": hashlib.sha256(VORBIS_PATCH.read_bytes()).hexdigest(),
        "chains_patch_sha256": hashlib.sha256(CHAINS_PATCH.read_bytes()).hexdigest(),
        "sources": SOURCES,
        "build_tools": BUILD_TOOLS,
        "python": sys.version,
        "work_directory": str(WORK),
        "flags": {key: env[key] for key in ("CC", "CXX", "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "SDKROOT")},
        "tools": {name: {
            "path": shutil.which(name, path=env["PATH"]),
            "version": subprocess.check_output([name, "--version"], env=env, text=True).splitlines()[0],
        } for name in ("clang", "cmake", "pkg-config", "make")},
        "sdk_version": subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip(),
    }
    stamp = WORK / "build-inputs.json"
    previous = json.loads(stamp.read_text()) if stamp.exists() else None
    fresh = previous != inputs
    if fresh and WORK.exists():
        shutil.rmtree(WORK)
    jobs = str(max(1, min(4, (os.cpu_count() or 2) - 1)))
    WORK.mkdir(parents=True, exist_ok=True)
    PREFIX.mkdir(parents=True, exist_ok=True)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    ALIAS.mkdir(parents=True, exist_ok=True)
    for link, target in ((build_prefix, PREFIX), (build_output, OUTPUT)):
        if link.is_symlink() and link.resolve() != target:
            link.unlink()
        if link.exists() and not link.is_symlink():
            raise SystemExit(f"Build alias is not a symbolic link: {link}")
        if not link.exists():
            link.symlink_to(target, target_is_directory=True)
    stamp.write_text(json.dumps(inputs, indent=2) + "\n")
    source_bundle = OUTPUT / "sources"
    source_bundle.mkdir(exist_ok=True)
    notices = OUTPUT / "licenses"
    notices.mkdir(exist_ok=True)
    commands = OUTPUT / "build-commands.log"
    with commands.open("w" if fresh else "a") as log:
        def run(args, cwd):
            log.write(json.dumps({"cwd": str(cwd), "args": list(map(str, args))}) + "\n")
            log.flush()
            subprocess.run(list(map(str, args)), cwd=cwd, env=env, check=True, stdout=log, stderr=log)

        def fetch(item, archive_name):
            provided_archive = ROOT / archive_name
            archive = provided_archive if provided_archive.exists() else source_bundle / archive_name
            cached = ROOT / ".tools/fonts/sources" / archive_name
            if not archive.exists() and cached.is_file():
                shutil.copy2(cached, archive)
            if not archive.exists():
                print(f"Downloading {item['name']} {item['version']}", flush=True)
                temporary = archive.with_suffix(".download")
                run(["curl", "--fail", "--location", "--retry", "2", "--connect-timeout", "15",
                     "--max-time", "180", item["url"], "-o", temporary], WORK)
                with temporary.open("rb") as file:
                    digest = hashlib.file_digest(file, "sha256").hexdigest()
                if digest != item["sha256"]:
                    temporary.unlink()
                    raise SystemExit(f"Source checksum mismatch: {item['name']}")
                temporary.rename(archive)
            with archive.open("rb") as file:
                if hashlib.file_digest(file, "sha256").hexdigest() != item["sha256"]:
                    raise SystemExit(f"Source checksum mismatch: {item['name']}")
            if archive.parent != source_bundle:
                shutil.copy2(archive, source_bundle / archive_name)
            return archive

        build_tools = WORK / "build-tools"
        build_tools.mkdir(exist_ok=True)
        for item in BUILD_TOOLS:
            with zipfile.ZipFile(fetch(item, item["archive"])) as archive:
                archive.extractall(build_tools)
        ninja_version = next(item["version"] for item in BUILD_TOOLS if item["name"] == "ninja")
        ninja = build_tools / f"ninja-{ninja_version}.data/scripts/ninja"
        ninja.chmod(0o755)
        env.update(PYTHONPATH=str(build_tools), NINJA=str(ninja))
        meson = [sys.executable, "-m", "mesonbuild.mesonmain"]

        for item in SOURCES:
            name = item["name"]
            archive = fetch(item, f"{name}-{item['version']}.tar")
            source = WORK / name
            if not source.exists():
                staging = WORK / f"extract-{name}"
                staging.mkdir(exist_ok=False)
                with tarfile.open(archive) as tar:
                    tar.extractall(staging, filter="data")
                roots = list(staging.iterdir())
                if len(roots) != 1 or not roots[0].is_dir():
                    raise SystemExit(f"Unexpected source archive layout: {name}")
                roots[0].rename(source)
                staging.rmdir()
            for file in source.iterdir():
                if file.is_file() and file.name.upper().startswith(("LICENSE", "COPYING", "AUTHORS", "PATENTS", "NOTICE")):
                    shutil.copy2(file, notices / f"{name}-{file.name}")
            if name == "dav1d":
                shutil.copy2(source / "doc/PATENTS", notices / "dav1d-PATENTS")
            stamp = source / ".allomer-built"
            if stamp.exists():
                continue
            print(f"Building {name}; details in {commands.relative_to(ROOT)}", flush=True)
            if name in ("libogg", "libvorbis", "lame", "opus"):
                args = ["./configure", f"--prefix={build_prefix}", "--disable-shared", "--enable-static"]
                if name == "lame":
                    args += ["--disable-frontend", "--disable-decoder", "--disable-analyzer-hooks"]
                if name == "opus":
                    args += ["--disable-extra-programs", "--disable-doc"]
                run(args, source)
                # Vorbis 1.3.7's configure script replaces CFLAGS with obsolete Darwin flags.
                overrides = [f"CFLAGS={env['CFLAGS']}"] if name == "libvorbis" else []
                run(["make", f"-j{jobs}", *overrides], source)
                run(["make", "install", *overrides], source)
            elif name == "libvpx":
                run(["./configure", f"--prefix={build_prefix}", "--target=arm64-darwin23-gcc",
                     "--enable-pic", "--enable-vp9-highbitdepth", "--disable-shared", "--enable-static", "--disable-examples",
                     "--disable-tools", "--disable-docs", "--disable-unit-tests"], source)
                run(["make", f"-j{jobs}"], source)
                run(["make", "install"], source)
            elif name == "libaom":
                run(["cmake", "-S", ".", "-B", "build", f"-DCMAKE_INSTALL_PREFIX={build_prefix}",
                     "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_ARCHITECTURES=arm64",
                     "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0", "-DBUILD_SHARED_LIBS=OFF",
                     "-DENABLE_APPS=OFF", "-DENABLE_DOCS=OFF", "-DENABLE_EXAMPLES=OFF",
                     "-DENABLE_TESTS=OFF", "-DENABLE_TOOLS=OFF", "-DCONFIG_AV1_DECODER=0",
                     "-DCONFIG_AV1_ENCODER=1", "-DCONFIG_WEBM_IO=0"], source)
                run(["cmake", "--build", "build", "--parallel", jobs], source)
                run(["cmake", "--install", "build"], source)
            elif name == "svt-av1":
                run(["cmake", "-S", ".", "-B", "build", f"-DCMAKE_INSTALL_PREFIX={build_prefix}",
                     "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_ARCHITECTURES=arm64",
                     "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0", "-DBUILD_SHARED_LIBS=OFF", "-DBUILD_APPS=OFF"], source)
                run(["cmake", "--build", "build", "--parallel", jobs], source)
                run(["cmake", "--install", "build"], source)
            elif name == "dav1d":
                run([*meson, "setup", "build", f"--prefix={build_prefix}", "--libdir=lib",
                     "--buildtype=release", "--default-library=static", "--wrap-mode=nofallback",
                     "-Denable_tools=false", "-Denable_tests=false", "-Denable_examples=false",
                     "-Denable_docs=false", "-Dxxhash_muxer=disabled"], source)
                run([*meson, "compile", "-C", "build", "-j", jobs], source)
                run([*meson, "install", "-C", "build"], source)
            else:
                with tarfile.open(archive) as tar:
                    for path in ("libavcodec/mjpegdec.c", "libavcodec/gifdec.c", "libavformat/gifdec.c", "libavfilter/vf_palettegen.c", "libavfilter/vf_paletteuse.c", "libavformat/oggparsevorbis.c", "libavcodec/vorbisdec.c", "libavcodec/libvorbisdec.c", "libavformat/oggdec.c", "libavformat/oggdec.h"):
                        member = next(item for item in tar.getmembers() if item.name.endswith("/" + path))
                        (source / path).write_bytes(tar.extractfile(member).read())
                for patch in (JPEG_PATCH, GIF_PATCH, PALETTE_PATCH, VORBIS_PATCH, CHAINS_PATCH):
                    run(["patch", "--batch", "--forward", "-F", "0", "-p1", "-i", patch], source)
                run(["./configure", f"--prefix={build_output}", "--arch=arm64", "--target-os=darwin",
                     "--disable-static", "--enable-shared", "--disable-autodetect", "--disable-network",
                     f"--shlibdir={build_output / 'Frameworks/Media'}", "--install-name-dir=@rpath",
                     "--disable-avdevice", "--disable-ffplay", "--disable-doc", "--disable-debug", "--enable-small",
                     "--disable-protocols", "--enable-protocol=file,pipe", "--pkg-config-flags=--static",
                     f"--extra-cflags={base_flags} -I{build_prefix / 'include'}",
                     f"--extra-ldflags={env['LDFLAGS']} -mmacosx-version-min=14.0 -Wl,-rpath,@loader_path/../Frameworks/Media",
                     "--enable-videotoolbox", "--enable-audiotoolbox", "--enable-libmp3lame",
                     "--enable-libopus", "--enable-libvorbis", "--enable-libvpx", "--enable-libaom",
                     "--disable-decoder=libaom_av1", "--enable-libsvtav1", "--enable-libdav1d",
                     "--enable-zlib", "--enable-bzlib"], source)
                run(["make", f"-j{jobs}"], source)
                run(["make", "install"], source)
            stamp.write_text(item["sha256"] + "\n")
        (source_bundle / "tools").mkdir(exist_ok=True)
        for filename in ("build-media.py", "native-sources.json", JPEG_PATCH.name, GIF_PATCH.name, PALETTE_PATCH.name, VORBIS_PATCH.name, CHAINS_PATCH.name):
            shutil.copy2(ROOT / "tools" / filename, source_bundle / "tools" / filename)
        (source_bundle / "tools/media-sources.json").unlink(missing_ok=True)
        (notices / "ffmpeg-local-changes.txt").write_text(
            "The local FFmpeg patch rejects a missing JPEG end marker when AV_EF_EXPLODE is requested.\n"
            "Strict GIF validation rejects an incomplete block stream or pixel rows.\n"
            "The palette generator supports two colors, an optional alpha threshold, and exact colors for unsplit palette entries.\n"
            "An optional bounded single-frame histogram retains 8-bit colors up to 65,536 distinct colors, then retries with 6-bit color channels.\n"
            "Palette application offers an optional per-bucket cache limit without changing color selection.\n"
            "Dithering is skipped when palettegen reports that no color reduction occurred.\n"
            "Vorbis timing excludes the first packet's priming duration when its audio page also ends the stream.\n"
            "Vorbis decoders accept new headers between chained streams; packet times include completed links.\n"
            "A seek to zero on a newly opened Vorbis input uses its known data offset. New header buffers include checked zero padding.\n"
            "Local changes use each file's existing license: MIT for oggdec.c/h; LGPL-2.1-or-later for the other changed files.\n")
        libraries_directory = OUTPUT / "Frameworks/Media"
        media_libraries = list(libraries_directory.glob("*.dylib"))
        if not media_libraries:
            raise SystemExit("The media build produced no shared libraries.")
        for binary in [OUTPUT / "bin/ffmpeg", OUTPUT / "bin/ffprobe", *media_libraries]:
            libraries = subprocess.check_output(["/usr/bin/otool", "-L", binary], text=True)
            for line in libraries.splitlines()[1:]:
                dependency = line.strip().split(" (", 1)[0]
                local = dependency.startswith("@rpath/") and (libraries_directory / dependency.removeprefix("@rpath/")).is_file()
                if not dependency.startswith(("/usr/lib/", "/System/Library/")) and not local:
                    raise SystemExit(f"Unbundled runtime dependency: {dependency}")
        for name in ("ffmpeg", "ffprobe"):
            run([OUTPUT / "bin" / name, "-version"], WORK)
        print(f"Built self-contained media tools at {OUTPUT}", flush=True)


if __name__ == "__main__":
    main()
