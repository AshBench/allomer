#!/usr/bin/env python3
"""Check email conversion with Python email and an independent MSG reader."""
import base64
from datetime import datetime, timezone
from email import policy
from email.message import EmailMessage
from email.parser import BytesParser
from html.parser import HTMLParser
import hashlib
import json
from pathlib import Path
import platform
import re
import statistics
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / ".tools/mailfile/target/aarch64-apple-darwin/release/mailfile"


def fixture():
    message = EmailMessage(policy=policy.SMTP)
    message["From"] = "Zoë Sender <sender@example.test>"
    message["To"] = "李 Recipient <recipient@example.test>"
    message["Cc"] = "copy@example.test"
    message["Bcc"] = "hidden@example.test"
    message["Reply-To"] = "reply@example.test"
    message["Subject"] = "Café — 日本語 😀"
    message["Date"] = "Tue, 08 Sep 2026 09:00:00 +0530"
    message["Message-ID"] = "<original@example.test>"
    message["X-Original-Field"] = "Keep this value"
    message["X-Repeat"] = "first value"
    message["X-Repeat"] = "second value"
    message.set_content("Hello café 日本語 😀.\nSecond line.\n")
    message.add_alternative('<h1>Hello café 日本語 😀.</h1><p>Second line.</p><img src="cid:pixel">'
                            '<img src="https://example.test/remote.png"><script>alert(1)</script>', subtype="html")
    pixel = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aB1kAAAAASUVORK5CYII=")
    message.get_payload()[1].add_related(pixel, maintype="image", subtype="png", cid="<pixel>",
                                        filename="pixel.png", disposition="inline")
    message.add_attachment(bytes(range(256)), maintype="application", subtype="octet-stream", filename="résumé.bin")
    message.add_attachment("café £".encode("cp1252"), maintype="text", subtype="plain",
                           filename="legacy.txt", params={"charset": "windows-1252"})
    nested = EmailMessage(policy=policy.SMTP)
    nested["From"] = "nested@example.test"
    nested["To"] = "sender@example.test"
    nested["Subject"] = "Attached email é"
    nested.set_content("Nested body.\n")
    message.add_attachment(nested, filename="nested.eml")
    return message.as_bytes()


def decode(path):
    return BytesParser(policy=policy.default).parsebytes(path.read_bytes())


def parts(message):
    return {part.get_filename(): part.get_payload(decode=True) for part in message.walk()
            if part.get_filename() and part.get_content_type() != "message/rfc822"}


