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

From GitHub:

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
| `g r` / `C-u g r` | refresh; with `C-u`, drop every cached listing for the bucket |
| `g g` / `5 g g` | first row of the listing / line 5 |
| `C` | copy toward the other window — download, or a server-side copy into another listing |
| `c` | copy to another S3 location, server-side |
| `r` | rename, or move elsewhere in S3 |
| `P` | upload a local file, or a directory recursively |
| `m` | mark, for `C` / `c` / `r` and the downloads |
| `d` / `x` | flag for deletion; delete everything flagged |
| `u` / `U` | unmark at point / unmark everything, either kind |
| `D` | delete the object, or the prefix recursively |
| `!` | show the accumulated error reports |
| `n` / `p` / `q` | next line / previous line / bury |

**`C` downloads.** With nothing in the other window it prompts for a path; with
Dired there it uses that directory, honouring `dired-dwim-target`. A prefix
comes down recursively.

`C`, `c`, `r` and the downloads act on the marked objects, or on the entry at
point when nothing is marked — see [Marks](#marks).

Also `M-x`: `s3-manager-switch-profile`, `s3-manager-upload-dry-run`,
`s3-manager-copy-dry-run`, `s3-manager-delete-recursive-dry-run`,
`s3-manager-clear-cache`, `s3-manager-forget-profiles`,
`s3-manager-list-profiles`.

Nothing to configure for Evil; the keymap is registered as overriding, and keys
it does not bind still reach Evil.

**One exception, if you have made `m` a prefix** — `mhh`, `mcc` and the like
bound in `global-map`. A global prefix outranks even an overriding map, so `m`
waits for a second key instead of marking, silently. Measured; `doc/SPEC.md`
§18.9. One line fixes it:

```elisp
(with-eval-after-load 'evil
  (evil-define-key 'normal s3-manager-mode-map "m" #'s3-manager-mark))
```

`m` is the only key this affects — the other eighteen were checked.

### Marks

`m` marks objects; `d` flags them for deletion. Two characters, and they never
stand in for each other:

```
 prud  s3://media/videos/2026/   4 entries  2 marked, 1 flagged

       Size Modified   Name
          -        -   raw/
*   1.8 GiB 2026-09-02 clip-01.mp4
*   1.2 GiB 2026-09-02 clip-02.mp4
D   1.2 KiB 2026-09-01 notes.md
```

`x` deletes what is flagged and looks at nothing else. `C`, `c`, `r` and the
downloads act on what is marked, or on the entry at point when nothing is —
Dired's rule, so one key means both "act on these" and "act on this".

A batch asks once, not once per object: one destination, one existence check
covering all of them, one confirmation naming what would be overwritten, one
`aws` process at a time, and one summary. Marks survive a copy or a download —
the objects are still there — and are dropped by a move.

One object and several differ where it matters. `c` on one offers its key, so
it can be renamed on the way; on several it asks for a *prefix*, and each keeps
its own name. The same for a download: a filename for one, a directory for
several. And `D` is always exactly the row under the cursor — prefixes cannot
be marked, so a mark-aware `D` could only ever do `x`'s job with the other
flag.

Marks are dropped when you change prefix, and the header line counts them so
that a mark scrolled off screen is not invisible state.

### Copying within S3

`c` copies to a prompted `s3://` destination and `r` renames or moves, both
server-side — the bytes never reach your machine. The destination is offered
for editing, and what the prompt shows is what happens. A prefix goes
recursively after a typed `yes` — only ever the one at point, since a prefix
cannot be marked — and `M-x s3-manager-copy-dry-run` (with `C-u`, for a move)
lists exactly what would happen first.

Refused before anything runs: a destination equal to its source, two
overlapping prefixes, an access point ARN or alias, and a listing on another
profile. `aws s3 cp` will happily copy an object onto itself, and `aws s3 mv`
catches only some spellings of it — one dropped trailing slash turns a
recursive move into "copy every object onto itself, then delete it".

### Big transfers

Above `s3-manager-large-transfer-size`, and for any recursive download, a
transfer asks before it starts:

```
downloading s3://media/big.mp4 to ~/dl/big.mp4 (4.2 GiB)
(r) run here  (c) copy command  (q) quit
```

`c` puts the `aws` command in the kill ring and shows it, so you can paste it
into a terminal and leave it running there. It is the command that would have
run — profile, endpoint and all — because both are built from the same
argument vector.

A recursive upload or S3-to-S3 copy does not ask: it already demands a typed
`yes`, and two questions for one action is worse than none. Set the option to
`nil` to switch the offer off entirely.

### Two windows

With a Dired buffer beside a listing, `C` copies toward the other window in
both directions, and marks decide what moves at either end. With a *second S3
listing* there instead, `C` copies the marked objects into its prefix,
server-side. `P` defaults its path there too. For the Dired half, bind it
yourself:

```elisp
(keymap-set dired-mode-map "C" #'s3-manager-dired-do-copy)
```

Safe to leave bound: with no listing visible it is `dired-do-copy` unchanged.
It uploads the marked files, with one confirmation for the batch.

**Using `evil-collection`?** The line above will not fire, and neither will
`evil-define-key` — `evil-collection`'s own dired module binds `C` to
`dired-do-copy` in normal state, an Evil state map outranks a major-mode map,
and it initialises after your config. Measured; see `doc/SPEC.md` §18.7. Bind
it per buffer instead, which wins whatever the load order:

```elisp
(add-hook 'dired-mode-hook
          (lambda ()
            (evil-local-set-key 'normal "C" #'s3-manager-dired-do-copy)))
```

The symptom when the binding loses is not an error — `C` is simply
`dired-do-copy`, asking for a directory to copy into.

### Worth knowing

- **Uploads ask before replacing.** S3 overwrites silently, so `P` checks first
  and names the existing object's size and date. Run
  `M-x s3-manager-upload-dry-run` on anything with symlinks in it — they are
  followed, and the preview is what shows you that.
- **Marking follows Dired.** `d`/`x` separates flagging from executing, and `m`
  is the general mark the transfer commands read; `D` on a prefix demands a
  typed `yes`. Marks are dropped when you change prefix.
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
| `s3-manager-view-max-size` | 10 MiB | above this, `RET` suggests `C` |
| `s3-manager-large-transfer-size` | 100 MiB | above this, a transfer offers its `aws` command; `nil` never offers |
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

Sync; bucket lifecycle; ACLs; metadata; versioning; presigned URLs; recursive
listing in one buffer; uploading from a remote (TRAMP) directory.

## Development

```sh
emacs -Q --batch -L . -L test -l test/s3-manager-test.el \
      -f ert-run-tests-batch-and-exit
eask compile && eask test ert ./test/s3-manager-test.el
```

Tests need no network and no `~/.aws` — `test/fake-aws` stands in for the CLI.
Tests tagged `cli` and `evil` skip themselves when those are absent.

The package is nine layered files, each requiring only the ones below it:
`core` → `process` → `model` → `ui` → `transfer` → `view`/`delete`/`copy`, with
`s3-manager.el` as the entry point.

[`doc/SPEC.md`](doc/SPEC.md) is the design document, including an appendix of
AWS CLI behaviour that was measured rather than assumed. Release notes are
generated from the commit log, on the
[releases page](https://github.com/nqminhuit/s3-manager.el/releases).

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
