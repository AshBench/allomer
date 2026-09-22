#!/usr/bin/env python3
"""Build the pinned, local slide and Word renderers and retain their source and notices."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
SOURCES = json.loads((ROOT / "tools/native-sources.json").read_text())["presentation"]
RENDERER = next(item for item in SOURCES if item["name"] == "pptx-renderer")
WORD = next(item for item in SOURCES if item["name"] == "docx-renderer")
REVISION = RENDERER["version"]
RETAINED = {"pptx-renderer", "docx-renderer"}
ARCHIVES = {item["archive"]: (item["url"], item["sha256"]) for item in SOURCES}


def digest(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def main():
    npm = shutil.which("npm")
    if not npm:
        raise SystemExit("Install Node.js and npm for the development build.")
    output = ROOT / ".tools/presentation"
    sources = output / "sources"
    sources.mkdir(parents=True, exist_ok=True)
    for name, (url, checksum) in ARCHIVES.items():
        archive = sources / name
        if not archive.exists():
            partial = archive.with_suffix(".download")
            try:
                with urllib.request.urlopen(url, timeout=60) as response, partial.open("wb") as file:
                    shutil.copyfileobj(response, file)
                if digest(partial) != checksum:
                    raise SystemExit(f"Source checksum mismatch: {name}")
                partial.replace(archive)
            finally:
                partial.unlink(missing_ok=True)
        if digest(archive) != checksum:
            raise SystemExit(f"Source checksum mismatch: {name}")
    build = ROOT / ".tools/presentation-build"
    build.mkdir(parents=True, exist_ok=True)
    package = ROOT / "helpers/presentation"
    dependencies = json.loads((package / "package.json").read_text())["dependencies"]
    locked = json.loads((package / "package-lock.json").read_text())["packages"][""]["dependencies"]
    if dependencies != locked:
        raise SystemExit("Refresh the presentation package-lock.json with npm install --package-lock-only.")
    for item in SOURCES:
        if item["name"] not in RETAINED and dependencies.get(item["name"]) != item["version"]:
            raise SystemExit(f"Retained source version differs from package.json: {item['name']}")
    for name in ("package.json", "package-lock.json"):
        shutil.copy2(package / name, build / name)
    fingerprint = digest(build / "package-lock.json")
    stamp = build / "installed-lock.sha256"
    if not stamp.exists() or stamp.read_text() != fingerprint or not (build / "node_modules/.bin/esbuild").exists():
        subprocess.run([npm, "ci", "--ignore-scripts", "--no-audit", "--no-fund"], cwd=build, check=True)
        stamp.write_text(fingerprint)
    source = build / f"pptx-renderer-{REVISION}"
    patch = ROOT / "tools/presentation-rendering.patch"
    source_fingerprint = RENDERER["sha256"] + "\n" + digest(patch)
    patch_stamp = build / "applied-source.sha256"
    if not source.exists() or not patch_stamp.exists() or patch_stamp.read_text() != source_fingerprint:
        if source.exists():
            shutil.rmtree(source)
        with tarfile.open(sources / RENDERER["archive"]) as archive:
            archive.extractall(build, filter="data")
        subprocess.run(["patch", "--batch", "--forward", "-F", "0", "-p1", "--input", patch], cwd=source, check=True)
        patch_stamp.write_text(source_fingerprint)
    word_source = build / f"docxjs-{WORD['version']}"
    word_stamp = build / "applied-word-source.sha256"
    # Re-extract whenever the pin changes, including a retag that keeps the same version string,
    # and whenever a previous extraction was interrupted.
    if not word_source.exists() or not word_stamp.exists() or word_stamp.read_text() != WORD["sha256"]:
        if word_source.exists():
            shutil.rmtree(word_source)
        with tarfile.open(sources / WORD["archive"]) as archive:
            archive.extractall(build, filter="data")
        word_stamp.write_text(WORD["sha256"])
    assets = output / "Resources/Presentation"
    assets.mkdir(parents=True, exist_ok=True)
    javascript = assets / "renderer.js"
    entry = build / "entry.ts"
    exports = {"parser/ZipParser": "parseZipLazyMedia, RECOMMENDED_ZIP_LIMITS", "model/Presentation": "buildPresentation",
               "renderer/SlideRenderer": "renderSlide", "utils/media": "resolveMediaPathCandidates"}
    entry.write_text("\n".join(f"export {{ {names} }} from {json.dumps(str(source / 'src' / module))};"
                               for module, names in exports.items()) + "\n")
    subprocess.run([build / "node_modules/.bin/esbuild", entry, "--bundle", "--minify",
        "--format=iife", "--global-name=PPTX", "--target=safari17", "--external:pdfjs-dist", "--external:pdfjs-dist/*",
        '--define:process.env.NODE_ENV="production"', f"--outfile={javascript}"], cwd=build, check=True)
    word_assets = output / "Resources/Word"
    word_assets.mkdir(parents=True, exist_ok=True)
    word_javascript = word_assets / "renderer.js"
    # The Word renderer reads the archive itself, so its ZIP reader is bundled with it.
    subprocess.run([build / "node_modules/.bin/esbuild", word_source / "src/docx-preview.ts", "--bundle", "--minify",
        "--format=iife", "--global-name=DOCX", "--target=safari17",
        '--define:process.env.NODE_ENV="production"', f"--outfile={word_javascript}"], cwd=build, check=True)
    notices = output / "licenses"
    if notices.exists():
        shutil.rmtree(notices)
    notices.mkdir()
    renderer_notices = notices / "renderer"
    renderer_notices.mkdir()
    for name in ("LICENSE", "THIRD_PARTY_NOTICES.md"):
        shutil.copy2(source / name, renderer_notices / name)
    shutil.copytree(source / "licenses", renderer_notices / "licenses")
    (renderer_notices / "CHANGES.txt").write_text(
        "Local changes to the pinned renderer: charts use SVG output. Slide and image failures stop PDF export. "
        "Package path lookups use canonical Unicode names. "
        "The original patch is retained as tools/presentation-rendering.patch in the source distribution.\n")
    word_notices = notices / "word-renderer"
    word_notices.mkdir()
    shutil.copy2(word_source / "LICENSE", word_notices / "LICENSE")
    dependencies = []
    for manifest in sorted((build / "node_modules").glob("*/package.json")):
        data = json.loads(manifest.read_text())
        if data["name"] == "esbuild":
            continue  # Development compiler; not included in the runtime bundle.
        target = notices / data["name"]
        target.mkdir()
        files = [p for p in manifest.parent.iterdir() if p.name.lower().startswith(("license", "notice", "copying"))]
        if not files:
            files = [p for p in manifest.parent.iterdir() if p.name.lower().startswith("readme")]
        if not files:
            raise SystemExit(f"Missing dependency notice: {data['name']}")
        for file in files:
            if file.is_dir():
                shutil.copytree(file, target / file.name)
            else:
                shutil.copy2(file, target / file.name)
        dependencies.append({"name": data["name"], "version": data["version"], "license": data.get("license")})
    # Pako's root MIT notice does not include the zlib source notices.
    headers = set()
    for file in sorted((build / "node_modules/pako/lib/zlib").glob("*.js")):
        text = file.read_text()
        start = text.find("// (C)")
        end = text.find("// 3. This notice may not be removed or altered from any source distribution.", start)
        if start >= 0 and end >= start:
            headers.add(text[start:text.index("\n", end)])
    if not headers:
        raise SystemExit("Missing pako zlib notices.")
    (notices / "pako/zlib-notices.txt").write_text("\n\n".join(sorted(headers)) + "\n")
    (sources / "tools/presentation-vector-charts.patch").unlink(missing_ok=True)
    for file in (patch, ROOT / "tools/build-presentation.py", ROOT / "tools/native-sources.json", package / "package.json", package / "package-lock.json"):
        target = sources / file.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(file, target)
    report = {"revision": REVISION, "source_archives": ARCHIVES, "lock_sha256": fingerprint,
        "patch_sha256": digest(patch), "javascript_bytes": javascript.stat().st_size,
        "javascript_sha256": digest(javascript), "word_revision": WORD["version"],
        "word_javascript_bytes": word_javascript.stat().st_size,
        "word_javascript_sha256": digest(word_javascript), "dependencies": dependencies,
        "scope": "Static headless browser code only. Viewer and search exports are excluded. No Node.js runtime is bundled. JavaScript uses native WebKit. PDF.js fallback is not included yet. Supply retained source and notices with distributions."}
    (output / "build.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Presentation assets: {assets}")
    print(f"Word assets: {word_assets}")


if __name__ == "__main__":
    main()
