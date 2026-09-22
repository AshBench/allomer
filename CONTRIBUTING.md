# Contributing to Allomer

Allomer changes file contents and keeps recovery data. A small defect can damage a user's file. Keep changes narrow, make failure explicit, and test the file operations that can fail.

## Set up the project

Use an Apple Silicon Mac with macOS 14 or later and Xcode with Swift 6.

```sh
swift package resolve
swift build
swift test
python3 tools/check-dependencies.py
```

Tool-dependent tests skip when their local helper is missing. Follow [docs/dependencies.md](docs/dependencies.md) to build a helper. Never replace a missing helper with a Homebrew runtime dependency in the app.

## Find the right place

`ConversionCore` has no dependency on the app. Put reusable conversion and recovery behavior there. Its folders match the format or responsibility they own.

`ConvertApp` owns macOS UI, app lifecycle, and observable state. Keep each view focused on one screen or reusable control. Put model behavior in an extension named for its feature when the main model would mix separate concerns.

`ConvertCLI` adapts command arguments to `ConversionCore`. It must not duplicate conversion rules.

See [docs/architecture.md](docs/architecture.md) for the full module map and invariants.

## Write maintainable code

- Use Swift 6 language rules. Fix concurrency warnings instead of suppressing them.
- Keep UI state on the main actor. Move synchronous conversion work off the main actor.
- Store task handles when work must support cancellation or orderly app shutdown.
- Check cancellation before costly work and before publishing output.
- Prefer macOS frameworks and the standard library. Add a dependency only when it owns a real format capability.
- Keep persisted key names in `PreferenceKey`. Treat a key rename as a data migration.
- Keep one clear responsibility per file. Split a file when its parts change for different reasons.
- Keep tests with the format or behavior they prove. Do not grow a catch-all conversion test file.
- Match the nearby style. Use four spaces, no tabs, LF line endings, and a final newline.
- Do not reformat unrelated code in a functional change.
- Write direct error messages that tell the user what failed and what they can do.
- Do not overwrite an existing destination or weaken the source-version checks.

The repository does not require a separate formatter. `.editorconfig` records the whitespace rules that editors can apply without changing the whole tree.

## Test a change

Add the smallest test that proves the behavior or regression. Use generated or redistributable fixtures. Do not commit personal files or files recovered from another app.

Run the focused test while developing. Run these checks before opening a pull request:

```sh
python3 tools/check-macos-runtime.py
swift test
swift build -c release --arch arm64
python3 tools/check-dependencies.py
```

GitHub Actions repeats these checks on Apple Silicon runners for macOS 14, 15, 26, and 27. The
native runtime check starts Vision behind the same restricted cache policy as the app helper. This
catches framework paths and sandbox needs that can change between macOS releases.

Run the matching script under `tools/check-*.py` for a changed converter. If packaging changed, also run:

```sh
python3 tools/build-app.py
python3 tools/check-app.py
```

For documentation changes:

```sh
cd website
npm ci --no-fund
npm run build
```

Record manual checks when macOS dialogs, Finder, notifications, login items, or menu-bar behavior are involved. Use [docs/release-checks.md](docs/release-checks.md) as the checklist.

## Change dependencies

Pin every source and record its checksum, license, build command, and notices. Update the normal manifest and lock file together. Change one component at a time. Follow [docs/dependencies.md](docs/dependencies.md) and update [THIRD_PARTY.md](THIRD_PARTY.md).

Do not copy code from an app with an incompatible license. Do not add proprietary binaries, decompiler output, recovered source, or extracted assets. Keep private compatibility research under the ignored `.research/` directory. Document externally visible behavior, then implement it from public specifications and original tests.

## Open a pull request

Explain the user-visible problem and the resulting behavior. List the commands and manual checks you ran. Call out changes to conversion output, recovery, dependencies, permissions, or performance. Update the docs and [CHANGELOG.md](CHANGELOG.md) when users will notice the change.
