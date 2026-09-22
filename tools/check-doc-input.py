#!/usr/bin/env python3
"""Check every basic DOC-input route, failures, source bytes, and cleanup."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


TARGETS = {
    "asciidoc": "adoc", "avi": "avi", "avif": "avif", "bmp": "bmp", "docx": "docx",
    "eps": "eps", "epub": "epub", "gif": "gif", "heic": "heic", "html": "html",
    "icns": "icns", "ico": "ico", "ipynb": "ipynb", "jpeg": "jpg", "jxl": "jxl",
    "latex": "tex", "m2ts": "m2ts", "man": "man", "markdown": "md", "mediawiki": "wiki",
    "mkv": "mkv", "mov": "mov", "mp4": "mp4", "mpeg": "mpeg", "odt": "odt",
    "opml": "opml", "org": "org", "pdf": "pdf", "png": "png", "postscript": "ps",
    "pptx": "pptx", "rst": "rst", "rtf": "rtf", "svg": "svg", "svgz": "svgz",
    "tiff": "tiff", "ts": "ts", "txt": "txt", "typst": "typ", "vob": "vob",
    "webm": "webm", "webp": "webp", "wmv": "wmv",
}
TEXT_OUTPUTS = {"asciidoc", "html", "ipynb", "latex", "man", "markdown", "mediawiki", "org", "rst", "txt", "typst"}


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=root / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=root / ".tools/bin")
    args = parser.parse_args()
    command, tools = args.command.resolve(), args.tools.resolve()
    environment = {"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools)}
    with tempfile.TemporaryDirectory(prefix="DOC input café ") as directory:
        work = Path(directory)
        media_options = work / "media.json"
        media_options.write_text(json.dumps({"videoMode": "bitrate", "videoBitrateKbps": 500}))

        def run(*arguments, failure=False):
            result = subprocess.run(list(map(str, arguments)), cwd=work, env=environment,
                                    capture_output=True, timeout=180)
            if failure:
                assert result.returncode != 0, (arguments, "Expected refusal")
            else:
                assert result.returncode == 0 and not result.stderr.strip(), \
                    (arguments, result.stderr.decode(errors="replace"))

        def convert(source, output, failure=False):
            source_hash = hashlib.sha256(source.read_bytes()).digest()
            names = set(work.iterdir())
            existing = output.read_bytes() if output.exists() else None
            run(command, "convert", source, output, "--media-options", media_options, failure=failure)
            assert hashlib.sha256(source.read_bytes()).digest() == source_hash, (source, "Source changed")
            assert not list(work.glob(".allomer-*")), "Conversion work leaked"
            assert set(work.iterdir()) == names | (set() if failure else {output}), (source, output, "Unexpected files")
            if failure:
                assert output.read_bytes() == existing if existing is not None else not output.exists(), output

        rtf = work / "original.rtf"
        rtf.write_text(r"{\rtf1\ansi\deff0{\fonttbl{\f0 Helvetica;}}\fs24 DOC input\par \b Bold\b0  caf\u233? \u26481?\u20140?\par Final paragraph.\par}")
        source = work / "original.doc"
        convert(rtf, source)
        assert source.read_bytes().startswith(bytes.fromhex("d0cf11e0a1b11ae1"))
        source_hash = hashlib.sha256(source.read_bytes()).digest()

        outputs = []
        for target, extension in TARGETS.items():
            output = work / f"result.{extension}"
            convert(source, output)
            assert output.stat().st_size > 0
            if target in TEXT_OUTPUTS:
                text = output.read_text()
                assert "DOC input" in text and "Final paragraph" in text, target
            outputs.append(output)
            print(f"DOC to {target} passed.", flush=True)

        before = outputs[0].read_bytes()
        convert(source, outputs[0], failure=True)
        assert outputs[0].read_bytes() == before
        malformed = work / "malformed.doc"
        malformed.write_bytes(bytes.fromhex("d0cf11e0a1b11ae1"))
        convert(malformed, work / "malformed.txt", failure=True)
        assert hashlib.sha256(source.read_bytes()).digest() == source_hash
        print("Passed 43 DOC-input outputs, one collision, and one malformed-input refusal.")


if __name__ == "__main__":
    main()
