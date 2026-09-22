#!/usr/bin/env python3
"""Exercise the packaged command outside the repository without development paths."""

import csv
import gzip
from email import policy
from email.parser import BytesParser
import hashlib
from html.parser import HTMLParser
import json
import math
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys
import tempfile
import wave
import xml.etree.ElementTree as ET
import zipfile
import zlib


class BookText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []

    def handle_data(self, data):
        self.parts.append(data)


def main():
    root = Path(__file__).resolve().parent.parent
    arguments = sys.argv[1:]
    if len(arguments) > 1:
        raise SystemExit("Usage: check-app.py [path-to-Allomer.app]")
    source_app = Path(arguments[0]).resolve() if arguments else root / "dist/preview/Allomer.app"
    if not source_app.is_dir():
        raise SystemExit(f"Missing app: {source_app}")
    app = source_app
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app], check=True)
    with tempfile.TemporaryDirectory(prefix="allomer-app-check-") as temporary:
        work = Path(temporary)
        installed = work / app.name
        subprocess.run(["/usr/bin/ditto", "--noextattr", "--noqtn", app, installed], check=True)
        app = installed
        command = app / "Contents/MacOS/allomer"
        probe = app / "Contents/Helpers/ffprobe"
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        assert info["CFBundleIconFile"] == "Allomer.icns"
        bundled_icon = app / "Contents/Resources/Allomer.icns"
        assert bundled_icon.read_bytes() == (root / "branding/generated/Allomer.icns").read_bytes()
        assert bundled_icon.read_bytes().startswith(b"icns")
        icon_type = next(item for item in info["UTImportedTypeDeclarations"]
                         if item["UTTypeIdentifier"] == "com.apple.iconcomposer.icon")
        assert "com.apple.package" in icon_type["UTTypeConformsTo"]
        assert "icon" in icon_type["UTTypeTagSpecification"]["public.filename-extension"]
        def run(*args, check=True, env=None):
            result = subprocess.run(list(map(str, args)), cwd=work,
                                    env=env or {"PATH": "/usr/bin:/bin"},
                                    check=False, capture_output=True, text=True)
            if check and result.returncode:
                if result.stdout:
                    print(result.stdout, file=sys.stderr, end="")
                if result.stderr:
                    print(result.stderr, file=sys.stderr, end="")
                result.check_returncode()
            return result
        def chunk(kind, data):
            return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
        image = work / "original.png"
        image.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 12, 8, 2, 0, 0, 0))
                          + chunk(b"IDAT", zlib.compress((b"\x00" + bytes([220, 60, 40]) * 16) * 12))
                          + chunk(b"IEND", b""))
        document = work / "Café 東京.md"
        document.write_text("# Café 東京\n\nAn **original** test document.\n")
        audio = work / "tone ' café.wav"
        with wave.open(str(audio), "wb") as writer:
            writer.setparams((2, 2, 48000, 0, "NONE", "not compressed"))
            writer.writeframes(b"".join(struct.pack("<hh", value, value) for value in
                (int(math.sin(i * 440 * 2 * math.pi / 48000) * 8192) for i in range(48000))))
        for source, extension in ((image, "jpg"), (image, "webp"), (image, "jxl"), (image, "svg"), (document, "docx"), (document, "doc"), (audio, "ogg")):
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            output = work / f"result.{extension}"
            options = work / "image-options.json"
            options.write_text('{"quality":1,"webpMode":"lossless"}')
            if extension == "jxl":
                options.write_text('{"quality":0,"jpegXLMode":"lossless","jpegXLEffort":1}')
            elif extension == "svg":
                options.write_text('{"tracing":{"advanced":true,"pathMode":"pixel","filterSpeckle":0,"colorPrecision":8,"layerDifference":1}}')
            extra = ["--image-options", options] if extension in ("webp", "jxl", "svg") else []
            run(command, "convert", source, output, *extra)
            assert hashlib.sha256(source.read_bytes()).hexdigest() == digest
            assert output.stat().st_size > 0
            converted = output.read_bytes()
            assert run(command, "convert", source, output, check=False).returncode != 0
            assert output.read_bytes() == converted
            if extension == "webp":
                assert converted[:4] == b"RIFF" and converted[8:12] == b"WEBP"
                run(command, "convert", output, work / "webp-roundtrip.png")
                for invalid in ("{", " " * 65_537):
                    options.write_text(invalid)
                    target = work / "invalid-options.webp"
                    assert run(command, "convert", source, target, "--image-options", options, check=False).returncode != 0
                    assert not target.exists()
            if extension == "docx":
                with zipfile.ZipFile(output) as archive:
                    text = "".join(ET.fromstring(archive.read("word/document.xml")).itertext())
                    assert "Café 東京" in text
            elif extension == "doc":
                assert converted.startswith(bytes.fromhex("d0cf11e0a1b11ae1"))
                assert "Café 東京" in run("/usr/bin/textutil", "-convert", "txt", "-stdout", output).stdout
            elif extension == "svg":
                svg = ET.fromstring(converted)
                assert svg.attrib["viewBox"] == "0 0 16 12"
                assert list(svg.iter("{http://www.w3.org/2000/svg}path"))
                assert not list(svg.iter("{http://www.w3.org/2000/svg}image"))
                restored = work / "traced-roundtrip.png"
                run(command, "convert", output, restored)
                pixels = subprocess.run([app / "Contents/Helpers/ffmpeg", "-hide_banner", "-loglevel", "error", "-i", restored,
                                         "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], cwd=work,
                                        env={"PATH": "/usr/bin:/bin"}, capture_output=True, check=True).stdout
                assert pixels == bytes([220, 60, 40]) * 16 * 12
                for notice in (root / ".tools/vectortrace/licenses").rglob("*"):
                    if notice.is_file():
                        relative = notice.relative_to(root / ".tools/vectortrace/licenses")
                        assert (app / "Contents/Resources/Licenses/vectortrace" / relative).read_bytes() == notice.read_bytes()
            elif extension == "jxl":
                restored = work / "jpegxl-roundtrip.png"
                run(command, "convert", output, restored)
                info = json.loads(run(probe, "-v", "error", "-show_streams", "-of", "json", restored).stdout)
                assert (info["streams"][0]["width"], info["streams"][0]["height"]) == (16, 12)
                pixels = subprocess.run([app / "Contents/Helpers/ffmpeg", "-hide_banner", "-loglevel", "error", "-i", restored,
                                         "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], cwd=work,
                                        env={"PATH": "/usr/bin:/bin"}, capture_output=True, check=True).stdout
                assert pixels == bytes([220, 60, 40]) * 16 * 12
            else:
                info = json.loads(run(probe, "-v", "error", "-show_streams", "-of", "json", output).stdout)
                stream = info["streams"][0]
                assert stream["codec_name"] == {"jpg": "mjpeg", "webp": "webp", "ogg": "vorbis"}[extension]
                if extension in ("jpg", "webp"):
                    assert (stream["width"], stream["height"]) == (16, 12)
                else:
                    assert stream["channels"] == 2
        transparent = work / "transparent.png"
        transparent.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 16, 12, 8, 6, 0, 0, 0))
                                + chunk(b"IDAT", zlib.compress(bytes(65) * 12)) + chunk(b"IEND", b""))
        background = work / "background.jpg"
        settings = work / "background-options.json"
        settings.write_text('{"alphaHandling":"custom","alphaCustomColor":"#336699","quality":1}')
        run(command, "convert", transparent, background, "--image-options", settings)
        pixels = subprocess.run([app / "Contents/Helpers/ffmpeg", "-hide_banner", "-loglevel", "error", "-i", background,
                                 "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], cwd=work,
                                env={"PATH": "/usr/bin:/bin"}, capture_output=True, check=True).stdout
        assert len(pixels) == 16 * 12 * 3 and max(abs(value - (51, 102, 153)[index % 3]) for index, value in enumerate(pixels)) <= 3
        avif = work / "maximum-quality.avif"
        run(command, "convert", transparent, avif, "--image-options", settings)
        run(command, "convert", avif, work / "avif-roundtrip.png")
        tiff = work / "compressed.tiff"
        settings = work / "tiff-options.json"
        settings.write_text('{"tiffCompression":"jpeg","tiffJPEGQuality":0.4}')
        run(command, "convert", image, tiff, "--image-options", settings)
        data = tiff.read_bytes()
        order = "<" if data[:2] == b"II" else ">"
        directory = struct.unpack_from(order + "I", data, 4)[0]
        count = struct.unpack_from(order + "H", data, directory)[0]
        entries = [struct.unpack_from(order + "HHII", data, directory + 2 + index * 12) for index in range(count)]
        assert any(tag == 259 and kind == 3 and length == 1 and (value & 0xffff if order == "<" else value >> 16) == 7
                   for tag, kind, length, value in entries)
        run(command, "convert", tiff, work / "tiff-roundtrip.png")
        animation = work / "animation.png"
        header = struct.pack(">IIBBBBB", 16, 12, 8, 2, 0, 0, 0)
        frame = lambda sequence, delay: struct.pack(">IIIIIHHBB", sequence, 16, 12, 0, 0, delay, 100, 0, 0)
        pixels = lambda color: zlib.compress((b"\x00" + bytes(color) * 16) * 12)
        animation.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"acTL", struct.pack(">II", 2, 2))
            + chunk(b"fcTL", frame(0, 4)) + chunk(b"IDAT", pixels([220, 60, 40]))
            + chunk(b"fcTL", frame(1, 9)) + chunk(b"fdAT", struct.pack(">I", 2) + pixels([40, 80, 220])) + chunk(b"IEND", b""))
        animated_gif = work / "animated.gif"
        original_animation = animation.read_bytes()
        options.write_text('{"gifMaxColors":2,"gifDither":false}')
        run(command, "convert", animation, animated_gif, "--image-options", options)
        assert animation.read_bytes() == original_animation
        assert animated_gif.read_bytes()[:6] == b"GIF89a"
        info = json.loads(run(probe, "-v", "error", "-show_frames", "-show_entries", "frame=duration_time",
                              "-of", "json", animated_gif).stdout)
        assert [float(frame["duration_time"]) for frame in info["frames"]] == [0.04, 0.09]
        assert b"\x21\xff\x0bNETSCAPE2.0\x03\x01\x01\x00\x00" in animated_gif.read_bytes()
        pixels = subprocess.run([app / "Contents/Helpers/ffmpeg", "-hide_banner", "-loglevel", "error", "-i", animated_gif,
                                 "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], cwd=work,
                                env={"PATH": "/usr/bin:/bin"}, capture_output=True, check=True).stdout
        assert pixels == bytes([220, 60, 40]) * 16 * 12
        animated_webp = work / "animated.webp"
        options.write_text('{"webpMode":"lossless"}')
        run(command, "convert", animation, animated_webp, "--image-options", options)
        assert animation.read_bytes() == original_animation
        info = json.loads(run(probe, "-v", "error", "-show_frames", "-show_entries", "frame=duration_time",
                              "-of", "json", animated_webp).stdout)
        assert [float(frame["duration_time"]) for frame in info["frames"]] == [0.04, 0.09]
        assert b"ANIM\x06\x00\x00\x00\x00\x00\x00\x00\x02\x00" in animated_webp.read_bytes()
        video = work / "original-video.mkv"
        run(app / "Contents/Helpers/ffmpeg", "-v", "error", "-f", "apng", "-ignore_loop", "1", "-i", animation,
            "-c:v", "ffv1", "-fps_mode", "passthrough", video)
        video_bytes = video.read_bytes()
        still_video = work / "still-image.mp4"
        original_image = image.read_bytes()
        run(command, "convert", image, still_video)
        still_info = json.loads(run(probe, "-v", "error", "-count_frames", "-show_entries",
            "stream=codec_type,width,height,nb_read_frames", "-of", "json", still_video).stdout)
        assert still_info["streams"] == [{"codec_type": "video", "width": 16, "height": 12, "nb_read_frames": "1"}]
        assert image.read_bytes() == original_image
        run(app / "Contents/Helpers/ffmpeg", "-v", "error", "-xerror", "-i", still_video, "-f", "null", "-")
        options.write_text('{"videoFrameRate":25,"videoMaxWidth":8,"videoLoopCount":2,"webpMode":"lossless"}')
        for extension in ("gif", "webp"):
            result = work / f"video-animation.{extension}"
            run(command, "convert", video, result, "--image-options", options)
            assert video.read_bytes() == video_bytes
            info = json.loads(run(probe, "-v", "error", "-show_frames", "-show_entries", "frame=width,height,duration_time",
                                  "-of", "json", result).stdout)
            assert len(info["frames"]) >= 2
            assert all((frame["width"], frame["height"]) == (8, 6) for frame in info["frames"])
        config = work / "settings.json"
        values = {"name": "Café 東京", "code": "00123", "flag": True, "list": [1, False, "true"],
                  "large": 9223372036854775807}
        config.write_text(json.dumps(values))
        for extension in ("yaml", "toml", "plist", "xml"):
            output = work / f"settings.{extension}"
            restored = work / f"from-{extension}.json"
            run(command, "convert", config, output)
            run(command, "convert", output, restored)
            assert json.loads(restored.read_text()) == values
        subtitle = work / "cue.srt"
        subtitle.write_text("1\n00:00:00,100 --> 00:00:01,250\nCafé 東京\n")
        caption = work / "cue.vtt"
        run(command, "convert", subtitle, caption)
        assert caption.read_text().startswith("WEBVTT") and "Café 東京" in caption.read_text()
        embedded = work / "embedded.mkv"
        run(app / "Contents/Helpers/ffmpeg", "-nostdin", "-v", "error", "-n", "-f", "image2", "-loop", "1",
            "-framerate", "25", "-i", image, "-f", "srt", "-i", subtitle, "-map", "0:v", "-map", "1:s",
            "-t", "2", "-c:v", "mpeg4", "-pix_fmt", "yuv420p", "-c:s", "srt", "-f", "matroska", embedded)
        extracted = work / "extracted.srt"
        subtitle_options = work / "subtitle-options.json"
        subtitle_options.write_text('{"embeddedTrack":1}')
        embedded_hash = hashlib.sha256(embedded.read_bytes()).hexdigest()
        run(command, "convert", embedded, extracted, "--subtitle-options", subtitle_options)
        assert "00:00:00,100 --> 00:00:01,250" in extracted.read_text() and "Café 東京" in extracted.read_text()
        assert hashlib.sha256(embedded.read_bytes()).hexdigest() == embedded_hash
        bundle_archive = work / "settings.zip"
        run(command, "convert", config, bundle_archive)
        for extension in ("tar", "tar.gz", "7z", "gz"):
            packed = work / f"settings.json.{extension}"
            run(command, "convert", bundle_archive, packed)
            restored = work / f"archive-{extension}.zip"
            run(command, "convert", packed, restored)
            with zipfile.ZipFile(restored) as archive:
                assert archive.namelist() == ["settings.json"]
                assert json.loads(archive.read("settings.json")) == values
        for notice in (root / "licenses").glob("*.txt"):
            assert (app / "Contents/Resources/Licenses" / notice.name).read_bytes() == notice.read_bytes()
        for component in ("carta", "webp", "jpegxl", "poppler", "tiff"):
            notices = root / ".tools" / component / "licenses"
            assert notices.is_dir() and any(notices.iterdir())
            for notice in notices.rglob("*"):
                if notice.is_file():
                    relative = notice.relative_to(notices)
                    assert (app / "Contents/Resources/Licenses" / component / relative).read_bytes() == notice.read_bytes()
        resources = root / ".tools/poppler/Resources/Poppler"
        for resource in resources.rglob("*"):
            if resource.is_file():
                assert (app / "Contents/Resources/Poppler" / resource.relative_to(resources)).read_bytes() == resource.read_bytes()
        table = work / "table.csv"
        table.write_text('name,code,text,empty\nCafé 東京,00123,=SUM(A1:A2),\n,,,\n')
        workbook = work / "table.xlsx"
        restored = work / "table-restored.tsv"
        run(command, "convert", table, workbook)
        run(command, "convert", workbook, restored)
        with table.open(newline="") as original, restored.open(newline="") as result:
            assert list(csv.reader(original)) == list(csv.reader(result, delimiter="\t"))
        records = work / "table-records.json"
        table.write_text('name,code\nCafé 東京,00123\n')
        run(command, "convert", table, records)
        assert json.loads(records.read_text()) == [{"name": "Café 東京", "code": "00123"}]
        xml_table = work / "table.xml"
        xml_table.write_text('<rows><row><name>Café 東京</name><code>00123</code></row></rows>')
        xml_csv = work / "xml-table.csv"
        run(command, "convert", xml_table, xml_csv)
        with xml_csv.open(newline="") as file:
            assert list(csv.reader(file)) == [["name", "code"], ["Café 東京", "00123"]]
        legacy = work / "legacy.xls"
        legacy.write_bytes((root / "Tests/Fixtures/sheet-values.xls").read_bytes())
        legacy_output = work / "legacy.csv"
        run(command, "convert", legacy, legacy_output)
        assert "00123" in legacy_output.read_text() and "Café 東京" in legacy_output.read_text()
        legacy_document = work / "legacy.docx"
        run(command, "convert", legacy, legacy_document)
        with zipfile.ZipFile(legacy_document) as archive:
            text = "".join(ET.fromstring(archive.read("word/document.xml")).itertext())
            assert "00123" in text and "Café 東京" in text
        for notice in (root / ".tools/tabular/licenses").rglob("*"):
            if notice.is_file():
                relative = notice.relative_to(root / ".tools/tabular/licenses")
                assert (app / "Contents/Resources/Licenses/tabular" / relative).read_bytes() == notice.read_bytes()
        fixtures = root / ".tools/ebook-build/libmobi-0.12/tests/samples"
        for name in ("sample-unicode-uncompressed", "sample-unicode-huffdic", "sample-cp1252", "sample-multimedia",
                     "sample-ncx", "sample-dict-infl2", "sample-obfuscated-fonts", "sample-textread"):
            source = work / (name + ".mobi")
            source.write_bytes((fixtures / source.name).read_bytes())
            output = work / (name + ".epub")
            run(command, "convert", source, output)
            raw = work / name
            raw.mkdir()
            run(app / "Contents/Helpers/mobitool", "-e", "-o", raw, "--", source)
            with zipfile.ZipFile(output) as archive, zipfile.ZipFile(raw / output.name) as original:
                assert archive.testzip() is None
                first = archive.infolist()[0]
                assert first.filename == "mimetype" and first.compress_type == zipfile.ZIP_STORED
                assert archive.read(first) == b"application/epub+zip"
                assert output.read_bytes()[28:30] == b"\x00\x00"
                for part in archive.namelist():
                    if part.endswith((".html", ".xhtml")):
                        html = ET.fromstring(archive.read(part))
                        assert html.tag == "{http://www.w3.org/1999/xhtml}html"
                        text = BookText()
                        text.feed(original.read(part).decode("utf-8"))
                        assert " ".join(html.itertext()).split() == " ".join(text.parts).split(), (name, part)
                    else:
                        assert archive.read(part) == original.read(part), (name, part)
            original = output.read_bytes()
            assert run(command, "convert", source, output, check=False).returncode != 0
            assert output.read_bytes() == original
        for notice in (root / ".tools/ebook/licenses").iterdir():
            assert (app / "Contents/Resources/Licenses/ebook" / notice.name).read_bytes() == notice.read_bytes()
        def font_tables(path):
            data = path.read_bytes()
            if data[:4] in (b"wOFF", b"wOF2"):
                return None
            count = struct.unpack(">H", data[4:6])[0]
            return {data[12 + 16 * i:16 + 16 * i].decode("latin1") for i in range(count)}

        variation = {"fvar", "gvar", "avar", "cvar", "HVAR", "VVAR", "MVAR", "CFF2", "DSIG"}
        font = work / "font.otf"
        font.write_bytes((root / "Tests/Fixtures/font-values.otf").read_bytes())
        for extension, signature in (("ttf", b"\x00\x01\x00\x00"), ("woff", b"wOFF"), ("woff2", b"wOF2")):
            output = work / ("font." + extension)
            run(command, "convert", font, output)
            assert output.read_bytes()[:4] == signature
            restored = work / ("from-" + extension + ".otf")
            run(command, "convert", output, restored)
            assert restored.read_bytes()[:4] == b"OTTO"
            assert "CFF " in font_tables(restored)
        assert font.read_bytes() == (root / "Tests/Fixtures/font-values.otf").read_bytes()
        # Both variable outline flavours reach every target as a static default instance.
        fixtures = root / ".tools/fonts/fixtures"
        for flavour in ("otf", "ttf"):
            fixture = fixtures / ("AdobeVFPrototype." + flavour)
            if not fixture.is_file():
                continue
            variable = work / ("variable." + flavour)
            variable.write_bytes(fixture.read_bytes())
            assert "fvar" in font_tables(variable)
            for extension in ("ttf", "otf", "woff", "woff2"):
                output = work / f"variable-{flavour}.{extension}"
                run(command, "convert", variable, output)
                tables = font_tables(output)
                if tables is not None:
                    assert not (variation & tables), (flavour, extension, sorted(variation & tables))
                    assert ("CFF " in tables) == (extension == "otf"), (flavour, extension)
                previous = output.read_bytes()
                assert run(command, "convert", variable, output, check=False).returncode != 0
                assert output.read_bytes() == previous
            assert variable.read_bytes() == fixture.read_bytes()
        for notices in ("fonts", "fontconvert"):
            origin = root / ".tools" / ("fonts" if notices == "fonts" else "fontconvert") / "licenses"
            for notice in origin.rglob("*"):
                if notice.is_file():
                    bundled = app / "Contents/Resources/Licenses" / notices / notice.relative_to(origin)
                    assert bundled.read_bytes() == notice.read_bytes() or bundled.is_symlink(), bundled
        email = work / "email.eml"
        email.write_bytes((root / "Tests/Fixtures/email-values.eml").read_bytes())
        parsed = BytesParser(policy=policy.default).parsebytes(email.read_bytes())
        for extension in ("emlx", "msg", "html", "txt"):
            output = work / ("email." + extension)
            run(command, "convert", email, output)
            assert output.stat().st_size
            if extension in ("emlx", "msg"):
                restored = work / ("email-from-" + extension + ".eml")
                run(command, "convert", output, restored)
                if extension == "emlx":
                    assert restored.read_bytes() == email.read_bytes()
                else:
                    reread = BytesParser(policy=policy.default).parsebytes(restored.read_bytes())
                    assert reread["Subject"] == parsed["Subject"]
                    for message in (parsed, reread):
                        payload = next(p for p in message.walk() if p.get_filename() == "résumé.bin")
                        assert payload.get_payload(decode=True) == bytes(range(256))
            else:
                assert "Second line." in output.read_text()
        for notice in (root / ".tools/mailfile/licenses").rglob("*"):
            if notice.is_file():
                relative = notice.relative_to(root / ".tools/mailfile/licenses")
                assert (app / "Contents/Resources/Licenses/mailfile" / relative).read_bytes() == notice.read_bytes()
        model = work / "shape.obj"
        model.write_text("mtllib material.mtl\nv 0 0 0\nv 2 0 0\nv 0 3 0\nvt 0 0\nvt 1 0\nvt 0 1\nusemtl material\nf 1/1 2/2 3/3\n")
        (work / "material.mtl").write_text("newmtl material\nKd 1 1 1\nmap_Kd original.png\n")
        for extension in ("glb", "fbx", "ply", "stl", "usdz"):
            output = work / ("model." + extension)
            run(command, "convert", model, output)
            assert output.stat().st_size
            if extension == "glb":
                data = output.read_bytes()
                assert struct.unpack_from("<4sII", data) == (b"glTF", 2, len(data))
                count = struct.unpack_from("<I", data, 12)[0]
                document = json.loads(data[20:20 + count])
                texture = document["images"][0]
                assert "bufferView" in texture and "uri" not in texture
            elif extension == "ply":
                header = output.read_bytes().split(b"end_header\n", 1)[0].decode()
                path = next(line.removeprefix("comment TextureFile ") for line in header.splitlines() if line.startswith("comment TextureFile "))
                assert (work / path).read_bytes() == image.read_bytes()
            elif extension == "usdz":
                with zipfile.ZipFile(output) as archive:
                    assert archive.testzip() is None and any(name.endswith(".png") for name in archive.namelist())
            if extension != "stl":
                returned = work / ("from-model-" + extension + ".stl")
                run(command, "convert", output, returned)
                assert struct.unpack_from("<I", returned.read_bytes(), 80)[0] == 1
        for notice in (root / ".tools/models/licenses").rglob("*"):
            if notice.is_file():
                relative = notice.relative_to(root / ".tools/models/licenses")
                assert (app / "Contents/Resources/Licenses/models" / relative).read_bytes() == notice.read_bytes()
        ps = work / "page.ps"
        ps.write_text("%!PS-Adobe-3.0\n<< /PageSize [240 180] >> setpagedevice\n"
                      "0 0 1 setrgbcolor 0 0 240 180 rectfill\n"
                      "1 setgray /Helvetica findfont 16 scalefont setfont 20 100 moveto (PDF package check) show showpage\n")
        pdf = work / "page.pdf"
        run(command, "convert", ps, pdf)
        assert pdf.read_bytes().startswith(b"%PDF-")
        for extension in ("ps", "eps"):
            output = work / f"from-pdf.{extension}"
            run(command, "convert", pdf, output)
            assert output.read_bytes().startswith(b"%!PS-Adobe-")
            returned = work / f"from-{extension}.pdf"
            run(command, "convert", output, returned)
            assert returned.read_bytes().startswith(b"%PDF-")
        for notice in (root / ".tools/pdf/licenses").rglob("*"):
            if notice.is_file():
                relative = notice.relative_to(root / ".tools/pdf/licenses")
                assert (app / "Contents/Resources/Licenses/pdf" / relative).read_bytes() == notice.read_bytes()
        for extension in ("png", "svg", "docx", "html", "md", "pptx"):
            output = work / f"pdf-page.{extension}"
            run(command, "convert", pdf, output)
            if extension == "png":
                assert struct.unpack_from(">II", output.read_bytes(), 16) == (1000, 750)
            elif extension == "svg":
                assert ET.parse(output).getroot().tag == "{http://www.w3.org/2000/svg}svg"
            elif extension == "docx":
                with zipfile.ZipFile(output) as archive:
                    assert archive.testzip() is None
                    assert "PDF package check" in "".join(ET.fromstring(archive.read("word/document.xml")).itertext())
            elif extension == "pptx":
                with zipfile.ZipFile(output) as archive:
                    assert archive.testzip() is None
                    assert struct.unpack_from(">II", archive.read("ppt/media/page1.png"), 16) == (480, 360)
                    assert ET.fromstring(archive.read("ppt/presentation.xml")).tag == "{http://schemas.openxmlformats.org/presentationml/2006/main}presentation"
            else:
                assert "PDF package check" in output.read_text()
        for notice in (root / ".tools/mupdf/licenses").rglob("*"):
            if notice.is_file():
                relative = notice.relative_to(root / ".tools/mupdf/licenses")
                assert (app / "Contents/Resources/Licenses/mupdf" / relative).read_bytes() == notice.read_bytes()
        returned = work / "presentation-returned.pdf"
        run(command, "convert", work / "pdf-page.pptx", returned)
        assert returned.read_bytes().startswith(b"%PDF-")
        assert (app / "Contents/Resources/Presentation/renderer.js").read_bytes() == (root / ".tools/presentation/Resources/Presentation/renderer.js").read_bytes()
        for notice in (root / ".tools/presentation/licenses").rglob("*"):
            if notice.is_file():
                relative = notice.relative_to(root / ".tools/presentation/licenses")
                assert (app / "Contents/Resources/Licenses/presentation" / relative).read_bytes() == notice.read_bytes()
        # Word prints directly at its own page size, so an original fixture declares A5 landscape.
        word = work / "word-layout.docx"
        namespaces = ('xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
                      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"')
        body = ('<w:p><w:r><w:t xml:space="preserve">Caf\u00e9 \u6771\u4eac</w:t></w:r></w:p>'
                '<w:sectPr><w:pgSz w:w="11906" w:h="8391" w:orient="landscape"/>'
                '<w:pgMar w:top="1417" w:right="1134" w:bottom="1417" w:left="1134" '
                'w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>')
        with zipfile.ZipFile(word, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("[Content_Types].xml",
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
                '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
                '<Default Extension="xml" ContentType="application/xml"/>'
                '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-'
                'officedocument.wordprocessingml.document.main+xml"/></Types>')
            archive.writestr("_rels/.rels",
                '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
                '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/'
                'relationships/officeDocument" Target="word/document.xml"/></Relationships>')
            archive.writestr("word/document.xml",
                f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
                f'<w:document {namespaces}><w:body>{body}</w:body></w:document>')
        laid_out = work / "word-layout.pdf"
        run(command, "convert", word, laid_out)
        assert laid_out.read_bytes().startswith(b"%PDF-")
        page = re.search(rb"/MediaBox\s*\[([^\]]*)\]", laid_out.read_bytes())
        assert page, "the printed Word page has no media box"
        box = [float(value) for value in page.group(1).split()]
        assert abs(box[2] - box[0] - 595.3) <= 1 and abs(box[3] - box[1] - 419.55) <= 1, box
        word_text = work / "word-layout.txt"
        run(app / "Contents/Helpers/mutool", "draw", "-F", "txt", "-o", word_text, laid_out)
        assert "Café 東京" in word_text.read_text()
        assert (app / "Contents/Resources/Word/renderer.js").read_bytes() == (
            root / ".tools/presentation/Resources/Word/renderer.js").read_bytes()
        # A layout this path cannot reproduce is refused, and the source is left alone.
        refused = work / "word-columns.docx"
        with zipfile.ZipFile(word) as source, zipfile.ZipFile(refused, "w", zipfile.ZIP_DEFLATED) as archive:
            for item in source.infolist():
                data = source.read(item.filename)
                if item.filename == "word/document.xml":
                    data = data.replace(b"</w:pgMar>", b"</w:pgMar>") \
                        .replace(b"w:gutter=\"0\"/>", b"w:gutter=\"0\"/><w:cols w:num=\"2\" w:space=\"425\"/>")
                archive.writestr(item, data)
        before = refused.read_bytes()
        target = work / "word-columns.pdf"
        result = run(command, "convert", refused, target, check=False)
        assert result.returncode != 0 and "columns" in result.stderr
        assert not target.exists() and refused.read_bytes() == before

        scanned = work / "pdf-page.png"
        recognized = work / "recognized-page.txt"
        run(command, "convert", scanned, recognized)
        assert "PDF package check" in recognized.read_text()
        searchable = work / "searchable.pdf"
        run(app / "Contents/Helpers/nativeguard", scanned, work, "image", scanned, searchable.name, "pdf")
        returned = work / "searchable.html"
        run(command, "convert", searchable, returned)
        assert "PDF package check" in returned.read_text()
        for source in (work / "Café 東京.md", work / "pdf-page.html", work / "result.docx"):
            printed = work / f"printed-{source.suffix[1:]}.pdf"
            run(command, "convert", source, printed)
            text = work / f"printed-{source.suffix[1:]}.txt"
            run(app / "Contents/Helpers/mutool", "draw", "-F", "txt", "-o", text, printed)
            expected = "PDF package check" if source.suffix == ".html" else "Café 東京"
            assert expected in text.read_text()
        vector = work / "vector.svg"
        vector.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80">'
                          '<rect width="120" height="80" fill="red"/>'
                          '<image href="original.png" width="16" height="12"/></svg>')
        for extension in ("png", "pdf", "svgz"):
            output = work / f"vector.{extension}"
            run(command, "convert", vector, output)
            if extension == "png":
                assert struct.unpack_from(">II", output.read_bytes(), 16) == (120, 80)
            elif extension == "pdf":
                assert output.read_bytes().startswith(b"%PDF-")
            else:
                assert gzip.decompress(output.read_bytes()) == vector.read_bytes()
                restored = work / "restored.svg"
                run(command, "convert", output, restored)
                assert restored.read_bytes() == vector.read_bytes()
        project = work / "Artwork.icon"
        for compression in (2, 3):
            source = work / f"packed-{compression}.psd"
            planes = bytes([220]) * 192 + bytes([60]) * 192 + bytes([40]) * 192
            pixels = planes if compression == 2 else b"".join((bytes([value]) + bytes(15)) * 12 for value in (220,60,40))
            source.write_bytes(b"8BPS" + struct.pack(">H6sHIIHH", 1, bytes(6), 3, 12, 16, 8, 3)
                + bytes(12) + struct.pack(">H", compression) + zlib.compress(pixels))
            output = work / f"packed-{compression}.png"
            run(command, "convert", source, output)
            sample = work / f"packed-{compression}.rgb"
            run(app / "Contents/Helpers/ffmpeg", "-v", "error", "-i", output, "-pix_fmt", "rgb24", "-f", "rawvideo", sample)
            assert sample.read_bytes() == bytes([220,60,40]) * 192
        for extension, dimension in (("ico", 256), ("icns", 1024)):
            icon = work / f"generated-icon.{extension}"
            run(command, "convert", image, icon)
            assert icon.read_bytes().startswith(b"\x00\x00\x01\x00\x07\x00" if extension == "ico" else b"icns")
            restored = work / f"icon-{extension}.png"
            run(command, "convert", icon, restored)
            assert struct.unpack_from(">II", restored.read_bytes(), 16) == (dimension, dimension)
        (project / "Assets").mkdir(parents=True)
        (project / "Assets/Shape.svg").write_text('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024"><rect width="1024" height="1024" fill="#dc2814"/></svg>')
        (project / "icon.json").write_text('{"groups":[{"layers":[{"image-name":"Shape.svg"}]}]}')
        originals = {path: path.read_bytes() for path in project.rglob("*") if path.is_file()}
        for extension in ("png", "jpg"):
            output = work / f"icon-artwork.{extension}"
            run(command, "convert", project, output)
            assert all(path.read_bytes() == data for path, data in originals.items())
            if extension == "png":
                assert struct.unpack_from(">II", output.read_bytes(), 16) == (1024, 1024)
            else:
                assert output.read_bytes().startswith(b"\xff\xd8")
            sample = work / f"icon-artwork-{extension}.rgb"
            run(app / "Contents/Helpers/ffmpeg", "-v", "error", "-i", output,
                "-vf", "format=rgb24,crop=1:1:512:512", "-pix_fmt", "rgb24", "-f", "rawvideo", sample)
            assert len(sample.read_bytes()) == 3
            assert max(abs(a-b) for a, b in zip(sample.read_bytes(), (220, 40, 20))) <= 3
        assert not list(work.glob(".allomer-*"))
        # Last, because it damages this copy: a bundle short one helper must refuse to start rather
        # than fall back to another directory and run with routes quietly missing. The second run
        # names the undamaged original's helpers, a complete directory elsewhere on this machine,
        # which must not rescue the damaged copy either.
        # A bundled renderer resource counts the same as a helper: emptying one must refuse the
        # whole install rather than drop its route from the offered formats.
        renderer = app / "Contents/Resources/Word/renderer.js"
        kept = renderer.read_bytes()
        renderer.write_bytes(b"")
        emptied = run(command, "formats", check=False)
        assert emptied.returncode != 0 and "Reinstall the app" in emptied.stderr, emptied.stderr
        renderer.unlink()
        removed = run(command, "formats", check=False)
        assert removed.returncode != 0 and "Reinstall the app" in removed.stderr, removed.stderr
        renderer.write_bytes(kept)
        assert run(command, "formats").returncode == 0

        (app / "Contents/Helpers/tiffcp").unlink()
        complete = source_app / "Contents/Helpers"
        assert (complete / "tiffcp").is_file(), complete
        for override in (None, {"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(complete)}):
            damaged = run(command, "formats", check=False, env=override)
            assert damaged.returncode != 0, (override, damaged.stdout)
            assert "missing" in damaged.stderr and "Reinstall the app" in damaged.stderr, (override, damaged.stderr)
    print("Packaged image, document, audio, subtitle, configuration, archive, spreadsheet, ebook, font, email, model, PostScript, PDF, Word page layout, OCR, SVG, Icon Composer, and damaged install checks passed with no development environment.")


if __name__ == "__main__":
    main()
