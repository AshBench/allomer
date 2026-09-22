#!/usr/bin/env python3
"""Create an original PGS subtitle fixture. Requires Pillow; --check uses bundled FFmpeg."""
import argparse
import hashlib
from itertools import groupby
import json
from pathlib import Path
import struct
import subprocess
import tempfile

from PIL import Image, ImageDraw, ImageFont


SIZE = (640, 360)
FONT = "/System/Library/Fonts/Supplemental/Arial.ttf"
COLORS = [(0, 0, 0, 0), (0, 0, 0, 255), (255, 255, 255, 255)]
CUES = [(1000, 2000, [(100, 275, "Amber kite")]),
        (3250, 5500, [(100, 225, "Quiet orbit"), (100, 280, "Silver pebble")])]


def segment(milliseconds, kind, payload):
    if (type(milliseconds) is not int or not 0 <= milliseconds <= 0xFFFFFFFF // 90
            or kind not in (0x14, 0x15, 0x16, 0x17, 0x80) or len(payload) > 65535):
        raise ValueError("Invalid PGS segment timestamp, type, or size.")
    return b"PG" + struct.pack(">IIBH", milliseconds * 90, 0, kind, len(payload)) + payload


def caption(text):
    if not text or len(text) > 80 or not text.isprintable():
        raise ValueError("A caption must contain 1 to 80 printable characters.")
    font = ImageFont.truetype(FONT, 32)
    left, top, right, bottom = font.getbbox(text, stroke_width=2)
    image = Image.new("L", (right - left + 8, bottom - top + 8))
    ImageDraw.Draw(image).text((4 - left, 4 - top), text, font=font,
                              fill=255, stroke_width=2, stroke_fill=128)
    return image.point(lambda value: 0 if value < 64 else 1 if value < 192 else 2)


def rle(image):
    if (image.mode != "L" or not 0 < image.width <= SIZE[0] or not 0 < image.height <= SIZE[1]
            or not set(image.tobytes()) <= {0, 1, 2}):
        raise ValueError("A bitmap must fit the canvas and use palette entries 0 to 2.")
    result = bytearray()
    pixels = image.tobytes()
    for y in range(image.height):
        for color, group in groupby(pixels[y * image.width:(y + 1) * image.width]):
            length = sum(1 for _ in group)
            flags = (0x80 if color else 0) | (0x40 if length >= 64 else 0)
            result.extend((0, flags | (length >> 8 if length >= 64 else length)))
            if length >= 64:
                result.append(length & 255)
            if color:
                result.append(color)
        result.extend((0, 0))
    return bytes(result)


def fixture(dark_text=False, cropped=False):
    output = bytearray()
    expected = {}
    colors = [(0, 0, 0, 0), (0, 0, 0, 0), (0, 0, 0, 255)] if dark_text else COLORS
    for number, (start, end, captions) in enumerate(CUES):
        if not 0 <= start < end or (number and start <= CUES[number - 1][1]):
            raise ValueError("Fixture cues must have positive duration and a gap.")
        rectangles = [(x, y, caption(text)) for x, y, text in captions]
        if not 1 <= len(rectangles) <= 2:
            raise ValueError("A fixture cue needs one or two rectangles.")
        frame = Image.new("RGBA", SIZE)
        refs, windows = bytearray(), bytearray([len(rectangles)])
        stored = []
        for index, (x, y, bitmap) in enumerate(rectangles):
            if x < 0 or y < 0 or x + bitmap.width > SIZE[0] or y + bitmap.height > SIZE[1]:
                raise ValueError("A rectangle is outside the canvas.")
            crop = cropped and index == 0
            refs.extend(struct.pack(">HBBHH", index, index, 0x80 if crop else 0, x, y))
            if crop:
                # The visible word is inside a larger object with unwanted text on its left.
                expanded = Image.new("L", (bitmap.width + 128, bitmap.height + 16))
                expanded.paste(caption("Wrong"), (0, 8))
                expanded.paste(bitmap, (128, 8))
                refs.extend(struct.pack(">HHHH", 128, 8, bitmap.width, bitmap.height))
                stored.append(expanded)
            else:
                stored.append(bitmap)
            windows.extend(struct.pack(">BHHHH", index, x, y, bitmap.width, bitmap.height))
            rgba = Image.new("RGBA", bitmap.size)
            rgba.putdata([colors[value] for value in bitmap.tobytes()])
            frame.paste(rgba, (x, y))
        # Each visible display starts a new epoch and supplies its own palette and objects.
        presentation = struct.pack(">HHBHBBBB", *SIZE, 0x10, number * 2, 0x80, 0, 0, len(rectangles))
        output.extend(segment(start, 0x16, presentation + refs))
        output.extend(segment(start, 0x17, windows))
        palette = bytes([0, 0, 0, 16, 128, 128, 0, 1, 16, 128, 128, 0 if dark_text else 255,
                         2, 16 if dark_text else 235, 128, 128, 255])
        output.extend(segment(start, 0x14, palette))
        for index in reversed(range(len(stored))) if cropped else range(len(stored)):
            bitmap = stored[index]
            encoded = rle(bitmap)
            object_data = (struct.pack(">HBB", index, 0, 0xC0) + (len(encoded) + 4).to_bytes(3, "big")
                           + struct.pack(">HH", *bitmap.size) + encoded)
            output.extend(segment(start, 0x15, object_data))
        output.extend(segment(start, 0x80, b""))
        clear = struct.pack(">HHBHBBBB", *SIZE, 0x10, number * 2 + 1, 0, 0, 0, 0)
        output.extend(segment(end, 0x16, clear))
        output.extend(segment(end, 0x80, b""))
        expected[start] = frame
        expected[end] = Image.new("RGBA", SIZE)
    return bytes(output), expected


