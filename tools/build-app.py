#!/usr/bin/env python3
"""Package a local ARM64 preview with its conversion tools."""

from pathlib import Path
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile

from release_config import contains_checkout_path, load_release

ROOT = Path(__file__).resolve().parent.parent
RELEASE = load_release()


def run(*args):
    subprocess.run(list(map(str, args)), cwd=ROOT, check=True)


def executable_targets(app):
    """Return every Mach-O file after checking the release architecture and target."""
    targets = []
    for path in sorted(app.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        probe = subprocess.run(["/usr/bin/lipo", "-archs", path], capture_output=True, text=True)
        if probe.returncode != 0:
            continue
        architectures = probe.stdout.split()
        if architectures != ["arm64"]:
            raise SystemExit(f"Not a thin ARM64 binary: {path.relative_to(app)} ({' '.join(architectures)})")
        load = subprocess.check_output(["/usr/bin/otool", "-l", path], text=True).splitlines()
        minimum = next((line.split()[1] for line in load if line.split()[:1] == ["minos"]), None)
        if minimum != RELEASE.minimum_system_version:
            raise SystemExit(f"Built for macOS {minimum or 'an unrecorded version'}, not "
                             f"{RELEASE.minimum_system_version}: {path.relative_to(app)}")
        if RELEASE.signed and contains_checkout_path(path):
            raise SystemExit(f"The checkout path is embedded in {path.relative_to(app)}. "
                             "Rebuild that component with source-path remapping before release signing.")
        targets.append(path)
    if not targets:
        raise SystemExit("No executable was staged in the app.")
    return targets


def main():
    application_icon = ROOT / "branding/generated/Allomer.icns"
    if not application_icon.is_file():
        raise SystemExit("Missing Allomer.icns. Run tools/build-brand-assets.py first.")
    run("python3", ROOT / "tools/check-dependencies.py")
    media_directory = ROOT / ".tools/media/Frameworks/Media"
    media_libraries = list(media_directory.glob("*.dylib"))
    presentation = ROOT / ".tools/native/Resources/Presentation"
    word = ROOT / ".tools/native/Resources/Word"
    report = json.loads((ROOT / ".tools/presentation/build.json").read_text())
    for directory, key, label in ((presentation, "javascript_sha256", "presentation"), (word, "word_javascript_sha256", "Word")):
        if not (directory / "renderer.js").is_file():
            raise SystemExit(f"Missing {label} renderer. Run tools/build-native.py first.")
        if hashlib.sha256((directory / "renderer.js").read_bytes()).hexdigest() != report[key]:
            raise SystemExit(f"{label.capitalize()} resources are stale. Run tools/build-native.py first.")
    if not media_libraries:
        raise SystemExit("Missing shared media libraries. Run tools/build-media.py first.")
    tools = {
        "carta": ROOT / ".tools/bin/carta",
        "ffmpeg": ROOT / ".tools/media/bin/ffmpeg",
        "ffprobe": ROOT / ".tools/media/bin/ffprobe",
        "tabular": ROOT / ".tools/tabular/bin/tabular",
        "mobitool": ROOT / ".tools/ebook/bin/mobitool",
        "fontconvert": ROOT / ".tools/fontconvert/bin/fontconvert",
        "fontguard": ROOT / ".tools/fontconvert/bin/fontguard",
        "mailfile": ROOT / ".tools/mailfile/bin/mailfile",
        "modeltool": ROOT / ".tools/models/bin/modeltool",
        "gs": ROOT / ".tools/pdf/bin/gs",
        "postscript": ROOT / ".tools/pdf/bin/postscript",
        "pdftops": ROOT / ".tools/poppler/bin/pdftops",
        "psguard": ROOT / ".tools/poppler/bin/psguard",
        "mutool": ROOT / ".tools/mupdf/bin/mutool",
        "pdfguard": ROOT / ".tools/mupdf/bin/pdfguard",
        "nativeconvert": ROOT / ".tools/native/bin/nativeconvert",
        "nativeguard": ROOT / ".tools/native/bin/nativeguard",
        "webconvert": ROOT / ".tools/native/bin/webconvert",
        "webguard": ROOT / ".tools/native/bin/webguard",
        "cwebp": ROOT / ".tools/webp/bin/cwebp",
        "webpguard": ROOT / ".tools/webp/bin/webpguard",
        "webpanim": ROOT / ".tools/webp/bin/webpanim",
        "webpanimguard": ROOT / ".tools/webp/bin/webpanimguard",
        "cjxl": ROOT / ".tools/jpegxl/bin/cjxl",
        "jxlguard": ROOT / ".tools/jpegxl/bin/jxlguard",
        "tiffcp": ROOT / ".tools/tiff/bin/tiffcp",
        "tiffguard": ROOT / ".tools/tiff/bin/tiffguard",
        "vectortrace": ROOT / ".tools/vectortrace/bin/vectortrace",
        "traceguard": ROOT / ".tools/vectortrace/bin/traceguard",
    }
    for name, binary in [*tools.items(), *((path.name, path) for path in media_libraries)]:
        if not binary.is_file():
            raise SystemExit(f"Missing {name}. Run the documented source/tool setup first.")
        if subprocess.check_output(["/usr/bin/lipo", "-archs", binary], text=True).strip() != "arm64":
            raise SystemExit(f"Expected an ARM64 tool: {name}")
        for line in subprocess.check_output(["/usr/bin/otool", "-L", binary], text=True).splitlines()[1:]:
            library = line.strip().split(" (", 1)[0]
            local = name in ("ffmpeg", "ffprobe", "nativeconvert") or binary.parent == media_directory
            bundled = local and library.startswith("@rpath/") and (media_directory / library.removeprefix("@rpath/")).is_file()
            if not library.startswith(("/usr/lib/", "/System/Library/")) and not bundled:
                raise SystemExit(f"Unbundled library in {name}: {library}")
    preview = ROOT / "dist/preview"
    preview.mkdir(parents=True, exist_ok=True)
    scratch_key = hashlib.sha256(str(ROOT.resolve()).encode()).hexdigest()[:12]
    scratch = Path("/private/tmp") / f"com.ashbench.allomer-swift-build-{scratch_key}"
    scratch.mkdir(parents=True, exist_ok=True)
    run("swift", "build", "-c", "release", "--arch", "arm64", "--force-resolved-versions",
        "--scratch-path", scratch)
    build = Path(subprocess.check_output(["swift", "build", "-c", "release", "--arch", "arm64",
                                         "--force-resolved-versions", "--scratch-path", scratch,
                                         "--show-bin-path"], cwd=ROOT, text=True).strip())
    with tempfile.TemporaryDirectory(dir=preview) as staging:
        app = Path(staging) / f"{RELEASE.product_name}.app"
        contents = app / "Contents"
        macos = contents / "MacOS"
        resources = contents / "Resources"
        helpers = contents / "Helpers"
        notices = resources / "Licenses"
        for directory in (macos, helpers, notices):
            directory.mkdir(parents=True, exist_ok=True)
        info = {
            "CFBundleName": RELEASE.product_name,
            "CFBundleDisplayName": RELEASE.product_name,
            "CFBundleIdentifier": RELEASE.bundle_identifier,
            "CFBundleExecutable": "AllomerApp",
            "CFBundleIconFile": application_icon.name,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": RELEASE.bundle_version,
            "CFBundleVersion": RELEASE.build,
            "NSHumanReadableCopyright": RELEASE.copyright,
            "LSMinimumSystemVersion": RELEASE.minimum_system_version,
            "LSArchitecturePriority": ["arm64"],
            "LSApplicationCategoryType": "public.app-category.utilities",
            "NSHighResolutionCapable": True,
            "NSPrincipalClass": "NSApplication",
            "NSDesktopFolderUsageDescription":
                f"{RELEASE.product_name} converts files in watched folders on your Desktop.",
            "NSDocumentsFolderUsageDescription":
                f"{RELEASE.product_name} converts files in watched folders in Documents.",
            "NSDownloadsFolderUsageDescription":
                f"{RELEASE.product_name} converts files in watched folders in Downloads.",
            "NSRemovableVolumesUsageDescription":
                f"{RELEASE.product_name} converts files in watched folders on removable volumes.",
            "NSNetworkVolumesUsageDescription":
                f"{RELEASE.product_name} converts files in watched folders on network volumes.",
            "UTImportedTypeDeclarations": [{
                "UTTypeIdentifier": "com.apple.iconcomposer.icon",
                "UTTypeDescription": "Icon Composer Icon",
                "UTTypeConformsTo": ["com.apple.package"],
                "UTTypeTagSpecification": {"public.filename-extension": ["icon"]},
            }],
        }
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        shutil.copy2(application_icon, resources / application_icon.name)
        shutil.copytree(build / "Allomer_ConversionCore.bundle", resources / "Allomer_ConversionCore.bundle")
        shutil.copytree(presentation, resources / "Presentation")
        shutil.copytree(word, resources / "Word")
        shutil.copytree(ROOT / ".tools/poppler/Resources/Poppler", resources / "Poppler")
        shutil.copytree(ROOT / ".tools/presentation/licenses", notices / "presentation")
        shutil.copy2(ROOT / ".tools/presentation/build.json", notices / "presentation/build.json")
        for name in ("AllomerApp", "allomer"):
            shutil.copy2(build / name, macos / name)
            run("/usr/bin/codesign", "--remove-signature", macos / name)
            run("/usr/bin/strip", "-S", "-x", macos / name)
        for name, binary in tools.items():
            shutil.copy2(binary, helpers / name)
        media = contents / "Frameworks/Media"
        media.mkdir(parents=True)
        for library in media_libraries:
            if library.is_symlink():
                target = library.readlink()
                if target.is_absolute() or target.name != str(target) or not (media_directory / target).is_file():
                    raise SystemExit(f"Invalid media library link: {library}")
                (media / library.name).symlink_to(target)
            else:
                shutil.copy2(library, media / library.name)
        shutil.copy2(ROOT / "LICENSE", notices / "Allomer-MIT.txt")
        for notice in (ROOT / "licenses").glob("*.txt"):
            shutil.copy2(notice, notices / notice.name)
        shutil.copy2(ROOT / "THIRD_PARTY.md", notices / "THIRD_PARTY.md")
        shutil.copytree(ROOT / ".tools/media/licenses", notices / "media")
        shutil.copytree(ROOT / ".tools/webp/licenses", notices / "webp")
        shutil.copytree(ROOT / ".tools/jpegxl/licenses", notices / "jpegxl")
        shutil.copytree(ROOT / ".tools/tiff/licenses", notices / "tiff")
        shutil.copytree(ROOT / ".tools/carta/licenses", notices / "carta")
        shutil.copytree(ROOT / ".tools/tabular/licenses", notices / "tabular")
        shutil.copytree(ROOT / ".tools/mailfile/licenses", notices / "mailfile")
        shutil.copytree(ROOT / ".tools/vectortrace/licenses", notices / "vectortrace")
        shutil.copytree(ROOT / ".tools/fontconvert/licenses", notices / "fontconvert")
        shutil.copytree(ROOT / ".tools/ebook/licenses", notices / "ebook")
        shutil.copytree(ROOT / ".tools/fonts/licenses", notices / "fonts")
        shutil.copytree(ROOT / ".tools/models/licenses", notices / "models")
        shutil.copytree(ROOT / ".tools/pdf/licenses", notices / "pdf")
        shutil.copytree(ROOT / ".tools/poppler/licenses", notices / "poppler")
        shutil.copytree(ROOT / ".tools/mupdf/licenses", notices / "mupdf")
        shared_rust = notices / "Rust"
        shared_rust.mkdir()
        for helper in ("carta", "tabular", "mailfile", "vectortrace", "fontconvert"):
            for name in ("Rust-standard-library.html", "licenses"):
                original = notices / helper / name
                shared = shared_rust / name
                if not shared.exists():
                    shutil.move(original, shared)
                elif original.is_dir():
                    original_files = {file.relative_to(original): file.read_bytes() for file in original.rglob("*") if file.is_file()}
                    shared_files = {file.relative_to(shared): file.read_bytes() for file in shared.rglob("*") if file.is_file()}
                    if original_files != shared_files:
                        raise SystemExit(f"Rust notices differ in {helper}. Rebuild the Rust helpers with the pinned toolchain.")
                    shutil.rmtree(original)
                else:
                    if original.read_bytes() != shared.read_bytes():
                        raise SystemExit(f"Rust notices differ in {helper}. Rebuild the Rust helpers with the pinned toolchain.")
                    original.unlink()
                original.symlink_to(Path("..") / "Rust" / name)
        targets = executable_targets(app)
        identity = RELEASE.signing_identity or "-"
        options = ["--options", "runtime", "--timestamp"] if RELEASE.signed else []
        main_executable = macos / info["CFBundleExecutable"]
        for binary in [path for path in targets if path != main_executable] + [main_executable]:
            run("/usr/bin/codesign", "--force", "--sign", identity, *options, binary)
        run("/usr/bin/codesign", "--force", "--sign", identity, *options, app)
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=2", app)
        output = preview / app.name
        if output.exists():
            shutil.rmtree(output)
        shutil.move(app, output)
    print(f"Local preview: {output}")
    if RELEASE.signed:
        print("The app is signed. Run tools/release.py to notarize it and build the release disk image.")
    else:
        print("The app is signed ad hoc for local testing. It cannot be notarized or distributed as a release.")


if __name__ == "__main__":
    main()
