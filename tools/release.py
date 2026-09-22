#!/usr/bin/env python3
"""Notarize, staple, verify, and describe an Allomer release."""

from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

from release_config import ROOT, contains_checkout_path, load_release


RELEASE = load_release()
APP = RELEASE.app_path
IMAGE = RELEASE.disk_image_path
PREVIEW = APP.parent
MANIFEST = PREVIEW / "release-manifest.json"


def run(*args, cwd=ROOT):
    subprocess.run(list(map(str, args)), cwd=cwd, check=True)


def quiet(*args, cwd=ROOT):
    result = subprocess.run(list(map(str, args)), cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        details = result.stderr.strip() or result.stdout.strip()
        raise SystemExit(details or f"Command failed: {' '.join(map(str, args))}")


def read(*args, cwd=ROOT, merge=False):
    return subprocess.run(list(map(str, args)), cwd=cwd, check=True, text=True,
                          stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT if merge else subprocess.PIPE).stdout


def field(text, name, default=None):
    prefix = f"{name}="
    return next((line[len(prefix):] for line in text.splitlines() if line.startswith(prefix)), default)


def load_value(lines, name):
    return next((parts[1] for line in lines if (parts := line.split())[:1] == [name]), None)


def digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def source_state():
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True,
                              capture_output=True)
    if revision.returncode:
        return {"revision": None, "clean": False, "description": "The repository has no commit."}
    status = read("git", "status", "--porcelain=v1", "--untracked-files=all")
    return {"revision": revision.stdout.strip(), "clean": not status,
            "description": "clean" if not status else "The working tree has uncommitted files."}


