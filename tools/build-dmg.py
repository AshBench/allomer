#!/usr/bin/env python3
"""Build and verify a disk image from the local app preview."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

from release_config import load_release

ROOT = Path(__file__).resolve().parent.parent
RELEASE = load_release()


def digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def main():
    app = RELEASE.app_path
    output = RELEASE.disk_image_path
    if not app.is_dir():
        raise SystemExit(f"Missing {app}. Run tools/build-app.py first.")
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app], check=True)
    if RELEASE.signed:
        stapled = subprocess.run(["/usr/bin/xcrun", "stapler", "validate", app], capture_output=True, text=True)
        if stapled.returncode:
            raise SystemExit("Notarize and staple the app before building the release disk image. "
                             "Run tools/release.py instead.")
    with tempfile.TemporaryDirectory(prefix="preview-image-", dir=app.parent) as temporary:
        work = Path(temporary)
        payload = work / "payload"
        payload.mkdir()
        subprocess.run(["/bin/cp", "-cR", app, payload / app.name], check=True)
        (payload / "Applications").symlink_to("/Applications")
        image = work / "preview.dmg"
        subprocess.run(["/usr/bin/hdiutil", "create", "-srcfolder", payload, "-volname", RELEASE.product_name, "-fs", "HFS+",
                        "-format", "UDZO", "-imagekey", "zlib-level=9", image], check=True)
        subprocess.run(["/usr/bin/hdiutil", "verify", image], check=True)
        mount = work / "mounted"
        mount.mkdir()
        subprocess.run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mount, image], check=True)
        try:
            installed = mount / app.name
            if not installed.is_dir() or (mount / "Applications").readlink() != Path("/Applications"):
                raise SystemExit("The disk image has an unexpected layout.")
            subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", installed], check=True)
            for file in app.rglob("*"):
                target = installed / file.relative_to(app)
                if file.is_symlink():
                    if not target.is_symlink() or target.readlink() != file.readlink():
                        raise SystemExit(f"The disk image changed a link: {file}")
                elif file.is_file() and digest(file) != digest(target):
                    raise SystemExit(f"The disk image changed a file: {file}")
        finally:
            subprocess.run(["/usr/bin/hdiutil", "detach", mount], check=True)
        image.replace(output)
        if RELEASE.signed:
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", RELEASE.signing_identity, "--timestamp",
                            "--identifier", RELEASE.disk_image_identifier, output], check=True)
            subprocess.run(["/usr/bin/hdiutil", "verify", output], check=True)
    files = {str(file.relative_to(app)): file.stat().st_size for file in app.rglob("*")
             if file.is_file() and not file.is_symlink()}
    record = ROOT / "research/package-size.json"
    previous = json.loads(record.read_text()) if record.exists() else {}
    report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "app_file_bytes": sum(files.values()),
        "dmg_bytes": output.stat().st_size, "compression": "UDZO, zlib level 9", "filesystem": "HFS+",
        "helper_count": len(list((app / "Contents/Helpers").iterdir())),
        "shared_media_library_count": sum(not file.is_symlink() for file in (app / "Contents/Frameworks/Media").iterdir()),
        "largest_files": dict(sorted(files.items(), key=lambda item: item[1], reverse=True)[:10]),
        "dmg_sha256": digest(output), **{key: value for key, value in previous.items() if key.startswith("before_")},
        "scope": ("Signed release candidate before disk-image notarization and stapling. " if RELEASE.signed
                  else "Local ad hoc preview. ")
            + "Counts regular file paths and excludes media and license symlink aliases. Includes the app, command, helpers, shared media libraries, and notices. Rust library notices share one stored copy. Excludes development files."}
    record.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Verified preview: {output} ({output.stat().st_size:,} bytes)")


if __name__ == "__main__":
    main()
