---
title: Get started
description: Install Allomer and run a manual, automatic, or command-line conversion.
---

# Get started

Allomer requires an Apple silicon Mac with macOS 14 or later. Conversion happens on the Mac.

:::caution Release status
The Homebrew command below becomes available after the first signed and notarized release is published. There is no production release yet.
:::

## Install with Homebrew

```sh
brew install --cask ashbench/tap/allomer
```

The fully qualified name grants Homebrew trust only to the Allomer cask. It does not trust every item that AshBench might publish later. If you add the tap separately, grant the same narrow trust before installing:

```sh
brew tap ashbench/tap
brew trust --cask ashbench/tap/allomer
brew install --cask ashbench/tap/allomer
```

See Homebrew's [tap trust documentation](https://docs.brew.sh/Tap-Trust) for the scope of each trust command.

This installs `Allomer.app` in Applications and links the bundled `allomer` command into Homebrew's binary directory. It does not install separate conversion tools.

## Open an unsigned beta from a disk image

Early test builds may have an ad hoc signature while Developer ID signing and notarization are being configured. Download these builds only from the AshBench GitHub release and compare the disk image's SHA-256 value with its release manifest:

```sh
shasum -a 256 ~/Downloads/Allomer-0.1.0-beta.1.dmg
```

After dragging Allomer to Applications, macOS will block its first launch. You can try to open it once and then use **System Settings → Privacy & Security → Open Anyway**, as described in [Apple's instructions](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unidentified-developer-mh40616/mac). The terminal alternative removes quarantine from this app only:

```sh
xattr -dr com.apple.quarantine /Applications/Allomer.app
open /Applications/Allomer.app
```

Do not disable Gatekeeper for the whole Mac. A signed and notarized release will not require this step.

Launch the app from Applications or run:

```sh
open -a Allomer
```

Homebrew can update or remove the app later:

```sh
brew upgrade --cask ashbench/tap/allomer
brew uninstall --cask ashbench/tap/allomer
```

`brew uninstall --cask --zap ashbench/tap/allomer` also removes saved settings, history, and recovery data. Use `--zap` only when you no longer need Undo.

## Convert one file

1. Open Allomer and select **Manual**.
2. Drag one file into the window or select **Choose File…**.
3. Select the destination under **Convert to**.
4. Review the format settings.
5. Select **Save Converted Copy…**.

Allomer keeps the source and refuses to replace an existing destination.

## Convert after a Finder rename

1. Select **Automatic**.
2. Select **Add Watched Folder…** and choose a folder.
3. Keep **Automatic conversion** on.
4. Rename a file in that folder. For example, rename `photo.png` to `photo.jpg`.
5. Approve the conversion if **After an extension change** is set to ask first.

Subfolders are included. Review [Automatic conversion](automatic.md) before enabling whole-system watching or changing backup retention.

## Use the command line

List the formats available in the installed app:

```sh
allomer formats
```

Convert a file by giving it a new output path:

```sh
allomer convert photo.png photo.jpg
```

The destination must not exist. Run `allomer` without arguments to see the supported option-file flags.

## Build from source

Contributors need Xcode with the Swift 6 toolchain. Some routes also need the pinned helper builds described in [Dependency updates](dependencies.md).

```sh
swift build
swift test
swift run allomer formats
```

The complete local app build is documented under [Build and run](project-status.md#build-and-run).

## Next steps

- Use the [format directory](formats.md) to find settings and current limits.
- Set up rules, watched folders, and Undo in [Automatic conversion](automatic.md).
- Check known gaps under [Project status](project-status.md).
