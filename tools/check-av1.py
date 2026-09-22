#!/usr/bin/env python3
"""Check bundled AV1 software decoding with original 8-bit and 10-bit video."""
import argparse
from fractions import Fraction
import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess
import tempfile
import wave


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=root / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=root / ".tools/bin")
    args = parser.parse_args()
    command, tools = args.command.resolve(), args.tools.resolve()
    environment = {"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools), "SVT_LOG": "1"}
    width, height, frames, rate = 720, 576, 25, 25
    outputs = {"mp4": "h264", "mov": "h264", "webm": "vp9", "mkv": "h264", "avi": "mpeg4",
               "3gp": "h264", "mxf": "mpeg2video", "mpeg": "mpeg2video", "m2ts": "h264",
               "vob": "mpeg2video", "wmv": "wmv2", "flv": "h264", "ts": "h264"}
    checks = 0
    with tempfile.TemporaryDirectory(prefix="AV1 decode café 100% ") as directory:
        work = Path(directory)

        def run(*arguments):
            result = subprocess.run(arguments, env=environment, cwd=work, capture_output=True, timeout=90)
            assert result.returncode == 0 and not result.stderr.strip(), (arguments, result.stderr.decode(errors="replace"))
            return result.stdout

        def ffmpeg(*arguments):
            return run(tools / "ffmpeg", "-nostdin", "-v", "error", "-xerror", "-n",
                       "-threads", "1", "-filter_threads", "1", *arguments)

        def probe(path):
            return json.loads(run(tools / "ffprobe", "-v", "error", "-threads", "1", "-count_frames",
                                  "-show_streams", "-show_format", "-of", "json", path))

        def frame_hashes(path, decoder=None, threads=1, converted=False):
            options = ["-c:v", decoder] if decoder else []
            data = ffmpeg(*options, "-threads", str(threads), "-err_detect", "explode", "-i", path,
                          "-map", "0:V:0", "-an", "-fps_mode", "passthrough", "-threads:v", "1", "-f", "framemd5", "-")
            lines = data.decode().splitlines()
            time_base = Fraction(next(line.split(":", 1)[1].strip() for line in lines if line.startswith("#tb 0:")))
            rows = [line.split(",") for line in lines if line and not line.startswith("#")]
            assert len(rows) == frames, (path, "Wrong decoded frame count", len(rows))
            times = [int(row[2]) * time_base for row in rows]
            expected = [times[0] + Fraction(i, rate) for i in range(frames)]
            if converted:
                # Existing output containers can quantize the initial audio/video offset.
                assert all(a < b for a, b in zip(times, times[1:])), (path, times)
                assert all(abs(a - b) <= Fraction(1, rate) for a, b in zip(times, expected)), (path, times)
            else:
                assert times == expected, (path, times)
            assert all(int(row[4]) > 0 for row in rows), path
            assert len({row[5].strip() for row in rows}) > 1, (path, "All decoded frames are identical")
            return [(int(row[4]), row[5].strip()) for row in rows]

        raw = work / "original.rgb"
        with raw.open("xb") as file:
            for frame in range(frames):
                row = bytes(value for x in range(width) for value in (
                    (x * 3 + frame * 11) % 256, (x * 7 + frame * 5) % 256, (x ^ (frame * 13)) % 256))
                for y in range(height):
                    offset = (y * 5 % width) * 3
                    file.write(row[offset:] + row[:offset])
        audio = work / "original.wav"
        with wave.open(str(audio), "wb") as file:
            file.setparams((2, 2, 48000, 0, "NONE", "not compressed"))
            file.writeframes(b"".join(struct.pack("<hh", round(9000 * math.sin(i * 440 * math.tau / 48000)),
                round(9000 * math.sin(i * 660 * math.tau / 48000))) for i in range(48000)))

        for depth in (8, 10):
            encoded = work / f"original-{depth}.mkv"
            pixel = "yuv420p" if depth == 8 else "yuv420p10le"
            ffmpeg("-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", f"{width}x{height}",
                   "-framerate", str(rate), "-i", raw, "-i", audio, "-map", "0:v:0", "-map", "1:a:0",
                   "-c:v", "libsvtav1", "-pix_fmt", pixel, "-preset", "8", "-svtav1-params", "lp=2",
                   "-crf", "30", "-b:v", "0", "-c:a", "aac", "-b:a", "192k", "-f", "matroska", encoded)
            reference = frame_hashes(encoded, "libdav1d")
            assert frame_hashes(encoded, "libdav1d", threads=2) == reference
            for container in ("mkv", "mp4", "webm"):
                source = encoded
                if container != "mkv":
                    source = work / f"original-{depth}.{container}"
                    # WebM requires Opus or Vorbis. The picture bitstream is retained.
                    codec = "libopus" if container == "webm" else "copy"
                    ffmpeg("-i", encoded, "-map", "0", "-c:v", "copy", "-c:a", codec, "-f", container, source)
                info = probe(source)
                video = [s for s in info["streams"] if s["codec_type"] == "video"]
                assert len(video) == 1 and video[0]["codec_name"] == "av1", info
                assert video[0]["pix_fmt"] == pixel and int(video[0]["nb_read_frames"]) == frames, video
                assert frame_hashes(source) == reference, (source, "Automatic decoder changed pixels")
                extensions = outputs if depth == 8 and container == "mkv" else {"mp4": "h264"}
                for extension, expected_codec in extensions.items():
                    output = work / f"converted-{depth}-{container}.{extension}"
                    original_hash = hashlib.sha256(source.read_bytes()).digest()
                    run(command, "convert", source, output)
                    assert hashlib.sha256(source.read_bytes()).digest() == original_hash, source
                    assert not list(work.rglob(".allomer-*")), list(work.iterdir())
                    result = probe(output)
                    video = [s for s in result["streams"] if s["codec_type"] == "video"]
                    sound = [s for s in result["streams"] if s["codec_type"] == "audio"]
                    assert len(video) == len(sound) == 1 and video[0]["codec_name"] == expected_codec, result
                    assert (video[0]["width"], video[0]["height"]) == (width, height), video
                    frame_hashes(output, converted=True)
                    pcm = ffmpeg("-i", output, "-map", "0:a:0", "-ac", "2", "-ar", "48000",
                                 "-c:a", "pcm_s16le", "-f", "s16le", "-")
                    assert len(pcm) % 4 == 0 and abs(len(pcm) // 4 - 48000) <= 4096 and any(pcm), output
                    checks += 1
            print(f"Passed {depth}-bit AV1 decoding in MKV, MP4 and WebM.", flush=True)

        damaged = work / "incomplete.mkv"
        source_bytes = encoded.read_bytes()
        damaged.write_bytes(source_bytes[:len(source_bytes) // 2])
        before = damaged.read_bytes()
        output = work / "must-not-publish.mp4"
        failed = subprocess.run([command, "convert", damaged, output], env=environment,
                                cwd=work, capture_output=True, timeout=90)
        assert failed.returncode != 0 and not output.exists(), failed.stdout
        assert damaged.read_bytes() == before and not list(work.rglob(".allomer-*"))
        print(f"Passed {checks} AV1 input conversions and incomplete-input cleanup. Decoded frame counts, timing, pixels across decoder threads, audio, and source bytes checked.")


if __name__ == "__main__":
    main()
