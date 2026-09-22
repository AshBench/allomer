# Allomer identity

An allomer is a material with the same crystalline form as another material but a different composition. The Allomer name applies that idea to files: the content remains recognizable while its representation changes. See the dictionary definition of [allomerism](https://www.dictionary.com/browse/allomerism).

Brand idea: **Same content. Another form.**

The mark is one stable circular form made from three sections. The long section represents continuity of content. The two shorter sections represent alternate file representations. The joins are diagonal so the mark does not resemble a refresh arrow or a power button.

## Files

- `allomer-mark.svg` is the one-color product mark.
- `allomer-mark-color.svg` is the color product mark.
- `allomer-logo.svg` is the outlined wordmark used in published material.
- `allomer-logo-source.svg` is the editable wordmark source.
- `allomer-app-icon.svg` is the macOS Dock icon source.
- `allomer-menu-bar.svg` is the 18-point menu bar reference.
- `generated/` contains packaged PNG and ICNS output.

The source is also available in the [Allomer brand file in Figma](https://www.figma.com/design/MSx6umcHKY56SNm43dpHIl). The final vectors were drawn and exported with [Inkscape](https://inkscape.org/).

The palette uses ink `#111318`, navy `#171B36`, mint `#47BFAE`, and periwinkle `#737BE2`. The wordmark source uses Instrument Sans SemiBold. The published wordmark converts the letters to paths, so the font is not required to display it.

Rebuild the packaged assets with:

```sh
python3 tools/build-brand-assets.py
```

This command needs Inkscape. The generated assets are checked in so building Allomer does not require Inkscape.
