#!/usr/bin/env python3
"""Check audio settings and embedded artwork with original WAV, PNG, JPEG, and BMP fixtures."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import platform
import re
import statistics
import struct
import subprocess
import tempfile
import wave
import zlib


FORMATS = {
    "mp3": "mp3", "aac": "aac", "m4a": "aac", "wav": "pcm_s24le",
    "aiff": "pcm_s24be", "flac": "flac", "alac": "alac", "ogg": "vorbis",
    "opus": "opus", "wma": "wmav2", "caf": "pcm_s24le", "ac3": "ac3",
    "eac3": "eac3", "mka": "flac", "au": "pcm_s24be", "tta": "tta", "wv": "wavpack",
}
LOSSLESS = {"wav", "aiff", "flac", "alac", "caf", "mka", "au", "tta", "wv"}
ART_FORMATS = {"mp3", "m4a", "alac", "flac", "aiff", "mka", "ogg", "opus"}
ART_CODECS = {".png": "png", ".jpg": "mjpeg", ".bmp": "bmp"}
TITLE, ARTIST = "Invented interval café", "Original fixture author"


def write_originals(work, seconds=0.75, edge=32):
    pcm = bytearray()
    for sample in range(round(48000 * seconds)):
        t = sample / 48000
        for frequency in (440, 660):
            value = 11000 * math.sin(2 * math.pi * frequency * t)
            value += 2700 * math.sin(2 * math.pi * (frequency * 2.3) * t)
            pcm.extend(struct.pack("<h", round(value)))
    audio = work / "original.wav"
    with wave.open(str(audio), "wb") as output:
        output.setparams((2, 2, 48000, 0, "NONE", "not compressed"))
        output.writeframes(pcm)
    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))
    rows = b"".join(b"\0" + bytes(value for x in range(edge)
        for value in ((x * 9 + y * 3) % 256, (x * 2 + y * 7) % 256, (x * 5 + y * 11) % 256))
        for y in range(edge))
    image = work / "original.png"
    image.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", edge, edge, 8, 2, 0, 0, 0))
                      + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
    return audio, image, bytes(pcm)


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=root / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=root / ".tools/bin")
    parser.add_argument("--benchmark-only", action="store_true", help="Measure three full conversions per format and cover setting; run without other build or conversion jobs.")
    args = parser.parse_args()
    command, tools = args.command.resolve(), args.tools.resolve()
    environment = {"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools)}
    checks = 0
    seconds, edge = (60, 2048) if args.benchmark_only else (0.75, 32)
    with tempfile.TemporaryDirectory(prefix="Audio options café 100% ") as directory:
        work = Path(directory)
        sequence = 0

        def run(*arguments):
            result = subprocess.run(arguments, env=environment, cwd=work, capture_output=True, timeout=90)
            assert result.returncode == 0, (arguments, result.stderr.decode(errors="replace"))
            assert not result.stderr.strip(), (arguments, result.stderr.decode(errors="replace"))
            return result.stdout

        def ffmpeg(*arguments):
            return run(tools / "ffmpeg", "-nostdin", "-v", "error", "-xerror", "-n",
                       "-threads", "1", "-filter_threads", "1", *arguments)

        def probe(path):
            return json.loads(run(tools / "ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", path))

        def decoded(path):
            return ffmpeg("-i", path, "-map", "0:a:0", "-c:a", "pcm_s16le", "-threads:a", "1", "-f", "s16le", "-")

        def audio_payload(path):
            return ffmpeg("-i", path, "-map", "0:a:0", "-c:a", "copy", "-f", "data", "-")

        def check_audio(path, extension, exact=False, rate=48000, channels=2):
            info = probe(path)
            streams = [stream for stream in info["streams"] if stream["codec_type"] == "audio"]
            assert len(streams) == 1 and streams[0]["codec_name"] == FORMATS[extension], (path, info)
            assert (int(streams[0]["sample_rate"]), streams[0]["channels"]) == (rate, channels), (path, info)
            samples = decoded(path)
            assert len(samples) % (channels * 2) == 0 and any(samples), path
            frames = len(samples) // (channels * 2)
            assert abs(frames - round(rate * seconds)) <= 4096, (path, frames, rate)
            if exact:
                assert samples == original_pcm, (path, "Lossless PCM changed.")
            return info

        def check_art(path, expected):
            info = probe(path)
            images = [stream for stream in info["streams"] if stream["codec_type"] != "audio"]
            assert len(images) == len(expected), (path, info, len(expected))
            if not expected:
                for item in [info["format"], *info["streams"]]:
                    assert not {key.lower() for key in item.get("tags", {})} & {
                        "metadata_block_picture", "coverart", "coverartmime", "wm/picture"}, (path, item)
            wanted = Counter((ART_CODECS[image.suffix], hashlib.sha256(image.read_bytes()).digest())
                             for image in expected if not (path.suffix == ".mka" and image.suffix == ".bmp"))
            for image in expected:
                if path.suffix == ".mka" and image.suffix == ".bmp":
                    pixels = ffmpeg("-i", image, "-frames:v", "1", "-pix_fmt", "rgba", "-f", "rawvideo", "-")
                    wanted[("bmp-pixels", hashlib.sha256(pixels).digest())] += 1
            actual = Counter()
            for stream in images:
                assert stream["codec_type"] == "video" and stream.get("disposition", {}).get("attached_pic") == 1, (path, stream)
                assert (stream["width"], stream["height"]) == (edge, edge), (path, stream)
                assert stream["codec_name"] in ART_CODECS.values(), (path, stream)
                data = ffmpeg("-i", path, "-map", f"0:{stream['index']}", "-c", "copy", "-f", "image2pipe", "-")
                key = (stream["codec_name"], hashlib.sha256(data).digest())
                if path.suffix == ".mka" and stream["codec_name"] == "png" and key not in wanted:
                    pixels = ffmpeg("-i", path, "-map", f"0:{stream['index']}", "-frames:v", "1",
                                    "-pix_fmt", "rgba", "-f", "rawvideo", "-")
                    key = ("bmp-pixels", hashlib.sha256(pixels).digest())
                actual[key] += 1
            assert actual == wanted, (path, "Cover bytes, codecs, or converted BMP pixels changed.")
            if path.suffix == ".mka" and images:
                extension = "jpg" if images[0]["codec_name"] == "mjpeg" else "png"
                assert images[0]["tags"]["filename"] == f"cover.{extension}", images[0]

        def check_metadata(path, preserved):
            info = probe(path)
            tags = {key.lower(): value for item in [info["format"], *info["streams"]]
                    if item.get("codec_type", "audio") == "audio" for key, value in item.get("tags", {}).items()}
            if preserved:
                assert tags.get("title") == TITLE and tags.get("artist") == ARTIST, (path, tags)
            else:
                assert TITLE not in tags.values() and ARTIST not in tags.values(), (path, tags)

        def convert(source, extension, options=None, failure=False, raw_options=None, collision=False):
            nonlocal sequence, checks
            sequence += 1
            output = work / f"result-{sequence}.{extension}"
            source_bytes = source.read_bytes()
            arguments = [command, "convert", source, output]
            if options is not None or raw_options is not None:
                settings = work / f"options-{sequence}.json"
                settings.write_text(raw_options if raw_options is not None else json.dumps(options), encoding="utf-8")
                arguments += ["--media-options", settings]
            saved = b"Existing output must survive.\n" if collision else None
            if collision:
                output.write_bytes(saved)
            result = subprocess.run(arguments, env=environment, cwd=work, capture_output=True, timeout=90)
            assert source.read_bytes() == source_bytes, (source, "Source bytes changed.")
            assert not list(work.rglob(".allomer-*")), list(work.iterdir())
            if failure or collision:
                assert result.returncode != 0, (arguments, result.stdout)
                assert output.read_bytes() == saved if collision else not output.exists(), output
            else:
                assert result.returncode == 0 and output.is_file(), (arguments, result.stderr.decode(errors="replace"))
            checks += 1
            return output

        audio, png, original_pcm = write_originals(work, seconds, edge)
        if args.benchmark_only:
            source = work / "benchmark.flac"
            ffmpeg("-i", audio, "-i", png, "-map", "0:a:0", "-map", "1:v:0", "-c:a", "flac",
                   "-compression_level:a", "8", "-c:v", "copy", "-disposition:v", "attached_pic",
                   "-metadata:s:v", "comment=Cover (front)", "-f", "flac", source)
            cases = []
            for extension in ("m4a", "ogg", "mka"):
                for keep in (False, True):
                    options = {"audioMode": "quality", "audioQuality": 100, "flacCompressionLevel": 8,
                               "preserveCoverArt": keep, "preserveMetadata": True, "cpuProfile": "medium"}
                    settings = work / "benchmark-options.json"
                    settings.write_text(json.dumps(options))
                    samples = []
                    for index in range(3):
                        before = hashlib.sha256(source.read_bytes()).hexdigest()
                        output = work / f"benchmark-{extension}-{keep}-{index}.{extension}"
                        measured = subprocess.run(["/usr/bin/time", "-l", command, "convert", source, output,
                                                   "--media-options", settings], env=environment, cwd=work,
                                                  capture_output=True, text=True, timeout=180)
                        assert measured.returncode == 0, measured.stderr
                        check_audio(output, extension, exact=extension == "mka")
                        check_art(output, [png] if keep else [])
                        assert hashlib.sha256(source.read_bytes()).hexdigest() == before
                        assert not list(work.rglob(".allomer-*"))
                        samples.append({"seconds": float(re.search(r"([\d.]+)\s+real", measured.stderr)[1]),
                            "resident_bytes": int(re.search(r"(\d+)\s+maximum resident set size", measured.stderr)[1]),
                            "output_bytes": output.stat().st_size,
                            "output_sha256": hashlib.sha256(output.read_bytes()).hexdigest()})
                    cases.append({"format": extension, "options": options, "runs": samples,
                        "median_seconds": statistics.median(s["seconds"] for s in samples),
                        "median_resident_bytes": statistics.median(s["resident_bytes"] for s in samples)})
            report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                "architecture": platform.machine(), "cpu": run("/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string").decode().strip(),
                "command_sha256": hashlib.sha256(command.read_bytes()).hexdigest(),
                "helper_sha256": {name: hashlib.sha256((tools / name).read_bytes()).hexdigest() for name in ("ffmpeg", "ffprobe")},
                "input_sha256": before, "input_bytes": source.stat().st_size, "duration_seconds": seconds,
                "sample_rate": 48000, "channels": 2, "art_dimensions": [edge, edge], "art_bytes": png.stat().st_size,
                "art_sha256": hashlib.sha256(png.read_bytes()).hexdigest(), "cases": cases,
                "scope": "Three complete conversions for each output and cover setting. Original 60-second stereo audio with a 2048-square PNG cover. Includes probing, artwork validation, encoding, output checks and publication. Source hashes warm the cache. GUI, fixture generation and independent Python validation are excluded. RSS is a per-process peak, not aggregate app/helper/system memory. This synthetic signal is not a listening-quality or general music benchmark."}
            (root / "research/audio-options-performance.json").write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps(report, indent=2), flush=True)
            return
        jpeg = work / "original.jpg"
        ffmpeg("-i", png, "-frames:v", "1", "-c:v", "mjpeg", "-threads:v", "1", "-pix_fmt", "yuvj444p", "-q:v", "2", jpeg)
        bmp = work / "original.bmp"
        ffmpeg("-i", png, "-frames:v", "1", "-c:v", "bmp", "-threads:v", "1", "-pix_fmt", "bgr24", bmp)

        def embedded(name, pictures):
            source = work / f"{name}.flac"
            inputs = ["-i", audio]
            mapping = ["-map", "0:a:0", "-c:a", "flac", "-threads:a", "1"]
            for index, picture in enumerate(pictures):
                inputs += ["-i", picture]
                mapping += ["-map", f"{index + 1}:v:0", f"-metadata:s:v:{index}", f"title=Original cover {index + 1}",
                            f"-metadata:s:v:{index}", "comment=Cover (front)" if index == 0 else "comment=Cover (back)"]
            if pictures:
                mapping += ["-c:v", "copy", "-disposition:v", "attached_pic"]
            ffmpeg(*inputs, *mapping, "-metadata", f"title={TITLE}", "-metadata", f"artist={ARTIST}", "-f", "flac", source)
            check_audio(source, "flac", exact=True)
            check_art(source, pictures)
            check_metadata(source, True)
            return source

        baseline = {}
        for extension in FORMATS:
            output = baseline[extension] = convert(audio, extension)
            check_audio(output, extension, exact=extension in LOSSLESS)
            check_art(output, [])
        print("Passed all 17 audio outputs without artwork.", flush=True)

        for extension in ("mp3", "aac", "m4a", "ogg"):
            outputs = []
            for quality in (0, 100):
                output = convert(audio, extension, {"audioMode": "quality", "audioQuality": quality})
                check_audio(output, extension)
                outputs.append(output)
            assert outputs[1].stat().st_size > outputs[0].stat().st_size, (extension, "Quality endpoints have no size effect.")
            assert audio_payload(baseline[extension]) == audio_payload(outputs[1]), (extension, "Default quality is not 100.")
        for bitrate in (64, 192):
            output = convert(audio, "mp3", {"audioMode": "bitrate", "audioBitrateKbps": bitrate})
            info = check_audio(output, "mp3")
            assert int(next(stream for stream in info["streams"] if stream["codec_type"] == "audio")["bit_rate"]) == bitrate * 1000, info
        for extension in ("flac", "mka"):
            sizes = []
            for level in (0, 8, 12):
                output = convert(audio, extension, {"flacCompressionLevel": level})
                check_audio(output, extension, exact=True)
                sizes.append(len(audio_payload(output)))
                if level == 8:
                    assert audio_payload(output) == audio_payload(baseline[extension]), (extension, "Default FLAC level is not 8.")
            assert sizes[0] > min(sizes[1:]), (extension, "FLAC compression settings have no effect.", sizes)
        output = convert(audio, "wav", {"sampleRate": 44100, "channels": 1})
        check_audio(output, "wav", rate=44100, channels=1)
        assert abs(len(decoded(output)) // 2 - 33075) <= 1

        tagged = embedded("tagged", [])
        legacy = {"audioBitrateKbps": 96, "videoBitrateKbps": 2500, "sampleRate": 44100,
                  "channels": 1, "preserveMetadata": False, "timeout": 30}
        output = convert(tagged, "flac", legacy)
        check_audio(output, "flac", rate=44100, channels=1)
        check_metadata(output, False)
        for key, values in {
            "audioMode": ("unknown", 1), "audioQuality": (-0.1, 100.1, "high"),
            "flacCompressionLevel": (-1, 13, 8.5), "audioBitrateKbps": (7, 1537),
            "sampleRate": (7999, 384001), "channels": (0, 9), "timeout": (0, -1),
            "preserveCoverArt": ("true",),
        }.items():
            for value in values:
                convert(audio, "flac", {key: value}, failure=True)
        for raw in ("{", "[]", "null", '{"audioQuality":NaN}', '{"audioQuality":1e999}'):
            convert(audio, "flac", failure=True, raw_options=raw)
        convert(audio, "flac", failure=True, raw_options='{"audioQuality":100,"padding":"' + "x" * 65536 + '"}')
        convert(audio, "flac", collision=True)
        print("Passed quality, bitrate, FLAC PCM, defaults, rate/channels, and invalid-option checks.", flush=True)

        sources = {image: embedded(image.stem + image.suffix[1:], [image]) for image in (png, jpeg, bmp)}
        art_inputs = {}
        for image, source in sources.items():
            for extension in sorted(ART_FORMATS):
                output = convert(source, extension)
                check_audio(output, extension, exact=extension in LOSSLESS)
                check_art(output, [image])
                check_metadata(output, True)
                if image == png:
                    if extension in ("ogg", "opus", "mka"):
                        art_inputs[extension] = output
                    output = convert(source, extension, {"preserveMetadata": False})
                    check_audio(output, extension, exact=extension in LOSSLESS)
                    check_art(output, [image])
                    check_metadata(output, False)
        for extension, source in art_inputs.items():
            for metadata in (True, False):
                output = convert(source, extension, {"preserveCoverArt": False, "preserveMetadata": metadata})
                check_audio(output, extension)
                check_art(output, [])
                check_metadata(output, metadata)
        for extension in sorted(set(FORMATS) - ART_FORMATS):
            convert(sources[png], extension, {"preserveCoverArt": True}, failure=True)
            output = convert(sources[png], extension, {"preserveCoverArt": False})
            check_audio(output, extension, exact=extension in LOSSLESS)
            check_art(output, [])
        output = convert(sources[png], "flac", {"preserveCoverArt": False})
        check_audio(output, "flac", exact=True)
        check_art(output, [])
        check_metadata(output, True)

        multiple = embedded("two-covers", [png, jpeg])
        for extension in sorted(ART_FORMATS - {"ogg", "opus"}):
            output = convert(multiple, extension)
            check_audio(output, extension, exact=extension in LOSSLESS)
            check_art(output, [png, jpeg])
        for extension in ("ogg", "opus"):
            convert(multiple, extension, failure=True)
        excessive = embedded("nine-covers", [png, jpeg] * 4 + [png])
        convert(excessive, "flac", failure=True)
        assert not list(work.rglob(".allomer-*"))
    assert not work.exists()
    print(f"Passed {checks} CLI cases: 17 audio outputs, quality/bitrate, lossless compression, metadata, "
          "cover bytes and status, converted BMP pixels, multiple covers, cover removal, limits, failures, source bytes, and cleanup.")


if __name__ == "__main__":
    main()
