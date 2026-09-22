#!/usr/bin/env python3
"""Check original bitmap subtitle conversion, timing, selection, failures, and cleanup."""
import argparse
import ctypes
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import re
import shutil
import statistics
import subprocess
import tempfile

from PIL import Image


def cues(path):
    result = []
    for block in path.read_text(encoding="utf-8-sig").strip().split("\n\n"):
        lines = block.splitlines()
        assert len(lines) >= 3 and lines[0].isdigit(), block
        match = re.fullmatch(r"(\d+):(\d\d):(\d\d),(\d{3}) --> (\d+):(\d\d):(\d\d),(\d{3})", lines[1])
        assert match, block
        values = list(map(int, match.groups()))
        assert all(values[index] < 60 for index in (1, 2, 5, 6)), values
        times = [((values[i] * 60 + values[i + 1]) * 60 + values[i + 2]) * 1000 + values[i + 3]
                 for i in (0, 4)]
        assert times[1] > times[0], times
        result.append((*times, "\n".join(lines[2:])))
    assert result
    return result


def compare(actual, expected, tolerance=0):
    assert len(actual) == len(expected), (actual, expected)
    for old, new in zip(expected, actual):
        assert old[2] == new[2] and abs(old[0] - new[0]) <= tolerance and abs(old[1] - new[1]) <= tolerance, (old, new)


