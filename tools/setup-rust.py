#!/usr/bin/env python3
"""Install the pinned Rust compiler within the build cache only."""

import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tomllib

ROOT = Path(__file__).resolve().parent.parent


def main():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("Build on an Apple Silicon Mac.")
    source = json.loads((ROOT / "tools/native-sources.json").read_text())["rustup"]
    toolchain = tomllib.loads((ROOT / "rust-toolchain.toml").read_text())["toolchain"]
    installer = ROOT / ".tools/rust-bootstrap" / source["version"] / "rustup-init"
    installer.parent.mkdir(parents=True, exist_ok=True)
    if not installer.exists():
        subprocess.run(["curl", "--fail", "--location", "--max-time", "180", "--output", installer,
            source["url"]], check=True)
    if hashlib.sha256(installer.read_bytes()).hexdigest() != source["sha256"]:
        raise SystemExit("Rust installer checksum mismatch. Verify an upstream release before changing the pin.")
    installer.chmod(0o755)
    env = dict(os.environ, RUSTUP_HOME=str(ROOT / ".tools/rustup"), CARGO_HOME=str(ROOT / ".tools/cargo"))
    subprocess.run([installer, "-y", "--no-modify-path", "--profile", toolchain["profile"],
                   "--default-toolchain", toolchain["channel"], "--target", ",".join(toolchain["targets"])],
                   env=env, check=True)


if __name__ == "__main__":
    main()
