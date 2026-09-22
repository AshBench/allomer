#!/usr/bin/env python3
"""Check video controls with original, bounded video and alpha ramps."""
import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile


def main():
    root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", type=Path, default=root / ".build/debug/allomer")
    parser.add_argument("--tools", type=Path, default=root / ".tools/bin")
    args = parser.parse_args()
    command, tools = args.command.resolve(), args.tools.resolve()
    environment = {"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(tools), "SVT_LOG": "1"}
    width, height, count = 128, 72, 24
    checks = 0
    with tempfile.TemporaryDirectory(prefix="Video controls café 100% ") as directory:
        work = Path(directory)

        def run(*arguments):
            result = subprocess.run(list(map(str, arguments)), env=environment, cwd=work,
                                    capture_output=True, timeout=180)
            assert result.returncode == 0 and not result.stderr.strip(), (arguments, result.stderr.decode(errors="replace"))
            return result.stdout

        def ffmpeg(*arguments):
            return run(tools / "ffmpeg", "-nostdin", "-v", "error", "-xerror", "-n",
                       "-threads", "1", "-filter_threads", "1", *arguments)

        def probe(path):
            data = json.loads(run(tools / "ffprobe", "-v", "error", "-threads", "1", "-select_streams", "V:0",
                                  "-show_streams", "-show_frames", "-show_format", "-of", "json", path))
            assert len(data["streams"]) == 1 and data["frames"], path
            return data

        def pixels(path, pixel="rgb24"):
            return ffmpeg("-i", path, "-map", "0:V:0", "-an", "-pix_fmt", pixel,
                          "-fps_mode", "passthrough", "-threads:v", "1", "-f", "rawvideo", "-")

        def convert(source, extension, options=None, failure=False):
            nonlocal checks
            checks += 1
            output = work / f"result-{checks}.{extension}"
            settings = work / f"options-{checks}.json"
            settings.write_text(json.dumps(options or {}))
            digest = hashlib.sha256(source.read_bytes()).digest()
            arguments = [command, "convert", source, output, "--media-options", settings]
            if failure:
                result = subprocess.run(arguments, env=environment, cwd=work, capture_output=True, timeout=180)
                assert result.returncode != 0 and not output.exists(), (arguments, result.stdout, result.stderr)
            else:
                run(*arguments)
            assert hashlib.sha256(source.read_bytes()).digest() == digest
            assert not list(work.rglob(".allomer-*"))
            return output

        def timeline(data):
            times = [Fraction(frame["best_effort_timestamp_time"]) for frame in data["frames"]]
            return [t - times[0] for t in times]

        raw = work / "original.rgba"
        raw.write_bytes(bytes(value for n in range(count) for y in range(height) for x in range(width)
                             for value in ((x * 7 + n * 11) % 256, (y * 9 + n * 3) % 256,
                                           ((x ^ y) * 13 + n * 7) % 256, x * 255 // (width - 1))))
        alpha = work / "alpha.mkv"
        ffmpeg("-f", "rawvideo", "-pixel_format", "rgba", "-video_size", f"{width}x{height}",
               "-framerate", "24", "-i", raw, "-c:v", "ffv1", "-pix_fmt", "bgra", alpha)
        source = work / "original.mkv"
        ffmpeg("-i", alpha, "-c:v", "ffv1", "-pix_fmt", "yuv420p", source)
        original = pixels(source)
        expected = timeline(probe(source))
        codecs = {"h264": ("mp4", "h264"), "hevc": ("mp4", "hevc"),
                  "vp9": ("webm", "vp9"), "av1": ("mkv", "av1")}
        for codec, (extension, name) in codecs.items():
            errors, sizes = [], []
            for quality in (0, 100):
                output = convert(source, extension, {"videoCodec": codec, "videoQuality": quality})
                info = probe(output)
                assert info["streams"][0]["codec_name"] == name
                assert len(info["frames"]) == count
                assert all(abs(a - b) <= Fraction(1, 1000) for a, b in zip(timeline(info), expected))
                decoded = pixels(output)
                assert len(decoded) == len(original)
                errors.append(sum(abs(a - b) for a, b in zip(original, decoded)))
                sizes.append(output.stat().st_size)
            assert errors[1] < errors[0] and sizes[1] > sizes[0], (codec, errors, sizes)
            output = convert(source, extension, {"videoCodec": codec, "videoMode": "bitrate", "videoBitrateKbps": 300})
            assert probe(output)["streams"][0]["codec_name"] == name
            print(f"Passed {codec} quality endpoints and bitrate.", flush=True)

        for extension, choices in {
            "mp4": ["vp9", "av1"], "mov": ["h264", "hevc"],
            "mkv": ["h264", "hevc", "vp9", "prores", "ffv1", "mpeg2video", "msmpeg4"], "webm": ["av1"],
            "3gp": ["h264"], "m2ts": ["h264", "mpeg2video"], "flv": ["h264"], "ts": ["h264", "mpeg2video"],
            "avi": ["mpeg2video", "msmpeg4"], "mxf": ["mpeg2video"], "mpeg": ["mpeg2video"],
            "vob": ["mpeg2video"], "wmv": ["msmpeg4"]
        }.items():
            for codec in choices:
                output = convert(source, extension, {"videoCodec": codec})
                # The encoder is named msmpeg4; the decoder reports the bitstream as msmpeg4v3.
                expected = {"msmpeg4": "msmpeg4v3"}.get(codec, codec)
                assert probe(output)["streams"][0]["codec_name"] == expected, (extension, codec)

        for profile, name in enumerate(("Proxy", "LT", "Standard", "HQ", "4444", "XQ")):
            output = convert(alpha, "mov", {"videoCodec": "prores", "proResProfile": profile})
            info = probe(output)
            assert info["streams"][0]["profile"] in (str(profile), name), info["streams"]
            assert info["streams"][0]["codec_tag_string"] == ("apco", "apcs", "apcn", "apch", "ap4h", "ap4x")[profile]
            assert len(info["frames"]) == count
            if profile >= 4:
                decoded = pixels(output, "rgba")
                assert len(decoded) == raw.stat().st_size
                assert max(abs(a - b) for a, b in zip(raw.read_bytes()[3::4], decoded[3::4])) <= 1
        print("Passed codec/container choices and six ProRes profiles, including alpha.", flush=True)

        for depth in (10, 12):
            pixel = f"yuv420p{depth}le"
            high_raw, high = work / f"depth-{depth}.yuv", work / f"depth-{depth}.mkv"
            high_raw.write_bytes(b"".join(struct.pack("<H", (i * 13 + n * 7) % (1 << depth))
                for n in range(8) for i in range(width * height * 3 // 2)))
            ffmpeg("-f", "rawvideo", "-pixel_format", pixel, "-video_size", f"{width}x{height}",
                   "-framerate", "24", "-i", high_raw, "-c:v", "ffv1", high)
            for codec, extension in (("vp9", "webm"), ("hevc", "mp4"), ("av1", "mkv"), ("ffv1", "mkv")):
                output = convert(high, extension, {"videoCodec": codec})
                expected_pixel = pixel if codec in ("vp9", "ffv1") else "yuv420p10le"
                assert probe(output)["streams"][0]["pix_fmt"] == expected_pixel
                decoded = pixels(output, expected_pixel)
                assert len(decoded) == high_raw.stat().st_size
                # VP9 at CRF zero and FFV1 retain the original 10/12-bit planes exactly.
                if codec in ("vp9", "ffv1"):
                    assert decoded == high_raw.read_bytes(), (depth, f"{codec} lost original pixel precision")
        print("Passed high-bit-depth output and exact VP9/FFV1 pixel comparisons.", flush=True)

        vfr = work / "variable.mkv"
        ffmpeg("-i", source, "-frames:v", "8", "-vf", r"settb=1/1000,setpts=N*100+mod(N\,3)*25",
               "-fps_mode", "passthrough", "-enc_time_base", "1/1000", "-c:v", "ffv1", vfr)
        vfr_times = timeline(probe(vfr))
        for codec, extension in (("h264", "mp4"), ("hevc", "mov"), ("vp9", "webm"),
                                 ("av1", "mkv"), ("prores", "mov"), ("automatic", "wmv")):
            output = convert(vfr, extension, {"videoCodec": codec})
            assert timeline(probe(output)) == vfr_times, (codec, "Changed VFR timestamps")
            if extension == "wmv":
                back = convert(output, "mp4")
                assert timeline(probe(back)) == vfr_times
        for rate in ("24000/1001", "24", "25", "30000/1001", "30", "50", "60000/1001", "60"):
            output = convert(vfr, "mp4", {"videoFrameRate": rate})
            times = timeline(probe(output))
            interval = 1 / Fraction(rate)
            assert all(abs(t - n * interval) <= Fraction(1, 1000000) for n, t in enumerate(times)), rate
            assert abs(len(times) * interval - Fraction(766, 1000)) <= interval, (rate, len(times))
        for codec, extension, key, speed in (("vp9", "webm", "vp9Speed", 0), ("vp9", "webm", "vp9Speed", 8),
                                            ("av1", "mkv", "av1Speed", 0), ("av1", "mkv", "av1Speed", 13)):
            assert len(probe(convert(vfr, extension, {"videoCodec": codec, key: speed}))["frames"]) == 8
        print("Passed variable timing, fixed frame rates, and encoder speed endpoints.", flush=True)

        gif = work / "animation.gif"
        ffmpeg("-i", alpha, "-frames:v", "3", "-vf", "fps=10", "-c:v", "gif", gif)
        for codec, extension in (("h264", "mp4"), ("hevc", "mov"), ("vp9", "webm"),
                                 ("av1", "mkv"), ("prores", "mov")):
            output = convert(gif, extension, {"videoCodec": codec, "proResProfile": 4})
            assert len(probe(output)["frames"]) == 3
            if codec == "prores":
                assert pixels(output, "rgba")[3::4] == pixels(gif, "rgba")[3::4]
        for rate in ("24000/1001", "24", "25", "30000/1001", "30", "50", "60000/1001", "60"):
            output = convert(gif, "ts", {"videoFrameRate": rate})
            times = timeline(probe(output))
            interval = 1 / Fraction(rate)
            assert all(abs(t - n * interval) <= Fraction(1, 90000) for n, t in enumerate(times)), rate
            assert abs(len(times) * interval - Fraction(3, 10)) <= interval
        short = work / "short.gif"
        ffmpeg("-i", source, "-frames:v", "1", "-c:v", "gif", "-final_delay", "1", short)
        assert len(probe(convert(short, "mp4", {"videoFrameRate": "24"}))["frames"]) == 1
        print("Passed GIF codec choices, alpha, fractional frame rates, and a 10 ms source.", flush=True)

        for extension, options in [
            ("mp4", {"videoCodec": "prores"}), ("mov", {"videoCodec": "vp9"}), ("mov", {"videoCodec": "av1"}),
            ("webm", {"videoCodec": "h264"}), ("wmv", {"videoCodec": "hevc"}),
            ("mp4", {"videoQuality": -1}), ("mp4", {"videoQuality": 101}),
            ("webm", {"vp9Speed": 9}), ("mkv", {"av1Speed": 14}), ("mov", {"proResProfile": 6}),
            ("mp4", {"videoFrameRate": "23"}), ("mkv", {"videoCodec": "av1", "videoMode": "bitrate", "videoBitrateKbps": 100001})
        ]:
            convert(source, extension, options, failure=True)
        print(f"Passed {checks} video control conversions/refusals. Source bytes and temporary cleanup checked.")


if __name__ == "__main__":
    main()