def check_cropped_pixels(library, source, generator):
    decoder = ctypes.CDLL(str(library.resolve()))
    callback_type = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_int64, ctypes.c_int64,
                                     ctypes.POINTER(ctypes.c_uint8), ctypes.c_int, ctypes.c_int)
    decode = decoder.decode_bitmap_subtitles
    decode.argtypes = [ctypes.c_char_p, ctypes.c_int, callback_type, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t]
    decode.restype = ctypes.c_int
    _, expected = generator.fixture(cropped=True)
    times = sorted(expected)
    failures, seen = [], []
    @callback_type
    def receive(_, start, end, pixels, width, height):
        try:
            time = times[len(seen)]
            assert start == time - times[0] and end == -1
            seen.append(time)
            if not pixels:
                assert time in [cue[1] for cue in generator.CUES] and width == height == 0
                return 0
            rectangles = next(items for begin, _, items in generator.CUES if begin == time)
            bounds = [(x, y, x + generator.caption(text).width, y + generator.caption(text).height)
                      for x, y, text in rectangles]
            crop = expected[time].crop((min(b[0] for b in bounds), min(b[1] for b in bounds),
                                       max(b[2] for b in bounds), max(b[3] for b in bounds)))
            assert crop.size == (width, height), (crop.size, width, height)
            actual = ctypes.string_at(pixels, width * height * 4)
            background = tuple(actual[:4])
            assert background in [(0, 0, 0, 255), (255, 255, 255, 255)]
            composed = Image.alpha_composite(Image.new("RGBA", crop.size, background), crop)
            assert composed.tobytes() == actual, "Cropped pixels or relative placement changed."
            return 0
        except BaseException as error:
            failures.append(str(error))
            return 1
    error = ctypes.create_string_buffer(1024)
    status = decode(str(source).encode(), 1, receive, None, error, len(error))
    assert status == 0 and not failures and seen == times, (status, error.value, failures, seen)


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=root / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=root / ".tools/bin")
    parser.add_argument("--benchmark", action="store_true")
    parser.add_argument("--benchmark-input", type=Path, help="Reuse a retained 200-cue benchmark for a byte-matched comparison.")
    parser.add_argument("--decoder-probe", type=Path, help="Development C bridge library for an independent cropped-pixel check.")
    args = parser.parse_args()
    if args.benchmark_input and not args.benchmark:
        parser.error("--benchmark-input requires --benchmark")
    command, tools = args.command.resolve(), args.tools.resolve()
    spec = importlib.util.spec_from_file_location("original_pgs", root / "tools/make-bitmap-subtitle-fixture.py")
    generator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generator)
    original, _ = generator.fixture()
    expected = [(start, end, "\n".join(text for _, _, text in rectangles))
                for start, end, rectangles in generator.CUES]
    env = {"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools)}
    with tempfile.TemporaryDirectory(prefix="Bitmap subtitles café 100% ") as directory:
        work = Path(directory)
        def run(*arguments):
            result = subprocess.run(arguments, env=env, cwd=work, capture_output=True, text=True, timeout=130)
            assert result.returncode == 0, (arguments, result.stderr)
            return result.stdout
        def convert(source, target, track=None, failure=None, collision=False):
            before = source.read_bytes()
            saved = target.read_bytes() if collision else None
            arguments = [command, "convert", source, target]
            if track is not None:
                options.write_text(json.dumps({"embeddedTrack": track}), encoding="utf-8")
                arguments += ["--subtitle-options", options]
            result = subprocess.run(arguments, env=env, cwd=work, capture_output=True, text=True, timeout=130)
            if failure is not None or collision:
                assert result.returncode != 0, (arguments, result.stdout)
                if failure:
                    assert failure in result.stderr, result.stderr
                assert target.read_bytes() == saved if collision else not target.exists()
            else:
                assert result.returncode == 0 and target.is_file(), (arguments, result.stderr)
            assert source.read_bytes() == before, source
            assert not list(work.rglob(".allomer-*")), list(work.iterdir())
        def mux(pgs, target, alternate=None, duration=6):
            inputs = ["-i", pgs]
            if alternate is not None:
                inputs += ["-f", "srt", "-i", alternate]
            mapping = ["-map", "[video]"]
            if alternate is not None:
                mapping += ["-map", "1:s:0"]
            mapping += ["-map", "0:s:0"]
            run(tools / "ffmpeg", "-nostdin", "-v", "error", "-xerror", "-n", "-threads", "1", "-copyts",
                *inputs, "-filter_complex", "color=c=black:s=640x360:r=1:d=6[video]", *mapping,
                "-c:v", "ffv1", "-threads:v", "1", "-pix_fmt", "yuv420p", "-c:s", "copy",
                "-disposition:s:0", "0", f"-disposition:s:{1 if alternate is not None else 0}", "default",
                "-t", str(duration), "-f", "matroska", target)

        options = work / "options.json"
        pgs = work / "original.sup"
        pgs.write_bytes(original)
        alternate = work / "other.srt"
        alternate.write_text("1\n00:00:00,500 --> 00:00:01,500\nThe other text track.\n", encoding="utf-8")
        movie = work / "original.mkv"
        mux(pgs, movie, alternate)
        info = json.loads(run(tools / "ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", movie))
        assert info["format"]["start_time"] == "0.000000", info
        assert [stream["codec_name"] for stream in info["streams"] if stream["codec_type"] == "subtitle"] == ["subrip", "hdmv_pgs_subtitle"], info
        formats = {"srt": "srt", "vtt": "webvtt", "ass": "ass", "ssa": "ass", "sbv": "subviewer", "sub": "microdvd"}
        for extension, demuxer in formats.items():
            output = work / f"result.{extension}"
            convert(movie, output, track=2)
            readback = output
            if extension != "srt":
                readback = work / f"readback-{extension}.srt"
                run(tools / "ffmpeg", "-nostdin", "-v", "error", "-xerror", "-n", "-f", demuxer,
                    "-i", output, "-map", "0:s:0", "-c:s", "srt", "-f", "srt", readback)
            compare(cues(readback), expected, 41 if extension == "sub" else 10)
        dvd = work / "dvd.mkv"
        dvb = work / "dvb.ts"
        xsub = work / "xsub.avi"
        for target, codec, video, muxer in [(dvd, "dvdsub", "copy", "matroska"), (dvb, "dvbsub", "mpeg2video", "mpegts")]:
            run(tools / "ffmpeg", "-nostdin", "-v", "error", "-xerror", "-n", "-copyts", "-start_at_zero",
                "-fix_sub_duration", "-i", movie, "-map", "0:v:0", "-map", "0:s:1", "-c:v", video,
                "-r:v", "25", "-threads:v", "1", "-c:s", codec, "-f", muxer, target)
        # The DVD encoder merges rectangles. XSUB accepts only one rectangle per cue.
        run(tools / "ffmpeg", "-nostdin", "-v", "error", "-xerror", "-n", "-copyts", "-start_at_zero",
            "-i", dvd, "-map", "0:v:0", "-map", "0:s:0", "-c:v", "copy", "-c:s", "xsub", "-f", "avi", xsub)
        for source in (dvd, dvb, xsub):
            # The pinned DVD encoder quantizes end offsets before the app reads this file.
            encoded = expected if source == dvb else [(1000, 1989, expected[0][2]), (3250, 5491, expected[1][2])]
            for extension, demuxer in formats.items():
                output = work / f"{source.stem}-result.{extension}"
                convert(source, output)
                readback = output
                if extension != "srt":
                    readback = work / f"{source.stem}-readback-{extension}.srt"
                    run(tools / "ffmpeg", "-nostdin", "-v", "error", "-xerror", "-n", "-f", demuxer,
                        "-i", output, "-map", "0:s:0", "-c:s", "srt", "-f", "srt", readback)
                compare(cues(readback), encoded, 41 if extension == "sub" else 10)
        for variant in ("dark", "cropped", "dark-cropped"):
            pgs_variant = work / f"{variant}.sup"
            pgs_variant.write_bytes(generator.fixture(dark_text="dark" in variant, cropped="cropped" in variant)[0])
            movie_variant = work / f"{variant}.mkv"
            mux(pgs_variant, movie_variant)
            for extension, demuxer in formats.items():
                output = work / f"{variant}-result.{extension}"
                convert(movie_variant, output)
                readback = output
                if extension != "srt":
                    readback = work / f"{variant}-readback-{extension}.srt"
                    run(tools / "ffmpeg", "-nostdin", "-v", "error", "-xerror", "-n", "-f", demuxer,
                        "-i", output, "-map", "0:s:0", "-c:s", "srt", "-f", "srt", readback)
                compare(cues(readback), expected, 41 if extension == "sub" else 10)
            if variant == "cropped":
                if args.decoder_probe:
                    check_cropped_pixels(args.decoder_probe, pgs_variant, generator)
                for field, value in [(19, 65535), (23, 0)]:
                    damaged = bytearray(pgs_variant.read_bytes())
                    assert damaged[10] == 0x16
                    damaged[13 + field:15 + field] = value.to_bytes(2, "big")
                    bad_crop = work / f"bad-crop-{field}.sup"
                    bad_crop.write_bytes(damaged)
                    bad_movie = work / f"bad-crop-{field}.mkv"
                    mux(bad_crop, bad_movie)
                    convert(bad_movie, work / f"bad-crop-{field}.srt", failure="")
        for track in (None, 1):
            output = work / f"text-{track}.srt"
            convert(movie, output, track=track)
            compare(cues(output), cues(alternate))
        offset = work / "offset.mkv"
        run(tools / "ffmpeg", "-nostdin", "-v", "error", "-xerror", "-n", "-copyts", "-i", movie,
            "-map", "0", "-c", "copy", "-output_ts_offset", "5", "-f", "matroska", offset)
        assert json.loads(run(tools / "ffprobe", "-v", "error", "-show_format", "-of", "json", offset))["format"]["start_time"] == "5.000000"
        output = work / "offset.srt"
        convert(offset, output, track=2)
        compare(cues(output), expected)
        convert(movie, work / "result.srt", track=2, collision=True)
        for track in (0, -1, 3, 257):
            convert(movie, work / f"missing-{track}.srt", track=track, failure="")
        empty = work / "no-subtitles.mkv"
        run(tools / "ffmpeg", "-nostdin", "-v", "error", "-n", "-i", movie, "-map", "0:v", "-c", "copy", empty)
        convert(empty, work / "empty.srt", failure="no embedded subtitle tracks")
        damaged = work / "truncated.mkv"
        damaged.write_bytes(movie.read_bytes()[:len(movie.read_bytes()) // 2])
        convert(damaged, work / "truncated.srt", track=2, failure="")

        packets, position = [], 0
        while position < len(original):
            assert original[position:position + 2] == b"PG" and position + 13 <= len(original)
            end = position + 13 + int.from_bytes(original[position + 11:position + 13], "big")
            assert end <= len(original)
            packets.append(original[position:end])
            position = end
        open_ended = work / "no-final-clear.sup"
        last_end = generator.CUES[-1][1] * 90
        open_ended.write_bytes(b"".join(packet for packet in packets if int.from_bytes(packet[2:6], "big") < last_end))
        open_movie = work / "no-final-clear.mkv"
        mux(open_ended, open_movie)
        convert(open_movie, work / "unknown-end.srt", failure="no known end time")
        saved_caption = generator.caption
        try:
            generator.caption = lambda text: Image.new("L", (64, 32), 2)
            unreadable = work / "unreadable.sup"
            unreadable.write_bytes(generator.fixture()[0])
        finally:
            generator.caption = saved_caption
        unreadable_movie = work / "unreadable.mkv"
        mux(unreadable, unreadable_movie)
        convert(unreadable_movie, work / "unreadable.srt", failure="no readable text")
        assert pgs.read_bytes() == original and not list(work.rglob(".allomer-*"))
        if args.benchmark:
            # The subtitle track spans ten minutes. The original video has only six black frames.
            generator.CUES = [(i * 3000 + 1000, i * 3000 + 2000, [(100, 275, "Amber kite")]) for i in range(200)]
            benchmark_pgs = work / "benchmark.sup"
            benchmark_pgs.write_bytes(generator.fixture()[0])
            benchmark = work / "benchmark.mkv"
            if args.benchmark_input:
                shutil.copy2(args.benchmark_input.resolve(), benchmark)
            else:
                mux(benchmark_pgs, benchmark, duration=600)
            expected = [(start, end, items[0][2]) for start, end, items in generator.CUES]
            samples = []
            for index in range(3):
                before = hashlib.sha256(benchmark.read_bytes()).hexdigest()
                output = work / f"benchmark-{index}.srt"
                measured = subprocess.run(["/usr/bin/time", "-l", command, "convert", benchmark, output],
                    env=env, cwd=work, check=True, capture_output=True, text=True, timeout=130)
                compare(cues(output), expected)
                assert hashlib.sha256(benchmark.read_bytes()).hexdigest() == before
                samples.append({"seconds": float(re.search(r"([\d.]+)\s+real", measured.stderr)[1]),
                    "resident_bytes": int(re.search(r"(\d+)\s+maximum resident set size", measured.stderr)[1]),
                    "output_bytes": output.stat().st_size})
            retained = root / ".tools" / f"bitmap-subtitle-benchmark-{before[:12]}.mkv"
            shutil.copy2(benchmark, retained)
            report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                "command_sha256": hashlib.sha256(command.read_bytes()).hexdigest(), "input_sha256": before,
                "input_bytes": benchmark.stat().st_size, "input_fixture": str(retained.relative_to(root)),
                "helper_sha256": {name: hashlib.sha256((tools / name).read_bytes()).hexdigest()
                    for name in ("nativeconvert", "nativeguard", "ffmpeg", "ffprobe")},
                "cues": 200, "runs": samples, "median_seconds": statistics.median(s["seconds"] for s in samples),
                "median_resident_bytes": statistics.median(s["resident_bytes"] for s in samples),
                "scope": "Three complete PGS-in-Matroska to SRT conversions. Includes probing, bitmap decoding, Vision recognition, cue validation and publication. Original repeated text spans ten minutes; the video has six black frames. Source hashes warm the file cache. GUI and Python work are excluded. RSS is per-process peak, not aggregate app/helper/service memory."}
            (root / "research/bitmap-subtitle-performance.json").write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps(report, indent=2), flush=True)
    assert not work.exists()
    print("Passed 24 bitmap codec/output pairs, 18 dark-text/cropped outputs, crop bounds, selected tracks, offsets, clear gap, two rectangles, source bytes, collisions, "
          "invalid and missing tracks, truncation, unknown end, unreadable pictures, and cleanup.")


if __name__ == "__main__":
    main()
