# `s3-manager.el` — Specification

Status: **Describes v0.2.0.** One living document rather than one per release:
superseded decisions are marked in place, and the text as it stood for an
earlier release is recoverable from that release's tag.

> This document is written to be implemented without re-deciding anything.
> Where a plausible design was considered and rejected, it is recorded as a
> **Rejected alternative** together with the reason, so that the decision is
> not silently relitigated mid-implementation. Facts about the AWS CLI here
> were verified against `aws-cli/2.33.30` on the development machine; see §18.

---

## 1. Goals and scope

### 1.1 Goal

An Emacs interface for browsing and managing objects on AWS S3 and
S3-compatible services (MinIO, Cloudflare R2, Wasabi, LocalStack), implemented
as a thin, **non-blocking** wrapper over the `aws` CLI.

Two properties are non-negotiable, because retrofitting either is a
rewrite rather than a patch:

1. **Emacs never blocks.** No operation, however slow, freezes the editor.
2. **No unbounded work.** No code path can be made to load an entire bucket
   into memory by a user who navigates into the wrong prefix.

### 1.2 In scope

- Discover and select AWS CLI profiles.
- Per-profile endpoint support for S3-compatible services.
- List buckets.
- Browse objects as a filesystem-like tree (`--prefix` + `--delimiter /`).
- Paginated listing with an explicit "load more".
- Download a single object.
- Download a prefix recursively.
- Delete a single object.
- Delete marked objects in a batch (Dired semantics).
- Delete a prefix recursively.
- View a small object in a read-only buffer.
- Structured error reporting that preserves the CLI's own stderr.

### 1.3 Explicitly out of scope

Sync; multipart tuning; bucket creation/deletion; ACL; object metadata editing;
versioning; presigned URLs; a native AWS SDK; a job queue; recursive listing in
the UI; TRAMP sources.

Shipped since v0.1.0, and no longer out of scope: **upload** (§11.8), **Dired
interoperability** (§11.9), and **copy and move between S3 locations**
(§11.10).

§17 records which of the remainder have seams left for them and which do not.

---

## 2. Runtime requirements

```
Emacs     >= 29.1
AWS CLI   >= 2.13.0
```

**Emacs 29.1** for `defvar-keymap`, `setopt`, and a stable
`json-parse-buffer`. (Verified present on the dev machine, Emacs 31.1:
`json-parse-buffer`, `cl-lib`, `tabulated-list`.)

**AWS CLI 2.13.0**, not merely "2.x". The `endpoint_url`
key in `~/.aws/config` (§7.3) and the `AWS_ENDPOINT_URL` environment variable
were introduced in CLI 2.13.0. On 2.0–2.12 the package still works, but
config-file endpoints are silently ignored by the CLI, which produces the
confusing symptom of every request going to `amazonaws.com`. The package must
therefore refuse to run below 2.13.0 rather than let the user debug that.

### 2.1 Emacs library requirements

```elisp
(require 'cl-lib)          ; cl-defstruct
(require 'tabulated-list)
(require 'subr-x)
(require 'seq)
```

`(require 'json)` is deliberately **absent**. `json-parse-buffer` is a native C
function, not part of `json.el`; requiring `json.el` pulls in the slow Lisp
implementation the package never calls.

Because native JSON was an **optional** build feature in Emacs 29 (it became
mandatory in Emacs 30), gate it at load time rather than failing mysteriously
inside a sentinel:

```elisp
(unless (and (fboundp 'json-parse-buffer) (json-available-p))
  (error "s3-manager requires an Emacs built with native JSON support"))
```

Do not write a `json.el` fallback: it is far slower, and it would mean
maintaining two parsers for a configuration Emacs 30 has already eliminated.

No third-party dependencies (`dash`, `s`, `transient`, `magit`).

### 2.2 Startup checks

```elisp
(defcustom s3-manager-aws-program "aws"
  "Path to the AWS CLI executable."
  :type 'file :group 's3-manager)
```

On the first invocation of `s3-manager` in a session, and never again:

1. `(executable-find s3-manager-aws-program)` — if nil:

   ```
   S3 Manager: AWS CLI executable not found ("aws").
   Install AWS CLI v2, or set `s3-manager-aws-program'.
   ```

2. **[CORRECTED]** Confirm the version **asynchronously**. An earlier version
   of this section called `aws --version` synchronously, on the grounds that it
   is "local, sub-100ms, and everything depends on its result". Two of those
   three are false: it was measured at **0.554s** — it is Python interpreter
   startup, not a local file read — and it runs on the very first keystroke of
   a session, so paying it synchronously breaks the one promise the package
   makes. `executable-find` (0.00007s) covers the common failure of the CLI not
   being installed; the version becomes a background `display-warning` rather
   than a refusal, which is proportionate given the only consequence of an
   older CLI is that config-file endpoints are ignored. Output format is a
   single line:

   ```
   aws-cli/2.33.30 Python/3.13.11 Linux/7.0.0-30-generic exe/x86_64.ubuntu.24
   ```

   Parse with `"\\`aws-cli/\\([0-9]+\\)\\.\\([0-9]+\\)\\.\\([0-9]+\\)"`. Compare
   against 2.13.0 using `version<`. Cache the result in
   `s3-manager--cli-version` so the check runs once per session.

---

## 3. Architecture

Three layers, strictly separated. Each layer may only call downward.

```
┌─────────────────────────────────────────────────────┐
│  UI          s3-manager-mode (tabulated-list-mode)  │
│              commands, keymap, marks, rendering     │
├─────────────────────────────────────────────────────┤
│  Model       s3-manager-entry / s3-manager-page     │
│              JSON → structs, cache, pagination      │
├─────────────────────────────────────────────────────┤
│  Transport   s3-manager--aws-async                  │
│              argv → make-process → JSON | error     │
└─────────────────────────────────────────────────────┘
```

The value of this split is testability: the entire Model and UI layer is
exercised in tests by replacing exactly one function (§15).

---

## 4. Transport layer

### 4.1 The primitive

Every interaction with the CLI goes through one function. There are no
exceptions other than the `--version` check in §2.2.

```elisp
(cl-defun s3-manager--aws-async (args &key on-success on-error name parse)
  "Run the AWS CLI asynchronously with ARGS, a list of strings.

ARGS are passed as an argument vector — never through a shell.
ARGS is the *service* invocation only, e.g. ("s3api" "list-buckets");
the global flags for PROFILE are prepended by this function, not by
the caller.  See §11.1 for why.

On exit code 0, call ON-SUCCESS with the parsed stdout: an alist when
PARSE is non-nil (the default), or the raw string when PARSE is nil.

On any non-zero exit code, call ON-ERROR with a plist:
  (:argv ARGV :exit-code N :stderr STRING :stdout STRING)

Return the process object, so the caller can cancel it."
  ...)
```

### 4.2 Process construction

```elisp
(let ((default-directory (s3-manager--safe-directory))   ; §4.5
      (process-environment (append '("AWS_PAGER="
                                     "AWS_CLI_AUTO_PROMPT=off")
                                   process-environment)))
  (make-process
   :name (or name "s3-manager")
   :command (cons s3-manager-aws-program args)
   :buffer stdout-buffer
   :stderr stderr-pipe                  ; a process, never a buffer — §4.3
   :connection-type 'pipe
   :noquery t
   :coding '(utf-8-unix . utf-8-unix)
   :sentinel #'...))
```

Notes on each choice:

- **`:connection-type 'pipe`** — a pty would mangle output (line-length
  wrapping, echo) and would make the CLI think it is interactive.
- **`:noquery t`** — an in-flight listing must not block `C-x C-c`.
- **`:coding '(utf-8-unix . utf-8-unix)`** — S3 keys may contain any UTF-8. The
  explicit `-unix` prevents CRLF translation from corrupting the JSON.
- **`AWS_PAGER=`** — CLI v2 pipes output through a pager when it detects a
  terminal. It should not detect one here, but an explicitly empty `AWS_PAGER`
  removes the failure mode entirely. `--no-cli-pager` is also passed (§11.1) as
  belt and braces.

### 4.3 Separating stdout and stderr — the pitfall

§12 requires that the CLI's stderr be preserved verbatim, which means stdout
and stderr must not be interleaved: a single byte of a CLI warning landing in
the stdout buffer breaks `json-parse-buffer`.

There are **two** independent traps here, both verified on this machine.

**Trap 1 — passing a buffer to `:stderr` corrupts the stderr text.**
`make-process` responds by creating an implicit pipe process carrying
`internal-default-process-sentinel`, which **inserts its own status line into
your stderr buffer**. Measured, for a subprocess writing exactly `err1`:

```
stderr buffer contents = "err1\n\nProcess NAME stderr finished\n"
```

A bare `make-pipe-process` with no `:sentinel` fails identically — the default
sentinel is the problem, not the implicitness. **The pipe process must be
created explicitly and given an explicit `:sentinel`.**

**Trap 2 — sentinel ordering is nondeterministic.** The main process's sentinel
and the stderr pipe's sentinel fire in either order, run to run, for identical
code. A naive implementation that dispatches from the main sentinel reports an
*empty* stderr for exactly the failures stderr exists to report.

**Required pattern** — explicit pipe, explicit sentinels, and a two-flag barrier
so dispatch happens only once both have finished:

```elisp
(let* ((stdout-buf (generate-new-buffer " *s3-aws-out*" t))
       (stderr-buf (generate-new-buffer " *s3-aws-err*" t))
       (exit-code nil) (main-done nil) (err-done nil))
  (cl-labels
      ((finish ()
         (when (and main-done err-done)
           ;; dispatch to on-success / on-error, then kill both buffers
           ...)))
    (let ((stderr-proc
           (make-pipe-process
            :name " *s3-aws-err*"
            :buffer stderr-buf
            :noquery t
            :coding 'utf-8-unix          ; MANDATORY — see §9.5
            :sentinel (lambda (p _event)
                        (when (memq (process-status p)
                                    '(closed failed exit signal))
                          (setq err-done t) (finish))))))
      ...)))
```

`:coding 'utf-8-unix` on the **pipe process specifically** is not optional and
is not inherited from the main process — the pipe is a separate process with its
own coding system. §9.5 explains what breaks without it.

`(delete-process MAIN)` also closes the stderr pipe and fires its sentinel, so
cancellation needs no separate pipe teardown — but it does **not** kill either
scratch buffer.

The `finish` closure must kill both temporary buffers exactly once. Leaking
these buffers is the most likely resource bug in this package; the ERT suite
asserts on buffer count around a stubbed request (§15).

Buffer names begin with a space so they never appear in the buffer list, and are
created with `INHIBIT-BUFFER-HOOKS` (`t` as the second argument to
`generate-new-buffer`) so no mode hooks or fontification run on multi-megabyte
JSON.

### 4.4 Parsing

```elisp
(defun s3-manager--parse-json (buf)
  "Parse BUF as the JSON payload of one aws invocation."
  (with-current-buffer buf
    (goto-char (point-min))
    (if (looking-at-p "\\`[ \t\n\r]*\\'")
        nil                              ; empty stdout == empty result
      (json-parse-buffer :object-type 'alist
                         :array-type  'list
                         :null-object nil
                         :false-object nil))))
