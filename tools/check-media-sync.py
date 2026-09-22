#!/usr/bin/env python3
"""Check audio/video offsets with original flashes and tone bursts."""
from array import array
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
    environment = {"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools)}
    rate, sample_rate = 25, 48000
    checks = 0
    with tempfile.TemporaryDirectory(prefix="Media sync café 100% ") as directory:
        work = Path(directory)

        def run(*arguments):
            result = subprocess.run(list(map(str, arguments)), env=environment, cwd=work,
                                    capture_output=True, timeout=120)
            assert result.returncode == 0 and not result.stderr.strip(), (arguments, result.stderr.decode(errors="replace"))
            return result.stdout

        def ffmpeg(*arguments):
            return run(tools / "ffmpeg", "-v", "error", "-nostdin", "-xerror", "-n",
                       "-threads", "1", "-filter_threads", "1", *arguments)

        def events(path):
            info = json.loads(run(tools / "ffprobe", "-v", "error", "-threads", "1", "-show_streams",
                                  "-show_frames", "-of", "json", path))
            video = [f for f in info["frames"] if f["media_type"] == "video"]
            audio = [f for f in info["frames"] if f["media_type"] == "audio"]
            sound = next(s for s in info["streams"] if s["codec_type"] == "audio")
            decoded = ffmpeg("-i", path, "-map", "0:V:0", "-vf", "scale=1:1:flags=area,format=gray",
                             "-fps_mode", "passthrough", "-threads:v", "1", "-f", "rawvideo", "-")
            assert len(decoded) == len(video)
            flashes = [float(f["best_effort_timestamp_time"]) for i, f in enumerate(video)
                       if decoded[i] > 128 and (i == 0 or decoded[i - 1] <= 128)]
            pcm = array("h", ffmpeg("-i", path, "-map", "0:a:0", "-c:a", "pcm_s16le", "-f", "s16le", "-"))
            hz, channels = int(sound["sample_rate"]), sound["channels"]
            assert sum(f["nb_samples"] for f in audio) * channels == len(pcm)
            bursts, last, cursor = [], float("-inf"), 0
            for position, frame in enumerate(audio):
                if "best_effort_timestamp_time" not in frame:
                    # WMA flushes one final frame without PTS. These fixtures end in silence.
                    assert position == len(audio) - 1 and sound["codec_name"] in ("wmav1", "wmav2")
                    assert not any(abs(v) > 9000 for v in pcm[cursor * channels:(cursor + frame["nb_samples"]) * channels])
                else:
                    start = float(frame["best_effort_timestamp_time"])
                    for i in range(frame["nb_samples"]):
                        if abs(pcm[(cursor + i) * channels]) > 9000:
                            when = start + i / hz
                            if when - last > 0.1:
                                bursts.append(when)
                            last = when
                cursor += frame["nb_samples"]
            assert len(flashes) == len(bursts) == 2, (path, flashes, bursts)
            return {"offsets": [a - v for a, v in zip(bursts, flashes)], "video": video, "audio": audio,
                    "samples": cursor, "rate": hz, "pixels": decoded}

        raw = work / "flashes.gray"
        with raw.open("xb") as file:
            for n in range(100):
                file.write(bytes([235 if 10 <= n < 15 or 60 <= n < 65 else 16]) * (720 * 576))
        wav = work / "bursts.wav"
        with wave.open(str(wav), "wb") as file:
            file.setparams((2, 2, sample_rate, 0, "NONE", "not compressed"))
            file.writeframes(b"".join(struct.pack("<hh", v, v) for i in range(sample_rate * 4)
                for v in [round(18000 * math.sin(math.tau * 1000 * i / sample_rate))
                          if 19200 <= i < 28800 or 115200 <= i < 124800 else 0]))

        cases = [("aligned", 0, 0, 4, 4, 0), ("audio-late", 0, 0.4, 4, 4, 0),
                 ("video-late", 0.4, 0, 4, 4, 0), ("audio-short", 0, 0, 4, 3, 0),
                 ("video-short", 0, 0, 3, 4, 0), ("audio-gap", 0, 0, 4, 4, 0.2),
                 ("shifted-origin", 5, 5.4, 4, 4, 0),
                 ("audio-gap20", 0, 0, 4, 4, 0.02), ("audio-gap50", 0, 0, 4, 4, 0.05)]
        containers = ("mp4", "mov", "webm", "mkv", "avi", "3gp", "mxf", "mpeg", "m2ts", "vob", "wmv", "flv", "ts")
        for name, video_delay, audio_delay, video_length, audio_length, gap in cases:
            source = work / f"{name}.mkv"
            af = f"atrim=duration={audio_length}"
            if gap:
                af += rf",asetpts=PTS+if(gte(T\,2)\,{gap}/TB\,0)"
            ffmpeg("-copyts", "-itsoffset", video_delay, "-f", "rawvideo", "-pixel_format", "gray",
                   "-video_size", "720x576", "-framerate", rate, "-i", raw, "-itsoffset", audio_delay,
                   "-i", wav, "-map", "0:v:0", "-map", "1:a:0", "-vf", f"trim=duration={video_length}",
                   "-af", af, "-c:v", "ffv1", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le",
                   "-metadata:s:a:0", "title=Tone track", "-metadata:s:a:0", "language=fra",
                   "-metadata:s:v:0", "title=Picture track", "-metadata:s:v:0", "language=deu",
                   "-disposition:a:0", "default+original", "-disposition:v:0", "default", source)
            reference = events(source)
            before = hashlib.sha256(source.read_bytes()).digest()
            for extension in containers:
                output = work / f"{name}-output.{extension}"
                run(command, "convert", source, output)
                actual = events(output)
                errors = [a - b for a, b in zip(actual["offsets"], reference["offsets"])]
                tolerance = 1 / rate if extension == "avi" else 0.002
                assert all(abs(e) <= tolerance for e in errors), (name, extension, errors)
                prefix = round(max(0, video_delay - min(video_delay, audio_delay)) * rate) if extension in ("avi", "mxf") else 0
                suffix = round(max(0, audio_delay + audio_length + gap - video_delay - video_length) * rate) if extension == "mxf" else 0
                assert len(actual["video"]) == len(reference["video"]) + prefix + suffix, (name, extension, len(actual["video"]), prefix, suffix)
                if prefix:
                    assert max(actual["pixels"][:prefix]) < 50
                if suffix:
                    assert max(actual["pixels"][-suffix:]) < 50
                assert hashlib.sha256(source.read_bytes()).digest() == before
                assert not list(work.glob(".allomer-*"))
                if extension == "mkv":
                    info = json.loads(run(tools / "ffprobe", "-v", "error", "-show_streams", "-of", "json", output))
                    video, audio = info["streams"]
                    assert video["tags"]["title"] == "Picture track" and video["tags"]["language"] == "deu"
                    assert audio["tags"]["title"] == "Tone track" and audio["tags"]["language"] == "fra"
                    assert video["disposition"]["default"] == audio["disposition"]["default"] == 1
                    assert audio["disposition"]["original"] == 1
                checks += 1
            if name == "audio-late":
                for extension in ("avi", "mxf", "wmv", "ts"):
                    settings = work / "fractional.json"
                    settings.write_text(json.dumps({"videoFrameRate": "30000/1001"}))
                    output = work / f"fractional.{extension}"
                    run(command, "convert", source, output, "--media-options", settings)
                    actual = events(output)
                    assert all(abs(a - b) <= float(Fraction(1001, 30000)) + 0.002
                               for a, b in zip(actual["offsets"], reference["offsets"])), extension
                    assert hashlib.sha256(source.read_bytes()).digest() == before
                    assert not list(work.glob(".allomer-*"))
                    checks += 1
            print(name, "passed all 13 containers.", flush=True)
        print(f"Passed {checks} audio/video synchronization conversions, decoded flashes and tones, padding, frame counts, source bytes, and cleanup.")


if __name__ == "__main__":
    main()
