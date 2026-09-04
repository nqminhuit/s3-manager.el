# Changelog

All notable changes to `s3-manager.el`. Dates are the release date; the design
document is `doc/SPEC.md`.

## 0.2.0 — 2026-09-04

### Added

- **Upload.** `P` uploads a local file into the prefix on screen, or a
  directory recursively after a typed `yes`. An existing key is named, with its
  size and date, and confirmed before it is replaced — `aws s3 cp` overwrites
  without asking and has no flag that would stop it.
- **`M-x s3-manager-upload-dry-run`** lists every object an upload would
  create, without creating any. Resolves symlinks exactly as the upload would.
- **Two-window Dired workflow.** `G`, `R` and `P` default to a Dired buffer
  visible in another window (honouring `dired-dwim-target`), and
  `M-x s3-manager-dired-upload` sends that buffer's marked files into the S3
  listing. One confirmation for the batch, one refresh at the end.
- **`!`** opens the error report; failures are now shown as well as recorded.
- New options: `s3-manager-transfer-timeout`, `s3-manager-display-errors`,
  `s3-manager-upload-follow-symlinks`.

### Fixed

- **Transfers were killed after 120 seconds.** The timer measured total
  duration, not idle time, so a large download died mid-flight and was reported
  as a timeout while the CLI was alive and reporting progress. This affected
  `G` and `R` in 0.1.1.
- **Four places discarded errors**: the CLI version probe, temporary directory
  cleanup, exit 130, and a failing callback. Each now leaves a report.
- The error buffer was never displayed, so a failure could pass unnoticed once
  the echo-area line was overwritten.

### Changed

- The package is now eight files instead of one. `s3-manager.el` remains the
  entry point and requires the rest; nothing about installation changes.
- Comments and docstrings cut back by about 200 lines, without touching code.

## 0.1.1 — 2026-09-03

### Fixed

- **The keymap was dead under Evil.** Evil's state maps outrank a major-mode
  map, so ten of the eleven keys were shadowed — `RET` on a bucket moved the
  cursor down instead of opening it. The map is now registered as overriding.
- **Navigation split the window.** Entering a bucket left the bucket list
  beside it, and `RET` on an object opened a second window; Dired does neither.

## 0.1.0 — 2026-09-03

First release. Profile discovery and switching, bucket and object browsing as a
filesystem, paged and cached listings, single and recursive download, single,
marked-batch and recursive delete, read-only viewing of small objects, and
structured error reporting — all asynchronous, with credentials never touched
and every command built as an argument vector rather than a shell string.
