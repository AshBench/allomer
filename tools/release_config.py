#!/usr/bin/env python3
"""Load and validate the values shared by the app and release builders."""

from dataclasses import dataclass
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = ROOT / "tools/release.json"


def contains_checkout_path(path):
    """Return true when a built file discloses this checkout's absolute path."""
    needle = str(ROOT).encode()
    overlap = len(needle) - 1
    previous = b""
    with path.open("rb") as file:
        while chunk := file.read(1024 * 1024):
            data = previous + chunk
            if needle in data:
                return True
            previous = data[-overlap:] if overlap else b""
    return False


@dataclass(frozen=True)
class ReleaseConfig:
    product_name: str
    bundle_identifier: str
    disk_image_identifier: str
    version: str
    build: str
    minimum_system_version: str
    copyright: str
    signing_identity: str | None
    team_identifier: str | None
    notary_keychain_profile: str | None
    release_url: str | None

    @property
    def signed(self):
        return self.signing_identity is not None

    @property
    def bundle_version(self):
        """Return the numeric version required by CFBundleShortVersionString."""
        return self.version.partition("-")[0].partition("+")[0]

    @property
    def app_path(self):
        return ROOT / "dist/preview" / f"{self.product_name}.app"

    @property
    def disk_image_path(self):
        suffix = self.version if self.signed else "preview"
        return self.app_path.with_name(f"{self.product_name}-{suffix}.dmg")


def load_release():
    values = json.loads(CONFIG_PATH.read_text())
    expected = set(ReleaseConfig.__annotations__)
    if set(values) != expected:
        missing = sorted(expected - set(values))
        extra = sorted(set(values) - expected)
        raise SystemExit(f"Invalid {CONFIG_PATH}: missing {missing or 'nothing'}; extra {extra or 'nothing'}.")
    required = expected - {"signing_identity", "team_identifier", "notary_keychain_profile", "release_url"}
    for key in required:
        if not isinstance(values[key], str) or not values[key].strip():
            raise SystemExit(f"{key} must be a nonempty string in {CONFIG_PATH}.")
    for key in expected - required:
        if values[key] is not None and (not isinstance(values[key], str) or not values[key].strip()):
            raise SystemExit(f"{key} must be null or a nonempty string in {CONFIG_PATH}.")
    if "/" in values["product_name"] or "\0" in values["product_name"]:
        raise SystemExit("product_name is not safe for an app or disk image name.")
    identifier = re.compile(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\Z")
    for key in ("bundle_identifier", "disk_image_identifier"):
        if not identifier.fullmatch(values[key]):
            raise SystemExit(f"{key} is not a valid reverse-DNS identifier.")
    if values["bundle_identifier"] == values["disk_image_identifier"]:
        raise SystemExit("disk_image_identifier must differ from bundle_identifier.")
    semver = re.compile(
        r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
        r"(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)"
        r"(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?"
        r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?\Z"
    )
    if not semver.fullmatch(values["version"]):
        raise SystemExit("version must be a Semantic Versioning 2.0.0 identifier.")
    if not re.fullmatch(r"[1-9]\d*", values["build"]):
        raise SystemExit("build must be a positive integer string.")
    if not re.fullmatch(r"\d+\.\d+", values["minimum_system_version"]):
        raise SystemExit("minimum_system_version must contain two numeric parts.")
    identity, team = values["signing_identity"], values["team_identifier"]
    if (identity is None) != (team is None):
        raise SystemExit("signing_identity and team_identifier must be set together.")
    if team is not None and not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise SystemExit("team_identifier must contain ten uppercase letters or digits.")
    if values["release_url"] is not None and not values["release_url"].startswith(("https://", "http://")):
        raise SystemExit("release_url must be an HTTP or HTTPS URL.")
    return ReleaseConfig(**values)
