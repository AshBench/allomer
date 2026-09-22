# Changelog

Notable project changes will be recorded here. Allomer has no production release yet.

## Unreleased

### Added

- Native SwiftUI app and command-line converter for Apple Silicon Macs.
- Manual conversion and watched-folder conversion after extension changes.
- Format-pair rules, per-format settings, history, recovery, and Undo.
- Local adapters for the format families documented under `docs/`.
- Reproducible helper builds, dependency records, package checks, and release checks.
- Original Allomer product mark, wordmark, menu bar mark, and macOS app icon.
- Grouped Docusaurus navigation, local documentation search, and branded light and dark themes.
- Homebrew cask generation and release publishing for the app and bundled command-line tool.

### Changed

- Grouped app and conversion sources by feature.
- Split conversion routing, execution, file operations, recovery records, and app workflows into focused files.
- Centralized persisted preference keys so settings migrations have one contract.
- Split app preferences and conversion defaults into focused Settings sidebar pages.