```

**The empty-stdout guard is required, not defensive.** `aws s3api
list-objects-v2` prints *nothing at all* for a prefix with no matches, and
`json-parse-buffer` on an empty buffer signals `(json-end-of-file 1 nil 0)`
(verified). Without the guard, every empty directory in the browser raises an
error.

Rationale for the parse options: alists with symbol keys read naturally via
`alist-get`, and mapping both JSON `null` and `false` to `nil` means an absent
`Contents` key, a `null`, and an empty array behave identically at every call
site. Every optional field in this response (`Contents`, `CommonPrefixes`,
`NextToken` — all of which are *absent*, not empty, when they do not apply;
see §11.3.1) has "false", "null" and "missing" as the same business meaning, so
collapsing them removes guard clauses rather than hiding information. Payloads are bounded by
`--max-items` (§5), so alists cost nothing against hash tables at ~6 keys.

A parse failure is itself an error and must be reported through `on-error` with
a synthetic exit code, not signalled from the sentinel — a signal thrown inside
a process sentinel is swallowed by Emacs and produces a silent hang.

### 4.5 TRAMP safety and `default-directory`

**Rejected alternative: `process-file`.** `process-file` and
`start-file-process` are TRAMP-aware: called from a buffer whose
`default-directory` is remote, they run `aws` **on the remote host**, with that
host's `~/.aws` and that host's credentials. Since S3 buffers are not file
buffers, their `default-directory` is inherited from whatever buffer the user
invoked the command from — so `M-x s3-manager` while visiting a file over TRAMP
would silently use a different machine's credentials.

`make-process` is **not** TRAMP-aware: it consults a file-name handler only when
passed `:file-handler t` (verified — the parameter is documented in its
docstring). Using `make-process` and never passing `:file-handler` is therefore
sufficient to guarantee local execution.

Binding `default-directory` is still required, but for two *different* reasons
than TRAMP redirection — both verified:

| `default-directory` at call time | Behavior of `make-process` |
|---|---|
| a remote path (`/ssh:host:/tmp/`) | no error; the subprocess silently runs in `$HOME` |
| a deleted directory | signals `(file-missing "Setting current directory" …)` |

The first matters because `aws s3 cp` destinations are often relative — a
download would land somewhere the user did not expect. The second turns a
routine listing into a crash whenever the user's current buffer visits a
directory that has since been removed.

```elisp
(defun s3-manager--safe-directory ()
  "A guaranteed-local, guaranteed-existing directory for subprocesses."
  (if (and default-directory
           (not (file-remote-p default-directory))
           (file-accessible-directory-p default-directory))
      default-directory
    (expand-file-name "~/")))
