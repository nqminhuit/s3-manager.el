;;; s3-manager-transfer.el --- Downloading and uploading objects  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Minh Nguyen

;; Author: Minh Nguyen <nqminhuit@gmail.com>
;; URL: https://github.com/nqminhuit/s3-manager.el

;; This file is not part of GNU Emacs.
;; Part of s3-manager.el.  GPL-3.0-or-later; see LICENSE.

;;; Commentary:

;; Download and upload.  Bytes move with `aws s3 cp', which does multipart
;; transfers and reports progress.  A transfer is neither registered nor
;; generation-guarded, so navigating away cannot abort one.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 's3-manager-core)
(require 's3-manager-process)
(require 's3-manager-model)
(require 's3-manager-ui)

;;;; Transfers
;;
;; Bytes move with `aws s3 cp' rather than `s3api get-object': it does
;; multipart above 8MB, reports progress, and preserves the object's
;; modification time, none of which get-object does.

(declare-function dired-dwim-target-directory "dired-aux" ())

(defun s3-manager--local-default-directory ()
  "Return the directory local paths should default to.
A Dired buffer in another window wins, so the two-window copy workflow
works in both directions; otherwise `s3-manager-download-directory'."
  (file-name-as-directory
   (expand-file-name (or (s3-manager--dwim-directory)
                         s3-manager-download-directory))))

(defun s3-manager--dwim-directory ()
  "Return a Dired directory visible in another window, or nil.
`dired-dwim-target-directory' is documented for exactly this, and it
returns nil when `dired-dwim-target' is off -- so this follows the
user's setting rather than imposing one."
  (and (bound-and-true-p dired-dwim-target)
       (require 'dired-aux nil t)
       (dired-dwim-target-directory)))

(defun s3-manager--refuse-remote (path complaint)
  "Signal a `user-error' when PATH is remote.  COMPLAINT completes the message.

Checked before any predicate that would touch PATH: `file-directory-p'
on a TRAMP path opens a connection.  `aws' cannot reach one in any
case, and `default-directory' is pinned to a local directory, so the
CLI's own failure would be mystifying."
  (when (file-remote-p path)
    (user-error "%s is remote; aws cannot %s" path complaint)))

(defun s3-manager--repeated (names)
  "Return the members of NAMES appearing more than once, each named once."
  (seq-uniq (seq-filter (lambda (name)
                          (> (seq-count (lambda (other) (equal other name))
                                        names)
                             1))
                        names)))

(defun s3-manager--transfer-finished ()
  "Note that one transfer in this buffer has stopped."
  (setq s3-manager--transfers (max 0 (1- s3-manager--transfers)))
  (when (zerop s3-manager--transfers)
    (setq s3-manager--transfer-status nil))
  (force-mode-line-update))

(defun s3-manager--large-transfer-p (size)
  "Return non-nil when a transfer of SIZE should offer its command.
SIZE is a byte count, or `unbounded' for a recursive transfer."
  (and s3-manager-large-transfer-size
       (or (eq size 'unbounded)
           (and (integerp size) (> size s3-manager-large-transfer-size)))))

(defun s3-manager--offer-command (args description size)
  "Ask whether to run ARGS here, or hand over the command line.
DESCRIPTION and SIZE are as in `s3-manager--offer-commands', of which
this is the one-command form."
  (s3-manager--offer-commands (list args) description size))

(defun s3-manager--offer-commands (argvs description size)
  "Ask whether to run ARGVS here, or hand over the command lines.
Returns non-nil to run them, nil when they were handed over instead, and
signals a `user-error' on quit -- so a caller can write
`(when (s3-manager--offer-commands ...) ...)'.

DESCRIPTION names the operation.  SIZE decides whether to ask at all;
for a batch it is the total, not the largest member, since what makes a
transfer worth leaving Emacs for is duration and duration adds up."
  (if (not (s3-manager--large-transfer-p size))
      t
    (pcase (car (read-multiple-choice
                 (format "%s (%s)" description
                         (if (eq size 'unbounded)
                             "recursive, size unknown"
                           (s3-manager--format-size size)))
                 '((?r "run here" "Transfer it from Emacs, as usual")
                   (?c "copy command"
                       "Put the aws command in the kill ring instead")
                   (?q "quit" "Do nothing"))))
      (?r t)
      (?c (s3-manager--show-commands
           (mapcar (lambda (args)
                     (s3-manager--full-argv s3-manager--profile args))
                   argvs))
          nil)
      (_ (user-error "Aborted")))))

(defun s3-manager--transfer (args description &optional on-done on-failure)
  "Run the transfer ARGS, reporting progress in the current buffer.
DESCRIPTION names the operation in messages and error reports.  ON-DONE
runs after it succeeds, ON-FAILURE after it fails -- for releasing
whatever the caller set up in advance."
  (cl-incf s3-manager--transfers)
  (setq s3-manager--transfer-status "starting")
  (force-mode-line-update)
  (message "S3: %s..." description)
  (s3-manager--aws-async
   args
   :profile s3-manager--profile
   :buffer (current-buffer)
   ;; Neither :register nor :generation: navigating away must not abort a
   ;; multi-gigabyte transfer.
   :parse nil
   ;; Not `s3-manager-timeout': that deadline runs from the start, so a
   ;; transfer big enough to outlast it is killed while healthy.
   :timeout s3-manager-transfer-timeout
   :progress-stream 'stdout
   ;; No --quiet and no --only-show-errors: both suppress the progress this
   ;; depends on.  --progress-frequency throttles it at the source.
   :on-progress (lambda (segment)
                  (setq s3-manager--transfer-status
                        (s3-manager--format-progress segment))
                  (force-mode-line-update))
   :on-success (lambda (_output)
                 (s3-manager--transfer-finished)
                 (message "S3: %s -- done" description)
                 (when on-done (funcall on-done)))
   :on-error (lambda (err)
               (s3-manager--transfer-finished)
               (s3-manager--report-error err description)
               (when on-failure (funcall on-failure)))))