class HTMLCheck(HTMLParser):
    def __init__(self):
        super().__init__()
        self.images, self.downloads, self.tags, self.words = [], {}, [], []
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        self.tags.append(tag)
        assert not any(key.startswith("on") for key in attrs), attrs
        if tag == "img" and "src" in attrs:
            self.images.append(attrs["src"])
        if tag == "a" and "download" in attrs:
            self.downloads[attrs["download"]] = base64.b64decode(attrs["href"].split(",", 1)[1])
    def handle_data(self, value):
        self.words.append(value)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--performance":
        performance()
        return
    import extract_msg
    import olefile
    if len(sys.argv) > 1 and sys.argv[1] == "--fixture":
        Path(sys.argv[2]).write_bytes(fixture())
        return
    tool = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else TOOL
    with tempfile.TemporaryDirectory(prefix="mail-check-") as directory:
        work = Path(directory)
        source = work / "email with spaces.eml"
        original_bytes = fixture()
        source.write_bytes(original_bytes)
        original = decode(source)
        def convert(src, name, headers=True, fails=False):
            output = work / name
            result = subprocess.run([tool, src, output, src.suffix[1:], output.suffix[1:], str(headers).lower()],
                                    capture_output=True, timeout=30)
            if fails:
                assert result.returncode != 0 and not output.exists(), result.stderr
            else:
                assert result.returncode == 0, result.stderr.decode()
                assert output.stat().st_size
            return output
        emlx = convert(source, "wrapped.emlx")
        count, remaining = emlx.read_bytes().split(b"\n", 1)
        assert remaining[:int(count)] == source.read_bytes()
        assert convert(emlx, "unwrapped.eml").read_bytes() == source.read_bytes()
        msg = convert(source, "message.msg")
        with extract_msg.openMsg(msg) as parsed:
            assert parsed.subject == str(original["Subject"]), parsed.subject
            assert parsed.body.replace("\r\n", "\n") == original.get_body(("plain",)).get_content().replace("\r\n", "\n")
            assert "recipient@example.test" in parsed.to
            assert "hidden@example.test" in parsed.bcc
            binary = {a.longFilename: a.data for a in parsed.attachments if isinstance(a.data, bytes)}
            assert binary == parts(original), binary.keys()
            nested = [a.data for a in parsed.attachments if not isinstance(a.data, bytes)]
            assert len(nested) == 1 and nested[0].subject == "Attached email é"
        returned = convert(msg, "returned.eml")
        reread = decode(returned)
        for name in ["Subject", "From", "To", "Cc", "Bcc", "Reply-To", "Date", "Message-ID", "X-Original-Field"]:
            assert str(reread[name]) == str(original[name]), (name, reread[name], original[name])
        assert parts(reread) == parts(original)
        nested = [p for p in reread.walk() if p.get_content_type() == "message/rfc822"]
        assert len(nested) == 1 and nested[0].get_payload()[0]["Subject"] == "Attached email é"
        for headers in [True, False]:
            html = convert(source, f"headers-{headers}.html", headers)
            check = HTMLCheck()
            check.feed(html.read_text())
            assert "script" not in check.tags
            assert len(check.images) == 1 and check.images[0].startswith("data:image/png;base64,")
            assert all(check.downloads[name] == data for name, data in parts(original).items())
            assert ("X-Original-Field" in "".join(check.words)) == headers
            if headers:
                assert "first value" in check.words and "second value" in check.words
        bad = work / "truncated.emlx"
        bad.write_bytes(b"999999\nSubject: test\n\nshort")
        convert(bad, "bad.eml", fails=True)
        bad_msg = work / "bad.msg"
        bad_msg.write_bytes(msg.read_bytes())
        with olefile.OleFileIO(bad_msg, write_mode=True) as ole:
            table = bytearray(ole.openstream("__properties_version1.0").read())
            struct.pack_into("<I", table, 20, 999)
            ole.write_stream("__properties_version1.0", bytes(table))
        convert(bad_msg, "bad-count.eml", fails=True)
        # A separate writer creates ANSI and RTF inputs from original test text.
        from extract_msg.ole_writer import OleWriter
        import compressed_rtf
        def independent_msg(name, body=None, rtf=None, codepage=1252):
            writer = OleWriter()
            writer.addEntry("__nameid_version1.0", storage=True)
            for stream in ["00020102", "00030102", "00040102"]:
                writer.addEntry(f"__nameid_version1.0/__substg1.0_{stream}", b"")
            entries = [struct.pack("<IIQ", 0x3FFD0003, 6, codepage)]
            def add(tag, data):
                writer.addEntry(f"__substg1.0_{tag:08X}", data)
                entries.append(struct.pack("<IIQ", tag, 6, len(data) + (1 if tag & 0xFFFF == 0x001E else 0)))
            add(0x001A001E, b"IPM.Note")
            add(0x0037001E, "Café ANSI".encode("cp1252"))
            if body is not None:
                add(0x1000001E, body)
            if rtf is not None:
                add(0x10090102, rtf)
            writer.addEntry("__properties_version1.0", bytes(32) + b"".join(entries))
            output = work / name
            writer.write(output)
            return output
        ansi = independent_msg("ansi.msg", body="Café £ €".encode("cp1252"))
        assert decode(convert(ansi, "ansi.eml")).get_body(("plain",)).get_content().strip() == "Café £ €"
        rtf_bytes = br"{\rtf1\ansi\ansicpg1252 Plain \b bold\b0  caf\'e9.\par Second line.}"
        rtf = independent_msg("rtf.msg", rtf=compressed_rtf.compress(rtf_bytes))
        rich = decode(convert(rtf, "rich.eml"))
        assert "Plain bold café." in rich.get_body(("plain",)).get_content()
        assert "Second line." in rich.get_body(("html",)).get_content()
        assert next(p for p in rich.walk() if p.get_content_type() == "text/rtf").get_payload(decode=True) == rtf_bytes
        rich_msg = convert(work / "rich.eml", "rich-return.msg")
        with extract_msg.openMsg(rich_msg) as parsed_rich:
            assert parsed_rich.body.replace("\r\n", "\n") == rich.get_body(("plain",)).get_content().replace("\r\n", "\n")
            assert parsed_rich.rtfBody == rtf_bytes
        truncated_rtf = independent_msg("bad-rtf.msg", rtf=b"bad")
        convert(truncated_rtf, "bad-rtf.eml", fails=True)
        signed = work / "signed.eml"
        signed.write_bytes(b'Subject: Signed\r\nContent-Type: multipart/signed; boundary="signature"\r\n\r\n'
                           b'--signature\r\nContent-Type: text/plain\r\n\r\nSigned body\r\n--signature--\r\n')
        assert convert(convert(signed, "signed.emlx"), "signed-return.eml").read_bytes() == signed.read_bytes()
        convert(signed, "signed.msg", fails=True)
        collision = work / "existing.msg"
        collision.write_bytes(b"keep existing")
        result = subprocess.run([tool, source, collision, "eml", "msg", "true"], capture_output=True)
        assert result.returncode and collision.read_bytes() == b"keep existing"
        assert source.read_bytes() == original_bytes
    print("Email: five routes, headers, Unicode, exact attachments, nested messages, offline HTML, invalid input and collisions passed.")


