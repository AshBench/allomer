#!/usr/bin/env python3
"""Generate small, original test fonts with curves and a kerning pair.

The generated files are committed under Tests/Fixtures, so this runs only when they need to
change. Authoring a font from scratch is outside what the bundled converter does, so this
development-only script needs a FontForge installed separately; none is built or shipped.
"""

import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tool", type=Path, default=Path("fontforge"),
                        help="A separately installed FontForge used only to author the fixtures.")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        shape = work / "glyph.svg"
        shape.write_text('''<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="1000" viewBox="0 0 1000 1000">
<path d="M100 800 L300 100 L500 800 L400 800 L350 620 L250 620 L200 800 Z
M275 530 L325 530 L300 400 Z"/>
<path d="M550 800 C700 750 800 400 600 200 L660 170 C950 370 790 850 570 890 Z"/>
</svg>''')
        script = '''New(); SetFontNames("OriginalFixture-Regular", "Original Fixture", "Original Fixture Regular", "Regular", "Original test shapes; MIT license", "1.0");
Reencode("UnicodeFull"); Select(0u0020); SetWidth(250);
Select(0u0041); Import($1,0,64); SetWidth(1000);
Select(0u0042); Import($1,0,64); SetWidth(1100);
Select(0u00E9); Import($1,0,64); SetWidth(1200);
Select(0u10437); Import($1,0,64); SetWidth(1300);
Select(0u0041); SetKern(0u0042,-80);
Generate($2,"",32768); Generate($3,"",32768);'''
        subprocess.run([args.tool, "-quiet", "-lang=ff", "-c", script, shape,
                        ROOT / "Tests/Fixtures/font-values.ttf", ROOT / "Tests/Fixtures/font-values.otf"],
                       cwd=work, check=True)


if __name__ == "__main__":
    main()
