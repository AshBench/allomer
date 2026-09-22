#!/usr/bin/env python3
"""Check font conversion against upstream fixtures with an independent font reader.

Install the readers first: python3 -m pip install -r tools/requirements-font-check.txt
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import struct
import subprocess
import sys
import tempfile
import urllib.request

from fontTools.pens.boundsPen import BoundsPen
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parent.parent
FORMATS = ("ttf", "otf", "woff", "woff2")
SIGNATURES = {"ttf": b"\x00\x01\x00\x00", "otf": b"OTTO", "woff": b"wOFF", "woff2": b"wOF2"}
# Adobe Variable Font Prototype 1.004 supplies one CFF2 and one glyf variable font, under the
# SIL Open Font License. Both are development fixtures and are not shipped.
RELEASE = "https://github.com/adobe-fonts/adobe-variable-font-prototype/releases/download/1.004/"
FIXTURES = {
    "AdobeVFPrototype.otf": "f7dc16e1ae8ed7de13e186fd20b9c254c1a0209724d30e2686874df64fa41e35",
    "AdobeVFPrototype.ttf": "a4b42a574f42232d321667141bef98b34b01a96597fbc0dcd33802d51f27c447",
}
LICENSE = ("https://raw.githubusercontent.com/adobe-fonts/adobe-variable-font-prototype/1.004/LICENSE.md",
           "6a73f9541c2de74158c0e7cf6b0a58ef774f5a780bf191f2d7ec9cc53efe2bf2")
# Roboto has 2048 units per em, which is the only way to reach the CFF FontMatrix this helper
# writes. It is Apache-2.0, pinned at the commit that last changed the file, and is not shipped.
ROBOTO_COMMIT = "eaef3058ec9d4f426c013b29fae53345e1c36f67"
ROBOTO = f"https://raw.githubusercontent.com/googlefonts/roboto-2/{ROBOTO_COMMIT}/"
ROBOTO_FILES = {
    "Roboto-Regular.ttf": ("src/hinted/Roboto-Regular.ttf",
                           "56a45233d29f11b4dfb86d248e921939d115778f87325e7ae8cc108383d6664d"),
    "Roboto-LICENSE.txt": ("LICENSE", "c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4"),
}
VARIATION = {"fvar", "gvar", "avar", "cvar", "HVAR", "VVAR", "MVAR", "CFF2"}


def sfnt_tables(path):
    data = path.read_bytes()
    if data[:4] in (b"wOFF", b"wOF2"):
        return None
    count = struct.unpack(">H", data[4:6])[0]
    return {data[12 + 16 * i:16 + 16 * i].decode("latin1") for i in range(count)}


def outlines(font):
    glyphs = font.getGlyphSet()
    bounds = {}
    for name in font.getGlyphOrder():
        pen = BoundsPen(glyphs)
        glyphs[name].draw(pen)
        bounds[name] = pen.bounds
    return bounds


def source_em(font):
    return font["head"].unitsPerEm


def compare(source_path, output_path):
    """Returns the worst outline-bound difference, raising on any preservation failure."""
    source, output = TTFont(source_path), TTFont(output_path)
    stale = VARIATION & set(output.keys())
    assert not stale, f"{output_path.name} kept variation tables {sorted(stale)}"
    assert "DSIG" not in output, f"{output_path.name} kept a signature the rewrite invalidated"
    source_map, output_map = source.getBestCmap(), output.getBestCmap()
    assert set(source_map) == set(output_map), f"{output_path.name} changed character coverage"
    assert source["head"].unitsPerEm == output["head"].unitsPerEm, f"{output_path.name} changed units per em"
    names = {r.nameID: r.toUnicode() for r in source["name"].names if r.platformID == 3}
    produced = {r.nameID: r.toUnicode() for r in output["name"].names if r.platformID == 3}
    for identifier in (1, 6, 0, 7, 8, 9, 13, 14):
        if identifier in names:
            assert produced.get(identifier) == names[identifier], f"{output_path.name} changed name {identifier}"
    source_bounds, output_bounds = outlines(source), outlines(output)
    source_metrics, output_metrics = source["hmtx"].metrics, output["hmtx"].metrics
    worst = 0.0
    for character, name in source_map.items():
        other = output_map[character]
        assert source_metrics[name][0] == output_metrics[other][0], f"{output_path.name} changed an advance"
        first, second = source_bounds[name], output_bounds[other]
        assert (first is None) == (second is None), f"{output_path.name} changed outline presence"
        if first is not None:
            worst = max(worst, max(abs(a - b) for a, b in zip(first, second)))
    assert worst <= 1.0, f"{output_path.name} moved an outline bound by {worst} font units"
    return worst


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=ROOT / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=ROOT / ".tools/bin")
    parser.add_argument("--report", type=Path, default=ROOT / "research/font-conversion.json")
    arguments = parser.parse_args()
    cache = ROOT / ".tools/fonts/fixtures"
    cache.mkdir(parents=True, exist_ok=True)
    for name, digest in FIXTURES.items():
        target = cache / name
        if not target.exists():
            urllib.request.urlretrieve(RELEASE + name, target)
        actual = hashlib.sha256(target.read_bytes()).hexdigest()
        if actual != digest:
            raise SystemExit(f"Fixture checksum mismatch for {name}: {actual}")
    notice = cache / "LICENSE.md"
    if not notice.exists():
        urllib.request.urlretrieve(LICENSE[0], notice)
    if hashlib.sha256(notice.read_bytes()).hexdigest() != LICENSE[1]:
        raise SystemExit("The fixture licence checksum does not match.")
    for name, (path, digest) in ROBOTO_FILES.items():
        target = cache / name
        if not target.exists():
            urllib.request.urlretrieve(ROBOTO + path, target)
        actual = hashlib.sha256(target.read_bytes()).hexdigest()
        if actual != digest:
            raise SystemExit(f"Fixture checksum mismatch for {name}: {actual}")

    def run(*args, check=True):
        return subprocess.run([str(arguments.command), *map(str, args)], cwd=ROOT,
                              env={"PATH": "/usr/bin:/bin"}, capture_output=True, text=True, check=check)

    results = []
    with tempfile.TemporaryDirectory(prefix="font-check-") as temporary:
        work = Path(temporary)
        sources = {name: cache / name for name in FIXTURES}
        sources["Roboto-Regular.ttf"] = cache / "Roboto-Regular.ttf"
        for name in ("font-values.ttf", "font-values.otf"):
            sources[name] = ROOT / "Tests/Fixtures" / name
        for name, source in sources.items():
            original = source.read_bytes()
            for target in FORMATS:
                output = work / f"{name.replace('.', '-')}.{target}"
                run("convert", source, output)
                assert output.read_bytes()[:4] == SIGNATURES[target], f"{output.name} has the wrong signature"
                tables = sfnt_tables(output)
                if tables is not None:
                    assert ("CFF " in tables) == (target == "otf"), f"{output.name} has the wrong outline table"
                    assert ("glyf" in tables) == (target != "otf"), f"{output.name} has the wrong outline table"
                worst = compare(source, output)
                if target == "otf":
                    # A font whose em is not 1000 units needs a FontMatrix in the CFF table.
                    scaled = TTFont(output)
                    matrix = scaled["CFF "].cff.topDictIndex[0].rawDict.get("FontMatrix")
                    expected = source_em(scaled)
                    assert (matrix is not None) == (expected != 1000), f"{output.name} FontMatrix"
                    if matrix is not None:
                        assert abs(matrix[0] - 1.0 / expected) < 1e-12, f"{output.name} FontMatrix {matrix}"
                # An existing destination is never replaced, and the failure leaves it untouched.
                before = output.read_bytes()
                assert run("convert", source, output, check=False).returncode != 0
                assert output.read_bytes() == before, f"{output.name} was overwritten"
                results.append({"source": name, "target": target, "bytes": output.stat().st_size,
                                "max_bound_delta": worst,
                                "sha256": hashlib.sha256(output.read_bytes()).hexdigest()})
            assert source.read_bytes() == original, f"{name} was modified"

        # Web fonts packaged by another tool are read correctly, so the container reader is not
        # only being checked against this app's own writer.
        for flavour in ("woff", "woff2"):
            foreign = work / f"foreign.{flavour}"
            packaged = TTFont(cache / "AdobeVFPrototype.otf")
            packaged.flavor = flavour
            packaged.save(foreign)
            for target in ("ttf", "otf"):
                output = work / f"foreign-{flavour}.{target}"
                run("convert", foreign, output)
                worst = compare(foreign, output)
                results.append({"source": f"foreign.{flavour}", "target": target,
                                "bytes": output.stat().st_size, "max_bound_delta": worst,
                                "sha256": hashlib.sha256(output.read_bytes()).hexdigest()})

        # Damaged input is refused and publishes nothing.
        for name, contents in [("short.ttf", b"\x00\x01\x00\x00"), ("noise.otf", bytes(range(256)) * 8),
                               ("truncated.woff2", (cache / "AdobeVFPrototype.otf").read_bytes()[:64])]:
            broken = work / name
            broken.write_bytes(contents)
            refused = work / (name + ".out.ttf")
            assert run("convert", broken, refused, check=False).returncode != 0, name
            assert not refused.exists(), f"{name} produced output"

        # The helper may read only the file the launcher was given.
        guard = arguments.tools / "fontguard"
        if guard.is_file():
            isolated = work / "isolated"
            isolated.mkdir()
            allowed = cache / "AdobeVFPrototype.otf"
            denied = ROOT / "Tests/Fixtures/font-values.otf"
            attempt = subprocess.run([str(guard), str(allowed), str(isolated), str(denied),
                                      str(isolated / "denied.ttf"), "ttf"], capture_output=True, text=True)
            assert attempt.returncode != 0, "The sandbox allowed an unlisted font to be read"
            assert not (isolated / "denied.ttf").exists()
            control = subprocess.run([str(guard), str(allowed), str(isolated), str(allowed),
                                      str(isolated / "allowed.ttf"), "ttf"], capture_output=True, text=True)
            assert control.returncode == 0, control.stderr
    report = {
        "generated": datetime.now(timezone.utc).isoformat(),
        "machine": platform.machine(),
        "command": str(arguments.command),
        "command_sha256": hashlib.sha256(arguments.command.read_bytes()).hexdigest(),
        "fixtures": {**{name: {"url": RELEASE + name, "sha256": digest} for name, digest in FIXTURES.items()},
                     **{name: {"url": ROBOTO + path, "sha256": digest}
                        for name, (path, digest) in ROBOTO_FILES.items()}},
        "fixture_license": {"url": LICENSE[0], "sha256": LICENSE[1]},
        "fonttools": __import__("fontTools").version,
        "conversions": results,
    }
    arguments.report.parent.mkdir(parents=True, exist_ok=True)
    arguments.report.write_text(json.dumps(report, indent=2) + "\n")
    worst = max(item["max_bound_delta"] for item in results)
    print(f"{len(results)} conversions passed independent checks; worst outline bound delta {worst} font units.")
    print(f"Report: {arguments.report}")


if __name__ == "__main__":
    main()