def performance():
    tool = ROOT / "dist/preview/Allomer.app/Contents/Helpers/mailfile"
    message = EmailMessage(policy=policy.SMTP)
    message["From"] = "sender@example.test"
    message["To"] = "recipient@example.test"
    message["Subject"] = "Email performance — café 日本語"
    message.set_content("Café 日本語 😀, original message text.\n" * 10000)
    attachment = bytes(range(256)) * 32768
    message.add_attachment(attachment, maintype="application", subtype="octet-stream", filename="data.bin")
    samples = []
    with tempfile.TemporaryDirectory(prefix="email-performance-") as directory:
        work = Path(directory)
        source = work / "source.eml"
        source.write_bytes(message.as_bytes())
        original = source.read_bytes()
        for index in range(3):
            output = work / f"output-{index}.msg"
            result = subprocess.run(["/usr/bin/time", "-l", tool, source, output, "eml", "msg", "true"],
                cwd=work, env={"PATH": "/usr/bin:/bin", "TMPDIR": str(work)}, check=True, capture_output=True, text=True, timeout=120)
            elapsed = re.search(r"([0-9.]+) real", result.stderr)
            memory = re.search(r"([0-9]+)\s+maximum resident set size", result.stderr)
            assert elapsed and memory, result.stderr
            samples.append({"elapsed_seconds": float(elapsed[1]), "peak_resident_bytes": int(memory[1]),
                            "output_bytes": output.stat().st_size})
            restored = work / f"restored-{index}.eml"
            subprocess.run([tool, output, restored, "msg", "eml", "true"], cwd=work,
                env={"PATH": "/usr/bin:/bin", "TMPDIR": str(work)}, check=True, capture_output=True, timeout=120)
            returned = decode(restored)
            assert next(returned.iter_attachments()).get_payload(decode=True) == attachment
            assert returned.get_body(("plain",)).get_content() == decode(source).get_body(("plain",)).get_content()
            assert source.read_bytes() == original
        report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
            "architecture": platform.machine(), "workload": "EML to MSG: 10000 Unicode text lines and one 8 MiB attachment",
            "scope": "Email helper process only; native app memory is separate",
            "input_bytes": len(original), "input_sha256": hashlib.sha256(original).hexdigest(),
            "helper_sha256": hashlib.sha256(tool.read_bytes()).hexdigest(), "samples": samples,
            "median_elapsed_seconds": statistics.median(s["elapsed_seconds"] for s in samples),
            "median_peak_resident_bytes": statistics.median(s["peak_resident_bytes"] for s in samples)}
    (ROOT / "research/email-performance.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