def check(path, expected):
    tools = Path(__file__).resolve().parent.parent / ".tools/media/bin"
    def run(*args):
        return subprocess.run(args, check=True, capture_output=True, text=True, timeout=30)
    probe = json.loads(run(tools / "ffprobe", "-v", "error", "-select_streams", "s:0",
                           "-show_packets", "-show_frames", "-of", "json", path).stdout)
    records = probe["packets_and_frames"]
    packets = [item for item in records if item["type"] == "packet"]
    frames = [item for item in records if item["type"] == "subtitle"]
    assert len(packets) == 15, packets
    assert {int(item["pts"]) for item in packets} == {time * 90 for time in expected}, packets
    actual = [(int(item["pts"]), item["start_display_time"], item["end_display_time"], item["num_rects"])
              for item in frames]
    assert actual == [(1000000, 0, 0xFFFFFFFF, 1), (2000000, 0, 0xFFFFFFFF, 0),
                      (3250000, 0, 0xFFFFFFFF, 2), (5500000, 0, 0xFFFFFFFF, 0)], actual
    with tempfile.TemporaryDirectory(prefix="original-pgs-check-") as directory:
        run(tools / "ffmpeg", "-nostdin", "-v", "error", "-xerror", "-n", "-threads", "1",
            "-auto_conversion_filters", "-copyts", "-i", path,
            "-filter_complex", "[0:s:0]format=rgba[out]", "-map", "[out]", "-t", "6",
            "-c:v", "png", "-threads:v", "1", "-fps_mode", "passthrough",
            "-enc_time_base", "1:1000000", "-frame_pts", "1", str(Path(directory) / "%d.png"))
        images = {int(file.stem): file for file in Path(directory).glob("*.png")}
        events = {time * 1000: frame for time, frame in expected.items()}
        assert events.keys() <= images.keys(), images
        for time, file in images.items():
            # The CLI can repeat the current picture just before a clear event.
            preceding = max((event for event in events if event <= time), default=None)
            frame = events[preceding] if preceding is not None else Image.new("RGBA", SIZE)
            with Image.open(file) as decoded:
                assert decoded.size == SIZE and decoded.convert("RGBA").tobytes() == frame.tobytes(), time
    invalid = [(segment, (-1, 0x80, b"")), (segment, (0, 0, b"")),
               (segment, (0, 0x80, bytes(65536))), (caption, ("",)), (caption, ("bad\ncaption",)),
               (rle, (Image.new("L", (641, 1)),)), (rle, (Image.new("L", (1, 1), 3),))]
    for function, args in invalid:
        try:
            function(*args)
        except ValueError:
            continue
        raise AssertionError("Invalid generator input accepted.")
    print(json.dumps({"packets": len(packets), "events": actual, "rendered_frames": sorted(images),
                      "pixel_match": True, "invalid_inputs_rejected": len(invalid)}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="New .sup path; the parent folder must exist.")
    parser.add_argument("--check", action="store_true", help="Check timings and rendered pixels with bundled tools.")
    parser.add_argument("--dark-text", action="store_true", help="Use black letters on transparency.")
    parser.add_argument("--cropped", action="store_true", help="Crop unwanted text out of the first picture object.")
    args = parser.parse_args()
    if args.output.suffix.lower() != ".sup" or not args.output.parent.is_dir() or args.output.exists():
        parser.error("Use a new .sup path in an existing folder.")
    if args.check and args.cropped:
        parser.error("The bundled FFmpeg renderer ignores PGS crops. Use the bitmap conversion checker for this fixture.")
    data, expected = fixture(dark_text=args.dark_text, cropped=args.cropped)
    with args.output.open("xb") as output:
        output.write(data)
    if args.check:
        check(args.output.resolve(), expected)
    print(f"{args.output}: {len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()}")


if __name__ == "__main__":
    main()
