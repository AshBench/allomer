#!/usr/bin/env python3
"""Render the checked-in Allomer vector artwork for app and web packaging."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ElementTree


ROOT = Path(__file__).resolve().parent.parent
BRANDING = ROOT / "branding"
GENERATED = BRANDING / "generated"
WEBSITE_IMAGES = ROOT / "website/static/img"


def run(*arguments):
    subprocess.run(list(map(str, arguments)), cwd=ROOT, check=True)


def render(inkscape, source, output, size):
    run(
        inkscape,
        source,
        "--export-type=png",
        f"--export-filename={output}",
        f"--export-width={size}",
        f"--export-height={size}",
    )


def build_wordmark(source, output, title, text_color, section_colors):
    ElementTree.register_namespace("", "http://www.w3.org/2000/svg")
    tree = ElementTree.parse(source)
    elements = {
        element.get("id"): element
        for element in tree.getroot().iter()
        if element.get("id")
    }
    required = {"title1", "g1", "wordmark-o", "path1", "path2", "path3"}
    if missing := required - elements.keys():
        raise SystemExit(f"The wordmark is missing elements: {', '.join(sorted(missing))}.")
    elements["title1"].text = title
    elements["g1"].set("fill", text_color)
    elements["wordmark-o"].attrib.pop("stroke", None)
    for identifier, color in zip(("path1", "path2", "path3"), section_colors):
        elements[identifier].set("stroke", color)
    tree.write(output, encoding="UTF-8", xml_declaration=True)
    with output.open("a") as wordmark:
        wordmark.write("\n")


def main():
    inkscape = shutil.which("inkscape")
    if not inkscape:
        raise SystemExit("Inkscape is required to rebuild the brand assets.")

    GENERATED.mkdir(parents=True, exist_ok=True)
    WEBSITE_IMAGES.mkdir(parents=True, exist_ok=True)
    run(
        inkscape,
        BRANDING / "allomer-logo-source.svg",
        "--export-type=svg",
        f"--export-filename={BRANDING / 'allomer-logo.svg'}",
        "--export-text-to-path",
        "--export-plain-svg",
        "--export-area-drawing",
    )
    if "<text" in (BRANDING / "allomer-logo.svg").read_text():
        raise SystemExit("The published wordmark still contains editable text.")
    build_wordmark(
        BRANDING / "allomer-logo.svg",
        BRANDING / "allomer-logo.svg",
        "Allomer logo",
        "#29305A",
        ("#29305A", "#47BFAE", "#737BE2"),
    )
    build_wordmark(
        BRANDING / "allomer-logo.svg",
        BRANDING / "allomer-logo-dark.svg",
        "Allomer logo for dark backgrounds",
        "#F4F6F8",
        ("#D9DDF2", "#60CDBD", "#8B92ED"),
    )

    icon_names = {
        16: ("icon_16x16.png",),
        32: ("icon_16x16@2x.png", "icon_32x32.png"),
        64: ("icon_32x32@2x.png",),
        128: ("icon_128x128.png",),
        256: ("icon_128x128@2x.png", "icon_256x256.png"),
        512: ("icon_256x256@2x.png", "icon_512x512.png"),
        1024: ("icon_512x512@2x.png",),
    }

    with tempfile.TemporaryDirectory(prefix="allomer-icon-") as temporary:
        iconset = Path(temporary) / "Allomer.iconset"
        iconset.mkdir()
        for size, names in icon_names.items():
            rendered = Path(temporary) / f"{size}.png"
            render(inkscape, BRANDING / "allomer-app-icon.svg", rendered, size)
            for name in names:
                shutil.copy2(rendered, iconset / name)
            if size == 1024:
                shutil.copy2(rendered, GENERATED / "Allomer-1024.png")
        run("/usr/bin/iconutil", "-c", "icns", "-o", GENERATED / "Allomer.icns", iconset)

    render(inkscape, BRANDING / "allomer-mark.svg", GENERATED / "Allomer-mark-512.png", 512)
    run(
        inkscape,
        BRANDING / "allomer-logo.svg",
        "--export-type=png",
        f"--export-filename={GENERATED / 'Allomer-logo.png'}",
        "--export-width=1200",
    )
    shutil.copy2(BRANDING / "allomer-mark-color.svg", WEBSITE_IMAGES / "allomer-mark.svg")
    render(inkscape, BRANDING / "allomer-app-icon.svg", WEBSITE_IMAGES / "allomer-app-icon.png", 64)


if __name__ == "__main__":
    main()
