#!/usr/bin/env python3
"""Check audio extraction, small timestamp gaps, and opening/closing sounds."""
from array import array
import argparse
from concurrent.futures import ThreadPoolExecutor
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
    formats = ("mp3", "aac", "m4a", "wav", "aiff", "flac", "alac", "ogg", "opus", "wma", "caf",
               "ac3", "eac3", "mka", "au", "tta", "wv")
    checks = 0
    with tempfile.TemporaryDirectory(prefix="Audio timing café ") as directory:
        work = Path(directory)

        def run(*arguments):
            result = subprocess.run(list(map(str, arguments)), env=environment, cwd=work,
                                    capture_output=True, timeout=120)
            assert result.returncode == 0 and not result.stderr.strip(), (arguments, result.stderr.decode(errors="replace"))
            return result.stdout

        def ffmpeg(*arguments):
            return run(tools / "ffmpeg", "-v", "error", "-nostdin", "-xerror", "-n",
                       "-threads", "1", "-filter_threads", "1", *arguments)

        # This independent reader is a development tool. It is not added to the app.
        prefix = root / ".tools/media-build/prefix"
        reader_source, reader = work / "vorbis-read.c", work / "vorbis-read"
        reader_source.write_text('''#include <stdio.h>
#include <vorbis/vorbisfile.h>
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    OggVorbis_File file;
    if (ov_fopen(argv[1], &file)) return 3;
    char buffer[16384]; int section; long count;
    while ((count = ov_read(&file, buffer, sizeof buffer, 0, 2, 1, &section)) > 0)
        if (fwrite(buffer, 1, count, stdout) != (size_t)count) return 4;
    ov_clear(&file);
    return count < 0 ? 5 : 0;
}
''')
        run("cc", "-I", prefix / "include", reader_source, prefix / "lib/libvorbisfile.a",
            prefix / "lib/libvorbis.a", prefix / "lib/libogg.a", "-o", reader)

        def check(path, starts, duration, rate=48000, include_video=False):
            info = json.loads(run(tools / "ffprobe", "-v", "error", "-show_streams", "-of", "json", path))
            assert len(info["streams"]) == (2 if include_video else 1)
            audio = next(s for s in info["streams"] if s["codec_type"] == "audio")
            assert audio["channels"] == 2 and int(audio["sample_rate"]) == rate
            pcm = array("h", run(reader, path) if path.suffix == ".ogg" else
                        ffmpeg("-i", path, "-map", "0:a:0", "-c:a", "pcm_s16le", "-f", "s16le", "-"))
            assert len(pcm) % 2 == 0 and abs(len(pcm) / 2 - round(duration * rate)) <= 4096, (path, len(pcm), duration)
            events, last = [], float("-inf")
            for i in range(0, len(pcm), 2):
                if abs(pcm[i]) > 9000:
                    when = i / 2 / rate
                    if when - last > 0.1:
                        events.append(when)
                    last = when
            delay = {".aac": 1024, ".ac3": 256, ".eac3": 256}.get(path.suffix, 0) / rate
            assert len(events) == len(starts), (path, events, starts)
            assert all(abs(actual - expected - delay) <= 0.002 + 1 / rate
                       for actual, expected in zip(events, starts)), (path, events, starts, delay)

        wav, raw = work / "original.wav", work / "original.gray"
        bursts = [(0.005, 0.025), (0.4, 0.6), (2.4, 2.6), (3.97, 3.99)]
        with wave.open(str(wav), "wb") as file:
            file.setparams((2, 2, 48000, 0, "NONE", "not compressed"))
            file.writeframes(b"".join(struct.pack("<hh", value, value) for i in range(48000 * 4)
                for value in [round(20000 * math.sin(math.tau * 1000 * i / 48000))
                              if any(a <= i / 48000 < b for a, b in bursts) else 0]))
        raw.write_bytes(bytes([80]) * (128 * 72 * 100))
        cases = [("aligned", 0, 0, 4, 4, 0), ("audio-late", 0, 0.4, 4, 4, 0),
                 ("video-late", 0.4, 0, 4, 4, 0), ("audio-short", 0, 0, 4, 3, 0),
                 ("video-short", 0, 0, 3, 4, 0), ("origin", 5, 5.4, 4, 4, 0),
                 ("gap20", 0, 0, 4, 4, 0.02), ("gap50", 0, 0, 4, 4, 0.05),
                 ("gap200", 0, 0, 4, 4, 0.2)]
        for name, video_delay, audio_delay, video_length, audio_length, gap in cases:
            source = work / f"{name}.mkv"
            af = f"atrim=duration={audio_length}"
            if gap:
                af += rf",asetpts=PTS+if(gte(T\,2)\,{gap}/TB\,0)"
            ffmpeg("-copyts", "-itsoffset", video_delay, "-f", "rawvideo", "-pixel_format", "gray",
                   "-video_size", "128x72", "-framerate", "25", "-i", raw, "-itsoffset", audio_delay,
                   "-i", wav, "-map", "0:v:0", "-map", "1:a:0", "-vf", f"trim=duration={video_length}",
                   "-af", af, "-c:v", "ffv1", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le", source)
            before = hashlib.sha256(source.read_bytes()).digest()
            starts = [a + (gap if a >= 2 else 0) for a, _ in bursts if a < audio_length]
            for extension in formats:
                output = work / f"{name}-output.{extension}"
                run(command, "convert", source, output)
                check(output, starts, audio_length + gap)
                assert hashlib.sha256(source.read_bytes()).digest() == before
                assert not list(work.glob(".allomer-*"))
                checks += 1
            print(name, "passed all 17 audio outputs.", flush=True)

        # Encoders with delayed first packets exposed stalls between separate timing/encoding graphs.
        settings = work / "stress.json"
        settings.write_text(json.dumps({"timeout": 5}))
        def stress(index):
            output = work / f"stress-{index}.{'tta' if index % 2 == 0 else 'wmv'}"
            run(command, "convert", source, output, "--media-options", settings)
            return output
        with ThreadPoolExecutor(max_workers=4) as pool:
            outputs = list(pool.map(stress, range(64)))
        for output in outputs:
            check(output, starts, 4.2, include_video=output.suffix == ".wmv")
            checks += 1
        assert hashlib.sha256(source.read_bytes()).digest() == before
        assert not list(work.glob(".allomer-*"))
        print("Concurrent TTA/WMV conversion passed 64 checks.", flush=True)

        pcm32 = b"".join(struct.pack("<ii", ((i * 7919) % 65536 - 32768) * 256,
                                   ((i * 9973) % 131072 - 65536) * 256) for i in range(48000))
        raw24, source24 = work / "precision.s32le", work / "precision.flac"
        raw24.write_bytes(pcm32)
        ffmpeg("-f", "s32le", "-ar", "48000", "-ac", "2", "-i", raw24, "-c:a", "flac", source24)
        before24 = source24.read_bytes()
        for extension in ("flac", "wav", "aiff", "alac", "caf", "au", "tta", "wv", "mka"):
            output = work / f"precision-output.{extension}"
            run(command, "convert", source24, output)
            assert ffmpeg("-i", output, "-f", "s32le", "-") == pcm32, (extension, "24-bit audio changed.")
            assert source24.read_bytes() == before24 and not list(work.glob(".allomer-*"))
            checks += 1
        print("All nine lossless outputs retain exact 24-bit samples.", flush=True)

        for rate in (8000, 16000, 22050, 32000, 44100):
            before = hashlib.sha256(wav.read_bytes()).digest()
            settings = work / f"rate-{rate}.json"
            settings.write_text(json.dumps({"sampleRate": rate}))
            output = work / f"resampled-{rate}.wma"
            run(command, "convert", wav, output, "--media-options", settings)
            check(output, [a for a, _ in bursts], 4, rate=rate)
            assert hashlib.sha256(wav.read_bytes()).digest() == before
            checks += 1

        short = work / "short.flac"
        ffmpeg("-i", wav, "-t", "0.75", "-c:a", "flac", short)
        for quality in (0, 37, 100):
            before = hashlib.sha256(short.read_bytes()).digest()
            settings = work / f"quality-{quality}.json"
            settings.write_text(json.dumps({"audioQuality": quality}))
            output = work / f"short-{quality}.ogg"
            run(command, "convert", short, output, "--media-options", settings)
            check(output, [a for a, _ in bursts if a < 0.75], 0.75)
            samples = run(reader, output)
            assert len(samples) == 36000 * 4, (quality, len(samples))
            decoded = work / f"short-{quality}.wav"
            ogg_before = hashlib.sha256(output.read_bytes()).digest()
            run(command, "convert", output, decoded)
            actual = ffmpeg("-i", decoded, "-c:a", "pcm_s16le", "-f", "s16le", "-")
            assert len(actual) == len(samples), (quality, len(actual), len(samples))
            assert max(abs(a - b) for a, b in zip(array("h", actual), array("h", samples))) <= 2
            assert hashlib.sha256(output.read_bytes()).digest() == ogg_before
            assert hashlib.sha256(short.read_bytes()).digest() == before
            checks += 2

        def compare_vorbis(output, reference, case):
            nonlocal checks
            for decoder in ("vorbis", "libvorbis"):
                for mode in ("file", "pipe", "seek-zero"):
                    arguments = [tools / "ffmpeg", "-v", "error", "-xerror", "-c:a", decoder]
                    if mode == "seek-zero":
                        arguments.extend(["-ss", "0"])
                    arguments.extend(["-i", "pipe:0" if mode == "pipe" else output, "-f", "s16le", "-"])
                    result = subprocess.run(list(map(str, arguments)), env=environment, cwd=work,
                        input=output.read_bytes() if mode == "pipe" else None, capture_output=True, timeout=30)
                    detail = (case, decoder, mode)
                    assert result.returncode == 0 and not result.stderr.strip(), (detail, result.stderr)
                    actual = array("h", result.stdout)
                    assert len(actual) == len(reference), (detail, len(actual), len(reference))
                    assert max(abs(a - b) for a, b in zip(actual, reference)) <= 2, detail
                    checks += 1

        # Compare both decoders with an independent reader at short page boundaries.
        for rate in (8000, 44100, 48000, 96000):
            for channels in (1, 2):
                for duration in (0.001, 0.02, 0.75, 1.01):
                    original = work / "boundary.wav"
                    with wave.open(str(original), "wb") as file:
                        file.setparams((channels, 2, rate, 0, "NONE", "not compressed"))
                        file.writeframes(array("h", (round(12000 * math.sin(math.tau * (731 + ch * 173) * i / rate))
                            for i in range(round(rate * duration)) for ch in range(channels))).tobytes())
                    for quality in (-1, 3, 10):
                        output = work / f"boundary-{rate}-{channels}-{duration}-{quality}.ogg"
                        ffmpeg("-i", original, "-c:a", "libvorbis", "-q:a", quality,
                               "-fflags", "+bitexact", "-serial_offset", checks + 1, output)
                        reference = array("h", run(reader, output))
                        assert len(reference) == round(rate * duration) * channels
                        compare_vorbis(output, reference, (rate, channels, duration, quality))

        for rate in (8000, 44100, 48000, 96000):
            for channels in (1, 2):
                for durations in ((0.75, 0.02), (1.01, 0.75), (0.02, 1.01, 0.001)):
                    for qualities in ((-1, -1, -1), (10, 10, 10), (-1, 3, 10), (10, 3, -1)):
                        links = [work / f"boundary-{rate}-{channels}-{d}-{q}.ogg"
                                 for d, q in zip(durations, qualities)]
                        chain = work / "chain.ogg"
                        original = b"".join(path.read_bytes() for path in links)
                        chain.write_bytes(original)
                        reference = array("h", b"".join(run(reader, path) for path in links))
                        compare_vorbis(chain, reference, (rate, channels, durations, qualities))
                        if (durations == (0.02, 1.01, 0.001) and qualities == (-1, 3, 10) and
                            channels == (1 if rate <= 44100 else 2)):
                            output = work / f"chain-{rate}.wav"
                            run(command, "convert", chain, output)
                            actual = array("h", ffmpeg("-i", output, "-f", "s16le", "-"))
                            assert len(actual) == len(reference), (rate, len(actual), len(reference))
                            assert max(abs(a - b) for a, b in zip(actual, reference)) <= 2, rate
                            assert chain.read_bytes() == original
                            checks += 1

        # Changing sample rate or channel count within a chain is still refused.
        for label, second in (("rate", "8000-2-0.02-3"), ("channels", "48000-1-0.02-3")):
            data = (work / "boundary-48000-2-0.75-3.ogg").read_bytes() + (work / f"boundary-{second}.ogg").read_bytes()
            source, output = work / f"changed-{label}.ogg", work / f"changed-{label}.wav"
            source.write_bytes(data)
            result = subprocess.run([command, "convert", source, output], env=environment, cwd=work,
                                    capture_output=True, timeout=30)
            assert result.returncode != 0 and not output.exists() and source.read_bytes() == data
            checks += 1

        # Corrupt a new setup header while retaining a valid Ogg page checksum.
        def ogg_checksum(data, position, end):
            data[position + 22:position + 26] = bytes(4)
            crc = 0
            for byte in data[position:end]:
                crc ^= byte << 24
                for _ in range(8):
                    crc = ((crc << 1) ^ (0x04C11DB7 if crc & 0x80000000 else 0)) & 0xFFFFFFFF
            data[position + 22:position + 26] = struct.pack("<I", crc)

        damaged = bytearray((work / "boundary-48000-2-0.02-10.ogg").read_bytes())
        changed = damaged.index(b"\x05vorbis") + 8
        damaged[changed] ^= 1
        position = 0
        while position < len(damaged):
            assert damaged[position:position + 4] == b"OggS"
            segments = damaged[position + 26]
            end = position + 27 + segments + sum(damaged[position + 27:position + 27 + segments])
            if position <= changed < end:
                ogg_checksum(damaged, position, end)
                break
            position = end
        source, output = work / "invalid-chain.ogg", work / "invalid-chain.wav"
        data = (work / "boundary-48000-2-0.75-3.ogg").read_bytes() + damaged
        source.write_bytes(data)
        result = subprocess.run([command, "convert", source, output], env=environment, cwd=work,
                                capture_output=True, timeout=30)
        assert result.returncode != 0 and not output.exists() and source.read_bytes() == data
        checks += 1

        # Remove a setup packet whose settings match the preceding link.
        complete = (work / "boundary-48000-2-0.02-3.ogg").read_bytes()
        position = 58  # The identification header occupies the first page.
        segments = complete[position + 26]
        lacing = complete[position + 27:position + 27 + segments]
        comment_segments = next(i + 1 for i, size in enumerate(lacing) if size < 255)
        body = position + 27 + segments
        end = body + sum(lacing)
        page = bytearray(complete[position:position + 27] + lacing[:comment_segments] +
                         complete[body:body + sum(lacing[:comment_segments])])
        assert page[27 + comment_segments:27 + comment_segments + 7] == b"\x03vorbis"
        page[26] = comment_segments
        ogg_checksum(page, 0, len(page))
        data = (work / "boundary-48000-2-0.75-3.ogg").read_bytes() + complete[:position] + page + complete[end:]
        source, output = work / "missing-setup.ogg", work / "missing-setup.wav"
        source.write_bytes(data)
        result = subprocess.run([command, "convert", source, output], env=environment, cwd=work,
                                capture_output=True, timeout=30)
        assert result.returncode != 0 and b"CRC mismatch" not in result.stderr
        assert not output.exists() and source.read_bytes() == data
        checks += 1
        packets = json.loads(run(tools / "ffprobe", "-v", "error", "-select_streams", "a", "-show_packets",
                                 "-of", "json", short))["packets"]
        data = short.read_bytes()
        for name, cut in [("whole-frame", int(packets[-1]["pos"])), ("partial-frame", len(data) - 10)]:
            damaged = work / f"{name}.flac"
            damaged.write_bytes(data[:cut])
            output = work / f"{name}.wav"
            result = subprocess.run([command, "convert", damaged, output], cwd=work, env=environment,
                                    capture_output=True, timeout=120)
            assert result.returncode != 0 and not output.exists()
            assert damaged.read_bytes() == data[:cut]
            checks += 1
        # Streaming FLAC can omit the sample count. It must still convert.
        unknown = work / "unknown-length.flac"
        streamed = bytearray(data)
        assert streamed[:4] == b"fLaC"
        value = int.from_bytes(streamed[18:26], "big") & ~((1 << 36) - 1)
        streamed[18:26] = value.to_bytes(8, "big")
        unknown.write_bytes(streamed)
        output = work / "unknown-length.wav"
        run(command, "convert", unknown, output)
        check(output, [a for a, _ in bursts if a < 0.75], 0.75)
        assert unknown.read_bytes() == streamed
        checks += 1
        assert not list(work.glob(".allomer-*"))
        print(f"Passed {checks} audio timing conversions/refusals, opening/closing sounds, gaps, sample rates, independent Vorbis decoding, truncated and unknown-length FLAC, source bytes, and cleanup.")


if __name__ == "__main__":
    main()
