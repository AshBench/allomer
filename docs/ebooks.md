---
sidebar_position: 6
---

# Ebook conversion

The app reads unencrypted MOBI, AZW, and AZW3 books and writes EPUB. These three Kindle formats are input formats only. An EPUB intermediate also connects them to the document outputs, such as DOCX, HTML, and plain text.

Change the extension in a watched folder or use the Manual tab. Automatic conversion keeps the original book for Undo. The reader is included in the app. Conversion requires no separate installation or network connection.

## Content and limits

The reader reconstructs the book's chapters, package information, styles, images, and other resources. Native macOS parsing converts reconstructed HTML into XHTML. Each chapter's text is checked before saving. Other ZIP members are streamed into the output and compared by size and SHA-256. The EPUB package must contain its manifest and reading order, with references to existing files.

The `mimetype` member is first and uncompressed. It has no ZIP extra fields. ZIP checksums are checked. Unsafe paths, symbolic links, duplicate members, and encrypted members are rejected.

macOS 14's ZIP writer adds timestamp and user fields to every local record, even when the entry has no such metadata. Allomer removes those fields from the first `mimetype` record and updates the later ZIP offsets. Newer systems already produce the required record, so they need no rewrite. This keeps the required local record compliant across supported macOS versions.

Input files have a 64 MiB limit. Record offsets and text headers are checked before the reader starts. The text-record allocation estimate must fit within 256 MiB. EPUB output has a 256 MiB expanded-data limit and a 10,000-member limit. Each chapter or metadata part has a 16 MiB limit. The reader has a two-minute time limit.

Encrypted books and Print Replica books are not supported by this path. Encryption support is disabled in the bundled reader. Complex interactive content, dictionary behavior, and exact reader presentation need further checks. Converting an EPUB to another document format can change layout or omit features that the target cannot represent.

## Development checks

Build on an Apple Silicon Mac with Xcode and Python 3.12 or later:

```sh
python3 tools/build-ebook.py
swift test
python3 tools/build-app.py
python3 tools/check-app.py
```

The build uses checksum-pinned libmobi 0.12 source. It targets ARM64 and macOS 14. The reader links only to system libraries and occupies about 224 KiB in the current build. Its source archive, rebuild script, notices, and build log are retained under `.tools/ebook/` for release preparation.

Eight upstream fixtures cover Unicode, Windows-1252 text, compressed and uncompressed books, navigation, dictionary text, fonts, images, audio, and video. The Swift check compares preserved resources against the upstream reader's output. It also checks all three input extensions through automatic conversion and exact Undo. Invalid record offsets, encrypted text, and excessive declared text sizes fail without publishing an output.

The packaged check runs outside the repository with only the system command path. Python's independent ZIP and XML readers check every reconstructed chapter. No user-installed converter is used.