def inspect_app(require_release_signature):
    """Read architecture, deployment target, and signature data from the staged app."""
    info = plistlib.loads((APP / "Contents/Info.plist").read_bytes())
    expected = {
        "CFBundleName": RELEASE.product_name,
        "CFBundleIdentifier": RELEASE.bundle_identifier,
        "CFBundleShortVersionString": RELEASE.bundle_version,
        "CFBundleVersion": RELEASE.build,
        "LSMinimumSystemVersion": RELEASE.minimum_system_version,
    }
    for key, value in expected.items():
        if info.get(key) != value:
            raise SystemExit(f"Info.plist has {key}={info.get(key)!r}; expected {value!r}.")
    report = {}
    teams = set()
    local_paths = []
    for path in sorted(APP.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        probe = subprocess.run(["/usr/bin/lipo", "-archs", path], capture_output=True, text=True)
        if probe.returncode:
            continue
        name = str(path.relative_to(APP))
        architectures = probe.stdout.split()
        if architectures != ["arm64"]:
            raise SystemExit(f"Not a thin ARM64 binary: {name} ({' '.join(architectures)})")
        load = read("/usr/bin/otool", "-l", path).splitlines()
        minimum = load_value(load, "minos")
        if minimum != RELEASE.minimum_system_version:
            raise SystemExit(f"Built for macOS {minimum}, not {RELEASE.minimum_system_version}: {name}")
        quiet("/usr/bin/codesign", "--verify", "--strict", path)
        shown = read("/usr/bin/codesign", "--display", "--verbose=4", path, merge=True)
        flags = re.search(r"flags=0x[0-9a-f]+\(([^)]*)\)", shown)
        entry = {
            "architecture": " ".join(architectures),
            "minimum_macos": minimum,
            "sdk": load_value(load, "sdk"),
            "bytes": path.stat().st_size,
            "signing_identifier": field(shown, "Identifier"),
            "code_directory_hash": field(shown, "CDHash"),
            "team_identifier": field(shown, "TeamIdentifier", "not set"),
            "hardened_runtime": flags is not None and "runtime" in flags.group(1).split(","),
            "secure_timestamp": field(shown, "Timestamp") is not None,
        }
        if require_release_signature and not entry["hardened_runtime"]:
            raise SystemExit(f"The hardened runtime is missing: {name}")
        if require_release_signature and not entry["secure_timestamp"]:
            raise SystemExit(f"The secure timestamp is missing: {name}")
        if require_release_signature and entry["team_identifier"] != RELEASE.team_identifier:
            raise SystemExit(f"Signed by team {entry['team_identifier']}, not {RELEASE.team_identifier}: {name}")
        if contains_checkout_path(path):
            local_paths.append(name)
        teams.add(entry["team_identifier"])
        report[name] = entry
    if not report:
        raise SystemExit(f"No executable in {APP}. Run tools/build-app.py first.")
    if len(teams) != 1:
        raise SystemExit(f"The app mixes team identifiers: {', '.join(sorted(teams))}")
    if local_paths and require_release_signature:
        raise SystemExit("The checkout path is embedded in release binaries: " + ", ".join(local_paths))
    if local_paths:
        print(f"Local checkout paths are embedded in {len(local_paths)} preview binaries. "
              "Release signing will refuse them until their build flags remap source paths.")
    return report


def notarize(target):
    """Submit one artifact, save Apple's response and log, then staple its ticket."""
    profile = RELEASE.notary_keychain_profile
    with tempfile.TemporaryDirectory(prefix="notarize-", dir=PREVIEW) as temporary:
        upload = target
        if target.is_dir():
            upload = Path(temporary) / f"{target.stem}.zip"
            run("/usr/bin/ditto", "-c", "-k", "--keepParent", target, upload)
        response = read("/usr/bin/xcrun", "notarytool", "submit", "--keychain-profile", profile,
                        "--wait", "--timeout", "1h", "--output-format", "json", upload)
    submission = json.loads(response)
    identifier = submission["id"]
    (PREVIEW / f"notary-submit-{identifier}.json").write_text(json.dumps(submission, indent=2) + "\n")
    log = PREVIEW / f"notary-log-{identifier}.json"
    run("/usr/bin/xcrun", "notarytool", "log", "--keychain-profile", profile, identifier, log)
    if submission.get("status") != "Accepted":
        raise SystemExit(f"Notarization returned {submission.get('status', 'an unknown status')}. Read {log}.")
    run("/usr/bin/xcrun", "stapler", "staple", target)
    run("/usr/bin/xcrun", "stapler", "validate", target)


def verify_disk_image(run_conversion_check):
    if not IMAGE.is_file():
        raise SystemExit(f"Missing {IMAGE}.")
    quiet("/usr/bin/hdiutil", "verify", IMAGE)
    if RELEASE.signed:
        quiet("/usr/bin/codesign", "--verify", "--strict", IMAGE)
        shown = read("/usr/bin/codesign", "--display", "--verbose=4", IMAGE, merge=True)
        if field(shown, "Identifier") != RELEASE.disk_image_identifier:
            raise SystemExit("The disk image has the wrong signing identifier.")
        if field(shown, "TeamIdentifier") != RELEASE.team_identifier:
            raise SystemExit("The disk image has the wrong signing team.")
    with tempfile.TemporaryDirectory(prefix="allomer-image-", dir=PREVIEW) as temporary:
        mount = Path(temporary) / "mounted"
        mount.mkdir()
        quiet("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
              "-mountpoint", mount, IMAGE)
        try:
            installed = mount / APP.name
            if not installed.is_dir() or (mount / "Applications").readlink() != Path("/Applications"):
                raise SystemExit("The disk image has an unexpected layout.")
            quiet("/usr/bin/codesign", "--verify", "--deep", "--strict", installed)
            if RELEASE.signed:
                run("/usr/bin/xcrun", "stapler", "validate", installed)
            if run_conversion_check:
                run("python3", ROOT / "tools/check-app.py", installed)
        finally:
            quiet("/usr/bin/hdiutil", "detach", mount)


def gatekeeper():
    quiet("/usr/bin/codesign", "--verify", "--deep", "--strict", APP)
    run("/usr/bin/xcrun", "stapler", "validate", APP)
    run("/usr/sbin/spctl", "--assess", "--ignore-cache", "--no-cache", "--verbose=4", "--type", "exec", APP)
    run("/usr/bin/xcrun", "stapler", "validate", IMAGE)
    with tempfile.TemporaryDirectory(prefix="allomer-quarantine-", dir=PREVIEW) as temporary:
        downloaded = Path(temporary) / IMAGE.name
        shutil.copy2(IMAGE, downloaded)
        run("/usr/bin/xattr", "-w", "com.apple.quarantine",
            f"0081;{int(time.time()):x};Safari;{uuid.uuid4()}", downloaded)
        run("/usr/sbin/spctl", "--assess", "--ignore-cache", "--no-cache", "--verbose=4",
            "--type", "open", "--context", "context:primary-signature", downloaded)


def write_manifest(executables, source):
    pins = [ROOT / "tools/release.json", ROOT / "tools/native-sources.json", ROOT / "Package.swift",
            ROOT / "Package.resolved", ROOT / "rust-toolchain.toml", ROOT / "THIRD_PARTY.md",
            *sorted(ROOT.glob("helpers/*/Cargo.toml")), *sorted(ROOT.glob("helpers/*/Cargo.lock")),
            *sorted(ROOT.glob("helpers/*/package.json")), *sorted(ROOT.glob("helpers/*/package-lock.json")),
            *sorted(ROOT.glob("tools/build-*.py")), ROOT / "tools/check-app.py", ROOT / "tools/release.py",
            ROOT / "tools/release_config.py", ROOT / "tools/setup-rust.py",
            *sorted(ROOT.glob("tools/*.patch"))]
    shown = read("/usr/bin/codesign", "--display", "--verbose=4", APP, merge=True)
    record = {
        "product_name": RELEASE.product_name,
        "bundle_identifier": RELEASE.bundle_identifier,
        "version": RELEASE.version,
        "bundle_version": RELEASE.bundle_version,
        "build": RELEASE.build,
        "minimum_macos": RELEASE.minimum_system_version,
        "architecture": "arm64",
        "release_url": RELEASE.release_url,
        "source": source,
        "recorded_at_utc": datetime.now(timezone.utc).isoformat(),
        "toolchain": {
            "swift": read("swift", "--version").splitlines()[0].strip(),
            "clang": read("/usr/bin/clang", "--version").splitlines()[0].strip(),
            "macos_sdk": read("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version").strip(),
        },
        "code_signature": {
            "identifier": field(shown, "Identifier"),
            "code_directory_hash": field(shown, "CDHash"),
            "team_identifier": field(shown, "TeamIdentifier", "not set"),
            "authority": [line.removeprefix("Authority=") for line in shown.splitlines()
                          if line.startswith("Authority=")] or ["ad hoc"],
        },
        "executables": executables,
        "pinned_inputs": {str(path.relative_to(ROOT)): digest(path) for path in pins},
        "reproducibility": "This identifies the source and build inputs. Signatures contain a secure timestamp, "
                           "and the disk image receives a new volume identifier, so releases are not byte-identical.",
    }
    if IMAGE.is_file():
        record["disk_image"] = {"name": IMAGE.name, "bytes": IMAGE.stat().st_size, "sha256": digest(IMAGE)}
    contents = json.dumps(record, indent=2, sort_keys=True) + "\n"
    if str(Path.home()) in contents or str(ROOT) in contents:
        raise SystemExit("The release manifest contains a private local path.")
    MANIFEST.write_text(contents)
    return record


def require_release_inputs(source):
    missing = []
    if not RELEASE.signing_identity: missing.append("signing_identity")
    if not RELEASE.team_identifier: missing.append("team_identifier")
    if not RELEASE.notary_keychain_profile: missing.append("notary_keychain_profile")
    if not RELEASE.release_url: missing.append("release_url")
    if missing:
        raise SystemExit(f"Set {', '.join(missing)} in tools/release.json before cutting a release.")
    if not source["revision"] or not source["clean"]:
        raise SystemExit("A release must come from a committed, clean Git revision. " + source["description"])


def main():
    arguments = sys.argv[1:]
    if arguments not in ([], ["--verify"]):
        raise SystemExit("Usage: release.py [--verify]")
    if not APP.is_dir():
        raise SystemExit(f"Missing {APP}. Run tools/build-app.py first.")
    verify_only = bool(arguments)
    source = source_state()
    if not verify_only:
        require_release_inputs(source)
    quiet("/usr/bin/codesign", "--verify", "--deep", "--strict", APP)
    executables = inspect_app(RELEASE.signed)
    if not verify_only:
        notarize(APP)
        run("python3", ROOT / "tools/build-dmg.py")
        notarize(IMAGE)
        gatekeeper()
        verify_disk_image(run_conversion_check=True)
    elif IMAGE.is_file():
        verify_disk_image(run_conversion_check=False)
    if not RELEASE.signed:
        print("Verified the ad hoc seal, ARM64 architecture, and macOS deployment target. "
              "Release signature, ticket, and Gatekeeper checks need the values in tools/release.json.")
    record = write_manifest(executables, source)
    print(f"Checked {len(executables)} binaries. Release manifest: {MANIFEST}")
    if "disk_image" in record:
        print(f"Disk image: {IMAGE.name}; SHA-256: {record['disk_image']['sha256']}")


if __name__ == "__main__":
    main()
