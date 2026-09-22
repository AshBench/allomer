---
sidebar_position: 7
---

# Font conversion

The app converts TTF, OTF, WOFF, and WOFF2. Change a font's extension in a watched folder or use the Manual tab. The app bundles a headless font converter. End users do not need Python, Homebrew, or a network connection.

## Variable fonts lose their axes

Variable fonts are accepted. Both variable outline kinds work: TrueType outlines with a `gvar` table, and CFF2 outlines.

**The output is a single static font, and the variation axes are gone.** The app writes the font's default design location, which is the instance the font itself names as its starting point. Weight, width, optical size, and any other axis are no longer adjustable in the converted file. A CFF2 font becomes an ordinary CFF font.

This is a real loss. If you need the axes, keep the original file. The app never replaces it.

The output is checked to contain none of `fvar`, `gvar`, `avar`, `cvar`, `HVAR`, `VVAR`, `MVAR`, or `CFF2`. Conversion fails rather than shipping a static font that still carries variation data. Feature variations in the layout tables are removed with the axes, so a `GSUB` table at version 1.1 is rewritten to version 1.0.

A `STAT` table is kept. It describes where a static font sits within its family, is valid without any axes, and is not variation data.

A digital signature (`DSIG`) is dropped. Any change to a font invalidates it, so keeping it would be misleading.

## Content and checks

The adapter reads the source with macOS's font reader before conversion. It then checks the output's actual file format, family name, PostScript name, units per em, and character coverage. Copyright, license, trademark, manufacturer, and designer text must remain when present. It checks character advances and outline bounds for every character in that coverage. Characters outside the first Unicode plane are included. Existing destination files are never overwritten.

A font with no readable family or PostScript name is refused, as is one missing `cmap`, `name`, `head`, `hhea`, `hmtx`, or `maxp`. Names are read through the optional CoreText call and compared as text. The two accessors that return a family or PostScript name directly cannot report absence and stop the process on a font that has none, so neither is used.

TTF output uses TrueType outlines. OTF output uses CFF outlines. WOFF and WOFF2 output uses TrueType outlines, because WOFF2 can transform TrueType outlines and cannot transform CFF. Keeping CFF inside the web containers was measured at about a third larger for the same font, so it was not adopted.

Converting CFF outlines to TrueType outlines replaces cubic curves with quadratic ones. The tolerance is one thousandth of an em, the usual value for this conversion. Converting the other way is exact: every quadratic curve has an identical cubic form. Across the twenty-four checked conversions the largest outline-bound difference is 0.398 font units, against a check that allows one. Both variable fixtures convert with no difference at all.

A CFF font records a left side bearing that renderers ignore, while a TrueType font is positioned by it. The converter recomputes those bearings from the converted outlines. Carrying the old values over shifted whole glyphs sideways in an early version.

Composite glyphs are placed from the glyph table directly, in full precision. Outline readers commonly resolve a composite the way FreeType does, rounding the placement to whole units, which for a component carrying a scale lands up to a unit away from where macOS draws the same glyph. That is allowed for a rasterizer and outside what the outline check above permits, so this conversion does the placement itself. Composites anchored to a point rather than an offset are refused.

Fonts with color data or bitmap strikes are still refused. The retained original remains available. TrueType hinting instructions are dropped when the outline kind changes. Full hinting and custom-table preservation still require more work, so font-format coverage is not yet full font-feature parity.

Inputs and outputs have a 64 MiB file limit. Web fonts have a 128 MiB expanded-size limit. The native reader accepts at most 256 font tables. The conversion process has a two-minute limit and runs outside the app's UI process, inside a sandbox that permits reading only the one source file and writing only into the conversion's own folder.

## Development checks

On an Apple Silicon Mac with Xcode, Python 3.12 or later, and CMake:

```sh
python3 tools/build-fonts.py
python3 tools/build-rust.py fontconvert
swift test
python3 tools/build-app.py
python3 tools/check-app.py
```

`tools/build-fonts.py` builds checksum-pinned upstream sources for ARM64 and macOS 14 into a static library prefix. It builds the HarfBuzz subsetter, Google's WOFF2 codec, and Brotli, and nothing else: HarfBuzz's shapers, rasterizers, and platform integrations are switched off. `tools/build-rust.py fontconvert` then compiles the helper and links that prefix.

The helper is original code. HarfBuzz rewrites the font at its default location, removes the variation tables, converts CFF2 to CFF, and drops the signature. The fontations libraries read outlines and write TrueType glyph data. An original writer produces the CFF table for the one direction HarfBuzz does not cover, TrueType outlines into a CFF font. An original reader and writer handle the WOFF 1.0 container; WOFF2 uses the pinned Google codec.

The built helper is 3,338,464 bytes and its sandbox launcher 34,344 bytes, against 6,718,376 bytes for the FontForge build they replace, so the pair is 3,345,568 bytes smaller. Code signing changes these slightly: in the packaged app they are 3,319,200 and 34,304 bytes. Both link only to libraries supplied by macOS. The replaced helper was GPL-3.0-or-later; every library the new one links is permissive.

`python3 tools/check-fonts.py` converts five fixtures into all four formats and checks each result with fontTools, independently of the app's own CoreText checks. Install the readers first with `python3 -m pip install -r tools/requirements-font-check.txt`. It downloads Adobe Variable Font Prototype 1.004, under the SIL Open Font License, into an ignored development cache and records the addresses and checksums in its report. It also converts web fonts packaged by fontTools, so the container reader is not only checked against this app's own writer. It checks that damaged fonts are refused without writing anything, that an occupied destination is never replaced, that sources keep their bytes, and that the sandbox refuses a font the launcher was not given.

The original fixture has straight and curved outlines, distinct character widths, a kerning pair, and a character outside the first Unicode plane. Its TTF and OTF files are committed. `tools/make-font-fixtures.py` regenerates them and needs a separately installed FontForge, because authoring a font from nothing is outside what the bundled converter does. Nothing from that tool is built or shipped.

The Swift checks cover all 16 input/output pairs, native reading, kerning, overwrite refusal, source preservation, automatic conversion, exact Undo, and a refused bitmap-strike font. A second test converts both variable fixtures into all four formats and checks that no variation table survives. A third converts Roboto, which has 2,048 units per em and composite glyphs carrying a scale. The packaged check runs with only the standard system command path.

`python3 tools/check-font-performance.py` downloads a checksum-pinned Source Sans 3 Regular font from Adobe's upstream repository under the SIL Open Font License. It measures three OTF-to-WOFF2 conversions with native validation and checks a return conversion to OTF. The source font and its license stay in the ignored development cache.

On the development Mac the 334,924-byte OTF becomes a 114,340-byte WOFF2 in a median 0.84 seconds, with a reported peak resident size of 36,683,776 bytes for the command. The FontForge path produced 112,212 bytes in a median 0.89 seconds with 57,311,232 bytes. Three samples do not prove a speed improvement, and the reported figure is not the app and its helpers measured together. The new output is 2,128 bytes larger because the cubic-to-quadratic conversion places its own points.
