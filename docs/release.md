---
sidebar_position: 3
---

# Cutting a release

No Allomer release has been cut yet. The local app uses an ad hoc signature. It is suitable for development on this Mac. It is not suitable for distribution.

A public release needs a Developer ID signature, Apple notarization, and stapled tickets on both the app and disk image. The release scripts keep the local preview path working when those credentials are absent.

## Release configuration

`tools/release.json` contains the product and release values used by all packaging scripts.

| Key | Purpose |
| --- | --- |
| `product_name` | App, volume, and disk image name. |
| `bundle_identifier` | App bundle identifier. |
| `disk_image_identifier` | Code-signing identifier for the disk image. |
| `version` | Semantic release version. A prerelease suffix is allowed. The numeric core becomes `CFBundleShortVersionString`. |
| `build` | Positive integer used by `CFBundleVersion`. Increase it for every distributed build. |
| `minimum_system_version` | Oldest supported macOS version. Every bundled binary must match it. |
| `copyright` | Copyright text stored in the app. |
| `signing_identity` | Full `Developer ID Application: ...` identity. `null` selects ad hoc signing. |
| `team_identifier` | Ten-character Apple team identifier. |
| `notary_keychain_profile` | Local profile created by `notarytool store-credentials`. |
| `release_url` | HTTPS page where the release and source are published. |

The scripts reject missing keys, invalid identifiers, a nonnumeric build, and partial signing configuration.

## Local preview

```sh
python3 tools/build-app.py
python3 tools/check-app.py
python3 tools/build-dmg.py
python3 tools/release.py --verify
```

The last command checks the seal, every Mach-O file, ARM64 architecture, the macOS 14 deployment target, the app metadata, and the disk image layout. It writes `dist/preview/release-manifest.json`. It reports the release checks that an ad hoc signature cannot pass.

## Inputs needed for a public release

The first public release still needs these external Apple inputs:

1. An Apple Developer Program account and a Developer ID Application certificate with its private key.
2. A notary credential stored in the login keychain.
3. A clean Apple silicon account or virtual machine for the signed-build checks in [Release checks](release-checks.md).

The release must start from a committed, clean Git revision. The final release address is already in
`tools/release.json`. The current preview contains no checkout paths. The signed release verifier
will refuse a future build if a local path appears again.

Confirm the signing identity with:

```sh
security find-identity -v -p codesigning
```

Create the notary profile once. The command prompts for an app-specific password. The password is stored in Keychain and does not enter the repository.

```sh
xcrun notarytool store-credentials allomer-notary --apple-id '<apple-id>' --team-id '<TEAMID>'
```

Then set the identity, team, profile, and release URL in `tools/release.json`.

## Public release flow

Start from the committed revision that will be tagged.

```sh
python3 tools/build-app.py
python3 tools/check-app.py
python3 tools/release.py
```

The scripts perform these steps:

1. Build every executable for ARM64 and macOS 14.
2. Sign nested code and the app with the hardened runtime and a secure timestamp.
3. Read every built binary back and verify its target and signing team.
4. Submit the app to Apple, save the response and log, and staple its ticket.
5. Build and sign the disk image from the stapled app.
6. Submit the disk image and staple its ticket.
7. Run Gatekeeper checks on the app and a quarantined copy of the disk image.
8. Mount the final image and run the packaged conversion check against the app inside it.
9. Write the release manifest and final SHA-256 digest.

The app must be stapled before it enters the image. A ticket attached only to the disk image does not follow the app when the user drags it to Applications.

The notary response and full log stay beside the artifacts in `dist/preview/`. Read the log even when Apple accepts the submission.

## Privacy and entitlements

The app has usage descriptions for Desktop, Documents, Downloads, removable volumes, and network volumes. Folder monitoring can read those locations without an Open panel, so macOS can ask for access and explain why.

The app has no entitlements file. Its code does not request JIT, unsigned executable memory, disabled library validation, or another hardened-runtime exception. Whole-system monitoring can require Full Disk Access. The user grants that access in System Settings.

## Update delivery

Allomer does not ship an update checker yet. After the first signed release establishes the GitHub release channel, add a small version check that opens that release page.

## Independent installation check

The local quarantine check is a smoke test. It cannot reproduce a browser download's full provenance record.

Use a clean Apple silicon Mac running macOS 14. Download the disk image over HTTPS. Disconnect the network. Mount it, drag Allomer to Applications, and launch it. Then run the format and Finder checks in [Release checks](release-checks.md).

## Publish the GitHub release

The first public build is `v0.1.0-beta.1`. Mark it as a GitHub prerelease. Create a draft release for tag `v<version>` and upload these files before publishing it:

- `Allomer-<version>.dmg`
- `release-manifest.json`
- The source for the exact Git revision in the manifest

Use the SHA-256 from the release manifest. The package-size report is written before the disk image ticket is attached, so it describes different bytes. Publish the release only after the uploaded names and digest match the manifest.

## Publish through Homebrew

The public install command is:

```sh
brew install --cask ashbench/tap/allomer
```

Homebrew gets this command from the `ashbench/homebrew-tap` repository and its `Casks/` directory. The fully qualified install grants trust only to this cask. Users who tap first can make that trust explicit with `brew trust --cask ashbench/tap/allomer`; the documentation does not ask them to trust the whole tap.

The `homebrew-release` environment requires owner approval. Its `HOMEBREW_TAP_DEPLOY_KEY` secret can write only to the tap repository. The workflow cannot read it until the environment approval succeeds.

Only a repository maintainer can publish a GitHub release or manually run this workflow. It does not run for pull requests, and fork workflows do not receive the environment secret. Publishing a GitHub release starts `.github/workflows/homebrew.yml`. The workflow downloads the DMG and release manifest, checks the Git revision, Developer ID signature, hardened runtime, secure timestamps, file name, and SHA-256, then generates `Casks/allomer.rb`. It runs `brew style` before it commits the cask to the tap. A preview or ad hoc build is refused.

To retry an existing release, run **Publish Homebrew cask** from GitHub Actions and enter its tag. To inspect the generated cask before publishing, run this beside a signed release manifest and DMG:

```sh
python3 tools/build-homebrew-cask.py \
  --download-url https://github.com/ashbench/allomer/releases/download/v0.1.0-beta.1/Allomer-0.1.0-beta.1.dmg
brew tap-new --no-git allomer-check/tap
mkdir -p "$(brew --repository allomer-check/tap)/Casks"
cp dist/preview/allomer.rb "$(brew --repository allomer-check/tap)/Casks/allomer.rb"
brew style --cask allomer-check/tap/allomer
```

The cask installs `Allomer.app` and links `Contents/MacOS/allomer` into Homebrew's binary directory. `brew uninstall --cask --zap ashbench/tap/allomer` also removes settings, history, and recovery files, so users should use `--zap` only when they no longer need Undo.
