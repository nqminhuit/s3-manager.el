# s3-manager.el

[![CI](https://github.com/nqminhuit/s3-manager.el/actions/workflows/ci.yml/badge.svg)](https://github.com/nqminhuit/s3-manager.el/actions/workflows/ci.yml)

Browse and manage AWS S3 and S3-compatible object storage from Emacs, through
the `aws` command line client.

```
 prud  s3://media/videos/2026/   4 entries

       Size Modified   Name
          -        -   raw/
    1.8 GiB 2026-09-02 clip-01.mp4
    1.2 GiB 2026-09-02 clip-02.mp4
    1.2 KiB 2026-09-01 notes.md
```

Emacs never blocks — every CLI call is asynchronous, including
multi-gigabyte transfers. Listings are paged with `/` as a delimiter, so
pointing at a bucket of millions of objects costs one request. Credentials are
never read, parsed, stored or logged.

## Requirements

Emacs 29.1+ with native JSON, and **AWS CLI 2.13.0+** — the first release that
honours `endpoint_url` in `~/.aws/config`. Older versions ignore it silently
and send everything to `amazonaws.com`; the package warns if it finds one.

## Installation

Not on MELPA.

```elisp
(use-package s3-manager
  :vc (:url "https://github.com/nqminhuit/s3-manager.el" :rev :newest)
  :commands (s3-manager s3-manager-switch-profile))
```

## Usage

`M-x s3-manager` asks which profile to use, then lists its buckets.

| Key | Action |
|-----|--------|
| `RET` | enter a bucket or prefix; open a small object read-only |
| `^` | up one level |
| `+` | fetch the next page of a truncated listing |
| `g` / `C-u g` | refresh; with `C-u`, drop every cached listing for the bucket |
| `C` | copy to the other window — download, recursively for a prefix |
| `P` | upload a local file, or a directory recursively |
| `G` / `R` | download the object, or the prefix recursively |
| `d` / `x` | mark for deletion; delete everything marked |
| `u` / `U` | unmark at point / unmark everything |
| `D` | delete the object, or the prefix recursively |
| `!` | show the accumulated error reports |
| `n` / `p` / `q` | next line / previous line / bury |

Also `M-x`: `s3-manager-switch-profile`, `s3-manager-upload-dry-run`,
`s3-manager-delete-recursive-dry-run`, `s3-manager-clear-cache`,
`s3-manager-forget-profiles`, `s3-manager-list-profiles`.

Nothing to configure for Evil; the keymap is registered as overriding, and keys
it does not bind still reach Evil.

### Two windows

With a Dired buffer beside a listing, `C` copies toward the other window in
both directions. `G`, `R` and `P` default their path there too, honouring
`dired-dwim-target`. For the Dired half, bind it yourself:

```elisp
(keymap-set dired-mode-map "C" #'s3-manager-dired-do-copy)
```

Safe to leave bound: with no listing visible it is `dired-do-copy` unchanged.
It uploads the marked files, with one confirmation for the batch.

### Worth knowing

- **Uploads ask before replacing.** S3 overwrites silently, so `P` checks first
  and names the existing object's size and date. Run
  `M-x s3-manager-upload-dry-run` on anything with symlinks in it — they are
  followed, and the preview is what shows you that.
- **Deleting follows Dired.** `d`/`x` separates marking from executing; `D` on
  a prefix demands a typed `yes`. Marks are dropped when you change prefix.
- **Failures are never summarised away.** Every one is appended to
  `*S3 Manager Error*` with the command and the CLI's own stderr verbatim, and
  shown unless `s3-manager-display-errors` is nil. `!` reopens it.

### S3-compatible services

Nothing is special-cased — configure the endpoint per profile:

```ini
# ~/.aws/config
[profile minio]
region = us-east-1
endpoint_url = https://minio.example.com
```

Or from Emacs, with `s3-manager-endpoint-alist` / `s3-manager-endpoint-url`.

## Configuration

| Variable | Default | |
|---|---|---|
| `s3-manager-aws-program` | `"aws"` | path to the CLI |
| `s3-manager-page-size` | `1000` | entries per listing request |
| `s3-manager-download-directory` | `"~/Downloads/"` | fallback download target |
| `s3-manager-view-max-size` | 10 MiB | above this, `RET` suggests `G` |
| `s3-manager-timeout` | `120` | seconds before a listing is abandoned |
| `s3-manager-transfer-timeout` | `nil` | same for transfers; `nil` waits |
| `s3-manager-cache-max-entries` | `200` | cached listings retained |
| `s3-manager-display-errors` | `t` | show the error report, not just record it |
| `s3-manager-upload-follow-symlinks` | `t` | follow links on recursive upload |
| `s3-manager-endpoint-alist` | `nil` | per-profile endpoint override |
| `s3-manager-endpoint-url` | `nil` | endpoint override for all profiles |

Listings are cached per `(profile, endpoint, bucket, prefix)`; nothing expires
on a timer, since `g` is one keystroke.

## Not included

Copy and move between S3 locations; sync; bucket lifecycle; ACLs; metadata;
versioning; presigned URLs; recursive listing in one buffer; uploading from a
remote (TRAMP) directory.

## Development

```sh
emacs -Q --batch -L . -L test -l test/s3-manager-test.el \
      -f ert-run-tests-batch-and-exit
eask compile && eask test ert ./test/s3-manager-test.el
```

Tests need no network and no `~/.aws` — `test/fake-aws` stands in for the CLI.
Tests tagged `cli` and `evil` skip themselves when those are absent.

The package is eight layered files, each requiring only the ones below it:
`core` → `process` → `model` → `ui` → `transfer` → `view`/`delete`, with
`s3-manager.el` as the entry point.

[`doc/SPEC.md`](doc/SPEC.md) is the design document, including an appendix of
AWS CLI behaviour that was measured rather than assumed.
[`CHANGELOG.md`](CHANGELOG.md) records what each release added.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
