#!/usr/bin/env python3
"""Create the Homebrew cask for a verified Allomer release."""

import argparse
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit

from release_config import ROOT, load_release


RELEASE = load_release()
DEFAULT_MANIFEST = ROOT / "dist/preview/release-manifest.json"
DEFAULT_OUTPUT = ROOT / "dist/preview/allomer.rb"


def fail(message):
    raise SystemExit(message)


def read_manifest(path):
    try:
        record = json.loads(path.read_text())
    except FileNotFoundError:
        fail(f"Missing release manifest: {path}")
    except json.JSONDecodeError as error:
        fail(f"Invalid release manifest: {error}")
    if not isinstance(record, dict):
        fail("The release manifest must contain a JSON object.")
    return record


def require_string(record, key):
    value = record.get(key)
    if not isinstance(value, str) or not value:
        fail(f"The release manifest has no valid {key}.")
    return value


def sha256(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def validate_release(record, manifest_path, download_url):
    expected = {
        "product_name": RELEASE.product_name,
        "bundle_identifier": RELEASE.bundle_identifier,
        "version": RELEASE.version,
        "bundle_version": RELEASE.bundle_version,
        "minimum_macos": RELEASE.minimum_system_version,
        "architecture": "arm64",
    }
    for key, value in expected.items():
        if record.get(key) != value:
            fail(f"The release manifest has {key}={record.get(key)!r}; expected {value!r}.")

    source = record.get("source")
    if not isinstance(source, dict) or source.get("clean") is not True:
        fail("Homebrew publishing requires a release from a clean Git revision.")
    revision = source.get("revision")
    if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40,64}", revision):
        fail("The release manifest has no valid Git revision.")

    signature = record.get("code_signature")
    if not isinstance(signature, dict) or signature.get("team_identifier") in (None, "not set"):
        fail("Homebrew publishing requires a Developer ID signature.")
    authorities = signature.get("authority")
    if not isinstance(authorities, list) or not any(
            isinstance(value, str) and value.startswith("Developer ID Application:")
            for value in authorities):
        fail("The release manifest does not contain a Developer ID Application authority.")

    executables = record.get("executables")
    if not isinstance(executables, dict) or not executables:
        fail("The release manifest contains no executables.")
    for name, executable in executables.items():
        if not isinstance(executable, dict) or executable.get("hardened_runtime") is not True:
            fail(f"The hardened runtime is missing from {name}.")
        if executable.get("secure_timestamp") is not True:
            fail(f"The secure timestamp is missing from {name}.")
        if executable.get("team_identifier") != signature["team_identifier"]:
            fail(f"The signing team differs for {name}.")

    image = record.get("disk_image")
    if not isinstance(image, dict):
        fail("The release manifest contains no disk image.")
    image_name = require_string(image, "name")
    expected_name = f"{RELEASE.product_name}-{RELEASE.version}.dmg"
    if image_name != expected_name:
        fail(f"The release disk image must be named {expected_name}.")
    digest = require_string(image, "sha256")
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        fail("The release disk image has no valid SHA-256 digest.")
    image_path = manifest_path.parent / image_name
    if not image_path.is_file():
        fail(f"Missing release disk image: {image_path}")
    if sha256(image_path) != digest:
        fail("The release disk image does not match the manifest SHA-256.")

    parsed = urlsplit(download_url)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
        fail("The Homebrew download URL must be a public HTTPS URL.")
    if parsed.query or parsed.fragment or any(character in download_url for character in '"\\\r\n'):
        fail("The Homebrew download URL contains unsupported characters.")
    if unquote(Path(parsed.path).name) != image_name:
        fail(f"The Homebrew download URL must end with {image_name}.")
    return digest


def render_cask(digest, download_url):
    minimum_macos = {"14.0": "sonoma"}.get(RELEASE.minimum_system_version)
    if minimum_macos is None:
        fail(f"Add the Homebrew name for macOS {RELEASE.minimum_system_version} before publishing.")
    return f"""cask "allomer" do
  version "{RELEASE.version}"
  sha256 "{digest}"

  url "{download_url}"
  name "{RELEASE.product_name}"
  desc "Local file conversion for Apple Silicon Macs"
  homepage "https://allomer.ashbench.com/"

  depends_on arch: :arm64
  depends_on macos: :{minimum_macos}

  app "{RELEASE.product_name}.app"
  binary "#{{appdir}}/{RELEASE.product_name}.app/Contents/MacOS/allomer"

  uninstall quit: "{RELEASE.bundle_identifier}"

  zap trash: [
    "~/Library/Application Support/{RELEASE.product_name}",
    "~/Library/Preferences/{RELEASE.bundle_identifier}.plist",
    "~/Library/Saved Application State/{RELEASE.bundle_identifier}.savedState",
  ]
end
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    arguments = parser.parse_args()

    manifest = arguments.manifest.resolve()
    digest = validate_release(read_manifest(manifest), manifest, arguments.download_url)
    output = arguments.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(render_cask(digest, arguments.download_url))
    print(f"Homebrew cask: {output}")


if __name__ == "__main__":
    main()
