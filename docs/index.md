---
slug: /
title: Allomer
hide_title: true
description: Local file conversion for Apple Silicon Macs.
---

<p className="allomer-kicker">Allomer by AshBench</p>

# Convert files on your Mac

<p className="allomer-lead">Allomer converts files locally. Use the native app, rename a file in a watched folder, or run the command-line tool.</p>

:::caution Early development
Allomer has no public production release yet. The Homebrew path is ready for the first signed and notarized release.
:::

## Install

After the first public release, one command will install both `Allomer.app` and the `allomer` command:

```sh
brew install --cask ashbench/tap/allomer
```

Until then, contributors can [build from source](project-status.md#build-and-run).

<div className="allomer-doc-grid">
  <a className="allomer-doc-card" href="./getting-started/">
    <strong>Get started</strong>
    <span>Install Allomer and make your first conversion.</span>
  </a>
  <a className="allomer-doc-card" href="./automatic/">
    <strong>Automatic conversion</strong>
    <span>Watch folders and convert when a file extension changes.</span>
  </a>
  <a className="allomer-doc-card" href="./formats/">
    <strong>Browse formats</strong>
    <span>Find settings, limits, and checks for each format family.</span>
  </a>
  <a className="allomer-doc-card" href="./project-status/">
    <strong>Project status</strong>
    <span>See what works now and what still needs release checks.</span>
  </a>
</div>

## Three ways to convert

### Use the app

Open Allomer, select **Manual**, choose one file, select an output format, and save the converted copy. Allomer refuses to overwrite an existing file.

### Rename in Finder

Open **Automatic**, add a watched folder, and rename a file to the extension you want. For example, rename `photo.png` to `photo.jpg`. Allomer checks the file contents before it converts anything and keeps a recoverable original for Undo.

### Use the command line

```sh
allomer formats
allomer convert photo.png photo.jpg
```

The installed command uses the converters inside `Allomer.app`. It does not need a separate Homebrew formula for each codec.

## Built for local work

- Conversion runs on the Mac. Allomer does not upload source files.
- The release bundle includes the required converters and their notices.
- Automatic conversion, history, backups, and Undo use the same conversion engine as manual and command-line work.
- The target catalog contains 115 formats. Each format guide states its tested behavior and current limits.

Start with [Get started](getting-started.md), or open the [format directory](formats.md).
