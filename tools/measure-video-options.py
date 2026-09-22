#!/usr/bin/env python3
"""Compare packaged video conversion cost with an original 30-second 720p clip."""
import argparse
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


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before-app", type=Path)
    parser.add_argument("--after-app", type=Path, default=root / "dist/preview/Allomer.app")
    parser.add_argument("--report", type=Path, default=root / "research/video-options-performance.json")
    parser.add_argument("--with-audio", action="store_true")
    parser.add_argument("--container", choices=("mp4", "mxf"), default="mp4")
    parser.add_argument("--timing-only", action="store_true", help="Measure the timing helper with unequal track lengths.")
    args = parser.parse_args()
    if not args.timing_only and args.before_app is None:
        parser.error("--before-app is required for a whole-command comparison")
    before = args.before_app.resolve() if args.before_app else None
    after = args.after_app.resolve()
    if args.timing_only:
        args.with_audio = True
    helper = after / "Contents/Helpers"
    environment = {"PATH": "/usr/bin:/bin"}
    width, height, rate, seconds = 1280, 720, 24, 30
    with tempfile.TemporaryDirectory(prefix="video-cost-") as directory:
        work = Path(directory)

        def run(*arguments):
            result = subprocess.run(list(map(str, arguments)), env=environment, cwd=work,
                                    capture_output=True, timeout=180)
            assert result.returncode == 0 and not result.stderr.strip(), result.stderr.decode(errors="replace")
            return result.stdout

        def digest(path):
            with path.open("rb") as file:
                return hashlib.file_digest(file, "sha256").hexdigest()

        raw = work / "original.rgb"
        with raw.open("xb") as file:
            for n in range(rate):
                row = bytes(value for x in range(width) for value in (
                    (x * 3 + n * 11) % 256, (x * 7 + n * 5) % 256, (x ^ (n * 13)) % 256))
                for y in range(height):
                    offset = (y * 5 % width) * 3
                    file.write(row[offset:] + row[:offset])
        short, source = work / "one-second.mkv", work / "original.mkv"
        ffmpeg = [helper / "ffmpeg", "-nostdin", "-v", "error", "-xerror", "-n", "-threads", "1", "-filter_threads", "1"]
        run(*ffmpeg, "-f", "rawvideo", "-pixel_format", "rgb24", "-video_size", f"{width}x{height}",
            "-framerate", rate, "-i", raw, "-c:v", "ffv1", "-pix_fmt", "yuv420p", short)
        inputs = ["-stream_loop", seconds - 1, "-i", short]
        if args.with_audio:
            audio = work / "original.wav"
            with wave.open(str(audio), "wb") as file:
                file.setparams((2, 2, 48000, 0, "NONE", "not compressed"))
                file.writeframes(b"".join(struct.pack("<hh", v, v) for i in range(48000 * (4 if args.timing_only else seconds))
                    for v in [round(9000 * math.sin(math.tau * 440 * i / 48000))]))
            inputs += ["-i", audio, "-map", "0:v:0", "-map", "1:a:0"]
        # Reset repeated packet times so the short Matroska clock does not accumulate rounding error.
        run(*ffmpeg, *inputs, "-c", "copy", "-bsf:v", f"setts=pts=N/({rate}*TB):dts=N/({rate}*TB)", source)
        source_hash = digest(source)
        if args.timing_only:
            cases, expected = [], None
            for name, threads, queue in [("default-queue-one-thread", 1, 10000000),
                                         ("short-queue-one-thread", 1, 1), ("short-queue-two-threads", 2, 1)]:
                samples = []
                for _ in range(3):
                    assert digest(source) == source_hash
                    result = subprocess.run(["/usr/bin/time", "-l", helper / "ffmpeg", "-hide_banner", "-v", "error",
                        "-nostdin", "-xerror", "-max_alloc", "268435456", "-threads", str(threads),
                        "-filter_threads", "1", "-err_detect", "explode", "-max_pixels", "32200000",
                        "-protocol_whitelist", "file,pipe", "-i", source, "-map", "0:v:0", "-c:v", "wrapped_avframe",
                        "-threads:v", "1", "-fps_mode:v", "passthrough", "-enc_time_base:v", "filter",
                        "-map", "0:a:0", "-c:a", "pcm_s16le", "-threads:a", "1",
                        "-max_interleave_delta", str(queue), "-f", "framecrc", "pipe:1"],
                        cwd=work, env=environment, capture_output=True, text=True, timeout=180)
                    assert result.returncode == 0, result.stderr
                    # Picture checksums include pointers. Compare picture timing and actual PCM checksums.
                    lines = result.stdout.splitlines()
                    records = {i: [",".join(line.split(",")[:5 if i == 0 else 6]) for line in lines
                                   if line.startswith(str(i) + ",")] for i in (0, 1)}
                    clocks = [line for line in lines if line.startswith("#tb ")]
                    assert len(records[0]) == rate * seconds and records[1]
                    if expected is None:
                        expected = (records, clocks)
                    assert (records, clocks) == expected
                    assert sum(int(row.split(",")[3]) for row in records[1]) == 48000 * 4
                    samples.append({"seconds": float(re.search(r"([\d.]+)\s+real", result.stderr)[1]),
                        "resident_bytes": int(re.search(r"(\d+)\s+maximum resident set size", result.stderr)[1])})
                record = {"case": name, "decoder_threads": threads, "queue_microseconds": queue, "runs": samples,
                    "median_seconds": statistics.median(s["seconds"] for s in samples),
                    "median_resident_bytes": statistics.median(s["resident_bytes"] for s in samples)}
                cases.append(record)
                print(name, record, flush=True)
            report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                "chip": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
                "helper_sha256": digest(helper / "ffmpeg"), "source_sha256": source_hash,
                "source_bytes": source.stat().st_size, "cases": cases,
                "scope": "Three isolated FFmpeg timing decodes per setting. Original 30-second 1280x720 FFV1 video at 24 fps with four seconds of stereo 48 kHz PCM. All picture timing/size records, audio timing/checksums, and decoded sample counts match. Source hashing warms the cache. Fixture generation and external checks are excluded. RSS is the helper process high-water reading, not the command process or aggregate app/helper memory. This is not a general performance or memory guarantee."}
            args.report.write_text(json.dumps(report, indent=2) + "\n")
            return
        cases = []
        configurations = [("before-bitrate", before, "bitrate"), ("after-bitrate", after, "bitrate"),
                          ("after-quality100", after, "quality")]
        for name, app, mode in configurations:
            command = app / "Contents/MacOS/allomer"
            settings = work / f"{name}.json"
            options = {"videoMode": mode, "videoBitrateKbps": 2500, "videoQuality": 100, "cpuProfile": "medium"}
            settings.write_text(json.dumps(options))
            samples = []
            for index in range(3):
                output = work / f"{name}-{index}.{args.container}"
                assert digest(source) == source_hash
                result = subprocess.run(["/usr/bin/time", "-l", command, "convert", source, output,
                    "--media-options", settings], cwd=work, env=environment, capture_output=True,
                    text=True, timeout=180)
                assert result.returncode == 0, result.stderr
                timing = {"seconds": float(re.search(r"([\d.]+)\s+real", result.stderr)[1]),
                          "resident_bytes": int(re.search(r"(\d+)\s+maximum resident set size", result.stderr)[1]),
                          "output_bytes": output.stat().st_size}
                assert digest(source) == source_hash and not list(work.glob(".allomer-*"))
                info = json.loads(run(helper / "ffprobe", "-v", "error", "-threads", "1", "-select_streams", "V:0",
                    "-count_frames", "-show_entries", "stream=codec_name,width,height,nb_read_frames:format=duration",
                    "-of", "json", output))
                assert len(info["streams"]) == 1
                video = info["streams"][0]
                assert video["codec_name"] == ("h264" if args.container == "mp4" else "mpeg2video")
                assert (video["width"], video["height"]) == (width, height)
                assert int(video["nb_read_frames"]) == rate * seconds
                assert abs(float(info["format"]["duration"]) - seconds) < 0.05
                if args.with_audio:
                    pcm = run(*ffmpeg, "-i", output, "-map", "0:a:0", "-c:a", "pcm_s16le", "-f", "s16le", "-")
                    assert len(pcm) % 4 == 0 and abs(len(pcm) // 4 - 48000 * seconds) <= 4096 and any(pcm)
                samples.append(timing)
                output.unlink()
            record = {"case": name, "options": options, "command_sha256": digest(command), "runs": samples,
                      "median_seconds": statistics.median(s["seconds"] for s in samples),
                      "median_resident_bytes": statistics.median(s["resident_bytes"] for s in samples)}
            cases.append(record)
            print(name, record, flush=True)
        report = {"recorded_at_utc": datetime.now(timezone.utc).isoformat(), "macos": platform.mac_ver()[0],
                  "chip": subprocess.check_output(["sysctl", "-n", "machdep.cpu.brand_string"], text=True).strip(),
                  "container": args.container,
                  "source": {"width": width, "height": height, "rate": rate, "seconds": seconds, "audio": args.with_audio,
                             "bytes": source.stat().st_size, "sha256": source_hash,
                             "timing": "Repeated video packets use frame-number timestamps rounded to the Matroska clock."}, "cases": cases,
                  "scope": "Three isolated whole-command runs per setting, in listed order. Original 720p/24 fps FFV1 input repeats a one-second synthetic pattern for 30 seconds. The audio field records whether stereo 48 kHz PCM input is included. Includes conversion, validation, and publication. Input hashes warm the file cache. Fixture creation and external output checks are excluded. RSS is a per-process high-water reading, not aggregate simultaneous app/helper/system-service memory. GUI excluded. This is not a general quality, speed, or memory guarantee."}
        args.report.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
