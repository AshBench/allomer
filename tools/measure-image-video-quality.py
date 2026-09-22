"""Compare native playback of one original noise image between two app builds."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import random
import subprocess
import tempfile

import numpy as np
from PIL import Image

root = Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--before-app", type=Path, required=True)
parser.add_argument("--after-app", type=Path, default=root / "dist/preview/Allomer.app")
parser.add_argument("--report", type=Path, default=root / "research/image-video-quality.json")
args = parser.parse_args()
apps = {"before": args.before_app.resolve(), "after": args.after_app.resolve()}
records = {}
with tempfile.TemporaryDirectory(prefix="Video rate quality ") as temporary:
    work = Path(temporary)
    source = work / "noise.png"
    Image.frombytes("RGB", (1024, 1024), random.Random(173).randbytes(1024 * 1024 * 3)).save(source)
    original = np.asarray(Image.open(source), dtype=np.float64)
    pixels = {}
    for name, app in apps.items():
        command = app / "Contents/MacOS/allomer"
        helpers = app / "Contents/Helpers"
        output = work / (name + ".mp4")
        subprocess.run([command, "convert", source, output], check=True, capture_output=True,
                       env={"PATH": "/usr/bin:/bin", "ALLOMER_TOOLS_DIR": str(helpers)}, timeout=120)
        frame = work / (name + ".png")
        subprocess.run([root / ".tools/check-image-video-native", output, frame],
                       check=True, capture_output=True, timeout=30)
        with Image.open(frame) as decoded:
            pixels[name] = np.asarray(decoded.convert("RGB"), dtype=np.float64)
        error = pixels[name] - original
        info = json.loads(subprocess.check_output([helpers / "ffprobe", "-v", "error", "-count_frames",
            "-show_entries", "stream=nb_read_frames,r_frame_rate", "-of", "json", output]))
        records[name] = {"command_sha256": hashlib.sha256(command.read_bytes()).hexdigest(),
            "output_bytes": output.stat().st_size, "streams": info["streams"],
            "rgb_rms_error": float(np.sqrt(np.mean(error ** 2))),
            "rgb_rms_error_by_channel": np.sqrt(np.mean(error ** 2, axis=(0, 1))).tolist(),
            "absolute_error_95th_percentile": float(np.percentile(np.abs(error), 95))}
    report = {"input_sha256": hashlib.sha256(source.read_bytes()).hexdigest(), "pixels": [1024, 1024],
        "macos": platform.mac_ver()[0], "runs": records,
        "changed_native_rgb_components": int(np.count_nonzero(pixels["before"] != pixels["after"])),
        "scope": "One original RGB noise fixture per packaged command. Compare the first frame decoded by AVFoundation into sRGB against the original PNG. Default GIF and video settings. This includes palette reduction, video compression, and chroma subsampling. It is not a general image-quality score or a performance measurement."}
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