```

Bind it around **both** `make-process` and `make-pipe-process`. `~/` rather than
`temporary-file-directory`, because a relative download landing in `$HOME` is
recoverable and one landing in `/tmp` may be silently garbage-collected.

### 4.6 Cancellation and stale responses

A user pressing `RET RET RET` through three directories starts three listings.
Without discipline, the first response to arrive wins and renders the wrong
prefix.

Each S3 buffer carries a monotonically increasing generation counter:

```elisp
(defvar-local s3-manager--generation 0)
(defvar-local s3-manager--process nil)
```

`s3-manager--start-request` performs, in this order:

1. If `s3-manager--process` is live: `(set-process-sentinel proc #'ignore)` then
   `(delete-process proc)`. Detaching the sentinel *first* is essential —
   otherwise killing the process invokes the error path and pops up an error
   buffer for a request the user deliberately abandoned. (Verified: with the
   sentinel replaced, `delete-process` fires no callback; without, it fires with
   event `"killed"`.)
2. `(cl-incf s3-manager--generation)`.
3. Start the new process, capturing `buffer` and the current `generation` in the
   callback closure.
4. Store the process in `s3-manager--process`.

Every callback begins with the same guard, and does nothing if it fails:

```elisp
(and (buffer-live-p buf)
     (= gen (buffer-local-value 's3-manager--generation buf)))
```

The generation counter is not redundant with process-killing. Between the
completion of page *N* and the launch of page *N+1* (§5.3), there is a moment
with **no live process to kill** — `s3-manager--process` is `nil`. Only the
generation check inside the page-*N* callback stops it from scheduling a
continuation for a prefix the user has already navigated away from. Sentinel
detachment is the optimization; the counter is the correctness mechanism.

#### 4.6.1 Transfers are deliberately *not* cancellable this way

`s3-manager--process` and `s3-manager--start-request` govern **listings only**.
A `s3 cp` download registers no entry there and is never cancelled by
navigation: aborting a 4 GB download because the user pressed `^` would be
indefensible. This asymmetry is intentional and must be commented in the source.

A transfer captures its origin buffer for progress reporting but **passes no
generation**. An earlier draft of this section had the generation guard stop
progress once the buffer moved on; that is wrong. The mode-line indicator
describes the *transfer*, not the listing, and a download that keeps running
while the user browses elsewhere in the same bucket should keep reporting —
otherwise the feedback disappears for the entire remainder of a long transfer.
Killing the buffer still stops it, via the `buffer-live-p` half of the guard.

Concurrent transfers are **counted**, not flagged, so that one finishing does
not clear an indicator another still needs.

Progress lines are condensed before display: the CLI emits
`Completed 70.5 KiB/70.5 KiB (558.5 KiB/s) with 1 file(s) remaining`, which is
far wider than a mode line, so the transferred amount and rate are extracted
and anything unrecognised is truncated.

`(add-hook 'kill-buffer-hook #'s3-manager--cancel nil t)` in the mode body kills
any in-flight *listing* when the buffer dies — without it, `:noquery t` means an
orphaned `aws` will not even prompt at Emacs exit.

### 4.6 Cancellation and stale responses

A user pressing `RET RET RET` through three directories starts three listings.
Without discipline, the first response to arrive wins and renders the wrong
prefix.

Each S3 buffer carries a monotonically increasing generation counter:

```elisp
(defvar-local s3-manager--generation 0)
(defvar-local s3-manager--process nil)
```

`s3-manager--start-request` performs, in this order:

1. If `s3-manager--process` is live: `(set-process-sentinel proc #'ignore)` then
   `(delete-process proc)`. Detaching the sentinel *first* is essential —
   otherwise killing the process invokes the error path and pops up an error
   buffer for a request the user deliberately abandoned.
2. `(cl-incf s3-manager--generation)`.
3. Start the new process, capturing `buffer` and the current `generation` in the
   callback closure.
4. Store the process in `s3-manager--process`.

Every callback begins with the same guard, and does nothing if it fails:

```elisp
(and (buffer-live-p buf)
     (= gen (buffer-local-value 's3-manager--generation buf)))
```

---

## 5. Pagination and caching

### 5.1 Why the CLI's own pagination cannot be relied on

**Rejected alternative: no pagination logic at all.** It is tempting to reason
that because the CLI paginates internally, the package needs none of its own —
omit `--no-paginate` and take whatever single JSON document comes back.

That is exactly the problem. The CLI's default behaviour is to fetch *every*
page and emit **one aggregated JSON document**. For a prefix with 400,000 keys
that is a multi-minute wall of API calls followed by a several-hundred-megabyte
parse, with no output at all until it finishes. `--delimiter /` reduces but does
not bound this: a bucket whose keys are flat under one prefix returns all of
them.

Treating pagination as someone else's problem is the single most expensive
decision available here.

### 5.2 The mechanism (verified)

`aws s3api list-objects-v2 --help` documents:

> `--max-items` … `NextToken` is provided in the command's output. To resume
> pagination, provide the `NextToken` value in the `--starting-token` argument
> of a subsequent command.

So:

- `--max-items N` caps how many items the CLI returns to us, and makes it
  synthesize a **`NextToken`** key in the output when more remain.
- `--starting-token TOKEN` resumes from there.
- `--page-size N` controls the underlying per-API-call size (a network tuning
  knob), independently of `--max-items`.

Note the key is `NextToken` — the CLI's own synthesized cursor. It is **not**
`NextContinuationToken`, which is the raw S3 API field and must not be used with
`--starting-token`.

### 5.3 Policy

```elisp
(defcustom s3-manager-page-size 1000
  "Number of entries fetched per listing request."
  :type 'integer :group 's3-manager)
```

**[CORRECTED — supersedes the `--max-items` design below]** Listings use the
raw S3 API, not the CLI's own paging:

```
--no-paginate --max-keys N [--continuation-token TOKEN]
```

`--max-keys` is S3's own `MaxKeys`, which counts **objects and prefixes
together**, and `NextContinuationToken` resumes losslessly.

#### 5.3.1 Why the documented flags cannot be used: they drop directories

`--max-items` truncates on the *primary* result key only (`Contents`). A
listing cut by it reports **zero `CommonPrefixes`**, and resuming never
recovers them — so every directory silently vanishes from a paginated
listing. Measured against a prefix holding three objects and one sub-prefix:

| Invocation | objects | prefixes | more? |
|---|---|---|---|
| no paging flags | 3 | `videos/` | no |
| `--max-items 2 --page-size 2` | 2 | **none** | yes |
| `--max-items 3 --page-size 3` | 3 | **none** | yes |
| `--max-items 4 --page-size 4` | 3 | `videos/` | no |
| `--no-paginate --max-keys 2` | 2 | none | yes |
| … `--continuation-token` | 1 | **`videos/`** | no |

Following the `--max-items 3` token returned nothing further: `videos/` was
lost permanently. The raw form returned all four entries across two pages.

This reverses an earlier version of this section, which had the two flags kept
equal to avoid a *quadratic* resume. That reasoning was correct as far as it
went — a page-boundary cut does yield a clean server-side cursor — but it
addressed cost, not correctness, and missed that the aggregation discards
prefixes outright. Losing directories is far worse than re-fetching.

**`--max-keys` and `--continuation-token` are undocumented** — absent from both
the synopsis and the options list — and work through the CLI's "a manual
pagination argument forces `--no-paginate`" path. That is a real maintenance
risk, accepted deliberately: they map one-to-one onto the stable `MaxKeys` and
`ContinuationToken` REST parameters, and the documented alternative is wrong.
They are mutually exclusive with `--max-items` (hard error, exit 252).

Because `--no-paginate` returns the raw response, `IsTruncated`, `KeyCount`,
`Name` and `MaxKeys` **are** present — unlike in the aggregated mode described
in §11.3.1.

The first page renders immediately. If the response contains
`NextToken`, the buffer stores it and the footer shows:

```
  [ 1000 shown — press + to load more ]
```

`+` (`s3-manager-load-more`) issues the same request with `--starting-token` and
**appends** to `s3-manager--entries`, preserving point.

`s3 cp --recursive` and `s3 rm --recursive` are exempt: those are single CLI
invocations that stream internally and never materialize a listing in Emacs.

### 5.4 Cache

```elisp
(defvar s3-manager--listing-cache (make-hash-table :test #'equal)
  "Maps (PROFILE BUCKET PREFIX) to a `s3-manager-page'.")
```

Global rather than buffer-local, so that navigating down and back up with `^`
is instant, and so two buffers on the same bucket share work.

Invalidation is **explicit only — no TTL**:

| Event | Invalidates |
|---|---|
| `g` (`s3-manager-refresh`) | the current `(profile bucket prefix)` key |
| single or batch delete | the prefix the deleted keys lived in |
| recursive delete of `P` | every key whose prefix is `P` or starts with `P` |
| `s3-manager-switch-profile` | every key for the old profile |

A TTL would mean the UI silently disagrees with itself depending on wall-clock
time. Explicit `g` is the Emacs convention (`dired`, `magit`, `package-menu`)
and is what users expect.

Cached pages store the accumulated entries *and* the `NextToken`, so returning
to a partially-loaded prefix resumes rather than restarts.

**Implementation note.** Recursive invalidation must collect keys first and
delete afterwards — `remhash` during `maphash` is not documented as safe:

```elisp
(let (doomed)
  (maphash (lambda (k _v)
             (when (and (equal (nth 0 k) profile)
                        (equal (nth 1 k) bucket)
                        (string-prefix-p prefix (nth 2 k)))
               (push k doomed)))
           s3-manager--listing-cache)
  (mapc (lambda (k) (remhash k s3-manager--listing-cache)) doomed))
```

The cache key must include the **resolved endpoint**, not just the profile: the
same bucket name on MinIO and on AWS is two different buckets, and conflating
them is a correctness bug specifically for the S3-compatible use case this
package exists to serve. The key is therefore
`(PROFILE ENDPOINT BUCKET PREFIX)`.

Cap the table (`s3-manager-cache-max-entries`, default 200, evicting the oldest
on insert) so a deep tree walk cannot retain listings indefinitely.

---

## 6. Data model

```elisp
(cl-defstruct (s3-manager-entry (:constructor s3-manager-entry--create)
                                (:copier nil))
  "An immutable S3 listing row.

IMPORTANT: this struct is used directly as a `tabulated-list' entry ID
and is compared with `equal', which on records is STRUCTURAL, not
identity-based.  Every slot must be a pure function of the S3 response.
Never add mutable state — marks, download progress, fetch timestamps —
because mutating any slot changes the entry's identity and silently
breaks point restoration across revert."
  type            ; `directory' or `object'
  key             ; full S3 key. For a directory, the CommonPrefix, e.g. "videos/2026/"
  display-name    ; key with the parent prefix stripped, e.g. "2026/" or "movie.mp4"
  size            ; integer bytes, or nil for a directory
  last-modified   ; ISO-8601 string, or nil for a directory
  storage-class)  ; string, or nil

(cl-defstruct (s3-manager-page (:copier nil))
  entries         ; list of s3-manager-entry
  next-token      ; string or nil
  truncated)      ; boolean
```

### 6.1 JSON → entries

From a `list-objects-v2` response:

- Each element of `CommonPrefixes` → an entry with `type` `directory`, `key` =
  its `Prefix`, `display-name` = `Prefix` with the request prefix stripped
  (trailing `/` retained).
- Each element of `Contents` → an entry with `type` `object`, `key` = `Key`,
  `size` = `Size`, `last-modified` = `LastModified`, `storage-class` =
  `StorageClass`.

**Required filter.** When a zero-byte "directory marker" object exists (created
by the S3 console and by many S3-compatible servers), `Contents` includes an
entry whose `Key` is exactly equal to the request prefix. It must be dropped, or
every directory displays a phantom empty-named file inside itself:

```elisp
(seq-remove (lambda (c) (equal (alist-get 'Key c) prefix)) contents)
```

Directories sort before objects by default, regardless of the active sort
column, matching Dired.

---

## 7. Profiles and endpoints

### 7.1 Discovery

```
aws configure list-profiles
```

Newline-separated profile names on stdout, exit 0. (Verified.) The result is
cached in `s3-manager--profiles` for the session; `s3-manager-switch-profile`
with a prefix argument re-reads it.

If the command exits non-zero, or returns nothing, report:

```
S3 Manager: no AWS profiles found. Run `aws configure' first.
```

### 7.2 Selection

```elisp
(completing-read "S3 profile (missing one? M-x s3-manager-forget-profiles): "
                 profiles nil t nil
                 's3-manager--profile-history
                 (car s3-manager--profile-history))
```

A history variable is used so that repeat invocations default sensibly, and the
most recent choice is the default, so re-selecting is a single `RET`.

The prompt names `s3-manager-forget-profiles` because the list is cached for
the session: a profile added to `~/.aws/config` after the first discovery is
not in it, and the prompt is the one place the absence is noticed.

**The prompt must not run inside a process sentinel.** Discovery is
asynchronous, so the naive arrangement — prompt from the `on-success`
callback — calls `completing-read` from a sentinel, which reenters the
minibuffer at an arbitrary point in whatever Emacs was doing. Discovery
therefore hands control back through `run-at-time 0` before invoking its
callbacks:

```elisp
(defun s3-manager--with-profiles (callback)
  "Call CALLBACK with the list of AWS profile names.
CALLBACK runs immediately when the list is known, and otherwise from a
timer once the CLI has answered — never from the sentinel, so it is safe
for it to prompt."
  ...)
```

Two consequences worth stating, because both are load-bearing:

- **The cached path is synchronous.** When the profile list is already known,
  `callback` runs in the caller's own dynamic extent, so the common case is an
  ordinary interactive prompt with no deferral at all.
- **Concurrent lookups share one subprocess.** Callbacks arriving while a
  discovery is in flight are queued. Without this, two quick invocations
  produce two `aws` processes and two stacked minibuffer prompts.

Note that `inhibit-quit` cannot be used to detect "am I in a sentinel" — it is
`t` inside timers as well. Testing this property requires observing the
resolver's own dynamic extent.

An empty profile list is a legitimate success (§18.5), reported as guidance
rather than an error, and deliberately **not** cached: the remedy is to run
`aws configure`, and the next attempt should see that it was run.

### 7.3 Endpoints

Preferred configuration is per-profile, in `~/.aws/config` — the package does
not need to know what MinIO or R2 are:

```ini
[profile minio]
region = us-east-1
endpoint_url = https://minio.example.com
```

This requires CLI >= 2.13.0 (§2). An Emacs-side override exists for cases where
editing the AWS config is not possible:

```elisp
(defcustom s3-manager-endpoint-url nil
  "Endpoint URL to pass to every AWS CLI invocation.
When nil, the endpoint configured for the profile is used."
  :type '(choice (const :tag "Use profile configuration" nil) string)
  :group 's3-manager)

(defcustom s3-manager-endpoint-alist nil
  "Alist mapping profile name to endpoint URL.
Takes precedence over `s3-manager-endpoint-url' for matching profiles."
  :type '(alist :key-type string :value-type string)
  :group 's3-manager)
```

Resolution order, highest first: `s3-manager-endpoint-alist` entry for the
current profile → `s3-manager-endpoint-url` → nothing (defer to the CLI). When
a value is resolved, `--endpoint-url VALUE` is appended to the base arguments.

---

## 8. Buffers and navigation

### 8.1 Buffer model

**Rejected alternative: one buffer per prefix**, named
`*s3:production:media:videos/2026/*`. It is the obvious Dired-shaped choice and
appears to give history and caching for free. It yields dozens of buffers after
a few minutes of browsing and buries the buffer list. Dired survives this
because filesystem trees are shallow and users visit tens of directories; an S3
bucket keyed `year=2026/month=03/day=17/hour=09/` is five buffers deep to reach
one object.

**One buffer per `(profile, bucket)`**, reused across prefixes within that
bucket, plus one buffer per profile for the bucket list:

```
*s3: production*                 ← bucket list
*s3: production/media*           ← object browser, any prefix within `media'
*s3: staging/backups*
```

The current prefix lives in the header line, not the buffer name. This bounds
buffer count by buckets visited rather than prefixes visited, still permits
several concurrent sessions, and keeps `^` under explicit control.

**Navigation displays in the selected window** -- `pop-to-buffer-same-window`,
never `pop-to-buffer`. [CORRECTED] The first implementation used
`pop-to-buffer`, which splits a single-window frame: entering a bucket left
the bucket list on screen beside it, and `RET` on an object opened the copy in
a second window. Dired does neither. Since `RET` is one key for descending and
for viewing, both must display the same way, so the view buffer follows the
same rule.

### 8.2 Buffer-local state

```elisp
(defvar-local s3-manager--profile   nil)  ; string
(defvar-local s3-manager--bucket    nil)  ; string, nil in a bucket-list buffer
(defvar-local s3-manager--prefix    "")   ; "" at bucket root, else ends in "/"
(defvar-local s3-manager--entries   nil)  ; list of s3-manager-entry
(defvar-local s3-manager--next-token nil) ; string or nil
(defvar-local s3-manager--marks     nil)  ; hash-table, key string -> t
(defvar-local s3-manager--history   nil)  ; list of (PREFIX . KEY-AT-POINT)
(defvar-local s3-manager--status    'ready) ; `loading' | `ready' | `error'
(defvar-local s3-manager--generation 0)
(defvar-local s3-manager--process   nil)
(defvar-local s3-manager--transfer-status nil) ; string for mode-line-process
```

### 8.3 History and `^`

Descending into a directory pushes `(current-prefix . key-of-entry-at-point)`
onto `s3-manager--history`. `^` pops it, restores the prefix, and moves point to
the entry whose key matches the recorded one — restoring by **key rather than by
line number**, so it still lands correctly if the listing changed underneath.

At the bucket root, `^` returns to the bucket-list buffer.

### 8.4 Header line

```
s3://media/videos/2026/                     production      1000 shown  +more
```

Showing profile, bucket, prefix, count, and whether more pages exist.

---

## 9. `s3-manager-mode`

```elisp
(define-derived-mode s3-manager-mode tabulated-list-mode "S3"
  "Major mode for browsing S3 objects."
  (setq tabulated-list-format
        [("Name"     48 t)
         ("Size"     10 s3-manager--sort-by-size :right-align t)
         ("Modified" 20 t)])
  (setq tabulated-list-padding 2)          ; mark column, as in package-menu
  (setq tabulated-list-sort-key '("Name" . nil))
  (setq-local revert-buffer-function #'s3-manager--revert)
  (setq-local mode-line-process '(s3-manager--transfer-status
                                  ("[" s3-manager--transfer-status "]")))
  (add-hook 'kill-buffer-hook #'s3-manager--cancel nil t)
  (tabulated-list-init-header))
```

`revert-buffer-function` must be set **in the mode body**, after
`define-derived-mode` has run the parent's setup: `tabulated-list-mode`
installs the synchronous `tabulated-list-revert`, which would repaint the stale
list and never fetch. The replacement takes three arguments
(`ignore-auto`, `noconfirm`, `preserve-modes`) even though it uses none — some
callers pass all three.

`tabulated-list-init-header` must be called after `tabulated-list-format` is
set, and again if the format is ever mutated.

### 9.0 Column order: the variable-width field goes last

`tabulated-list` pads columns but never truncates them, so a value wider than
its column pushes every column after it out of alignment. Names are the only
unbounded field here — S3 keys are routinely long and bucket names run to 63
characters — so Name is the **last** column in both layouts:

```
       Size Modified   Name
    92 MiB 2026-09-03  20260809_095247.mp4
   110 MiB 2026-09-03  TheWisdomOfFatherBrown.TheDuelOfDrHirsch.final.mp4
   2.8 MiB 2026-09-02  a.png
```

An overlong name can then only run off the right-hand end, which costs nothing.
Truncating instead was rejected: the tail of a key is usually the part that
distinguishes it from its neighbours.

An earlier version of this section put Name first, matching how the columns
read aloud. Measured against a real prefix, names of 45–53 characters shifted
the Size column by up to nine places from row to row.

### 9.1 Type indication

**Rejected alternative: a `Type` column holding `DIR`/`FILE`.** It spends eight
columns of a width-constrained table to encode one bit. Instead, directories are rendered with a trailing `/`
and the `s3-manager-directory` face (inheriting `dired-directory`), exactly as
Dired does. Size and Modified render as `-` for directories.

### 9.2 Entry IDs

The `ID` of each `tabulated-list-entries` element is **the `s3-manager-entry`
struct itself**. This makes `s3-manager--entry-at-point` a one-liner over
`tabulated-list-get-id` with no key-to-struct lookup table, and lets sorters
compare typed fields rather than reparse formatted strings:

```elisp
(defun s3-manager--sort-by-size (a b)
  "Sort entries A and B by size; directories sort first."
  (let ((sa (s3-manager-entry-size (car a)))
        (sb (s3-manager-entry-size (car b))))
    (cond ((and (null sa) (null sb)) nil)
          ((null sa) t)
          ((null sb) nil)
          (t (< sa sb)))))
```

A sorter is *required* for Size: the displayed value is a human-readable string
(`1.2 KB`, `1.8 GB`) and the default lexicographic sort on it is meaningless.

### 9.3 Marks

`tabulated-list-padding` of 2 reserves the left margin; marks are written with
`tabulated-list-put-tag`. The authoritative record is `s3-manager--marks` (a
hash table keyed by S3 key), so marks survive a re-sort and a partial re-render.
After any repaint, marks are reapplied from the hash table.

Two constraints, both verified:

- `tabulated-list-put-tag` **no-ops silently** when `tabulated-list-padding` is
  0. Padding is set to 2 (not 1) so a second mark type can be added later
  without reflowing every column.
- **Do not use `tabulated-list-print`'s `UPDATE` argument to preserve marks.**
  Its own documentation warns that tags are *not* removed from entries that
  haven't changed, so it leaves stale marks on rows. Erase and reapply from the
  hash — that is the only correct order.

Marks live in the hash rather than in a struct slot because entry structs are
`tabulated-list` IDs compared with `equal`, and `equal` on records is structural
(§6): a mutable `marked` slot would change an entry's identity and break point
restoration.

### 9.3.1 The header line is contested — columns move into the buffer

`tabulated-list-init-header` installs the column titles into
`header-line-format`, which is also where §8.4 puts the profile, the current
`s3://` path and the request status. Whichever is written second wins, and the
loss is silent: a test asserting that `header-line-format` contains "2 buckets"
passes happily while the column titles have vanished.

Resolution: `(setq-local tabulated-list-use-header-line nil)` in the mode body.
The column titles are then rendered as the first line of the buffer — retaining
their `(space :align-to …)` alignment and their click-to-sort keymap — and the
header line is free for the S3 context.

A test must assert on the **first buffer line**, not only on
`header-line-format`, or this regresses unnoticed.

### 9.3.2 One mode, two column layouts

§9's format is the object browser's. The same mode also serves the bucket list
(§8.1), whose columns differ. `tabulated-list-format` is buffer-local, so each
setup function installs its own layout and calls `tabulated-list-init-header`
itself; the mode body must **not** set the format. Doing it this way from the
start means the object browser adds its layout without touching the mode body.

### 9.4 Loading state

Starting a listing sets `s3-manager--status` to `loading` and updates the header
line to show `Loading…`; the previous contents remain visible and readable until
the new data arrives, rather than blanking the buffer. On arrival,
`tabulated-list-print` is called with `REMEMBER-POS` non-nil.

### 9.5 Transfer progress

**[CORRECTED] `aws s3 cp` writes progress to STDOUT, not stderr.** An earlier
draft of this spec put the progress filter on stderr; that would have captured
nothing. The measured stream split for the `s3` transfer commands is:

| Command | Outcome | stdout | stderr |
|---|---|---|---|
| `s3 cp` | success | progress (CR-delimited) **+** `download: … to …` | *(empty)* |
| `s3 cp` | failure | *(empty)* | `fatal error: …` ✅ *verified* |
| `s3api get-object` | success | JSON metadata blob | *(empty)* |
| `s3api get-object` | failure | *(empty)* | `\nAn error occurred (…)…` |

This is the opposite arrangement from `s3api`, and it means the transport
primitive needs a per-invocation choice of **which stream feeds the progress
filter**: stdout for `s3` subcommands, stderr for everything else. The stderr
pipe of §4.3 still exists in both cases, because that is where errors go.

A single sample line, through a pipe, with `cat -A`:

```
Completed 70.5 KiB/70.5 KiB (558.5 KiB/s) with 1 file(s) remaining^Mdownload: s3://…/f.txt to …/o.txt$
```

`^M` is `\r`, `$` is the single terminating `\n`. Splitting on `\n` alone yields
one enormous line containing every progress update ever emitted — which is
exactly the failure §9.5.1 describes from the other direction.

The filter splits incoming text on `[\r\n]`, keeps the final non-empty segment,
and assigns it to `s3-manager--transfer-status`, which `mode-line-process`
displays. Progress text is never inserted into a buffer, so a long transfer
costs no memory and scrolls nothing. On completion the variable is reset to nil.

`--progress-multiline` emits `\n`-separated progress instead and is a legitimate
simpler alternative; it is not chosen here because the CR form lets the mode
line show one continuously-overwritten status without any extra bookkeeping.

Also verified: progress is emitted **even when stdout is not a TTY**, so piping
does not suppress it. And **never pass `--quiet`** to a transfer — it suppresses
error messages too, leaving a failed transfer with a non-zero exit and *nothing*
on either stream to show the user.

#### 9.5.1 The coding-system trap

A CR-only stream triggers Emacs's Mac-EOL auto-detection, which **rewrites every
`\r` to `\n`** before your filter ever sees it. Measured on this machine with a
subprocess emitting `"Completed 1\rCompleted 2\r"`:

| `:coding` on the pipe process | Result |
|---|---|
| `utf-8` | **CR = 0** — every carriage return destroyed |
| `undecided` | **CR = 0** — every carriage return destroyed |
| `utf-8-unix` | CR = 2 — correct |

`nil` inherits `default-process-coding-system`, which is `undecided`-based and
therefore environment-dependent — it happened to preserve CRs in one batch-mode
run here and must not be relied on. **Set `:coding 'utf-8-unix` explicitly on
the `make-pipe-process` carrying stderr** (§4.3). Setting it on the main process
does not cover the pipe.

Consequence of getting this wrong: the filter finds no carriage returns, treats
the entire transfer as one unterminated line, and a 2 GB download accumulates
tens of thousands of progress ticks instead of overwriting one.

When testing this by hand, count characters — `(cl-count ?\r s)` — rather than
inspecting `message` output; a terminal renders literal CRs as carriage returns
and preserved CRs *look* stripped.

#### 9.5.2 Filter requirements

- **Carry a remainder across chunks.** Filter chunk boundaries do not align with
  CR boundaries on a real transfer; a segment will be split. Prepend the
  unterminated tail of the previous chunk to the next.
- **Retain nothing unbounded.** Progress ticks (segments beginning `Completed `)
  update the mode line and are then discarded. Keep at most the last ~50
  *non-progress* segments — from either stream — for the error report.
  Retention is O(50) regardless of transfer size.
- **Throttle both ends.** `force-mode-line-update` at aws's native tick rate
  causes visible redisplay churn: throttle repaints to ~0.2 s, and pass
  `--progress-frequency 1` (verified present in `aws s3 cp --help`) to reduce
  the source rate.
- **Do not pass `--quiet` or `--only-show-errors` to `s3 cp`.** Both suppress
  progress output entirely, which is the thing being captured.

---

## 10. Keymap

```elisp
(defvar-keymap s3-manager-mode-map
  :doc "Keymap for `s3-manager-mode'."
  :parent tabulated-list-mode-map
  ...)
```

| Key | Command | Action |
|-----|---------|--------|
| `RET` | `s3-manager-open` | directory → descend; object → **view** (§11.7) |
| `^` | `s3-manager-up` | parent prefix, or back to bucket list |
| `g r` | `s3-manager-refresh` | invalidate cache for this prefix and re-list |
| `g g` | `s3-manager-beginning-of-listing` | first row, skipping the column header |
| `+` | `s3-manager-load-more` | fetch the next page |
| `C` | `s3-manager-copy` | copy to the other window: Dired, or nothing there, → download; an S3 listing → server-side (§11.10) |
| `c` | `s3-manager-copy-to` | copy to a prompted S3 location (§11.10) |
| `r` | `s3-manager-rename` | rename, or move elsewhere in S3 (§11.10) |
| `P` | `s3-manager-upload` | upload a local file, or a directory recursively (§11.8) |
| `d` | `s3-manager-mark-delete` | mark for deletion, move down |
| `u` | `s3-manager-unmark` | unmark, move down |
| `U` | `s3-manager-unmark-all` | clear all marks |
| `x` | `s3-manager-execute` | execute marked deletions |
| `D` | `s3-manager-delete` | delete entry at point immediately (confirm) |
| `n` / `p` | next / previous line | |
| `!` | `s3-manager-show-errors` | display the accumulated failure reports (§12) |
| `q` | `quit-window` | |

Unbound, `M-x` only: `s3-manager-upload-dry-run`,
`s3-manager-copy-dry-run`, `s3-manager-delete-recursive-dry-run`,
`s3-manager-dired-upload`,
`s3-manager-dired-do-copy` (meant for `C` in `dired-mode-map`),
`s3-manager-get`, `s3-manager-get-recursive`, `s3-manager-switch-profile`,
`s3-manager-clear-cache`, `s3-manager-forget-profiles`,
`s3-manager-list-profiles`.

`RET` on an object **views** it; it does not download. A `RET` that silently
starts a multi-gigabyte download is a footgun, and spending the most valuable
key on the map to duplicate `C` would waste it.

**`g` is a prefix, not a command.** `evil-collection` gives Dired that shape --
`gr` reverts, `gg` is left to Evil -- and binding `g` itself would swallow
`gg`, since this map is registered as overriding and anything it resolves beats
Evil, an inherited `g` from `special-mode` included. `gg` is bound rather than
left to Evil so that it works without Evil too, and it is
`s3-manager-beginning-of-listing` rather than `beginning-of-buffer`: this mode
sets `tabulated-list-use-header-line` to nil, spending the header line on the
profile and prefix, so the column names are a real line in the buffer with no
entry behind them and every command refuses it.

The `d`/`x` split follows Dired: `d` marks, `x` executes. Making `d` delete
immediately would put the destructive action on one of the most easily mistyped
keys in the map.

`C` is the download key, not a duplicate of one. With nothing in the other
window it prompts for a path, exactly as a dedicated key would; with Dired
there it uses that directory; with a second S3 listing it copies server-side
(§11.9, §11.10).

**`s3-manager-get` and `s3-manager-get-recursive` are therefore unbound.** They
had `G` and `R` through 0.3.0, and `C` reaches both, so a key each bought only
one thing: forcing a download *past* a visible S3 listing. That is rare enough
for `M-x`, and keeping `G` cost Evil users end-of-buffer, which they press far
more often than they force a download. The commands stay; only the bindings
went.

---

## 11. Operations

### 11.1 Base arguments

Prepended to every invocation:

```elisp
(defun s3-manager--base-args (profile)
  (append (when profile (list "--profile" profile))
          (when-let* ((url (s3-manager--endpoint-for profile)))
            (list "--endpoint-url" url))
          (list "--no-cli-pager" "--no-cli-auto-prompt")))
```

**The transport prepends these, not the caller.** If callers assembled the
full vector, the first element would be a global flag rather than the service
name — and the exit-code classification in §12 depends on knowing whether the
command is an `aws s3` transfer. Centralising it also means no call site can
forget the two guard flags.

`--no-cli-auto-prompt` joins `--no-cli-pager`: a user with `cli_auto_prompt`
enabled in `~/.aws/config` would otherwise get an invocation that blocks on
interactive input forever.

`--output json` is added only for `s3api` commands; the `s3` commands do not
emit JSON.

### 11.2 List buckets

```
aws --profile P [--endpoint-url U] --no-cli-pager \
    s3api list-buckets --output json
```

Response keys used: `Buckets[].Name`, `Buckets[].CreationDate`. The `Owner`
object is ignored.

### 11.3 List objects

```
aws --profile P [--endpoint-url U] --no-cli-pager \
    s3api list-objects-v2 \
    --bucket BUCKET \
    --prefix PREFIX \
    --delimiter / \
    --max-items 1000 \
    --page-size 1000 \
    [--starting-token TOKEN] \
    --output json
```

`--prefix` is omitted entirely when the prefix is `""`.

**Never pass `--encoding-type`.** The CLI sets `EncodingType=url` internally and
URL-decodes `Key` and `Prefix` on the way out — but *only* when it set the flag
itself. Passing it explicitly disables that decoding and returns
percent-encoded keys, silently corrupting every key containing a space, a `+`,
or non-ASCII.

#### 11.3.1 What the paginated response actually contains

**[CORRECTED]** Auto-pagination does not return the raw S3 response. Botocore
aggregates `Contents` and `CommonPrefixes` and **discards every other field**
except `Prefix` and `RequestCharged`. The top-level keys are:

```
Contents          (absent when nothing matches)
CommonPrefixes    (absent when there are no sub-prefixes)
Prefix            (echoes the request prefix; "" at root)
RequestCharged    (usually null)
NextToken         (present only when --max-items truncated the result)
```

**Do not reference `KeyCount`, `IsTruncated`, `Name`, `MaxKeys`, `Delimiter`, or
`NextContinuationToken` — none of them exist in this mode.** They appear only
under `--no-paginate`, which this package never uses. An earlier draft of this
spec listed `KeyCount` and `IsTruncated` as consumed keys; that was wrong.

`Contents` and `CommonPrefixes` are **absent, not empty arrays**, when nothing
matches. Because §4.4 maps missing keys to `nil`, `(alist-get 'Contents r)`
already yields `nil` for all three of "absent", "null", and "empty" — but no
code may assume the key exists.

Consumed keys: `Contents[].Key`, `.Size`, `.LastModified`, `.StorageClass`;
`CommonPrefixes[].Prefix`; `NextToken`.

Two field-level details:

- `LastModified` is ISO-8601 with a **numeric `+00:00` offset, not a `Z`
  suffix**. `parse-iso8601-time-string` handles it; a hand-rolled `Z` matcher
  does not.
- `ETag`, if ever used, arrives with **literal embedded double quotes** in the
  string.

### 11.4 Get object

```
aws --profile P [--endpoint-url U] \
    s3 cp s3://BUCKET/KEY /local/path
```

**Rejected alternative: `s3api get-object`,** for API consistency with the
`s3api` calls used everywhere else. That trade is a bad one. `s3api get-object`
issues a single unranged GET on one connection; `s3 cp` performs a multipart,
parallel download — verified by counting `Range` headers under `--debug`: four
for `s3 cp` against zero for `get-object` on the same object. On a
multi-gigabyte object that is a several-fold difference in wall-clock time.
`s3 cp` additionally yields progress output (§9.5) and sets the local file's
mtime from the object's `LastModified`.

The consistency argument does not survive contact with §11.5 either: recursive
download has no `s3api` equivalent worth writing, so `s3` is already in use.

**Rule: `s3api` for metadata, `s3` for bytes.**

Destination is prompted with `read-file-name`, defaulting to
`(expand-file-name display-name s3-manager-download-directory)`. Existing files
prompt for confirmation before being overwritten — `s3 cp` will not ask.

```elisp
(defcustom s3-manager-download-directory "~/Downloads/"
  "Default destination directory for downloads."
  :type 'directory :group 's3-manager)
```

### 11.5 Get recursive

```
aws --profile P [--endpoint-url U] \
    s3 cp s3://BUCKET/PREFIX /local/dir/ --recursive
```

Only offered when point is on a directory entry. The destination directory is
created if absent, after confirmation.

### 11.6 Delete

**Single object** (`D` on an object):

```
aws --profile P [--endpoint-url U] --no-cli-pager \
    s3api delete-object --bucket BUCKET --key KEY --output json
```

Confirmation: `y-or-n-p` with the full `s3://bucket/key`.

**Marked batch** (`x`):

```
aws --profile P [--endpoint-url U] --no-cli-pager \
    s3api delete-objects --bucket BUCKET \
    --delete '{"Objects":[{"Key":"a"},{"Key":"b"}],"Quiet":false}' \
    --output json
```

`delete-objects` removes up to **1000 keys per call**; marks are chunked
accordingly. The JSON argument is built with `json-serialize` and passed as a
single argv element — no shell, so no quoting concerns even for keys containing
quotes, spaces, or newlines.

**Critical:** `delete-objects` **exits 0 even when individual deletions fail.**
The response contains both a `Deleted` array and an `Errors` array. The `Errors`
array must be checked on success and reported; ignoring it is a silent
data-integrity bug.

Confirmation prompt: `Delete 3 objects? (y or n)`.

**Recursive** (`D` on a directory):

```
aws --profile P [--endpoint-url U] \
    s3 rm s3://BUCKET/PREFIX --recursive --only-show-errors
```

`--only-show-errors` is required here, unlike for `s3 cp`. Without it, `s3 rm
--recursive` prints one `delete: s3://…` line to **stdout per object**; on a
million-key prefix that is a million lines Emacs would accumulate for no reason.
This invocation is run with stdout unbuffered (no output buffer, no JSON
parsing) and a line callback used only to count deletions.

Confirmation uses `yes-or-no-p` — the full typed word — never `y-or-n-p`:

```
Recursively delete ALL objects under s3://media/videos/ ? (yes or no)
```

This can destroy an unbounded amount of data and must never be reachable
by a single keystroke.  Recursive upload (§11.8) asks the same way, since
it can overwrite just as many objects. `s3 rm --recursive` is also correct here; enumerating and deleting
one key at a time would be orders of magnitude slower.

`s3-manager-delete-recursive-dry-run` (no default binding) runs the same command
with `--dryrun` and shows what would be removed.

### 11.7 View object

`RET` on an object downloads it to a temporary file and opens it read-only, but
only when `Size` is below a threshold:

```elisp
(defcustom s3-manager-view-max-size (* 10 1024 1024)
  "Objects larger than this many bytes are not opened by `RET'."
  :type 'integer :group 's3-manager)
```

Above the threshold, `RET` reports the size and suggests `C`. This keeps the
most-pressed key from ever being an unbounded operation.

---

### 11.8 Upload

```
aws s3 cp /abs/local/file s3://BUCKET/PREFIX/name --progress-frequency 1
aws s3 cp /abs/local/dir/ s3://BUCKET/PREFIX/dir/ --recursive --progress-frequency 1
aws s3 cp … --dryrun                                    (preview; transfers nothing)
aws s3api head-object --bucket BUCKET --key PREFIX/name  (existence probe)
```

`P` uploads into the listing's own prefix under the source's leaf name,
regardless of where point is. A directory goes recursively after a typed `yes`,
the same bar as a recursive delete.

**The trailing slash on a recursive destination is load-bearing.** Measured:
`s3 cp DIR s3://B/PREFIX --recursive` maps `DIR/a.txt` onto `PREFIX/a.txt` and
drops the directory's own name, scattering the tree across the listing the user
was looking at. The leaf is written into the destination URI, never inferred.

**Overwrite: `head-object`, then confirm.** `s3 cp` replaces a key without a
word. It grew a `--no-overwrite` flag by 2.33.30 — *"only files not present at
the destination will be transferred"* — but that skips silently rather than
asking, which is the opposite of what is wanted here, and the version that
introduced it was not established against the 2.13.0 this package requires. The discrimination is an **allowlist**:
absent is exit 254 *plus* `An error occurred (404) when calling the HeadObject
operation` — botocore's own format string, hence identical across
S3-compatible endpoints. A 403 is a permission error, 255 an unreachable
endpoint, a timeout carries no exit code; reading any of them as absence would
silently overwrite an object the caller was merely forbidden to *look at*. When
the check itself fails, the error is reported and the user asked, because real
AWS answers 403 for a missing key when the caller lacks `s3:ListBucket`.

**Rejected alternative: probe per key on a recursive upload.** Unbounded. The
dry run plus the typed confirmation cover it instead.

**The confirmation cannot run where the answer arrives.** A sentinel executes
at whatever point the command loop had reached when the pipe became readable,
so `y-or-n-p` there re-enters the minibuffer from an arbitrary place. The
probe's callbacks classify only; a zero-second timer does the prompting, as
`s3-manager--profiles-resolved` already does for the profile prompt. Both
branches take the hop, so ordering does not depend on the answer.

**Symlinks are followed**, the CLI's default, and it does not detect cycles. A
link beside its own target uploads the same file twice — observed. Silently
*skipping* files the user asked to upload is the worse failure, so the default
stands and `s3-manager-upload-dry-run` makes it visible beforehand;
`s3-manager-upload-follow-symlinks` is the escape hatch. Every argument
deciding *what* is sent is shared between preview and upload, or the preview
would not describe the thing it previews.

**Refused up front:** a directory that is empty (S3 has no directories, so it
would report success having done nothing), anything not a regular file (a fifo
would be read forever, and transfers have no timeout), and a source that has
become unreadable between the prompt and the transfer.

**After an upload** the destination's cache entry is invalidated and, for a
recursive one, everything at and beneath the new prefix. The refresh names the
prefix recorded when the upload *started*: a transfer is outside the generation
guard, so the user may have navigated since. Point is restored by key, not by
entry — an uploaded object's `Size` and `LastModified` are the server's, so no
entry for it can be synthesized in advance.

---

### 11.9 Dired interoperability

Two windows, both directions.

`C` and `P` default their local path to a Dired buffer visible in another
window, via `dired-dwim-target-directory`. The user's `dired-dwim-target`
decides; nil there turns it off.

**`C` is the key, in both buffers.** In an S3 listing it copies the entry at
point to the Dired window, dispatching on the entry type as `RET` and `D`
already do: an object downloads, a prefix downloads recursively. In a Dired
buffer, `s3-manager-dired-do-copy` uploads the marked files to a visible S3
listing and otherwise calls `dired-do-copy` unchanged, prefix argument
included.

**The fallback rule is the window layout, not `buffer-list`.** A listing that
exists but is displayed nowhere must not turn an ordinary `C` into an upload to
a bucket the user cannot see. `dired-dwim-target-directories` uses the same
rule in the other direction, considering only windows whose buffer is in
`dired-mode`.

The package does not modify `dired-mode-map`; the binding is the user's. This
also leaves room for §17's "copy between S3 locations": `C` reads as *copy to
whatever is in the other window*, so a second S3 listing there is an addition
rather than a redefinition.

**Re-examined, and the measurements settle it.** Binding Dired's `C` from the
package was considered, so that `P` could go and one key would serve both
directions. It does not work, for reasons no amount of care in this package can
fix (§18.7): under `evil-collection` a `dired-mode-map` binding never fires, and
the Evil-state binding that does fire only wins if it runs *after*
`evil-collection-init`, which is lazy. Making it stick would mean re-applying
the binding from `dired-mode-hook` — a package overwriting another package's
key on every Dired buffer to win a load-order race.

**`P` therefore stays**, and it is not redundant with `C` from Dired: it needs
no second window, no marked file, and no binding in anyone else's keymap, and
it takes a path the user types. It is the only upload that works on a fresh
install.

`M-x s3-manager-dired-upload` goes the other way explicitly: the marked files,
or the file at point when none are marked, into the S3 listing in the other
window.

- **One confirmation for the batch**, naming the keys that already exist. A
  probe per file is bounded and cheap beside the transfer; a prompt per file is
  not. Probes are sequential, so the question is reproducible.
- **Remote sources are refused** before anything starts: `aws` cannot read a
  TRAMP path, and `default-directory` is pinned to a local directory anyway.
- **One transfer per file** — `s3 cp` takes one source — and **one refresh**
  when the last lands.
- **A batch is not atomic.** Failures are counted and reported individually,
  never folded into a total.


---

### 11.10 Copy and move between S3 locations

```
aws s3 cp s3://B/key  s3://B2/key2  --progress-frequency 1
aws s3 mv s3://B/pre/ s3://B2/pre2/ --recursive --progress-frequency 1
aws s3 cp … --dryrun                                  (preview; writes nothing)
aws s3api head-object --bucket B2 --key key2           (existence probe)
```

Server-side: the bytes never reach this machine, which is why this is not
spelled as a download followed by an upload.

`c` copies and `r` renames or moves, both on the entry at point. Both offer a
destination for editing — for `r` the entry's own URI, so changing the last
segment renames and changing the rest moves. **What the prompt shows is what
happens:** the destination is taken as typed, never given the source's own name
behind the user's back. `C` is the exception, because it never prompts; it uses
the other window's prefix plus the source's name, which is the Dired reading of
"copy this there".

**The guards are ours, and they run before anything is invoked.** Measured:
`s3 cp SRC SRC` exits 0 having done nothing visible, and `s3 mv` catches only
the spellings its own string comparison happens to match:

```
aws s3 mv s3://B/share/ s3://B/share --recursive --dryrun
  → exit 0, and every object under share/ is mapped onto itself
```

One dropped slash. For a move that is copy-onto-self followed by delete, on an
endpoint where self-copy succeeds — which is measured to be the case here, and
is not true of real AWS. So the destination is normalised first (a prefix
always gains its trailing slash) and compared here, and the CLI's exit 252 is
only ever a backstop. §12 glosses that code accordingly, since it also means
"this package built a bad argv".

Also refused, all before any request:

- **Overlapping prefixes, in either direction.** The CLI allows `share/` →
  `share/sub/` and exits 0, but objects under the overlap are both source and
  destination, and which of its worker threads reaches one first is a race.
  There is no confirmation wording that makes a nondeterministic outcome
  acceptable.
- **An access point ARN or alias as the destination.** Two names can resolve to
  one bucket, which no comparison of two strings can see; the CLI's own `s3 mv`
  documentation warns that such a move can delete the object.
  `--validate-same-s3-paths` is the alternative, at the cost of extra API calls
  and an unestablished minimum version.
- **A destination on another profile**, reachable only through `C`. One
  invocation carries one `--profile`, and the endpoint follows from the
  profile, so the copy is not a command that can be constructed.

**A move is `s3 mv`, not a copy-verify-delete built here.** The CLI's own
description is *"copies the source object … and then deletes the source
object"* — per object — so a failure part-way leaves anything it did not reach
untouched at the source, and re-running finishes the job. That is the invariant
a move needs, already provided; reimplementing it would give up multipart copy,
concurrency and retry for nothing. The failure message says which state the two
ends are in, because the CLI's stderr does not.

**Confirmation matches the damage.** A single object is probed and the existing
destination named with its size and date, exactly as an upload is. A prefix
takes a typed `yes` naming both URIs — and, for a move, saying that the
originals are deleted. A prefix is not probed: one `head-object` per key is
unbounded, which §11.8 already rejected for the recursive upload, and
`s3-manager-copy-dry-run` is the answer instead.

**Both ends are refreshed, on failure too**, since `aws s3` exits 1 or 2 having
done part of the work. Not merely the destination's immediate parent: S3 has no
directories, so one new key can bring a row into existence at several levels at
once, and a listing showing any of them is stale. A rename in place — where the
two ends are one listing — is deduplicated to a single reload, with point on
what arrived rather than on what left.

---

## 12. Error handling

**[CORRECTED] The report is displayed, not merely recorded.** v0.1.0 wrote
every failure to `*S3 Manager Error*` and never showed it, on the grounds that
a permission error during a browse should not steal a window. That holds for a
browse and fails everywhere else: an echo-area summary is overwritten by the
next `message`, which during a transfer is under a second. `display-buffer`
unless `s3-manager-display-errors` is nil; the summary always names the buffer;
`!` opens it on demand.

**Nothing is swallowed.** An audit found four places that discarded an error —
`:on-error #'ignore` on the version probe, `ignore-errors` around temporary
directory cleanup, an empty `cond` branch for exit 130, and a callback failure
that was only `message`d. Recording is now separate from reporting, so
background work the user did not ask for still leaves a trace.

**No failure is reported only as a count.** A batch names each one.

```elisp
(define-error 's3-manager-error "S3 Manager error")
```

Every non-zero exit is routed to one handler, which:

1. Writes a report to `*S3 Manager Error*` (not displayed automatically unless
   the failure is unexpected):

   ```
   S3 Manager Error

   Command:
   aws --profile production --no-cli-pager s3api list-buckets --output json

   Exit code: 254

   stderr:
   An error occurred (AccessDenied) when calling the ListBuckets operation:
   User: arn:aws:iam::123456789012:user/dev is not authorized to perform:
   s3:ListAllMyBuckets
   ```

2. Extracts a one-line summary for the echo area by matching stderr against
   `"An error occurred (\\([A-Za-z]+\\)) when calling the \\([A-Za-z]+\\) operation"`,
   producing `S3: AccessDenied on ListBuckets (C-h e for detail)`. Falls back to
   the first non-empty stderr line.

3. Signals `s3-manager-error`, which commands catch to leave the buffer in a
   consistent state. The package never crashes out of a sentinel.

### 12.1 Exit codes

| Code | Meaning | Package response |
|------|---------|------------------|
| 0 | Success | proceed (but check `Errors` for `delete-objects`, §11.6) |
| 1 | **`aws s3` only:** one or more transfers failed | **partial** — report *and* refresh |
| 2 | **`aws s3` only:** one or more files skipped | **partial** — report *and* refresh |
| *(signal)* | Killed by a signal | **not an exit code** — see below |
| 130 | Interrupted (SIGINT) | silent — this is our own cancellation |
| 252 | Command syntax invalid ✅ *verified* | report as a bug in the package |
| 253 | Invalid environment or configuration | **documented but never observed** — do not branch on it |
| 254 | Service returned an error (`AccessDenied`, `NoSuchBucket`, …) | report verbatim |
| 255 | General error — bad profile, network failure ✅ *verified* | report verbatim |

Codes marked ✅ were reproduced on the dev machine; the remainder are from AWS
documentation.

**Codes 1 and 2 are partial success, not failure, and only occur for `aws s3`
subcommands.** A recursive delete that removes 900 of 1000 objects exits
non-zero. Treating that as a flat failure and skipping the refresh leaves the
user looking at 900 objects that no longer exist — a worse outcome than the
original error. These two codes must therefore route to a distinct
`s3-manager-partial-error` condition that reports the retained stderr *and*
proceeds with cache invalidation and re-listing.

Code 252 indicates the package constructed an invalid command line, so its
report should invite a bug report rather than blame the user.

**A signalled process does not report an exit code at all.** When
`process-status` is `signal`, `process-exit-status` returns the *signal number*.
Read as an exit code, SIGHUP and SIGINT arrive as 1 and 2 — the two values that
mean partial success — so a transfer killed outright would be reported as having
partly worked. The sentinel must record which of `exit` and `signal` occurred
and classify accordingly.

**Classify by stderr text, not by 253 vs 255.** Every environment failure tested
— missing credentials, a nonexistent profile, an unreachable endpoint — returned
**255**, never 253. Treat `{253, 255}` as one environment/credentials/network
family and distinguish within it by matching stderr:

```
"Unable to locate credentials"                  → credentials
"The config profile (X) could not be found"     → bad profile
"Could not connect to the endpoint URL"         → network / endpoint
```

Exit codes are glossed in the error buffer (`254` → "service error", `2` →
"partial: some objects skipped"). The difference between a report that says
"exit 255" and one that says "exit 255 (general error — often a bad profile or
an unreachable endpoint)" is the difference between an actionable bug report and
a shrug.

---

## 13. Security requirements

The package **must not**:

- read, parse, or store an access key or secret key;
- invoke `aws configure get aws_secret_access_key` or any equivalent;
- place credentials in a buffer, a variable, a log, or an error message;
- pass credentials on the command line.

Credential handling is entirely the CLI's responsibility. The package selects a
profile by name and nothing more.

Additionally:

- **No shell, ever.** All invocations use an argv vector via `make-process`.
  This eliminates quoting and injection concerns for bucket names, object keys,
  and the JSON payload of §11.6 — S3 keys may legally contain quotes, spaces,
  newlines, and shell metacharacters.
- **Execution is local by construction.** `make-process` consults a file-name
  handler only when passed `:file-handler t`, which the package never does
  (§4.5). This is what prevents a TRAMP buffer from redirecting `aws` to another
  host's credentials — *not* the `default-directory` binding, which exists for
  the separate reasons given in §4.5.
- **Never pass `--debug`.** It writes `Authorization` headers and
  `X-Amz-Security-Token` to stderr, which would land verbatim in the error
  buffer. There is no debugging benefit worth that.

### 13.1 Redaction

Credentials never appear on the command line — only `--profile NAME` and
`--endpoint-url URL`. The one real leak vector is an endpoint URL carrying
embedded userinfo (`https://key:secret@minio.example.com`), which a user may
legitimately configure and which would otherwise be echoed into the error buffer
and the mode line.

Everything written to `*S3 Manager Error*`, to `mode-line-process`, and to the
echo area passes through `s3-manager--redact`, which masks at minimum:

- URL userinfo — `://user:PASS@` → `://user:***@`
- `X-Amz-Signature=`, `X-Amz-Credential=`, `X-Amz-Security-Token=` query values
- `aws_secret_access_key = …` / `AWS_SESSION_TOKEN=…` assignments
- `AKIA…` / `ASIA…` access key IDs

The access key ID is not itself a secret, but it identifies an account and users
paste error buffers into tickets; masking it costs one regexp.

`process-environment` is never logged.

The `*S3 Manager Error*` buffer reproduces the (redacted) argv, which contains
profile names, bucket names, and object keys. Object keys can themselves be
sensitive, so the buffer is ordinary and killable and is never written to disk.

---

## 14. Repository layout and tooling

**[CORRECTED] The package is no longer a single file.** v0.1.0 shipped one
2100-line file and v0.2.0 grew it to 2532, at which point it was reported
unnavigable. Each file now requires only the ones below it. The one place the
layering runs backwards is the keymap, which binds commands defined above it;
those are `declare-function`ed, since a `#'` reference to an undefined function
is a warning and warnings are fatal here.

```
s3-manager.el          entry point: M-x s3-manager, and the requires
s3-manager-core.el     options, buffer-local state, error reporting
s3-manager-process.el  the async CLI transport, profiles
s3-manager-model.el    entries and the listing cache
s3-manager-ui.el       major mode, rendering, navigation, marks
s3-manager-transfer.el download and upload
s3-manager-view.el     reading a small object
s3-manager-delete.el   removing objects and prefixes
s3-manager-copy.el     copy and move between S3 locations
Eask                   build / lint / test manifest
README.md              user-facing documentation
LICENSE                GPL-3.0
doc/SPEC.md            this document
test/
  s3-manager-test.el   ERT suite
  fixtures/
    list-buckets.json
    list-objects-root.json
    list-objects-nested.json
    list-objects-truncated.json     ; contains NextToken
    list-objects-empty.json
    list-objects-dir-marker.json    ; Contents includes the prefix itself
    delete-objects-partial.json     ; exit 0 with a non-empty Errors array
    error-access-denied.txt         ; a recorded stderr body
```

Deliberately one file, not a package directory. At this size a single
well-organized file is easier to navigate, byte-compile and reason about, and
nothing in it has an independent reuse story that would justify separation.

### 14.1 Eask

`eask` is not yet installed on the dev machine; install with
`npm i -g @emacs-eask/cli`. Tests remain runnable without it via
`emacs --batch -L . -L test -l test/s3-manager-test.el -f ert-run-tests-batch-and-exit`,
so the suite is never blocked on the tool.

```elisp
(package "s3-manager" "0.1.0" "Manage S3 objects from Emacs")
(website-url "https://github.com/minh/s3-manager.el")
(keywords "tools" "convenience")
(package-file "s3-manager.el")
(script "test" "eask test ert ./test/s3-manager-test.el")
(source "gnu")
(source "melpa")
(depends-on "emacs" "29.1")
(setq byte-compile-error-on-warn t)
```

### 14.2 Quality bar

Per the project decision, this targets **clean personal-use quality, not MELPA
submission**: docstrings on every public symbol, a clean byte-compile with
`byte-compile-error-on-warn`, and consistent `s3-manager-` / `s3-manager--`
prefixing. `package-lint` and full `checkdoc` conformance are explicitly *not*
gates for this release; §17 lists them as v0.2 work.

---

## 15. Test plan

### 15.1 The seam

All tests replace exactly one function — `s3-manager--aws-async` — with a stub
that invokes `on-success` (or `on-error`) **synchronously** with fixture data:

```elisp
(defmacro s3-manager-test--with-response (json &rest body)
  (declare (indent 1))
  `(cl-letf (((symbol-function 's3-manager--aws-async)
              (lambda (args &rest keys)
                (push args s3-manager-test--calls)
                (funcall (plist-get keys :on-success) ,json)
                nil)))
     ,@body))
```

Capturing `args` on every call means argv construction is directly assertable —
which is the highest-value thing to test, since a wrong flag is the most likely
defect and the one hardest to notice by eye.

No test touches the network or reads `~/.aws`.

### 15.1.1 Offline argv validation against the real CLI

String-equality assertions catch typos but not *semantic* errors — a flag that
does not exist on that subcommand, a required argument omitted, or a mutually
exclusive pair. The CLI will validate all of those **without network access or
credentials**, using `--generate-cli-skeleton`:

```
build the argv → append --generate-cli-skeleton output → run → assert exit 0
```

Verified on this machine:

- `aws s3api list-objects-v2 --bucket b --endpoint-url http://127.0.0.1:1
  --generate-cli-skeleton output` → **exit 0**, 1036 bytes, no connection
  attempted (the endpoint is a dead port).
- `aws s3api get-object --generate-cli-skeleton input` (required args missing) →
  **exit 252**, `the following arguments are required: --bucket, --key`.
- An invented flag (`--no-such-flag x`) → **exit 252**.

So the parser runs fully and rejects bad command lines offline. This gives the
fixture-only suite a genuine integration check on the one thing fixtures cannot
cover: whether the commands we construct are commands the CLI accepts.

**Limitation — the pagination flags must be excluded.** `--max-items`,
`--page-size` and `--starting-token` are client-side options that botocore
folds into a `PaginationConfig` structure, which the skeleton generator does not
recognise:

```
Parameter validation failed:
Unknown parameter in input: "PaginationConfig", must be one of: Bucket,
Delimiter, EncodingType, MaxKeys, Prefix, ContinuationToken, ...
```

The check therefore validates the **service-level** arguments only. Strip the
three pagination flags before running it. Verified: the same command exits 0
without them and 252 with them.

Gate these on `(executable-find "aws")` and skip otherwise, so the suite still
runs on a machine without the CLI.

**Do not build golden-file fixtures from skeleton output.** The skeleton is the
full API model and includes fields the paginator strips (§11.3.1); the CLI's own
help warns it is not stable across versions. Fixtures must be captured from real
responses.

### 15.2 Cases

**Parsing and the model**

- `CommonPrefixes` become `directory` entries; `Contents` become `object` entries.
- `display-name` strips the request prefix; directories keep the trailing `/`.
- An empty prefix (neither key present) yields no entries and does not error.
- **The directory-marker entry whose `Key` equals the request prefix is dropped.**
- Sizes format correctly across boundaries (0 B, 999 B, 1.0 KB, 1.8 GB).
- Directories sort before objects under every sort column.
- `s3-manager--sort-by-size` orders correctly with nil sizes present.

**Argv construction** — assert the exact list for each of:

- `list-buckets`; `list-objects-v2` at root (no `--prefix`) and nested;
- a continuation request carrying `--starting-token`;
- `s3 cp`, `s3 cp --recursive`, `s3api delete-object`, `s3api delete-objects`,
  `s3 rm --recursive`;
- with and without an endpoint override, and with the endpoint alist taking
  precedence over the scalar.

**Pagination**

- A response containing `NextToken` sets `s3-manager--next-token` and the
  "more" indicator.
- `load-more` appends rather than replaces, and preserves earlier entries.
- A response without `NextToken` clears the indicator.

**Cache**

- Two listings of the same key issue one request.
- `g` forces a second request.
- A recursive delete of `P` evicts `P` and every key beneath it, and nothing
  else.

**Errors**

- A non-zero exit invokes `on-error` and populates `*S3 Manager Error*`.
- The `AccessDenied` stderr fixture produces the expected one-line summary.
- `delete-objects` returning exit 0 with a non-empty `Errors` array is
  **reported as a failure**, not silently accepted.

**Staleness and resources**

- A callback bearing a stale generation makes no change to the buffer.
- A stubbed request leaves no leaked ` *s3-aws-*` buffers behind.
- A transfer in progress is **not** cancelled by a navigation that starts a new
  listing (§4.6.1).

**Transport-level regressions** — these guard the traps in §18.6, which are
invisible in normal use and expensive to rediscover:

- Empty stdout yields zero entries rather than signalling `json-end-of-file`.
- The progress filter recovers a CR-delimited segment that has been **split
  across two filter chunks**.
- A stderr payload arriving *after* the main sentinel is still present in the
  error report (the §4.3 barrier). Simulate by driving the two sentinels in
  both orders.
- The stderr text in a report contains no `Process … finished` line (§4.3
  trap 1).
- Exit codes 1 and 2 from an `aws s3` subcommand produce
  `s3-manager-partial-error` **and still trigger a refresh**; 254 does not.
- `s3-manager--redact` masks URL userinfo and `AKIA…` in a sample stderr.

---

### 15.2.1 Cases added for v0.2.0

Upload argv for both forms, including the trailing slash that keeps a
directory's leaf; key derivation and its refusals; the `head-object`
discrimination, with 403, 255 and a timeout each asserted *not* to mean
absence; the overwrite prompt and what declining does; the sentinel-to-timer
hop; cache invalidation naming the destination rather than the current prefix;
point restoration by key; the dry run sharing every decisive argument with the
upload; the Dired batch — one prompt, one refresh, failures counted, remote
sources refused; and two hygiene tests over every source file, since splitting
the package introduced a file-local-variables trap that no functional test
would catch.

---

## 16. Definition of Done

Each release is complete when this runs end to end against a real endpoint.

1. `M-x s3-manager` → profile prompt → select `production`.
2. `*s3: production*` lists buckets; Emacs stayed responsive throughout.
3. `RET` on `media` → `*s3: production/media*` showing:
   ```
     videos/                      -          -
     images/                      -          -
     README.md                1.2 KB   2026-09-01
   ```
4. `RET` on `videos/` → descends; header line reads `s3://media/videos/`.
5. `C` on `old.mp4`, with no other window → destination prompt → file appears
   locally; progress was visible in the mode line; Emacs remained usable
   during the transfer.
6. `^` → back at `videos/`, **with point on `old.mp4`**.
7. `C` on `2026/`, with no other window → destination prompt → the whole
   prefix downloads.
8. `d` `d` `d` on three objects, `x` → `Delete 3 objects?` → confirm → one
   `delete-objects` call → buffer refreshes without them.
9. `D` on `videos/` → `yes-or-no-p` requiring the full word → recursive delete.
10. In a bucket with more than 1000 keys under one prefix: the first page
    renders promptly, the footer offers `+`, and `+` appends the next page.
11. Revoking `s3:DeleteObject` and retrying: `AccessDenied` is reported in the
    echo area and in `*S3 Manager Error*`, and the package continues to work.

### v0.2.0 adds

12. `P` on a file not yet in the prefix → uploads with no overwrite prompt; the
    row appears and **point lands on it**.
13. `P` on the same file again → `already exists (31 B, modified …).
    Overwrite?` quoting the service's own size and date; declining changes
    nothing.
14. `P` on a directory → typed `yes` → the tree lands under `NAME/`, not
    flattened into the current prefix.
15. `M-x s3-manager-upload-dry-run` on that directory first → the preview names
    exactly what step 14 then uploads, symlinks resolved the same way, and
    writes nothing.
16. A transfer longer than 120 seconds completes rather than timing out.
17. Dired in one window, an S3 listing in the other: mark three files,
    `M-x s3-manager-dired-upload` → one prompt, three transfers, one refresh,
    `uploaded 3 files`.
18. `C` with that Dired window open → the destination defaults to its
    directory, not `~/Downloads/`.
19. Uploading where the caller may not write: the service's own words reach the
    screen, the report is displayed, and the package keeps working.

### v0.3.0 adds

20. `c` on an object → the destination is offered for editing → the object
    appears at the new key and **point lands on it**.
21. `c` onto an existing key → `already exists (N B, modified …). Overwrite?`
    quoting the service's own size and date; declining changes nothing.
22. `c` on a prefix → typed `yes` → the tree lands under the destination as
    typed, and every listing above it shows the new row.
23. `r` → the object is at the new key and gone from the old, both listings
    refresh, and point is on what arrived.
24. `r` on a prefix, answering with the trailing slash dropped → **refused by
    us**, with no CLI call at all. This is the one that would otherwise move
    every object onto itself and delete it.
25. `C` with a second listing in the other window → a server-side copy into its
    prefix; with Dired there → still a download; with Dired nearer than a
    second listing → still a download.
26. `M-x s3-manager-copy-dry-run` with a prefix argument → names every object a
    recursive move would relocate, and writes and deletes nothing.
27. A copy to a listing on another profile → refused, naming both profiles.

Items 6, 10, 11, 13 and 15 are the ones that distinguish this from a CLI
wrapper.

### What has actually been run against a real endpoint

The list above is the bar, not a record of having cleared it. Kept honest,
because a Definition of Done nobody has executed is a wish:

| | |
|---|---|
| Run live | 1-9, 12-15, 17, 20-24, 26, and the first clause of 25 |
| Covered by tests only | **16** (a transfer past 120 seconds on real bytes), **18** (`C` defaulting to the Dired window), **19** (a write-denied bucket), **27** (a cross-profile refusal), and the last two clauses of **25** (`C` falling back to a download with Dired in the other window, and with Dired nearer than a second listing) |

The test-only ones need a large object, a bucket the caller cannot write, a
second profile, and a hand-arranged window layout respectively — none hard,
none yet done.

---

## 17. Deferred, and the seams left for it

| Version | Work | Seam already in place? |
|---|---|---|
| ~~0.2.0~~ | ~~Upload~~ | **Shipped** — §11.8 |
| ~~0.3.0~~ | ~~Dired integration~~ | **Shipped early** — §11.9 |
| ~~0.3.0~~ | ~~Copy and move between S3 locations~~ | **Shipped** — §11.10 |
| 0.4.0 | Concurrent transfer queue | Yes — transport is already async; needs a scheduler over it, not a rewrite |
| 0.4.0 | Idle-based transfer watchdog | Partly — see §11.8; the current answer is no timeout at all |
| 0.5.0 | Metadata, versions, ACL | Partly — needs extra columns; `s3api head-object` is already used by the upload probe |
| 1.0.0 | Stable public API | — |

**No seam is left** for: a native AWS SDK (would replace the transport layer
wholesale), recursive listing in the UI (deliberately excluded — see §5.1), or
server-side sync.

**Distribution is GitHub only.** MELPA submission is not planned, so
`package-lint` conformance is not a release gate. For the record, the multi-file
layout is already clean under it: with `package-lint-main-file` set to
`s3-manager.el` the seven secondary files report nothing, and the entry point
reports one cosmetic warning about the summary line. Linting the secondary files
without that setting produces noise, because each is then judged as a package of
its own.

---

## 18. Appendix: verified AWS CLI reference

Verified against `aws-cli/2.33.30 Python/3.13.11 Linux` on the development
machine, by reading `--help` output and by executing commands that fail without
credentials. **No live S3 API calls were made.**

### 18.1 Pagination flags — `s3api list-objects-v2`

| Flag | Verified | Meaning |
|---|---|---|
| `--starting-token` | ✅ present | resume point; takes the `NextToken` from a prior response |
| `--page-size` | ✅ present | items per underlying API call (network tuning) |
| `--max-items` | ✅ present | items returned to the caller; triggers `NextToken` in output |
| `--no-paginate` | present | disables auto-pagination entirely; not used |

Help text, verbatim: *"`NextToken` is provided in the command's output. To
resume pagination, provide the `NextToken` value in the `--starting-token`
argument of a subsequent command. **Do not** use the `NextToken` response
element directly outside of the AWS CLI."*

### 18.1.1 Upload facts, measured for v0.2.0

Against `aws-cli/2.33.30` and a live S3-compatible endpoint, using `--dryrun`
so nothing was written.

| Probe | Result |
|---|---|
| `s3 cp FILE s3://… --dryrun` | prints `(dryrun) upload: SRC to DEST`, exit 0, writes nothing |
| `s3 cp DIR s3://B/P/ --recursive` | uploads DIR's **contents flat into `P/`**; the leaf is dropped |
| `s3 cp DIR s3://B/P/DIR/ --recursive` | mirrors the tree under `P/DIR/` |
| `head-object`, key present | exit **0**, JSON with `ContentLength`, `LastModified`, `ETag` |
| `head-object`, key absent | exit **254**, stderr `An error occurred (404) when calling the HeadObject operation: Not Found` |
| `--follow-symlinks` | **default**; a link beside its own target uploads the file twice |
| MIME type | guessed from the extension unless `--no-guess-mime-type` |
| `--generate-cli-skeleton` | works for `s3api head-object`; **absent** on the high-level `s3 cp` |
| filenames with spaces | intact — argv vector, never a shell |

**The transfer timeout was wrong.** `(run-at-time timeout nil …)` arms one
timer for total duration, not idle time, so any transfer outliving it was
killed mid-flight and reported as `No response after 120 seconds` — measured
with the CLI alive and still writing progress. Transfers now take
`s3-manager-transfer-timeout`, default nil.

---

### 18.1.2 Copy and move facts, measured for v0.3.0

Against `aws-cli/2.33.30` and a live S3-compatible endpoint. Everything that
would have written used `--dryrun`, except the rows marked *(real)*, which ran
inside `s3://temp/s3-manager-selftest/` and were removed afterwards.

| Probe | Result |
|---|---|
| `s3 cp s3://A/k s3://B/k2` | `(dryrun) copy: SRC to DST`; cross-bucket is fine |
| `s3 mv s3://A/k s3://B/k2` | `(dryrun) move: SRC to DST` |
| `s3 cp s3://A/P/ s3://A/Q/ --recursive` | **flattens the leaf** — `P/README.md` lands as `Q/README.md`, exactly as the local directory upload does (§18.1.1) |
| `s3 cp SRC SRC` | **exit 0.** No self-copy protection at all |
| `s3 mv SRC SRC` | exit **252**, stderr `Cannot mv a file onto itself: SRC - DST`; client-side, fires under `--dryrun` too |
| `s3 mv s3://A/P/ s3://A/P --recursive` | **exit 0**, and every object under `P/` is mapped onto itself — one dropped slash defeats the check above |
| `s3 mv s3://A/P/ s3://A/P/sub/ --recursive` | allowed, exit 0; the source is enumerated up front, so it terminates |
| `s3 cp` between two S3 URIs *(real)* | emits `Completed N Bytes/N Bytes (R/s)` on **stdout**, carriage-return terminated, the same shape `s3-manager--format-progress` already parses — so the mode line works even though no bytes cross this machine |
| `s3 mv` *(real)* | *"copies the source object … and then deletes the source object"* — per object, so a partial failure never loses one |
| `--copy-props` | S3→S3 only; its default copies tags and the metadata directive, so it is not passed |
| `--no-overwrite` | exists in 2.33.30; **skips** silently rather than asking, and its introducing version was not established |
| keys with spaces *(real)* | intact through copy, move and the dry run — argv vector, never a shell |

The self-move row is why §11.10's guard is the package's own rather than the
CLI's. Real AWS rejects a self-copy with `InvalidRequest`; this endpoint does
not, so there `mv` would have deleted everything it had just copied onto
itself.

---

### 18.2 `s3 cp` / `s3 rm` flags

| Flag | `cp` | `rm` | Note |
|---|:--:|:--:|---|
| `--recursive` | ✅ | ✅ | |
| `--dryrun` | ✅ | ✅ | one word — **not** `--dry-run` |
| `--only-show-errors` | ✅ | ✅ | **the correct way to silence a transfer** |
| `--quiet` | ✅ | ✅ | **never use** — suppresses error messages too, leaving a failed transfer with nothing on either stream |
| `--no-progress` | ✅ | ✗ | `cp` only; ignored/absent on `rm` |
| `--progress-frequency` | ✅ | ✗ | throttles updates at the source |
| `--progress-multiline` | ✅ | ✗ | `\n`-separated progress instead of CR |

### 18.3 JSON keys consumed

| Command | Keys |
|---|---|
| `list-buckets` | `Buckets[].Name`, `Buckets[].CreationDate` |
| `list-objects-v2` (auto-paginated) | `Contents[].Key`, `.Size`, `.LastModified`, `.StorageClass`; `CommonPrefixes[].Prefix`; `Prefix`; `NextToken` |
| `delete-object` | *(none — exit code only)* |
| `delete-objects` | `Deleted[].Key`; **`Errors[].Key`, `.Code`, `.Message`** |

Keys that **do not exist** in auto-paginated `list-objects-v2` output, despite
appearing in the S3 API documentation and in `--generate-cli-skeleton`:
`Name`, `KeyCount`, `MaxKeys`, `IsTruncated`, `Delimiter`, `EncodingType`,
`ContinuationToken`, `NextContinuationToken`. Botocore aggregates `Contents` and
`CommonPrefixes` and discards the rest. They reappear only under
`--no-paginate`, which this package never uses.

### 18.3.1 Stream routing

| Command | Outcome | stdout | stderr |
|---|---|---|---|
| `s3api …` | success | JSON | *(empty)* |
| `s3api …` | failure | *(empty)* | `\nAn error occurred (Code) when calling the Op operation: …` — note the **leading newline**, trim it |
| `s3 cp` | success | **progress (CR) + `download:` line** | *(empty)* |
| `s3 cp` | failure | *(empty)* | `fatal error: …` ✅ *verified* |

### 18.3.2 Pagination token shapes

`NextToken` is a base64 JSON envelope, not a server cursor:

| Invocation | Decoded token | Resume cost |
|---|---|---|
| `--max-items 10` alone | `{"ContinuationToken": null, "boto_truncate_amount": 10}` | **O(n) — re-lists from the start** |
| `--max-items 10 --page-size 5` | `{"ContinuationToken": "…"}` | O(1) |
| `--max-items 12 --page-size 5` | `{"ContinuationToken": "…", "boto_truncate_amount": 2}` | O(1) + 2 discarded |

Hence the §5.3.1 rule that the two flags are always equal.

**Confirmed against a live endpoint.** With `--max-items` and `--page-size`
both 3, against a prefix holding nine objects, the returned token decoded to:

```json
{"ContinuationToken": "c2hhcmUvVGhlV2lzZG9tT2ZGYXRoZXJCcm93bi5UaGVEdWVs…"}
```

— no `boto_truncate_amount`, i.e. a pure server-side cursor. Three pages took
exactly three API calls and produced nine distinct keys.

`--no-paginate` is **not** an escape hatch: it returns the raw
`NextContinuationToken`, but the CLI exposes **no `--continuation-token` flag in
its documented synopsis** to send it back, and it is mutually exclusive with
`--page-size`/`--max-items`/`--starting-token` (hard error, exit 252).

### 18.4 Exit codes reproduced locally

| Command | Code |
|---|---|
| `aws s3api list-objects-v2 --bucket` (missing value) | `252` |
| `aws bogus-service bogus-op` | `252` |
| `AWS_PROFILE=__nope__ aws s3api list-buckets` | `255` |
| `aws s3api list-buckets --endpoint-url http://127.0.0.1:1` | `255` |

### 18.5 Other CLI facts

- `aws configure list-profiles` — ✅ newline-separated names, exit 0.
- `aws --version` — ✅ `aws-cli/X.Y.Z Python/... OS/... exe/...`.
- `--progress-frequency` — ✅ present on `aws s3 cp`.
- `--no-cli-pager`, `--no-cli-auto-prompt`, `--endpoint-url`, `--profile`,
  `--output` — ✅ all present as global flags.

### 18.6 Emacs-side facts, verified on Emacs 31.1

These are the ones that will cost an implementer a day each if rediscovered the
hard way.

| Claim | Verified result |
|---|---|
| `:coding 'utf-8` or `'undecided` on a CR-only stream | **CR count 0** — every `\r` rewritten to `\n`. `utf-8-unix` gives CR 2. |
| `:stderr BUFFER` | Emacs appends `"\nProcess NAME stderr finished\n"` **into the stderr text**. A pipe process with no explicit `:sentinel` does the same. |
| stderr-pipe vs. main sentinel ordering | **Nondeterministic** — both orders observed for identical code. |
| `json-parse-buffer` on empty buffer | signals `(json-end-of-file 1 nil 0)` |
| `equal` on a `cl-defstruct` record | **structural** (`equal` → t, `eq` → nil) |
| `make-process` and TRAMP | consults a handler **only** with `:file-handler t`; the parameter is documented in its docstring |
| `make-process` with remote `default-directory` | no error — subprocess silently runs in `$HOME` |
| `make-process` with deleted `default-directory` | signals `(file-missing "Setting current directory" …)` |
| `set-process-sentinel` to `#'ignore` before `delete-process` | callback suppressed; without it, sentinel fires with `"killed"` |

### 18.7 Dired's `C` under `evil-collection`, measured for 0.4.0

Emacs 31.1, `evil` and `evil-collection` from MELPA, a real `dired-mode`
buffer in `evil-normal-state`.

| Setup | `(key-binding "C")` |
|---|---|
| `keymap-set dired-mode-map "C"` ours, then `evil-collection-init 'dired` | `dired-do-copy` — **ours never fires**, though `keymap-lookup dired-mode-map` still reports it |
| `evil-define-key 'normal dired-mode-map` ours, then `evil-collection-init 'dired` | `dired-do-copy` — **clobbered by ordering** |
| `evil-collection-init 'dired`, then `evil-define-key 'normal` ours | `s3-manager-dired-do-copy` — the only arrangement that works |

An Evil state map outranks a major-mode map, which is the same mechanism
§10 documents for this package's own keymap — but here the package would be on
the losing side of it, and the winning side is a race against another package's
lazy initialisation. Hence §11.9: the Dired binding stays the user's.

---

| `json-available-p` | `t` here — but native JSON was **optional** in Emacs 29 |
| `process-connection-type` default | `t`, i.e. a **pty** — `:connection-type 'pipe` is mandatory |
| `tabulated-list-mode` `revert-buffer-function` | set to the **synchronous** `tabulated-list-revert`; must be overridden |
| `tabulated-list-format` `SORT` of `t` | sorts the **rendered string** — `"9 B"` sorts after `"1.8 GB"` |
| `tabulated-list-put-tag` | no-ops silently when `tabulated-list-padding` is 0 |

---

## 19. Implementation order

Build the vertical slice that proves the architecture before building breadth —
and build **the transport async and stderr-separated from the very first
commit**, because every later function is shaped by its contract.

1. `s3-manager--aws-async` + `s3-manager--base-args` + the version check.
2. Profile discovery and selection.
3. Bucket listing into a `tabulated-list-mode` buffer.
   *At this point the whole architecture is proven: async, error paths,
   rendering.*
4. `s3-manager-entry`, object listing with `--delimiter`, navigation, `^`.
5. Pagination and cache.
6. `G` and `R`.
7. Marks, `x`, `D`, recursive delete.
8. `RET`-to-view.
9. ERT suite and fixtures.
