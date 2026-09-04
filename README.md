# s3-manager.el

[![CI](https://github.com/nqminhuit/s3-manager.el/actions/workflows/ci.yml/badge.svg)](https://github.com/nqminhuit/s3-manager.el/actions/workflows/ci.yml)

Browse and manage objects on AWS S3 and S3-compatible services from Emacs,
through the `aws` command line client.

```
 prud  s3://media/videos/2026/   4 entries

       Size Modified   Name
          -        -   raw/
    1.8 GiB 2026-09-02 clip-01.mp4
    1.2 GiB 2026-09-02 clip-02.mp4
    1.2 KiB 2026-09-01 notes.md
```

Two properties shape the whole design:

- **Emacs never blocks.** Every AWS CLI invocation is asynchronous. A listing,
  a multi-gigabyte download, a recursive delete — none of them freeze the
  editor.
- **No unbounded work.** Prefixes are listed one page at a time with `/` as a
  delimiter, so pointing at a bucket holding millions of objects costs one
  request, not all of them.

Credentials are never read, parsed, stored or logged. The package picks a
profile by name and leaves everything else to the CLI.

## Requirements

| | |
|---|---|
| Emacs | 29.1 or newer, built with native JSON support |
| AWS CLI | **2.13.0** or newer |

The AWS CLI floor is not arbitrary: 2.13.0 is the first release that honours
`endpoint_url` in `~/.aws/config`. Older versions ignore it *silently* and send
every request to `amazonaws.com`, which is a confusing way to discover that
your MinIO endpoint was never used. The package warns if it finds one.

## Installation

Not on MELPA. Clone it and put it on your `load-path`:

```elisp
(add-to-list 'load-path "/path/to/s3-manager.el")
(require 's3-manager)
```

Or with `use-package` and a straight/elpaca-style recipe:

```elisp
(use-package s3-manager
  :vc (:url "https://github.com/nqminhuit/s3-manager.el" :rev :newest)
  :commands (s3-manager s3-manager-switch-profile))
```

## Usage

`M-x s3-manager` asks which profile to use, then lists its buckets. `RET` on a
bucket opens it; `RET` on a prefix descends into it.

| Key | Action |
|-----|--------|
| `RET` | enter a bucket or prefix; open a small object read-only |
| `^` | up one level, or back to the bucket list |
| `+` | fetch the next page of a truncated listing |
| `g` | refresh, bypassing the cache |
| `C-u g` | refresh, dropping every cached listing for this bucket |
| `P` | upload a local file, or a directory recursively |
| `G` | download the object at point |
| `R` | download everything under the prefix at point |
| `d` | mark the object at point for deletion |
| `u` / `U` | unmark at point / unmark everything |
| `x` | delete the marked objects |
| `D` | delete the object at point, or the prefix at point recursively |
| `n` / `p` | next / previous line |
| `!` | show the accumulated error reports |
| `q` | bury the buffer |

Navigation reuses the selected window, like Dired: entering a bucket, moving
between prefixes and opening an object all replace what is on screen rather
than splitting the frame. There is one buffer per profile for the bucket list
and one per bucket for browsing it, reused across every prefix inside that
bucket, so the buffer list grows with buckets visited rather than with
directories entered.

Columns are click-to-sort. Directories always sort first. Name is the last
column deliberately: `tabulated-list` does not truncate, so putting the one
unbounded field first would let a long key push the other columns out of
alignment.

### Evil users

Nothing to configure. Evil's state keymaps outrank a major-mode map, and its
normal state binds most of the keys above (`RET`, `^`, `g`, `d`, `x`, `D`, `G`,
`R`, `u`, `+`), so the package registers its keymap as overriding in every
Evil state. Keys it does not bind are left alone, so `j`, `k`, `:` and `/`
still behave as usual, and your own `evil-define-key` for
`s3-manager-mode-map` still takes precedence over the package's.

Other commands, not bound to keys:

- `M-x s3-manager-switch-profile` — pick a different profile (`C-u` re-reads the
  profile list first)
- `M-x s3-manager-upload-dry-run` — list what `P` would write, without writing
  it
- `M-x s3-manager-delete-recursive-dry-run` — list what `D` on a prefix would
  remove, without removing it
- `M-x s3-manager-clear-cache`, `M-x s3-manager-forget-profiles`
- `M-x s3-manager-list-profiles`

### Uploading

`P` asks for a local file and uploads it into the prefix you are looking at,
under the file's own name — not under whatever row point happens to be on.

S3 replaces an existing object without a word, and `aws s3 cp` has no flag that
would stop it, so the upload is preceded by a `head-object` check. If the key
already exists you are told its size and last-modified date and asked before
anything is sent. If the check itself fails — real AWS answers 403 rather than
404 for a missing key when you lack `s3:ListBucket` — the error is reported and
you are asked whether to upload anyway, because neither assuming nor refusing
would be honest.

Choosing a directory uploads it recursively, under its own name, after a typed
`yes` — the same bar as a recursive delete, because the volume is unbounded and
no per-key overwrite check is made (one probe per file would be unbounded too).
The directory's own name is written into the destination deliberately: `aws s3
cp DIR s3://bucket/prefix --recursive` drops it and scatters the contents flat
across the prefix you were looking at.

Symbolic links are followed, which is the CLI's own default — silently skipping
files you asked to upload is the worse failure — so a link to a large tree
uploads that tree, and a link beside its own target uploads the same file
twice. Set `s3-manager-upload-follow-symlinks` to nil for
`--no-follow-symlinks`.

That is what `M-x s3-manager-upload-dry-run` is for: it names every object that
would be created, before any of them are, resolving links exactly as the upload
would. Worth running once on anything you have not sent before.

### Two windows

With a Dired buffer visible in another window, `G`, `R` and `P` all default to
its directory instead of `s3-manager-download-directory` — the same thing
`dired-dwim-target` does between two Dired buffers, and it is honoured, so
setting it to nil turns this off too.

Going the other way, `M-x s3-manager-dired-upload` in a Dired buffer uploads
its marked files (or the file at point, as Dired itself does) into the S3
listing in the other window. One confirmation covers the batch, naming any keys
it would overwrite; the listing refreshes once when the last transfer lands.
The package does not touch `dired-mode-map`, so bind it yourself:

```elisp
(keymap-set dired-mode-map "U" #'s3-manager-dired-upload)
```

### When something fails

Failures are never summarised away. Every one is appended to `*S3 Manager
Error*` with the command, the exit code, and the CLI's own stderr reproduced
verbatim — the service's wording, not a paraphrase of it. The echo area gets a
one-line summary that names that buffer, and the buffer is shown as well unless
you set `s3-manager-display-errors` to nil. `!` opens it at any time.

A batch operation reports each failure individually rather than as a count, so
"deleted 7, 2 failed" is always accompanied by which two, and why.

### Deleting

`d`/`x` follows Dired: marking is separate from executing, so the destructive
step is never the key you might mistype. `D` on an *object* asks `y-or-n-p`.
`D` on a *prefix* deletes everything beneath it and demands a typed `yes` —
it is the one operation here that can destroy an unbounded amount of data.

Marks are dropped when you move to another prefix. Carried over they would be
invisible and still acted on, which would delete objects you could not see.

## S3-compatible services

Nothing about MinIO, Cloudflare R2, Wasabi or LocalStack is special-cased —
configure the endpoint per profile and the CLI does the rest:

```ini
# ~/.aws/config
[profile minio]
region = us-east-1
endpoint_url = https://minio.example.com
```

If editing the AWS config is not an option, override from Emacs instead:

```elisp
(setq s3-manager-endpoint-alist
      '(("minio" . "https://minio.example.com")))
```

## Configuration

| Variable | Default | |
|---|---|---|
| `s3-manager-aws-program` | `"aws"` | path to the CLI |
| `s3-manager-page-size` | `1000` | entries per listing request (`MaxKeys`) |
| `s3-manager-download-directory` | `"~/Downloads/"` | default download target |
| `s3-manager-view-max-size` | 10 MiB | above this, `RET` refuses and suggests `G` |
| `s3-manager-timeout` | `120` | seconds before a listing or metadata call is abandoned |
| `s3-manager-transfer-timeout` | `nil` | seconds before a *transfer* is abandoned; `nil` waits indefinitely |
| `s3-manager-cache-max-entries` | `200` | cached listings retained |
| `s3-manager-endpoint-alist` | `nil` | per-profile endpoint override |
| `s3-manager-endpoint-url` | `nil` | endpoint override for all profiles |
| `s3-manager-display-errors` | `t` | show the error report as well as recording it |
| `s3-manager-upload-follow-symlinks` | `t` | follow symlinks during a recursive upload |

The two timeouts are separate because they measure different things. A listing
that has not answered in two minutes is stuck; a transfer that has been running
for two minutes may simply be large. The timer is armed for a total duration
rather than reset by activity, so any wall-clock value would kill a healthy
transfer for being big — hence `nil`.

Listings are cached per `(profile, endpoint, bucket, prefix)`, so moving back
up a level is instant. Nothing expires on a timer — `g` is one keystroke, which
is what every other Emacs listing does.

## Not in v0.1.0

Upload, copy and move; sync; bucket creation and deletion; ACLs; metadata
editing; versioning; presigned URLs; recursive listing in one buffer; TRAMP and
Dired integration.

## Development

```sh
# no build tool needed -- files must be compiled in dependency order
emacs -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' \
      -f batch-byte-compile \
      s3-manager-core.el s3-manager-process.el s3-manager-model.el \
      s3-manager-ui.el s3-manager-transfer.el s3-manager-view.el \
      s3-manager-delete.el s3-manager.el
emacs -Q --batch -L . -L test -l test/s3-manager-test.el \
      -f ert-run-tests-batch-and-exit

# or via Eask
eask compile && eask test ert ./test/s3-manager-test.el
```

The package is one entry point over six layers, each requiring only the ones
below it:

| File | | Lines |
|---|---|---|
| `s3-manager-core.el` | options, buffer-local state, error reporting | ~460 |
| `s3-manager-process.el` | the async CLI transport, profiles | ~600 |
| `s3-manager-model.el` | entries and the listing cache | ~200 |
| `s3-manager-ui.el` | major mode, rendering, navigation, marks | ~620 |
| `s3-manager-transfer.el` | download and upload | ~460 |
| `s3-manager-view.el` | reading a small object | ~180 |
| `s3-manager-delete.el` | removing objects and prefixes | ~225 |
| `s3-manager.el` | `M-x s3-manager`, and the requires | ~115 |

The one place the layering runs backwards is the keymap: `s3-manager-ui.el`
binds commands defined in the files above it, since they operate on the buffer
it defines. Those six are `declare-function`ed rather than reordered.

Tests need no network and no `~/.aws`: `test/fake-aws` stands in for the CLI,
with its stdout, stderr, exit code and timing driven by the environment. The
few tests that shell out to a real `aws` to validate argument vectors offline
are tagged `cli` and skip themselves when it is absent; the Evil keymap tests
are tagged `evil` and skip themselves unless Evil is on the `load-path`. To
run those, put Evil there yourself:

```sh
emacs -Q --batch -L . -L test -L /path/to/evil \
      -l test/s3-manager-test.el \
      --eval '(ert-run-tests-batch-and-exit (quote (tag evil)))'
```

CI installs Evil from NonGNU ELPA and fails the step if the tests skip rather
than run -- a `skip-unless` test is worth only as much as the guarantee that
its dependency is present.

`doc/SPEC-v0.1.0.md` is the design document, including a reference appendix of
AWS CLI and Emacs subprocess behaviour that was measured rather than assumed.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
