---
sidebar_position: 3
---

# Archives

The archive adapter creates and converts ZIP, TAR, compressed TAR (`.tar.gz` or `.tgz`), GZIP, and 7z files. It uses the archive library supplied by macOS. The system GZIP command checks compressed-stream checksums.

A single-file fixture passes all 25 input and output pairs. Separate checks cover empty files, multiple files, nested paths, Unicode names, top-level folders, automatic replacement, and Undo.

## Settings

Choose Fast, Balanced, or Small file compression. TAR has no compression. ZIP uses Deflate, 7z uses LZMA2, and compressed TAR uses GZIP. Higher compression can take more time and memory.

The top-level-folder option puts the archive's files under a folder named after the source. Existing inner folder structure remains in place.

GZIP stores one regular file. It cannot include a folder or multiple files on this path. Use compressed TAR for those cases. A GZIP stream does not retain the original archive's file path. When opening it, the adapter derives the filename by removing `.gz` from the current name.

You can also place a regular file into an archive. The manual converter offers archive targets after its normal conversion targets.

## Output checks

File data streams through a 64 KiB buffer. Conversion does not extract archive contents into the user's folders. The adapter hashes each file while copying it. It reopens the output and checks paths, file types, sizes, and hashes before publication.

The current path rejects absolute paths, parent traversal, duplicate paths, links, special files, and encrypted entries. It accepts regular files and directories. A TAR root entry named `.` is treated as the container itself.

Current limits are 100,000 entries, 4 KiB per path, 16 MiB of combined paths, and 16 GiB of expanded file data. Exceeding a limit stops conversion before the final file is published. Recovery behavior is shared with the other automatic converters.

Complete archive fidelity is still in progress. Permissions, timestamps, extended attributes, links, encryption, large archives, and behavior on the minimum supported macOS version need further checks. The fixture results do not prove every archive variant or option.
