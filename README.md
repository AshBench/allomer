<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/allomer-logo-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="branding/allomer-logo.svg">
    <img src="branding/allomer-logo.svg" alt="Allomer" width="560">
  </picture>
</p>

Allomer is a native, open source file converter for Apple Silicon Macs. It converts files locally. It can also watch folders and convert a file when its extension changes.

Allomer is an AshBench project. Its website is [allomer.ashbench.com](https://allomer.ashbench.com).

> [!NOTE]
> Allomer is preparing its first public beta. There is no signed release yet.

## Features

- Manual conversion and automatic conversion from Finder renames.
- A catalog of 115 image, document, media, archive, data, font, email, and 3D formats.
- Per-format settings and saved rules for format pairs.
- Local processing with macOS frameworks and bundled conversion tools.
- Original-file recovery, conversion history, and Undo.
- Watched-folder exclusions, whole-system monitoring, and new-file content detection.
- A native SwiftUI app and an `allomer` command-line tool.

The catalog is larger than the set of routes that has full parity coverage. See the [project status](docs/project-status.md#what-works-now) for tested behavior and known limits.

## Requirements

- Apple silicon.
- macOS 14 or later.
- Xcode with the Swift 6 toolchain for development.

A released app must contain every required converter. Users must not need Homebrew, another download, or a network connection to convert files.

## Install

After the first signed release is published, Homebrew will install the app and its command-line tool:

```sh
brew install --cask ashbench/tap/allomer
```

The fully qualified name trusts only the Allomer cask under Homebrew's non-official tap policy. There is no production release yet. See [Get started](docs/getting-started.md) for the current install status, unsigned beta steps, and usage.

## Build and test

```sh
swift build
swift test
swift run allomer formats
```

Convert a file with the command-line tool:

```sh
swift run allomer convert photo.png photo.jpg
```

Some routes need native helpers under `.tools/`. Those helpers are development build inputs and are not stored in Git. Start with the [dependency guide](docs/dependencies.md). After the helpers are ready, build a local app bundle with:

```sh
python3 tools/build-app.py
python3 tools/check-app.py
```

The result is `dist/preview/Allomer.app`.

## Project map

- `Sources/ConversionCore` contains routing, converters, automatic monitoring, and recovery.
- `Sources/ConvertApp` contains app state and SwiftUI views, grouped by feature.
- `Sources/ConvertCLI` contains the command-line interface.
- `Tests` contains focused tests for the app and conversion core.
- `helpers` contains source for bundled helper programs.
- `tools` contains reproducible build and verification scripts.
- `branding` contains the original product mark, wordmark, and app icon sources.
- `docs` contains user, developer, and release documentation.

See [Architecture](docs/architecture.md) before changing routing, concurrency, file replacement, or recovery.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) for code style, test expectations, and the pull request checklist. Report security problems as described in [SECURITY.md](SECURITY.md). User-visible changes are tracked in [CHANGELOG.md](CHANGELOG.md).

Third-party versions and notices are recorded in [THIRD_PARTY.md](THIRD_PARTY.md). Allomer source is available under the [MIT License](LICENSE).
