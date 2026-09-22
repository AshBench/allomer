#!/usr/bin/env python3
"""Check embedded text tracks, source preservation, timing, and bounded failures."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import tempfile
import wave


def cues(path):
    result = []
    for block in path.read_text(encoding="utf-8-sig").strip().split("\n\n"):
        lines = block.splitlines()
        match = re.fullmatch(r"(\d+):(\d\d):(\d\d),(\d{3}) --> (\d+):(\d\d):(\d\d),(\d{3})", lines[1])
        assert match, block
        values = list(map(int, match.groups()))
        times = [((values[i] * 60 + values[i + 1]) * 60 + values[i + 2]) * 1000 + values[i + 3] for i in (0, 4)]
        result.append((*times, "\n".join(lines[2:])))
    return result


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=root / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=root / ".tools/bin")
    parser.add_argument("--benchmark", action="store_true")
    args = parser.parse_args()
    command, tools = args.command.resolve(), args.tools.resolve()
    env = {"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools)}
    with tempfile.TemporaryDirectory(prefix="Embedded subtitles café 100% ") as directory:
        work = Path(directory)
        def run(*arguments, check=True):
            return subprocess.run(arguments, env=env, cwd=work, check=check, capture_output=True, text=True, timeout=130)
        def mux(source, target, muxer, video="mpeg4", subtitle="srt", second=None):
            inputs = ["-f", "image2", "-loop", "1", "-framerate", "25", "-i", image,
                      "-f", "srt", "-i", source, "-i", audio]
            if second: inputs += ["-f", "srt", "-i", second]
            mapping = ["-map", "0:v", "-map", "2:a", "-map", "1:s"]
            if second: mapping += ["-map", "3:s", "-disposition:s:0", "0", "-disposition:s:1", "default"]
            run(tools / "ffmpeg", "-nostdin", "-v", "error", "-n", "-threads", "1", *inputs, *mapping,
                "-c:v", video, "-threads:v", "1", "-pix_fmt", "yuv420p", "-c:a", "libopus" if muxer == "webm" else "aac",
                "-c:s", subtitle, "-metadata:s:s:0", "language=eng", "-t", "4", "-f", muxer, target)
        image = work / "original.ppm"
        image.write_bytes(b"P6\n32 24\n255\n" + bytes([100, 150, 210]) * (32 * 24))
        audio = work / "silence.wav"
        with wave.open(str(audio), "wb") as stream:
            stream.setparams((1, 2, 48000, 0, "NONE", "not compressed")); stream.writeframes(bytes(48000 * 2 * 4))
        first = work / "first.srt"
        first.write_text("1\n00:00:00,125 --> 00:00:01,865\nCafé 世界 👋\nSecond line\n\n"
                         "2\n00:00:01,500 --> 00:00:03,235\nOverlap & punctuation.\n")
        second = work / "second.srt"
        second.write_text("1\n00:00:00,500 --> 00:00:02,250\nThe other track.\n")
        expected = cues(first)
        options = work / "options.json"
        checked = []
        for name, muxer, video, subtitle in [
            ("mp4", "mp4", "mpeg4", "mov_text"), ("mov", "mov", "mpeg4", "mov_text"),
            ("3gp", "3gp", "mpeg4", "mov_text"), ("mkv", "matroska", "mpeg4", "srt"),
            ("ass.mkv", "matroska", "mpeg4", "ass"), ("webm", "webm", "libvpx-vp9", "webvtt")]:
            movie = work / ("movie." + name)
            mux(first, movie, muxer, video, subtitle, second)
            before = hashlib.sha256(movie.read_bytes()).hexdigest()
            embedded = expected
            if subtitle == "mov_text":
                # MOV text samples cannot overlap. Check the actual encoded track,
                # including the shortened first sample produced by the fixture muxer.
                packets = json.loads(run(tools / "ffprobe", "-v", "error", "-select_streams", "s:0",
                    "-show_packets", "-show_data", "-show_entries", "packet=pts_time,duration_time,data", "-of", "json", movie).stdout)["packets"]
                embedded = []
                for packet in packets:
                    raw = bytes.fromhex("".join(line.partition(": ")[2].split("  ")[0]
                        for line in packet["data"].strip().splitlines()))
                    length = int.from_bytes(raw[:2], "big")
                    if not length: continue
                    text = raw[2:2 + length].decode("utf-8")
                    start = round(float(packet["pts_time"]) * 1000)
                    embedded.append((start, start + round(float(packet["duration_time"]) * 1000), text))
                assert [item[2] for item in embedded] == [item[2] for item in expected]
            for extension in ("srt", "vtt", "ass", "ssa", "sbv", "sub"):
                output = work / f"result-{name}.{extension}"
                run(command, "convert", movie, output)
                readback = output if extension == "srt" else work / f"readback-{name}-{extension}.srt"
                if readback != output: run(command, "convert", output, readback)
                actual = cues(readback)
                assert len(actual) == len(embedded)
                tolerance = 41 if extension == "sub" else 10
                for old, new in zip(embedded, actual):
                    assert old[2] == new[2] and abs(old[0] - new[0]) <= tolerance and abs(old[1] - new[1]) <= tolerance, (name, extension, old, new)
                assert hashlib.sha256(movie.read_bytes()).hexdigest() == before
                checked.append([name, extension])
            options.write_text('{"embeddedTrack":2}')
            selected = work / f"selected-{name}.srt"
            run(command, "convert", movie, selected, "--subtitle-options", options)
            assert cues(selected) == cues(second)
            for invalid in (0, -1, 3, 257):
                options.write_text(json.dumps({"embeddedTrack": invalid}))
                target = work / f"missing-{name}-{invalid}.srt"
                assert run(command, "convert", movie, target, "--subtitle-options", options, check=False).returncode != 0
                assert not target.exists()
            assert run(command, "convert", movie, selected, check=False).returncode != 0
            assert cues(selected) == cues(second)
            assert hashlib.sha256(movie.read_bytes()).hexdigest() == before
            assert not list(work.glob(".allomer-*"))
            for percentage in (50, 90):
                damaged = work / f"damaged-{name}-{percentage}.{movie.suffix.lstrip('.')}"
                original = movie.read_bytes(); damaged.write_bytes(original[:len(original) * percentage // 100])
                target = work / f"damaged-{name}-{percentage}.srt"
                assert run(command, "convert", damaged, target, check=False).returncode != 0, (name, percentage)
                assert not target.exists() and damaged.read_bytes() == original[:len(original) * percentage // 100]
        empty = work / "no-subtitles.mkv"
        run(tools / "ffmpeg", "-nostdin", "-v", "error", "-n", "-i", movie, "-map", "0:v", "-c", "copy", "-f", "matroska", empty)
        target = work / "empty.srt"
        failure = run(command, "convert", empty, target, check=False)
        assert failure.returncode != 0 and "no embedded subtitle tracks" in failure.stderr and not target.exists()
        linked = work / "linked.mkv"; linked.symlink_to(empty)
        assert run(command, "convert", linked, target, check=False).returncode != 0 and not target.exists()
        oversized = work / "oversized.srt"
        with oversized.open("wb") as stream: stream.truncate(16 * 1024 * 1024 + 1)
        assert run(command, "convert", oversized, work / "oversized.vtt", check=False).returncode != 0
        assert not (work / "oversized.vtt").exists() and not list(work.glob(".allomer-*"))
        print(f"Passed {len(checked)} embedded text-track routes, selection, timing, source preservation, refusals, and cleanup.", flush=True)
        if args.benchmark:
            def timestamp(value): return f"{value // 3600000:02}:{value // 60000 % 60:02}:{value // 1000 % 60:02},{value % 1000:03}"
            first.write_text("\n".join(f"{i + 1}\n{timestamp(i * 300)} --> {timestamp(i * 300 + 250)}\nOriginal cue {i:05d}, café 世界.\n" for i in range(10_000)))
            benchmark = work / "benchmark.mkv"
            # The original video/audio streams are short; the subtitle timeline lasts 50 minutes.
            run(tools / "ffmpeg", "-nostdin", "-v", "error", "-n", "-i", empty, "-f", "srt", "-i", first,
                "-map", "0:v", "-map", "1:s", "-c", "copy", "-f", "matroska", benchmark)
            samples = []
            for index in range(3):
                before = hashlib.sha256(benchmark.read_bytes()).hexdigest()
                result = work / f"benchmark-{index}.srt"
                measured = run("/usr/bin/time", "-l", command, "convert", benchmark, result)
                assert cues(result) == cues(first) and hashlib.sha256(benchmark.read_bytes()).hexdigest() == before
                samples.append({"seconds": float(re.search(r"([\d.]+)\s+real", measured.stderr)[1]),
                    "resident_bytes": int(re.search(r"(\d+)\s+maximum resident set size", measured.stderr)[1]), "output_bytes": result.stat().st_size})
            report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                "command_sha256": hashlib.sha256(command.read_bytes()).hexdigest(), "input_sha256": before,
                "helper_sha256": {name: hashlib.sha256((tools / name).read_bytes()).hexdigest() for name in ("ffmpeg", "ffprobe")},
                "input_bytes": benchmark.stat().st_size, "cues": 10_000, "runs": samples,
                "median_seconds": statistics.median(s["seconds"] for s in samples),
                "median_resident_bytes": statistics.median(s["resident_bytes"] for s in samples),
                "scope": "Three complete Matroska-to-SRT conversions. A short VP9 video and a 50-minute original text track share the container. Includes track probing, extraction, cue validation, and publication. Source hashing warms the cache. Python comparisons and GUI memory are excluded. RSS is per-process high-water, not aggregate simultaneous memory."}
            retained = root / ".tools" / f"subtitle-extraction-benchmark-{before[:12]}.mkv"
            retained.parent.mkdir(exist_ok=True)
            shutil.copy2(benchmark, retained)
            report["input_fixture"] = str(retained.relative_to(root))
            (root / "research/subtitle-extraction-performance.json").write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps(report, indent=2), flush=True)


if __name__ == "__main__": main()
