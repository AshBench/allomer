#!/usr/bin/env python3
"""Check source pins, vendored headers, and npm manifest agreement without downloads."""
import hashlib
import json
from pathlib import Path
import re
import tomllib
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent


def main():
    sources = json.loads((ROOT / "tools/native-sources.json").read_text())
    count = 0
    for group, entries in sources.items():
        entries = entries if isinstance(entries, list) else [entries]
        names = set()
        for entry in entries:
            name = entry.get("name", group)
            assert name not in names, f"Duplicate source: {name}"
            names.add(name)
            assert isinstance(entry["version"], str) and entry["version"], name
            assert re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]), f"Invalid checksum: {name}"
            url = urlsplit(entry["url"])
            assert url.scheme == "https" and url.hostname, f"Invalid source URL: {name}"
            if "archive" in entry:
                assert Path(entry["archive"]).name == entry["archive"], name
            if "revision" in entry:
                assert re.fullmatch(r"[0-9a-f]{40}", entry["revision"]), name
            if group == "vendored":
                with (ROOT / entry["path"]).open("rb") as file:
                    actual = hashlib.file_digest(file, "sha256").hexdigest()
                assert actual == entry["sha256"], f"Vendored source changed: {entry['path']}"
            count += 1
    for relative in ("helpers/presentation", "website"):
        directory = ROOT / relative
        package = json.loads((directory / "package.json").read_text())
        locked = json.loads((directory / "package-lock.json").read_text())["packages"][""]
        for key in ("dependencies", "devDependencies", "optionalDependencies"):
            assert package.get(key, {}) == locked.get(key, {}), f"Refresh {relative}/package-lock.json"
    package = json.loads((ROOT / "helpers/presentation/package.json").read_text())
    # Both renderers are pinned upstream source archives, not npm packages.
    for entry in sources["presentation"]:
        if entry["name"] not in ("pptx-renderer", "docx-renderer"):
            assert package["dependencies"][entry["name"]] == entry["version"], "Retained presentation source version differs"
    toolchain = tomllib.loads((ROOT / "rust-toolchain.toml").read_text())["toolchain"]
    tracing = tomllib.loads((ROOT / "helpers/vectortrace/Cargo.toml").read_text())
    assert tracing["dependencies"]["visioncortex"] == "=" + sources["visioncortex"]["version"], "Tracing source and Cargo pins differ"
    assert re.fullmatch(r"\d+\.\d+\.\d+", toolchain["channel"]), "Use a released Rust version"
    assert toolchain["targets"] == ["aarch64-apple-darwin"], "The helper build targets Apple Silicon"
    crates = 0
    for manifest in sorted(ROOT.glob("helpers/*/Cargo.toml")):
        crate = tomllib.loads(manifest.read_text())
        name = manifest.parent.name
        assert (manifest.parent / "Cargo.lock").is_file(), f"Commit {name}/Cargo.lock"
        for section in ("dependencies", "build-dependencies"):
            for dependency, requirement in crate.get(section, {}).items():
                version = requirement if isinstance(requirement, str) else requirement.get("version", "")
                assert version.startswith("="), f"Pin {name} dependency {dependency} to one version"
                crates += 1
    # The font helper links libraries this catalog pins rather than anything the machine supplies.
    fonts = {entry["name"] for entry in sources["fonts"]}
    assert {"harfbuzz", "woff2", "brotli"} <= fonts, "The font libraries are no longer pinned"
    print(f"Checked {count} native pins, {crates} Rust dependency pins, vendored files, "
          "npm manifests, and the Rust toolchain pin.")


if __name__ == "__main__":
    main()
