#!/usr/bin/env python3
"""Build an ARM64 Rust helper and retain dependency notices."""

import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
TOOLCHAIN = tomllib.loads((ROOT / "rust-toolchain.toml").read_text())["toolchain"]["channel"]
CARTA = json.loads((ROOT / "tools/native-sources.json").read_text())["carta"]
CARTA_COMMIT, CARTA_DIGEST = CARTA["revision"], CARTA["sha256"]


def prepare_carta(output):
    sources = output / "sources"
    sources.mkdir(parents=True, exist_ok=True)
    archive = sources / f"carta-{CARTA['version']}.tar.gz"
    if not archive.exists():
        urllib.request.urlretrieve(CARTA["url"], archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != CARTA_DIGEST:
        raise SystemExit("The document source checksum does not match.")
    work = ROOT / ".tools/carta-build"
    work.mkdir(exist_ok=True)
    source = work / f"carta-{CARTA_COMMIT}"
    with tarfile.open(archive) as file:
        if not source.exists():
            file.extractall(work, filter="data")
        names = ("crates/carta/src/main.rs", "crates/carta/src/resources.rs", "crates/carta-core/src/media/mod.rs")
        with tempfile.TemporaryDirectory(dir=work) as temporary:
            staged = Path(temporary)
            for name in names:
                target = staged / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(file.extractfile(f"{source.name}/{name}").read())
            subprocess.run(["patch", "--batch", "--forward", "-F", "0", "-p1", "-i", ROOT / "tools/carta-resources.patch"], cwd=staged, check=True)
            for name in names:
                data = (staged / name).read_bytes()
                if (source / name).read_bytes() != data:
                    (source / name).write_bytes(data)
    for name in ("build-rust.py", "setup-rust.py", "native-sources.json", "carta-resources.patch"):
        destination = sources / "tools" / name
        destination.parent.mkdir(exist_ok=True)
        shutil.copy2(ROOT / "tools" / name, destination)
    shutil.copy2(ROOT / "LICENSE", sources / "LICENSE")
    shutil.copy2(ROOT / "rust-toolchain.toml", sources / "rust-toolchain.toml")
    return source


def prepare_visioncortex(output):
    pin = json.loads((ROOT / "tools/native-sources.json").read_text())["visioncortex"]
    sources = output / "sources"
    sources.mkdir(parents=True, exist_ok=True)
    archive = sources / f"visioncortex-{pin['version']}.crate"
    if not archive.exists():
        urllib.request.urlretrieve(pin["url"], archive)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != pin["sha256"]:
        raise SystemExit("The tracing source checksum does not match.")
    with tempfile.TemporaryDirectory(dir=output) as temporary:
        with tarfile.open(archive) as file:
            file.extractall(temporary, filter="data")
        staged = Path(temporary) / f"visioncortex-{pin['version']}"
        subprocess.run(["patch", "--batch", "--forward", "-F", "0", "-p1", "-i",
            ROOT / "tools/visioncortex-color-sum.patch"], cwd=staged, check=True)
        source = output / "visioncortex"
        if source.exists():
            shutil.rmtree(source)
        shutil.copytree(staged, source)


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ("tabular", "mailfile", "carta", "vectortrace", "fontconvert"):
        raise SystemExit("Usage: python3 tools/build-rust.py tabular|mailfile|carta|vectortrace|fontconvert")
    name = sys.argv[1]
    package_directory = ROOT / "helpers" / name
    output_directory = ROOT / ".tools" / name
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("Build on an Apple Silicon Mac.")
    subprocess.run([sys.executable, ROOT / "tools/check-dependencies.py"], check=True)
    if name == "carta":
        package_directory = prepare_carta(output_directory)
    if name == "vectortrace":
        prepare_visioncortex(output_directory)
    features = ["--no-default-features", "--features", "cli,full"] if name == "carta" else []
    rustflags = f"--remap-path-prefix={ROOT}=."
    env = dict(os.environ)
    env.update(RUSTUP_HOME=str(ROOT / ".tools/rustup"), CARGO_HOME=str(ROOT / ".tools/cargo"),
               CARGO_TARGET_DIR=str(output_directory / "target"), MACOSX_DEPLOYMENT_TARGET="14.0", ZERO_AR_DATE="1",
               RUSTUP_TOOLCHAIN=TOOLCHAIN, RUSTFLAGS=rustflags)
    if name == "fontconvert":
        prefix = ROOT / ".tools/fonts/prefix"
        if not (prefix / "lib/libharfbuzz-subset.a").is_file():
            raise SystemExit("Build the font libraries with tools/build-fonts.py first.")
        env["FONTCONVERT_PREFIX"] = str(prefix)
    cargo = ROOT / ".tools/cargo/bin/cargo"
    if not cargo.is_file():
        raise SystemExit("Install the pinned local Rust toolchain with tools/setup-rust.py first.")
    target = "aarch64-apple-darwin"
    subprocess.run([cargo, "build", "--release", "--locked", "--target", target, "-j", "4", "-p", name] + features,
                   cwd=package_directory, env=env, check=True)
    metadata = json.loads(subprocess.check_output([cargo, "metadata", "--locked", "--format-version", "1",
        "--filter-platform", target] + features, cwd=package_directory, env=env))
    nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
    pending = [package["id"] for package in metadata["packages"]
               if package["name"] == name and package["source"] is None]
    assert len(pending) == 1, "Expected one helper package."
    resolved = set()
    while pending:
        package_id = pending.pop()
        if package_id in resolved:
            continue
        resolved.add(package_id)
        pending.extend(dependency["pkg"] for dependency in nodes[package_id]["deps"]
                       if any(kind["kind"] != "dev" for kind in dependency["dep_kinds"]))
    notices = output_directory / "licenses"
    if notices.exists():
        shutil.rmtree(notices)
    notices.mkdir(parents=True)
    if name == "carta":
        for license_name in ("LICENSE-MIT", "LICENSE-APACHE"):
            shutil.copy2(package_directory / license_name, notices / license_name)
        shutil.copytree(package_directory / "crates/carta-highlight/data/syntax", notices / "syntax")
    manifest = []
    source_manifest = []
    sources = output_directory / "sources"
    lock = tomllib.loads((package_directory / "Cargo.lock").read_text())
    checksums = {(p["name"], p["version"]): p.get("checksum") for p in lock["package"]}
    for package in metadata["packages"]:
        if package["id"] not in resolved or (package["source"] is None and package["name"] != "visioncortex"):
            continue
        source = Path(package["manifest_path"]).parent
        files = [path for path in source.rglob("*") if path.is_file()
                 and (path.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE", "COPYRIGHT"))
                      or any(part.upper() in ("LICENSES", "LICENSE", "LICENCES", "LICENCE") for part in path.relative_to(source).parts[:-1]))]
        if package.get("license_file"):
            files.append(source / package["license_file"])
        dependency_name = f"{package['name']}-{package['version']}"
        if not files:
            fallback_name = {"compressed-rtf-1.0.1": "compressed-rtf-1.0.1.txt", "flo_curves-0.3.1": "Apache-2.0.txt"}.get(dependency_name)
            fallback = ROOT / "licenses" / (fallback_name or "")
            if not fallback_name or not fallback.is_file():
                raise SystemExit(f"Missing license notice: {package['name']}")
            if dependency_name == "flo_curves-0.3.1" and package["license"] != "Apache-2.0":
                raise SystemExit("Review the curve library's license declaration.")
            destination = notices / dependency_name
            destination.mkdir()
            shutil.copy2(fallback, destination / "LICENSE")
            shutil.copy2(source / "Cargo.toml", destination / "Cargo.toml")
        for file in set(files):
            destination = notices / dependency_name / file.relative_to(source)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(file, destination)
        manifest.append({"name": package["name"], "version": package["version"],
                         "license": package["license"], "repository": package["repository"]})
        if "MPL-2.0" in package["license"] or dependency_name == "flo_curves-0.3.1":
            archive = Path(env["CARGO_HOME"]) / "registry/cache" / source.parent.name / f"{dependency_name}.crate"
            expected = checksums[(package["name"], package["version"])]
            if not archive.is_file() or hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
                raise SystemExit(f"Missing or invalid matching source archive: {dependency_name}")
            sources.mkdir(exist_ok=True)
            shutil.copy2(archive, sources / archive.name)
            source_manifest.append({"archive": archive.name, "sha256": expected, "repository": package["repository"],
                                    "license": package["license"], "changes": "Unmodified upstream crate"})
    if source_manifest:
        if name == "vectortrace":
            pin = json.loads((ROOT / "tools/native-sources.json").read_text())["visioncortex"]
            source_manifest.append({"archive": f"visioncortex-{pin['version']}.crate", "sha256": pin["sha256"],
                "repository": "https://github.com/visioncortex/visioncortex", "license": "MIT OR Apache-2.0",
                "changes": "tools/visioncortex-color-sum.patch widens color totals to prevent overflow."})
        (sources / "sources.json").write_text(json.dumps(source_manifest, indent=2) + "\n")
    rust_docs = ROOT / f".tools/rustup/toolchains/{TOOLCHAIN}-{target}/share/doc/rust"
    shutil.copy2(rust_docs / "COPYRIGHT-library.html", notices / "Rust-standard-library.html")
    shutil.copytree(rust_docs / "licenses", notices / "licenses")
    (notices / "dependencies.json").write_text(json.dumps(manifest, indent=2) + "\n")
    shutil.copy2(package_directory / "Cargo.lock", notices / "Cargo.lock")
    binary = output_directory / "target" / target / "release" / name
    if subprocess.check_output(["lipo", "-archs", binary], text=True).strip() != "arm64":
        raise SystemExit(f"The {name} helper is not ARM64.")
    for line in subprocess.check_output(["otool", "-L", binary], text=True).splitlines()[1:]:
        if not line.strip().startswith(("/usr/lib/", "/System/Library/")):
            raise SystemExit(f"Unbundled {name} dependency: {line}")
    (output_directory / "bin").mkdir(exist_ok=True)
    shutil.copy2(binary, output_directory / "bin" / name)
    link = ROOT / ".tools/bin" / name
    link.parent.mkdir(exist_ok=True)
    link.unlink(missing_ok=True)
    link.symlink_to(f"../{name}/bin/{name}")
    guard_name = {"vectortrace": "traceguard", "fontconvert": "fontguard"}.get(name)
    if guard_name:
        guard = output_directory / "bin" / guard_name
        subprocess.run(["clang", "-O2", "-arch", "arm64", "-mmacosx-version-min=14.0", "-Wno-deprecated-declarations",
            f'-DCONVERTER_BINARY_NAME="{name}"', ROOT / "helpers/toolguard/main.c", "-o", guard], env=env, check=True)
        guard_link = ROOT / ".tools/bin" / guard_name
        guard_link.unlink(missing_ok=True)
        guard_link.symlink_to(f"../{name}/bin/{guard_name}")
    build = {
        "rust": TOOLCHAIN, "target": target, "minimum_macos": "14.0",
        "features": features, "rustflags": rustflags,
        "cargo_lock_sha256": hashlib.sha256((package_directory / "Cargo.lock").read_bytes()).hexdigest(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    }
    if guard_name:
        build["guard_sha256"] = hashlib.sha256(guard.read_bytes()).hexdigest()
    if name == "fontconvert":
        build["font_libraries"] = json.loads((ROOT / ".tools/fonts/build-inputs.json").read_text())["libraries"]
        for relative in ("helpers/fontconvert/src/main.rs", "helpers/fontconvert/src/cff.rs",
                         "helpers/fontconvert/src/container.rs", "helpers/fontconvert/src/outline.rs",
                         "helpers/fontconvert/src/shim.rs", "helpers/fontconvert/shim/fontshim.cc",
                         "helpers/fontconvert/build.rs", "helpers/fontconvert/Cargo.toml",
                         "helpers/fontconvert/Cargo.lock", "helpers/toolguard/main.c",
                         "tools/build-rust.py", "tools/build-fonts.py", "tools/native-sources.json",
                         "rust-toolchain.toml", "LICENSE"):
            destination = sources / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, destination)
        build["original_sources"] = {str(file.relative_to(ROOT)): hashlib.sha256(file.read_bytes()).hexdigest()
            for file in sorted((ROOT / "helpers/fontconvert").rglob("*"))
            if file.is_file() and "target" not in file.parts}
    if name == "vectortrace":
        for relative in ("helpers/vectortrace/src/main.rs", "helpers/vectortrace/Cargo.toml", "helpers/vectortrace/Cargo.lock",
                         "helpers/bounded_heap.rs", "helpers/toolguard/main.c", "tools/build-rust.py", "tools/native-sources.json",
                         "rust-toolchain.toml", "licenses/Apache-2.0.txt", "tools/visioncortex-color-sum.patch", "LICENSE"):
            destination = sources / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / relative, destination)
        build["original_sources"] = {str(file.relative_to(ROOT)): hashlib.sha256(file.read_bytes()).hexdigest()
            for file in (ROOT / "helpers/vectortrace/src/main.rs", ROOT / "helpers/bounded_heap.rs", ROOT / "helpers/toolguard/main.c", Path(__file__))}
        build["color_sum_patch_sha256"] = hashlib.sha256((ROOT / "tools/visioncortex-color-sum.patch").read_bytes()).hexdigest()
    if name == "carta":
        build.update(source_commit=CARTA_COMMIT, source_sha256=CARTA_DIGEST,
                     resource_patch_sha256=hashlib.sha256((ROOT / "tools/carta-resources.patch").read_bytes()).hexdigest())
    (output_directory / "build.json").write_text(json.dumps(build, indent=2) + "\n")
    print(f"Helper: {output_directory / 'bin' / name}")


if __name__ == "__main__":
    main()
