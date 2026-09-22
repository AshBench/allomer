#!/usr/bin/env python3
"""Check native Word output and plain-text routes with an independent DOC reader."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import re
import statistics
import subprocess
import tempfile
import xml.etree.ElementTree as ET
import zipfile

from PIL import Image


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=root / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=root / ".tools/bin")
    parser.add_argument("--antiword", type=Path, required=True)
    parser.add_argument("--cfb-check", type=Path, help="Optional strict container checker built from check-doc-container.rs")
    parser.add_argument("--benchmark", action="store_true")
    args = parser.parse_args()
    command, tools, reader = args.command.resolve(), args.tools.resolve(), args.antiword.resolve()
    env = {"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools)}
    reader_env = {"PATH": "/usr/bin:/bin"}
    if (reader.parent / "Resources").is_dir(): reader_env["ANTIWORDHOME"] = str(reader.parent / "Resources")
    with tempfile.TemporaryDirectory(prefix="Native Word café 100% ") as temporary:
        work = Path(temporary)
        sequence = 0

        def convert(source, extension, success=True, measured=False):
            nonlocal sequence
            sequence += 1
            output = work / f"result-{sequence}.{extension}"
            before = hashlib.sha256(source.read_bytes()).hexdigest()
            invocation = [command, "convert", source, output]
            if measured: invocation = ["/usr/bin/time", "-l", *invocation]
            result = subprocess.run(invocation, env=env, capture_output=True, text=True, timeout=130)
            assert (result.returncode == 0) == success, (source.name, extension, result.stderr)
            assert hashlib.sha256(source.read_bytes()).hexdigest() == before
            assert output.exists() == success
            assert not list(work.glob(".allomer-*"))
            timing = {}
            if measured:
                timing = {"seconds": float(re.search(r"([\d.]+)\s+real", result.stderr)[1]),
                    "resident_bytes": int(re.search(r"(\d+)\s+maximum resident set size", result.stderr)[1]),
                    "output_bytes": output.stat().st_size}
            return output, timing

        def read_doc(path):
            assert path.read_bytes().startswith(bytes.fromhex("d0cf11e0a1b11ae1"))
            if args.cfb_check:
                subprocess.run([args.cfb_check.resolve(), path], check=True, capture_output=True, timeout=120)
            data = subprocess.check_output([reader, "-x", "db", path], env=reader_env, timeout=120)
            return ET.fromstring(data)

        def words(text): return re.sub(r"\s+", " ", text).strip()

        literal = "Literal <b>markup</b>, café 世界.\nA backslash: \\pict.\nLast paragraph.\n"
        for encoding in ("utf-8", "utf-16", "utf-32"):
            source = work / (encoding + ".txt")
            source.write_bytes(literal.encode(encoding))
            output, _ = convert(source, "doc")
            assert words("".join(read_doc(output).itertext())) == words(literal)
        for extension in ("rtf", "html", "docx", "pdf"):
            output, _ = convert(source, extension)
            if extension == "html":
                text = output.read_text()
                assert "&lt;b&gt;markup&lt;/b&gt;" in text and "café 世界" in text
            if extension == "docx":
                with zipfile.ZipFile(output) as archive:
                    text = "".join(ET.fromstring(archive.read("word/document.xml")).itertext())
                    assert words(literal.replace("\n", "")) == words(text)

        source = work / "styled.rtf"
        source.write_text(r'{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\fs24 Normal \b Bold\b0  \i Italic\i0\par Second paragraph.\par}')
        output, _ = convert(source, "doc")
        document = read_doc(output)
        assert words("".join(document.itertext())) == "Normal Bold Italic Second paragraph."
        assert any("Bold" in "".join(node.itertext()) for node in document.findall(".//emphasis[@role='bold']"))
        assert any("Italic" in "".join(node.itertext()) for node in document.findall(".//emphasis"))

        # Cross the native writer's missing-FAT and native reader's DIFAT limits.
        for count in (1_525_000, 3_600_000, 7_900_000):
            large = work / f"large-{count}.txt"
            literal = ("Plain text, café.\n" * (count // 18 + 1))[:count]
            large.write_text(literal)
            output, _ = convert(large, "doc")
            assert words("".join(read_doc(output).itertext())) == words(literal)
        large.write_text("x" * 8_000_001)
        convert(large, "doc", success=False)
        formatted = work / "many-runs.rtf"
        formatted.write_text(r'{\rtf1\ansi ' + r'\b Bold\b0  plain.\par ' * 25_000 + '}')
        output, _ = convert(formatted, "doc")
        document = read_doc(output)
        assert words("".join(document.itertext())) == words("Bold plain. " * 25_000)
        assert len(document.findall(".//emphasis[@role='bold']")) == 25_000

        oversized = work / "oversized.txt"
        with oversized.open("wb") as stream:
            stream.write(b"Text")
            stream.truncate(64 * 1024 * 1024 + 1)
        convert(oversized, "doc", success=False)
        oversized.unlink()

        html = work / "source.html"
        html.write_text('<!doctype html><meta charset="utf-8"><h1>Heading</h1><p>Body café 世界.</p>')
        output, _ = convert(html, "doc")
        assert words("".join(read_doc(output).itertext())) == "Heading Body café 世界."
        markdown = work / "source.md"
        markdown.write_text("# Heading\n\nBody café 世界.\n")
        output, _ = convert(markdown, "doc")
        assert words("".join(read_doc(output).itertext())) == "Heading Body café 世界."
        docx, _ = convert(markdown, "docx")
        output, _ = convert(docx, "doc")
        assert words("".join(read_doc(output).itertext())) == "Heading Body café 世界."

        Image.new("RGB", (16, 12), (50, 150, 200)).save(work / "picture.png")
        html.write_text('<!doctype html><meta charset="utf-8"><p>Keep the picture.</p><img src="picture.png">')
        convert(html, "doc", success=False)
        html.write_text('<!doctype html><meta charset="utf-8"><a href="https://example.invalid">Keep the link</a>')
        convert(html, "doc", success=False)
        for index, content in enumerate([r'{\rtf1 Body', r'{\rtf1{\header Header}Body}',
                                        r'{\rtf1 Body{\footnote Note}}', r'{\rtf1{\object Embedded}}']):
            invalid = work / f"invalid-{index}.rtf"; invalid.write_text(content)
            convert(invalid, "doc", success=False)
        linked = work / "linked.rtf"; linked.symlink_to(source)
        convert(linked, "doc", success=False)
        occupied = work / "occupied.doc"; occupied.write_bytes(b"Existing destination")
        result = subprocess.run([command, "convert", source, occupied], env=env, capture_output=True, timeout=130)
        assert result.returncode != 0 and occupied.read_bytes() == b"Existing destination"
        print("Native DOC, independent text/style reading, large FAT/DIFAT containers, TXT encodings and routes, chained documents, source preservation, refusals, and cleanup passed.", flush=True)

        if args.benchmark:
            source = work / "large.txt"
            source.write_text("".join(f"Paragraph {index:05d}: Original text with café and a final period.\n" for index in range(25_000)))
            runs = []
            for _ in range(3):
                output, timing = convert(source, "doc", measured=True)
                document = read_doc(output)
                assert words("".join(document.itertext())) == words(source.read_text())
                runs.append(timing)
            report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                "command_sha256": hashlib.sha256(command.read_bytes()).hexdigest(),
                "helper_sha256": hashlib.sha256((tools / "nativeconvert").read_bytes()).hexdigest(),
                "reader_sha256": hashlib.sha256(reader.read_bytes()).hexdigest(),
                "container_checker_sha256": hashlib.sha256(args.cfb_check.resolve().read_bytes()).hexdigest() if args.cfb_check else None,
                "input_bytes": source.stat().st_size, "input_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                "paragraphs": 25_000, "runs": runs, "median_seconds": statistics.median(run["seconds"] for run in runs),
                "median_resident_bytes": statistics.median(run["resident_bytes"] for run in runs),
                "scope": "Three complete TXT-to-DOC conversions of one original workload. Includes native input reading and DOC writing, declared text checks, container rebuilding, and publication. Input hashing warms the cache. Python and independent reader work are excluded. RSS is per-process high-water memory, not aggregate simultaneous app/helper/service memory. GUI memory is excluded."}
            (root / "research/native-doc-performance.json").write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps(report, indent=2), flush=True)


if __name__ == "__main__":
    main()
