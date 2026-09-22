#!/usr/bin/env python3
"""Build the original converter that uses macOS frameworks."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess


def main():
    root = Path(__file__).resolve().parent.parent
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("Build on an Apple Silicon Mac.")
    output = root / ".tools/native"
    (output / "bin").mkdir(parents=True, exist_ok=True)
    subprocess.run(["python3", root / "tools/build-presentation.py"], check=True)
    shutil.copytree(root / ".tools/presentation/Resources", output / "Resources", dirs_exist_ok=True)
    env = dict(os.environ, PATH="/usr/bin:/bin:/usr/sbin:/sbin", MACOSX_DEPLOYMENT_TARGET="14.0")
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    env["SDKROOT"] = sdk
    report = {"sdk": sdk, "swift": subprocess.check_output(["swiftc", "--version"], text=True).splitlines()[0],
              "binaries": {}, "sources": {}}
    media = root / ".tools/media"
    libraries = media / "Frameworks/Media"
    if not (media / "include/libavcodec/avcodec.h").is_file() or not (libraries / "libavcodec.dylib").is_file():
        raise SystemExit("Build the bundled media libraries before the native helper.")
    (output / "Frameworks").mkdir(exist_ok=True)
    media_link = output / "Frameworks/Media"
    if media_link.is_symlink():
        media_link.unlink()
    media_link.symlink_to("../../media/Frameworks/Media", target_is_directory=True)
    bitmap_object = output / "bitmap-subtitle.o"
    subprocess.run(["clang", "-O2", "-arch", "arm64", "-mmacosx-version-min=14.0", "-I", media / "include",
        "-c", root / "helpers/nativeconvert/BitmapSubtitle.c", "-o", bitmap_object], env=env, check=True)
    for name, guard in (("nativeconvert", "nativeguard"), ("webconvert", "webguard")):
        binary, launcher = output / "bin" / name, output / "bin" / guard
        native_flags = ["-import-objc-header", root / "helpers/nativeconvert/BitmapSubtitle.h", bitmap_object,
            "-L", libraries, "-lavformat", "-lavcodec", "-lavutil", "-Xlinker", "-rpath", "-Xlinker",
            "@loader_path/../Frameworks/Media"] if name == "nativeconvert" else []
        subprocess.run(["swiftc", "-O", "-whole-module-optimization", "-target", "arm64-apple-macosx14.0", "-sdk", sdk,
            *sorted((root / f"helpers/{name}").glob("*.swift")), *native_flags, "-o", binary], env=env, check=True)
        flags = ["-DWEB_RESOURCE_DIRECTORY"] if name == "webconvert" else ["-DNATIVE_MEDIA_LIBRARIES"]
        subprocess.run(["clang", "-O2", "-arch", "arm64", "-mmacosx-version-min=14.0", "-Wno-deprecated-declarations",
            f'-DCONVERTER_BINARY_NAME="{name}"', "-DNATIVE_FRAMEWORK_CACHES", *flags,
            root / "helpers/toolguard/main.c", "-o", launcher], env=env, check=True)
        for tool in (binary, launcher):
            if subprocess.check_output(["lipo", "-archs", tool], text=True).strip() != "arm64":
                raise SystemExit(f"The native tool is not ARM64: {tool.name}")
            for line in subprocess.check_output(["otool", "-L", tool], text=True).splitlines()[1:]:
                dependency = line.strip().split(" (", 1)[0]
                bundled = tool == binary and name == "nativeconvert" and dependency.startswith("@rpath/") \
                    and (libraries / dependency.removeprefix("@rpath/")).is_file()
                if not dependency.startswith(("/usr/lib/", "/System/Library/")) and not bundled:
                    raise SystemExit(f"Unbundled native dependency: {line}")
            report["binaries"][tool.name] = {"sha256": hashlib.sha256(tool.read_bytes()).hexdigest(), "bytes": tool.stat().st_size}
            link = root / ".tools/bin" / tool.name
            link.parent.mkdir(exist_ok=True)
            link.unlink(missing_ok=True)
            link.symlink_to(f"../native/bin/{tool.name}")
    for name in ("helpers/nativeconvert/main.swift", "helpers/nativeconvert/WordContainer.swift",
                 "helpers/nativeconvert/BitmapSubtitle.swift", "helpers/nativeconvert/BitmapSubtitle.c",
                 "helpers/nativeconvert/BitmapSubtitle.h",
                 "helpers/webconvert/main.swift", "helpers/webconvert/PresentationRenderer.swift",
                 "helpers/webconvert/WordRenderer.swift",
                 "helpers/toolguard/main.c", "tools/build-native.py", "LICENSE"):
        target = output / "sources" / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / name, target)
        report["sources"][name] = hashlib.sha256((root / name).read_bytes()).hexdigest()
    report["shared_media_libraries"] = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sorted(libraries.glob("*.dylib")) if not path.is_symlink()}
    (output / "build-inputs.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Native tools: {output / 'bin'}")


if __name__ == "__main__":
    main()
