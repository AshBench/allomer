#!/usr/bin/env python3
"""Check audio-only container routes, codec-frame endings, and failed-output cleanup."""
from array import array
import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess
import tempfile
import wave


SOURCES = {
    "mp3": ("mp3", "mp3"), "aac": ("aac", "aac"), "m4a": ("mov", "aac"),
    "wav": ("wav", "pcm_s24le"), "aiff": ("aiff", "pcm_s24be"), "flac": ("flac", "flac"),
    "alac": ("mov", "alac"), "ogg": ("ogg", "vorbis"), "opus": ("ogg", "opus"),
    "wma": ("asf", "wmav2"), "caf": ("caf", "pcm_s24le"), "ac3": ("ac3", "ac3"),
    "eac3": ("eac3", "eac3"), "mka": ("matroska", "flac"), "au": ("au", "pcm_s24be"),
    "tta": ("tta", "tta"), "wv": ("wv", "wavpack"),
}
# Container, codec, decoder delay, maximum added samples, closing-edge tolerance.
# Counts apply at 48 kHz. WMA can spread a short tone across its transform window.
TARGETS = {
    "avi": ("avi", "mp3", 1105, 2304, 96),
    "m2ts": ("mpegts", "ac3", 256, 3072, 96),
    "mpeg": ("mpeg", "mp2", 481, 2304, 96),
    "ts": ("mpegts", "aac", 1024, 2048, 96),
    "vob": ("mpeg", "ac3", 256, 3072, 96),
    "wmv": ("asf", "wmav2", 0, 4096, 576),
}
RATE = 48000


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=root / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=root / ".tools/bin")
    args = parser.parse_args()
    command, tools = args.command.resolve(), args.tools.resolve()
    environment = {"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools)}
    with tempfile.TemporaryDirectory(prefix="Audio containers café ") as directory:
        work = Path(directory)
        options = work / "options.json"
        options.write_text(json.dumps({"sampleRate": RATE, "channels": 2, "audioBitrateKbps": 192}))

        def run(*arguments, failure=False):
            result = subprocess.run(list(map(str, arguments)), cwd=work, env=environment,
                                    capture_output=True, timeout=120)
            if failure:
                assert result.returncode != 0, (arguments, "Expected refusal")
            else:
                assert result.returncode == 0 and not result.stderr.strip(), (arguments, result.stderr.decode(errors="replace"))
            return result.stdout

        def convert(source, output, failure=False):
            before = hashlib.sha256(source.read_bytes()).digest()
            names = set(work.iterdir())
            existing = output.read_bytes() if output.exists() else None
            run(command, "convert", source, output, "--media-options", options, failure=failure)
            assert hashlib.sha256(source.read_bytes()).digest() == before, (source, "Source changed")
            assert not list(work.glob(".allomer-*")), "Conversion work leaked"
            assert set(work.iterdir()) == names | (set() if failure else {output}), (source, output, "Unexpected files")
            if failure:
                assert output.read_bytes() == existing if existing is not None else not output.exists(), output

        def fixture(name, seconds, bursts):
            path = work / name
            with wave.open(str(path), "wb") as file:
                file.setparams((2, 2, RATE, 0, "NONE", "not compressed"))
                file.writeframes(b"".join(struct.pack("<hh", value, value) for index in range(round(seconds * RATE))
                    for value in [round(20000 * math.sin(math.tau * 1000 * index / RATE))
                                  if any(start <= index / RATE < end for start, end in bursts) else 0]))
            return path

        def decoded(path, codec, container=None):
            input_options = ["-f", "mpegts"] if path.suffix in (".ts", ".m2ts") else []
            info = json.loads(run(tools / "ffprobe", "-v", "error", *input_options,
                                  "-show_streams", "-show_format", "-of", "json", path))
            streams = info["streams"]
            assert len(streams) == 1 and streams[0]["codec_type"] == "audio", (path, streams)
            stream = streams[0]
            assert stream["codec_name"] == codec and stream["channels"] == 2 and int(stream["sample_rate"]) == RATE, (path, stream)
            if container is not None:
                assert container in info["format"]["format_name"].split(","), (path, info["format"])
            pcm = array("h", run(tools / "ffmpeg", "-v", "error", "-nostdin", "-xerror",
                                 "-threads", "1", *input_options, "-i", path, "-map", "0:a:0",
                                 "-c:a", "pcm_s16le", "-f", "s16le", "pipe:1"))
            assert len(pcm) > 0 and len(pcm) % 2 == 0, path
            events = []
            for index in range(0, len(pcm), 2):
                if abs(pcm[index]) <= 9000:
                    continue
                frame = index // 2
                if not events or frame - events[-1][1] > RATE // 10:
                    events.append([frame, frame])
                else:
                    events[-1][1] = frame
            return len(pcm) // 2, events

        def check(source, expected, target, name):
            output = work / f"{name}.{target}"
            convert(source, output)
            container, codec, delay, padding, closing_tolerance = (
                (target, target, 256, 3072, 96) if target in ("ac3", "eac3") else TARGETS[target])
            frames, events = decoded(output, codec, container)
            source_frames, source_events = expected
            assert source_frames <= frames <= source_frames + padding, (source, target, source_frames, frames, padding)
            assert len(events) == len(source_events), (source, target, source_events, events)
            for original, actual in zip(source_events, events):
                assert abs(actual[0] - original[0] - delay) <= 96, (source, target, "Opening sound moved", original, actual)
                closing_shift = actual[1] - original[1] - delay
                # MP2 re-encoding can ring 144 samples past WMA's decoded threshold. Keep the early-cut bound strict.
                assert -closing_tolerance <= closing_shift <= (192 if target == "mpeg" else closing_tolerance), \
                    (source, target, "Closing sound moved or was cut", original, actual)
            return output

        original = fixture("original.wav", 4, [(0.005, 0.025), (0.4, 0.6), (2.4, 2.6), (3.97, 3.99)])
        outputs = []
        for extension, (container, codec) in SOURCES.items():
            source = work / f"encoded.{extension}"
            convert(original, source)
            expected = decoded(source, codec, container)
            assert len(expected[1]) == 4, (source, "Source encoding lost a tone")
            for target in TARGETS:
                outputs.append(check(source, expected, target, f"{extension}-to-{target}"))
            print(f"{extension}: six audio-only outputs passed.", flush=True)

        short = fixture("short.wav", 0.02, [(0, 0.02)])
        expected = decoded(short, "pcm_s16le")
        assert len(expected[1]) == 1
        for target in TARGETS:
            check(short, expected, target, "short")

        boundary_checks = 0
        for boundary, targets in [(1152, ("mpeg",)), (1536, ("ac3", "eac3", "m2ts", "vob"))]:
            for frames in (boundary - 1, boundary, boundary + 1):
                seconds = frames / RATE
                source = fixture(f"ending-{frames}.wav", seconds, [(0, seconds)])
                expected = decoded(source, "pcm_s16le", "wav")
                assert expected[0] == frames and len(expected[1]) == 1
                for target in targets:
                    check(source, expected, target, f"ending-{frames}")
                    boundary_checks += 1

        invalid = work / "invalid.wav"
        invalid.write_bytes(b"This is not an audio file.\n")
        for target, existing in zip(TARGETS, outputs[:6]):
            convert(original, existing, failure=True)
            convert(invalid, work / f"invalid.{target}", failure=True)
        print(f"Passed 102 audio-container pairs, six 20 ms cases, {boundary_checks} codec-frame endings, and 12 failure/cleanup checks.")


if __name__ == "__main__":
    main()
