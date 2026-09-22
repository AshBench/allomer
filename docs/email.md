---
title: Email conversion
---

Email conversion works locally through the bundled ARM64 `mailfile` helper. It uses the same engine for automatic extension changes and manual conversion.

| Input | Direct output |
| --- | --- |
| EML | EMLX, MSG, HTML |
| EMLX | EML |
| MSG | EML |

The engine can connect these routes to document outputs. For example, MSG-to-TXT uses EML and HTML. The Email setting controls whether rendered documents include message headers. It defaults to on. Message-file conversion always keeps headers.

EML-to-EMLX adds a byte count and an Apple property list. EMLX-to-EML copies exactly the indicated message bytes. Mailbox flags in the property list do not become EML headers. Signed MIME data can pass through this byte-preserving route.

MSG output uses the public Microsoft compound-file format. It stores Unicode text, recipients, message headers, plain and HTML bodies, and attachments. Attached emails become embedded MSG objects. MSG input supports Unicode and recognized older code pages. Rich-text bodies use Microsoft's RTF decompressor and the macOS RTF reader. EML output retains the original RTF as a MIME alternative. Attached MSG objects become attached EML messages.

HTML output removes active content and remote images. It embeds supported raster images referenced by Content-ID. Attachments are included as download links in the HTML file. Document conversions render this HTML; each destination controls how those links and images appear. External links remain clickable. Rendering does not fetch them.

## Current limits

- Inputs are limited to 64 MiB. Outputs are limited to 128 MiB.
- A message can have at most 1,000 attachments and 4,096 MIME parts. Nesting is limited to 16 attached messages.
- MSG files have an entry limit and a 256 MiB total stream limit. Rust parser allocations have a separate 256 MiB limit.
- Decompressed RTF is limited to 8 MiB. macOS uses its own allocations while reading RTF.
- MSG conversion rejects linked and OLE attachments, non-email Outlook objects, and signed or encrypted messages. It does not remove encryption or verify signatures.
- MIME content is rebuilt for MSG conversion. Cryptographic signatures over the original MIME bytes will not remain valid. Message text and attachments are checked in tests; arbitrary MAPI properties and advanced layout fidelity are not yet covered.
- HTML export removes styles and elements outside its supported HTML set. It does not claim identical visual layout.

Failed conversions leave the source intact. Automatic conversions keep the original for Undo.

## Development checks

Build on an Apple Silicon Mac with Xcode and the pinned local Rust toolchain:

```sh
python3 tools/setup-rust.py
python3 tools/build-rust.py mailfile
swift test --filter EmailTests/testEmailRoutesHeadersAndAutomaticUndo
```

The independent check uses Python's email parser and `extract-msg` 0.56.1. The latter is a development dependency only:

```sh
python3 -m venv .tools/mail-check
.tools/mail-check/bin/python -m pip install extract-msg==0.56.1
.tools/mail-check/bin/python tools/check-mailfile.py .tools/mailfile/bin/mailfile
```

The check covers all five direct routes, Unicode headers, older text encodings, binary and text attachments, inline images, embedded messages, RTF, invalid lengths, and overwrite refusal. The Swift check covers intermediate document routes, the header option, automatic conversion, and exact Undo.

After packaging, `python3 tools/check-mailfile.py --performance` measures an EML-to-MSG conversion with 10,000 Unicode text lines and an 8 MiB attachment. It checks the restored text and attachment bytes. The 11,939,729-byte input converted in a median 0.07 seconds with 47,808,512 bytes peak RSS on the development Mac. The first measured run took 0.40 seconds. This measures the helper process only. It excludes the app's memory and does not predict every email workload. `research/email-performance.json` records all samples and the packaged binary hash.

The helper is about 1.9 MiB. Its dynamic libraries come from macOS. The build retains upstream notices for all 81 resolved dependency packages. It also retains the unmodified source archives for its MPL dependencies under `.tools/mailfile/sources`. Include that matching source bundle with a distributed release.

The file mappings follow [Microsoft's MSG specification](https://learn.microsoft.com/en-us/openspecs/exchange_server_protocols/ms-oxmsg/b046868c-9fbf-41ae-9ffb-8de2bd4eec82) and the [Library of Congress EMLX description](https://www.loc.gov/preservation/digital/formats/fdd/fdd000615.shtml).