(defun s3-manager--read-destination-file (name)
  "Read a local destination for an object called NAME."
  (let ((chosen (expand-file-name
                 (read-file-name (format "Download %s to: " name)
                                 (s3-manager--local-default-directory)
                                 nil nil
                                 ;; The editable default must be a name that
                                 ;; cannot escape the directory it joins:
                                 ;; "~root" here meant one RET wrote to /root.
                                 (s3-manager--safe-leaf name)))))
    ;; Must stay above `file-directory-p', which would open a connection.
    (s3-manager--refuse-remote chosen "write there")
    (let ((destination
           ;; Naming a directory means "into it, under the object's own name".
           (if (file-directory-p chosen)
               (expand-file-name name chosen)
             chosen)))
      ;; `aws s3 cp' overwrites without asking, so this is the only chance.
      (when (and (file-exists-p destination)
                 (not (y-or-n-p (format "%s exists.  Overwrite? " destination))))
        (user-error "Download aborted"))
      (let ((parent (file-name-directory destination)))
        (unless (file-directory-p parent)
          (make-directory parent t)))
      destination)))

(defun s3-manager--get-args (uri destination &optional recursive)
  "Return the `s3 cp' arguments downloading URI to DESTINATION.
With RECURSIVE, URI is a prefix and its whole tree comes down.  A value
rather than a command, so what runs and what is shown are one vector.
DESTINATION is absolute, so it cannot be read as an option."
  (append (list "s3" "cp" uri destination)
          (when recursive '("--recursive"))
          ;; No --quiet and no --only-show-errors: both suppress the progress
          ;; the mode line depends on.
          '("--progress-frequency" "1")))

(defun s3-manager--download-one (entry)
  "Download the single object ENTRY, asking where it should land."
  (unless (eq (s3-manager-entry-type entry) 'object)
    (user-error "%s"
                (substitute-command-keys
                 "That is a prefix; use \\[s3-manager-get-recursive]")))
  (let* ((key (s3-manager-entry-key entry))
         (destination (s3-manager--read-destination-file
                       (s3-manager-entry-display-name entry)))
         (args (s3-manager--get-args (s3-manager--s3-uri key) destination))
         (description (format "downloading %s to %s"
                              key (abbreviate-file-name destination))))
    (when (s3-manager--offer-command args description
                                     (s3-manager-entry-size entry))
      (s3-manager--transfer args description))))

(defun s3-manager--read-local-directory (prompt default)
  "Read a local directory after PROMPT, offering DEFAULT.
Returns the path and does *not* create it, so a caller can put the
question of creating it after whatever else it asks.  A remote one is
refused -- not hypothetical, since the default honours
`dired-dwim-target' and a remote Dired next door is what gets offered."
  (let ((directory (expand-file-name (read-directory-name prompt default
                                                          nil nil))))
    (s3-manager--refuse-remote directory "write there")
    (file-name-as-directory directory)))

(defun s3-manager--ensure-local-directory (directory)
  "Create DIRECTORY after confirmation when it is absent.
`aws s3 cp' would make it silently, so a mistyped path would otherwise
be a directory nobody meant with the bytes already in it."
  (unless (file-directory-p directory)
    (unless (y-or-n-p (format "Create %s? " directory))
      (user-error "Download aborted"))
    (make-directory directory t)))

(defun s3-manager--check-download-leaves (entries)
  "Signal unless every entry in ENTRIES can be written under its own name.
A batch names no destination out loud, so a key like \"backups/~root\"
would write outside the chosen directory with nothing having shown the
user where -- see `s3-manager--safe-leaf-p'.

The whole batch is refused rather than the offenders skipped: several
unsafe names cannot share one stand-in, and downloading some of what was
marked is worse than downloading none.  The single-object path still
reaches them, and shows the path first."
  (when-let* ((unsafe (seq-remove
                       (lambda (entry)
                         (s3-manager--safe-leaf-p
                          (s3-manager--leaf-of
                           (s3-manager-entry-display-name entry))))
                       entries)))
    (user-error "Cannot write %s under its own name; download %s singly"
                (string-join (mapcar #'s3-manager-entry-key
                                     (seq-take unsafe 3))
                             ", ")
                (if (cdr unsafe) "them" "it"))))

(defun s3-manager--check-download-collisions (jobs directory)
  "Signal when two of JOBS would write the same file in DIRECTORY.
Two keys in one listing are distinct, and so are their leaves on a
case-sensitive filesystem.  On a case-insensitive one \"A.txt\" and
\"a.txt\" are one file, and the batch would run two transfers at it with
nothing to say which won."
  (let* ((fold (file-name-case-insensitive-p directory))
         (names (mapcar (lambda (job)
                          (let ((leaf (file-name-nondirectory (car job))))
                            (if fold (downcase leaf) leaf)))
                        jobs)))
    (when-let* ((clashing (s3-manager--repeated names)))
      (user-error "Marked objects share a destination name: %s"
                  (string-join clashing ", ")))))

(defun s3-manager--download-jobs (entries directory)
  "Return one (DESTINATION ARGS DESCRIPTION) per entry in ENTRIES.
Each lands under its own display name in DIRECTORY, which
`s3-manager--check-download-leaves' has established stays inside it."
  (mapcar
   (lambda (entry)
     (let* ((key (s3-manager-entry-key entry))
            (destination (expand-file-name
                          (s3-manager--leaf-of
                           (s3-manager-entry-display-name entry))
                          directory)))
       (list destination
             (s3-manager--get-args (s3-manager--s3-uri key) destination)
             (format "downloading %s to %s"
                     key (abbreviate-file-name destination)))))
   entries))

(defun s3-manager--download-batch (entries)
  "Download ENTRIES into one local directory, one transfer at a time.
One prompt for the directory and at most one for overwriting: a probe
per object is bounded, a prompt per object is not."
  (let* ((total (length entries))
         ;; Before the prompt: refusing afterwards would waste the answer.
         (_ (s3-manager--check-download-leaves entries))
         (directory (s3-manager--read-local-directory
                     (format "Download %d objects to: " total)
                     (s3-manager--local-default-directory)))
         (jobs (s3-manager--download-jobs entries directory))
         (lead (format "Download %d objects to %s"
                       total (abbreviate-file-name directory))))
    (s3-manager--check-download-collisions jobs directory)
    (when (s3-manager--offer-commands
           (mapcar #'cadr jobs) lead
           ;; The total, not the largest: what makes a batch worth leaving
           ;; Emacs for is how long it runs, and that adds up.
           (seq-reduce (lambda (sum entry)
                         (+ sum (or (s3-manager-entry-size entry) 0)))
                       entries 0))
      ;; Only now: answering `c' or `q' at the offer must not leave a
      ;; directory behind for a transfer that never ran.
      (s3-manager--ensure-local-directory directory)
      ;; After the offer too, so someone who takes the command line away is
      ;; not asked about files Emacs will no longer write.
      (when-let* ((existing (seq-filter #'file-exists-p (mapcar #'car jobs))))
        ;; `aws s3 cp' overwrites without asking, so this is the only chance.
        (unless (y-or-n-p (s3-manager--batch-question
                           lead
                           (mapcar #'file-name-nondirectory existing) nil))
          (user-error "Download aborted")))
      (s3-manager--run-sequentially
       jobs
       (lambda (job done)
         (s3-manager--transfer (nth 1 job) (nth 2 job)
                               (lambda () (funcall done t))
                               (lambda () (funcall done nil))))
       (lambda (failed)
         (s3-manager--batch-summary "downloaded" "object" total failed))))))

(defun s3-manager--download (entries)
  "Download ENTRIES, which is never empty.
Dired's split: one object gets a filename prompt and can be renamed on
the way down, while several share a directory and keep their own names.
Marks survive -- the objects are still there, as after `dired-do-copy'."
  (if (cdr entries)
      (s3-manager--download-batch entries)
    (s3-manager--download-one (car entries))))

(defun s3-manager-get ()
  "Download the marked objects, or the object at point when none are marked."
  (interactive)
  (unless s3-manager--bucket
    (user-error "Not an object listing"))
  (s3-manager--download (s3-manager--marked-entries)))

(defun s3-manager-get-recursive ()
  "Download every object under the prefix at point."
  (interactive)
  (unless s3-manager--bucket
    (user-error "Not an object listing"))
  (let ((entry (s3-manager--entry-at-point)))
    (unless (eq (s3-manager-entry-type entry) 'directory)
      (user-error "%s"
                  (substitute-command-keys
                   "That is an object; use \\[s3-manager-get]")))
    (let* ((prefix (s3-manager-entry-key entry))
           (leaf (directory-file-name (s3-manager-entry-display-name entry)))
           (default (expand-file-name
                     leaf (s3-manager--local-default-directory)))
           (destination (s3-manager--read-local-directory
                         (format "Download %s recursively to: " prefix)
                         default)))
      (let ((args (s3-manager--get-args
                   (s3-manager--s3-uri prefix) destination t))
            (description (format "downloading %s to %s"
                                 prefix (abbreviate-file-name destination))))
        (when (s3-manager--offer-command args description 'unbounded)
          ;; After the offer, so handing the command over does not leave a
          ;; directory behind for a transfer that never ran here.
          (s3-manager--ensure-local-directory destination)
          (s3-manager--transfer args description))))))

(defun s3-manager--upload-key-name (source)
  "Return the S3 leaf name for local SOURCE.
No tilde guard: nothing expands one on the S3 side.  An unusable name is
refused rather than defaulted -- inventing a key would write the user's
bytes somewhere they never named."
  (let ((name (file-name-nondirectory (directory-file-name source))))
    (when (member name s3-manager--unsafe-leaf-names)
      (user-error "Cannot derive an object name from %s" source))
    name))

(defun s3-manager--upload-key (source prefix)
  "Return the destination key for uploading SOURCE into PREFIX.
A directory yields a key ending in \"/\", and that slash is load-bearing:
without it `s3 cp DIR s3://B/PREFIX --recursive' drops the directory's
own name and scatters the tree flat across the listing."
  (concat prefix
          (s3-manager--upload-key-name source)
          (if (file-directory-p source) "/" "")))

(defun s3-manager--upload-source ()
  "Read a local file or directory to upload, and return its absolute path."
  (let ((source (expand-file-name
                 (read-file-name "Upload file or directory: "
                                 (s3-manager--local-default-directory)
                                 nil t))))
    ;; MUSTMATCH is advisory -- a default, a history entry or completion
    ;; ignoring it all reach here -- and these checks also narrow the window
    ;; between this prompt and the transfer.
    (s3-manager--refuse-remote source "read it")
    (unless (file-exists-p source)
      (user-error "%s does not exist" source))
    (unless (file-readable-p source)
      (user-error "%s is not readable" source))
    (if (file-directory-p source)
        (when (null (directory-files
                     source nil directory-files-no-dot-files-regexp t))
          ;; S3 has no directories, so an empty one transfers nothing, exits
          ;; 0, and reads as a success that did not work.
          (user-error "%s is empty, and S3 has no directories to create"
                      source))
      (unless (file-regular-p source)
        ;; `aws s3 cp' would read a fifo forever, and
        ;; `s3-manager-transfer-timeout' is nil by default.
        (user-error "%s is not a regular file" source)))
    source))

(defun s3-manager--after-upload (prefix key &optional recursive)
  "Refresh after an upload of KEY into PREFIX.
With RECURSIVE, cached listings at and beneath KEY go too.  PREFIX is
what was recorded when the upload started, not the buffer's prefix now:
a transfer outlives navigation."
  (s3-manager--cache-invalidate (s3-manager--cache-key prefix))
  (when recursive
    (s3-manager--cache-purge s3-manager--profile
                             (s3-manager--endpoint-for s3-manager--profile)
                             s3-manager--bucket
                             key))
  (when (equal prefix s3-manager--prefix)
    (s3-manager--reload nil key)))

(defun s3-manager--upload-args (source uri recursive &optional dry-run)
  "Return the `s3 cp' arguments uploading SOURCE to URI.
With RECURSIVE, both paths carry a trailing slash and `--recursive' is
passed.  With DRY-RUN nothing is transferred.  SOURCE is absolute, so it
cannot be read as an option.

Everything deciding *what* is sent is shared between the two forms: a
preview that could differ from what it previews is worse than none, and
the symlink decision leans on it."
  (append (list "s3" "cp"
                (if recursive (file-name-as-directory source) source)
                uri)
          (when recursive '("--recursive"))
          (when (and recursive (not s3-manager-upload-follow-symlinks))
            '("--no-follow-symlinks"))
          (if dry-run
              '("--dryrun")
            ;; No --quiet and no --only-show-errors: both suppress the
            ;; progress the mode line depends on.  Neither belongs in a dry
            ;; run, which transfers nothing to report on.
            '("--progress-frequency" "1"))))

(defun s3-manager--upload-description (source uri)
  "Return the gerund clause naming an upload of SOURCE to URI."
  (format "uploading %s to %s" (abbreviate-file-name source) uri))

(defun s3-manager--upload-start (source uri key prefix &optional recursive done)
  "Upload SOURCE to URI, refreshing PREFIX with point on KEY afterwards.
With RECURSIVE, SOURCE is a directory and its whole tree is sent.  DONE
replaces the refresh for a batch that refreshes once at the end, and is
called on failure too."
  ;; Re-checked rather than trusted from the prompt: a head-object round trip
  ;; and an unbounded `y-or-n-p' sit between the two.
  (unless (file-readable-p source)
    (user-error "%s is no longer readable" source))
  (let ((finish (lambda (ok)
                  (if done
                      (funcall done ok)
                    (s3-manager--after-upload prefix key recursive)))))
    (s3-manager--transfer
     (s3-manager--upload-args source uri recursive)
     (s3-manager--upload-description source uri)
     (lambda () (funcall finish t))
     ;; Also on failure: `aws s3' exits 1 or 2 having done part of the work.
     (lambda () (funcall finish nil)))))

(defun s3-manager--prompt-later (buffer thunk &optional context)
  "Run THUNK in BUFFER from a zero-second timer.
CONTEXT names the operation in a failure report; it defaults to
\"Upload\".

A prompt inside a process sentinel re-enters the minibuffer from
wherever Emacs happened to be, so every branch takes this hop and
ordering cannot depend on the answer.  A `user-error' from THUNK is the
user declining; anything else is reported, since a signal inside a timer
is easy to miss."
  (let ((context (or context "Upload")))
    (run-at-time
     0 nil
     (lambda ()
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (condition-case err
               (funcall thunk)
             (user-error (message "S3: %s" (error-message-string err)))
             (error
              (s3-manager--report-error
               (s3-manager--local-error context (error-message-string err))
               (downcase context))))))))))

(defun s3-manager--head-object-absent-p (err)
  "Return non-nil when ERR is `head-object' reporting that the key is absent.
An allowlist, never a denylist: 403 is a permission error and 255 an
unreachable endpoint, and reading either as absence would silently
overwrite an object.  The stderr matched is botocore's own format
string, so it is identical across S3-compatible endpoints."
  (and (eq (nth 0 err) 's3-manager-cli-error)
       (eql (nth 2 err) 254)
       (string-match-p
        "An error occurred (404) when calling the HeadObject operation"
        (or (nth 3 err) ""))))

(defun s3-manager--confirm-overwrite (response uri &optional aborted)
  "Confirm overwriting URI, which `head-object' RESPONSE says exists.
Signals a `user-error' reading ABORTED, by default \"Upload aborted\",
when the answer is no.  The service's own size and date are shown: they
are what says whether this is the object the user thinks it is."
  (unless (y-or-n-p
           (format "%s already exists (%s, modified %s).  Overwrite? "
                   uri
                   (s3-manager--format-size
                    (alist-get 'ContentLength response))
                   (s3-manager--format-date
                    (alist-get 'LastModified response))))
    (user-error "%s" (or aborted "Upload aborted"))))

(defun s3-manager--head-object-args (bucket key)
  "Return the `head-object' arguments probing KEY in BUCKET."
  (list "s3api" "head-object" "--bucket" bucket "--key" key "--output" "json"))

(defun s3-manager--head-object (bucket key on-present on-absent on-unknown)
  "Ask whether KEY exists in BUCKET, then take one of three branches.
ON-PRESENT is called with the parsed response; the other two take no
arguments.  ON-UNKNOWN means the check itself failed, already reported.

BUCKET is explicit because a copy's destination need not be the bucket
on screen; the profile is this buffer's and must be, since one
invocation carries one --profile.

Every branch goes through `s3-manager--prompt-later': this runs in a
sentinel and all three callers may prompt."
  (let ((origin (current-buffer)))
    (s3-manager--aws-async
     (s3-manager--head-object-args bucket key)
     :profile s3-manager--profile
     :buffer origin
     ;; No :register -- that slot belongs to the listing, and taking it would
     ;; orphan a fetch and let `^' cancel this probe.  No :generation either:
     ;; the user asked for this and must get an answer even after navigating,
     ;; which is why the caller captures what it needs beforehand.
     :name "s3-head-object"
     :on-success (lambda (response)
                   (s3-manager--prompt-later
                    origin (lambda () (funcall on-present response))))
     :on-error
     (lambda (err)
       (if (s3-manager--head-object-absent-p err)
           (s3-manager--prompt-later origin on-absent)
         ;; Not absence: the check itself failed.  Real AWS answers 403
         ;; rather than 404 for a missing key when the caller lacks
         ;; s3:ListBucket, so refusing outright would make this useless under
         ;; a tight policy -- but proceeding silently would be an unannounced
         ;; overwrite.  Report it, then let the caller ask.
         (s3-manager--report-error err "head-object")
         (s3-manager--prompt-later origin on-unknown))))))

(defun s3-manager--upload-probe (source uri key prefix)
  "Check whether KEY exists, then upload SOURCE to URI.
`aws s3 cp' overwrites without a word, so `s3api head-object' is the
only way to ask first.  The CLI's own `--no-overwrite' skips silently
rather than asking, and is not available at the version required here."
  (message "S3: checking %s..." uri)
  (let ((start (lambda () (s3-manager--upload-start source uri key prefix))))
    (s3-manager--head-object
     s3-manager--bucket key
     (lambda (response)
       (s3-manager--confirm-overwrite response uri)
       (funcall start))
     start
     (lambda ()
       (unless (y-or-n-p
                (format "Could not check whether %s exists.  Upload anyway? "
                        uri))
         (user-error "Upload aborted"))
       (funcall start)))))

(defun s3-manager-upload ()
  "Upload a local file or directory into the prefix being shown.
The destination is this listing's own prefix under the source's own
name, wherever point is, and the prompts name the full target URI.  A
directory goes recursively, after a typed confirmation."
  (interactive)
  (unless s3-manager--bucket
    (user-error "%s" (substitute-command-keys
                      "Not an object listing; \\[s3-manager-open] a bucket first")))
  (let* ((source (s3-manager--upload-source))
         (prefix s3-manager--prefix)
         (key (s3-manager--upload-key source prefix))
         (uri (s3-manager--s3-uri key)))
    (if (file-directory-p source)
        (progn
          ;; `yes-or-no-p', as for a recursive delete: an unbounded number of
          ;; objects is about to be written with no per-key overwrite check,
          ;; and that must not ride on a single keystroke.
          (unless (yes-or-no-p
                   (format "Recursively upload everything under %s to %s%s? "
                           (abbreviate-file-name source) uri
                           (if s3-manager-upload-follow-symlinks
                               " (following symlinks)" "")))
            (user-error "Upload aborted"))
          (s3-manager--upload-start source uri key prefix t))
      ;; Ahead of the probe: the size is known locally, so someone who wants
      ;; the command should not wait for a `head-object' round trip and answer
      ;; an overwrite question about an upload they will not run.
      (when (s3-manager--offer-command
             (s3-manager--upload-args source uri nil)
             (s3-manager--upload-description source uri)
             (or (file-attribute-size (file-attributes source)) 0))
        (s3-manager--upload-probe source uri key prefix)))))

(declare-function dired-get-marked-files "dired"
                  (&optional localp arg filter distinguish-one-marked error))
(declare-function dired-do-copy "dired-aux" (&optional arg))

(defun s3-manager--visible-listing ()
  "Return an S3 object listing shown in another window, or nil.
The selected window is excluded, so the question reads the same from
either side of the pair."
  (seq-find #'s3-manager--object-listing-p
            (mapcar #'window-buffer
                    (delq (selected-window) (window-list)))))

(defun s3-manager--dired-target ()
  "Return an S3 object-listing buffer to upload into.
A visible one wins, so the window layout picks the destination."
  (let ((visible (s3-manager--visible-listing))
        (live (seq-filter #'s3-manager--object-listing-p (buffer-list))))
    (cond
     (visible visible)
     ((null live) (user-error "No S3 object listing to upload into"))
     ((null (cdr live)) (car live))
     (t (get-buffer (completing-read "Upload into: "
                                     (mapcar #'buffer-name live) nil t))))))

(defun s3-manager--dired-sources ()
  "Return the marked files in this Dired buffer, as absolute paths."
  (let ((files (dired-get-marked-files)))
    (unless files (user-error "Nothing to upload"))
    (dolist (file files)
      (s3-manager--refuse-remote file "read it"))
    (mapcar #'expand-file-name files)))

(defun s3-manager--probe-each (bucket keys existing unchecked done)
  "Probe KEYS in BUCKET one at a time, then call DONE with EXISTING and UNCHECKED.
BUCKET is explicit because a copy's destination need not be the bucket
on screen; the profile is this buffer's and must be.

Sequential: the ordering makes the confirmation reproducible, and the
probes are dwarfed by the transfer that follows.  Collected rather than
asked as they go, because a probe per object is bounded and a prompt per
object is not."
  (if (null keys)
      (funcall done (nreverse existing) (nreverse unchecked))
    (let ((key (car keys)) (rest (cdr keys)))
      (s3-manager--aws-async
       ;; The argv helper, not `s3-manager--head-object': these callbacks
       ;; classify and chain rather than prompt, and its timer hop would defer
       ;; every step of the batch for no reason.
       (s3-manager--head-object-args bucket key)
       :profile s3-manager--profile
       :buffer (current-buffer)
       :name "s3-head-object"
       :on-success
       (lambda (_response)
         (s3-manager--probe-each bucket rest (cons key existing) unchecked done))
       :on-error
       (lambda (err)
         (if (s3-manager--head-object-absent-p err)
             (s3-manager--probe-each bucket rest existing unchecked done)
           (s3-manager--record-error err "head-object")
           (s3-manager--probe-each bucket rest existing (cons key unchecked)
                                   done)))))))

(defun s3-manager--batch-question (lead existing unchecked)
  "Return the one confirmation covering a batch.
LEAD names the operation and its destination; EXISTING and UNCHECKED are
what `s3-manager--probe-each' found.  Only three overwrite victims are
named -- a prompt that scrolls is a prompt nobody reads."
  (concat lead
          (when existing
            (format ", overwriting %d (%s)" (length existing)
                    (string-join (seq-take existing 3) ", ")))
          (when unchecked
            (format ", %d unchecked" (length unchecked)))
          "? "))

(defun s3-manager--run-sequentially (items start finish)
  "Run START on each of ITEMS in turn, then call FINISH with the failures.
START receives one item and a continuation, and must call that
continuation exactly once -- non-nil for success -- on *both* paths, or
the batch stops there with the rest unattempted and no summary.  FINISH
receives how many failed.

Sequential: each transfer is an `aws' process holding a pipe and two
buffers, and one listing can hand this hundreds of marked objects."
  (let ((failed 0) (step nil))
    (setq step
          (lambda (remaining)
            (if (null remaining)
                (funcall finish failed)
              (funcall start (car remaining)
                       (lambda (ok)
                         (unless ok (setq failed (1+ failed)))
                         (funcall step (cdr remaining)))))))
    (funcall step items)))

(defun s3-manager--batch-summary (verb noun total failed)
  "Say how a batch of TOTAL ended, FAILED of them having not run.
VERB is the past tense naming what happened; NOUN names one item.  A
batch is not atomic, so failures are counted apart from the total and
the report buffer holding them is named."
  (if (zerop failed)
      (message "S3: %s %d %s%s" verb total noun (if (= total 1) "" "s"))
    (message "S3: %s %d, %d failed -- see %s"
             verb (- total failed) failed s3-manager--error-buffer)))

(defun s3-manager--upload-batch (sources prefix)
  "Upload SOURCES into PREFIX one at a time, refreshing when the last lands."
  (let ((total (length sources))
        (directories (seq-filter #'file-directory-p sources)))
    (s3-manager--run-sequentially
     sources
     (lambda (source done)
       (let* ((recursive (file-directory-p source))
              (key (s3-manager--upload-key source prefix))
              (uri (s3-manager--s3-uri key)))
         ;; Guarded here rather than in `s3-manager--upload-start', whose
         ;; `user-error' would unwind the whole batch.
         (if (not (file-readable-p source))
             (progn
               (s3-manager--record-error
                (s3-manager--local-error (format "upload %s" source)
                                         "No longer readable")
                "upload")
               (funcall done nil))
           (s3-manager--upload-start source uri key prefix recursive done))))
     (lambda (failed)
       (s3-manager--after-upload prefix nil)
       ;; Each uploaded directory created keys beneath its own prefix.
       (dolist (directory directories)
         (s3-manager--cache-purge
          s3-manager--profile
          (s3-manager--endpoint-for s3-manager--profile)
          s3-manager--bucket
          (s3-manager--upload-key directory prefix)))
       (s3-manager--batch-summary "uploaded" "file" total failed)))))

;;;###autoload
(defun s3-manager-dired-upload ()
  "Upload the marked files in this Dired buffer into an S3 listing.
With nothing marked, the file at point, as Dired itself does.  One
confirmation covers the batch: a probe per file is bounded, a prompt per
file is not."
  (interactive)
  (unless (derived-mode-p 'dired-mode)
    (user-error "Not a Dired buffer"))
  (let* ((sources (s3-manager--dired-sources))
         (target (s3-manager--dired-target))
         (recursive (seq-some #'file-directory-p sources))
         (leaves (mapcar #'s3-manager--upload-key-name sources)))
    ;; Keys come from the leaf, so /a/x.txt and /b/x.txt both write
    ;; PREFIX/x.txt: two transfers, one object, nothing to say which won.
    ;; The probe cannot see it -- neither key exists yet.
    (when-let* ((clashing (s3-manager--repeated leaves)))
      (user-error "Marked files share a name: %s"
                  (string-join clashing ", ")))
    (with-current-buffer target
      (let* ((prefix s3-manager--prefix)
             (keys (mapcar (lambda (source)
                             (s3-manager--upload-key source prefix))
                           (seq-remove #'file-directory-p sources)))
             (origin (current-buffer)))
        (message "S3: checking %d destination%s..."
                 (length keys) (if (= (length keys) 1) "" "s"))
        (s3-manager--probe-each
         s3-manager--bucket keys nil nil
         (lambda (existing unchecked)
           (s3-manager--prompt-later
            origin
            (lambda ()
              (let ((question
                     (s3-manager--batch-question
                      (format "Upload %d file%s to %s"
                              (length sources)
                              (if (= (length sources) 1) "" "s")
                              (s3-manager--s3-uri prefix))
                      existing unchecked)))
                ;; A directory makes the volume unbounded, as it does for `P'.
                (unless (if recursive
                            (yes-or-no-p question)
                          (y-or-n-p question))
                  (user-error "Upload aborted"))
                (s3-manager--upload-batch sources prefix))))))))))

;;;###autoload
(defun s3-manager-dired-do-copy (&optional arg)
  "Upload the marked files to a visible S3 listing, else `dired-do-copy'.
Bound to `C' in Dired, so one key means \"copy to the other window\" in
both directions.  The window layout decides, not whether a listing
merely exists: a buried S3 buffer must not turn an ordinary copy into an
upload to a bucket the user cannot see.  ARG passes through untouched."
  (interactive "P" dired-mode)
  (if (s3-manager--visible-listing)
      (s3-manager-dired-upload)
    (dired-do-copy arg)))

(defun s3-manager-upload-dry-run ()
  "Show what uploading a local file or directory would write, without writing.
Names every object that would be created, before any of them are.
Symbolic links resolve exactly as the upload itself would resolve them.

No overwrite check: `--dryrun' reports what would be sent, not what
would be replaced, and pretending otherwise needs a probe per file."
  (interactive)
  (unless s3-manager--bucket
    (user-error "Not an object listing"))
  (let* ((source (s3-manager--upload-source))
         (recursive (file-directory-p source))
         (key (s3-manager--upload-key source s3-manager--prefix))
         (uri (s3-manager--s3-uri key)))
    (message "S3: listing what uploading %s would write..."
             (abbreviate-file-name source))
    (s3-manager--aws-async
     (s3-manager--upload-args source uri recursive t)
     :profile s3-manager--profile
     :buffer (current-buffer)
     :parse nil
     ;; Enumerates the whole tree, which is what it is recommended for.
     :timeout s3-manager-transfer-timeout
     :name "s3-cp-dryrun"
     :on-success
     (lambda (output)
       (s3-manager--show-dry-run
        (format "Would upload %s to %s:"
                (abbreviate-file-name source) uri)
        output))
     :on-error (lambda (err)
                 (s3-manager--report-error err "s3 cp --dryrun")))))

(provide 's3-manager-transfer)

;;; s3-manager-transfer.el ends here
