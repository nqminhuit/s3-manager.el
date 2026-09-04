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
;; Bytes move with `aws s3 cp' rather than `s3api get-object': it performs a
;; multipart parallel download above 8MB, reports progress, and preserves the
;; object's modification time, none of which get-object does.

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

`dired-dwim-target-directory' is documented for exactly this -- its own
comment says a non-Dired buffer may want to profit from it -- and it
returns nil when the user has turned `dired-dwim-target' off, so this
follows their setting rather than imposing one."
  (and (bound-and-true-p dired-dwim-target)
       (require 'dired-aux nil t)
       (dired-dwim-target-directory)))

(defun s3-manager--transfer-finished ()
  "Note that one transfer in this buffer has stopped."
  (setq s3-manager--transfers (max 0 (1- s3-manager--transfers)))
  (when (zerop s3-manager--transfers)
    (setq s3-manager--transfer-status nil))
  (force-mode-line-update))

(defun s3-manager--transfer (args description &optional on-done on-failure)
  "Run the transfer ARGS, reporting progress in the current buffer.
DESCRIPTION names the operation in messages and error reports.
ON-DONE, when given, is called with no arguments after it succeeds.
ON-FAILURE likewise after it fails, for releasing anything the caller
set up in advance."
  (cl-incf s3-manager--transfers)
  (setq s3-manager--transfer-status "starting")
  (force-mode-line-update)
  (message "S3: %s..." description)
  (s3-manager--aws-async
   args
   :profile s3-manager--profile
   :buffer (current-buffer)
   ;; Neither :register nor :generation: navigation must not abort a
   ;; multi-gigabyte transfer, and progress keeps reporting into the buffer
   ;; that started it even after that buffer has moved on.
   :parse nil
   ;; Not `s3-manager-timeout': that deadline is measured from the start of
   ;; the process, so a transfer big enough to outlast it is killed while
   ;; healthy and reported as "No response after 120 seconds".
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
  (let* ((directory (s3-manager--local-default-directory))
         (chosen (expand-file-name
                  (read-file-name (format "Download %s to: " name)
                                  directory nil nil name)))
         ;; Naming a directory means "into it, under the object's own name".
         (destination (if (file-directory-p chosen)
                          (expand-file-name name chosen)
                        chosen)))
    ;; `aws s3 cp' overwrites without asking, so this is the only chance.
    (when (and (file-exists-p destination)
               (not (y-or-n-p (format "%s exists.  Overwrite? " destination))))
      (user-error "Download aborted"))
    (let ((parent (file-name-directory destination)))
      (unless (file-directory-p parent)
        (make-directory parent t)))
    destination))

(defun s3-manager-get ()
  "Download the object at point."
  (interactive)
  (unless s3-manager--bucket
    (user-error "Not an object listing"))
  (let ((entry (s3-manager--entry-at-point)))
    (unless (eq (s3-manager-entry-type entry) 'object)
      (user-error "%s"
                  (substitute-command-keys
                   "That is a prefix; use \\[s3-manager-get-recursive]")))
    (let* ((key (s3-manager-entry-key entry))
           (destination (s3-manager--read-destination-file
                         (s3-manager-entry-display-name entry))))
      (s3-manager--transfer
       (list "s3" "cp" (s3-manager--s3-uri key) destination
             "--progress-frequency" "1")
       (format "downloading %s to %s" key (abbreviate-file-name destination))))))

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
           (destination (file-name-as-directory
                         (expand-file-name
                          (read-directory-name
                           (format "Download %s recursively to: " prefix)
                           default nil nil)))))
      (unless (file-directory-p destination)
        (unless (y-or-n-p (format "Create %s? " destination))
          (user-error "Download aborted"))
        (make-directory destination t))
      (s3-manager--transfer
       (list "s3" "cp" (s3-manager--s3-uri prefix) destination
             "--recursive" "--progress-frequency" "1")
       (format "downloading %s to %s"
               prefix (abbreviate-file-name destination))))))

(defun s3-manager--upload-key-name (source)
  "Return the S3 leaf name for local SOURCE.
The mirror of `s3-manager--view-file-name', but running outwards: no
tilde guard is needed (nothing expands them on the S3 side), and an
unusable name is refused rather than defaulted -- inventing a key would
write the user's bytes somewhere they never named."
  (let ((name (file-name-nondirectory (directory-file-name source))))
    (when (member name '("" "." ".."))
      (user-error "Cannot derive an object name from %s" source))
    name))

(defun s3-manager--upload-key (source prefix)
  "Return the destination key for uploading SOURCE into PREFIX.

A directory yields a key ending in \"/\", and that slash is
load-bearing rather than cosmetic: `s3 cp DIR s3://B/PREFIX --recursive'
maps DIR/a.txt onto PREFIX/a.txt and drops the directory\='s own name, so
the tree is scattered flat across the listing the user was looking at.
Writing the leaf into the destination is what keeps it."
  (concat prefix
          (s3-manager--upload-key-name source)
          (if (file-directory-p source) "/" "")))

(defun s3-manager--upload-source ()
  "Read a local file or directory to upload, and return its absolute path."
  (let ((source (expand-file-name
                 (read-file-name "Upload file or directory: "
                                 (s3-manager--local-default-directory)
                                 nil t))))
    ;; MUSTMATCH is advisory -- a default, a history entry, or completion
    ;; ignoring it all reach here -- and these checks also narrow the window
    ;; between this prompt and the transfer, which for a single file spans a
    ;; round trip and an unbounded confirmation.
    (unless (file-exists-p source)
      (user-error "%s does not exist" source))
    (unless (file-readable-p source)
      (user-error "%s is not readable" source))
    (if (file-directory-p source)
        (when (null (directory-files
                     source nil directory-files-no-dot-files-regexp t))
          ;; S3 has no directories, so uploading an empty one transfers
          ;; nothing, exits 0, and is reported as a success that leaves the
          ;; listing unchanged -- which reads as the feature being broken.
          (user-error "%s is empty, and S3 has no directories to create"
                      source))
      (unless (file-regular-p source)
        ;; A fifo or a character device would make `aws s3 cp' read forever,
        ;; and `s3-manager-transfer-timeout' is nil, so nothing would stop it.
        (user-error "%s is not a regular file" source)))
    source))

(defun s3-manager--after-upload (prefix key &optional recursive)
  "Refresh after an upload of KEY into PREFIX.
With RECURSIVE, cached listings at and beneath KEY go too.  PREFIX is
the destination recorded when the upload started, not the buffer's
prefix now -- a transfer outlives navigation -- so the listing is
re-read only while that destination is still on screen."
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
passed.  With DRY-RUN, nothing is transferred and the CLI reports what
it would have sent.  SOURCE is absolute, so it can never be read as an
option.

Every argument that decides *what* is sent -- the paths, `--recursive',
the symlink flag -- is shared between the two forms.  A preview that
could differ from the upload it previews would be worse than no preview,
since the symlink decision leans on it."
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

(defun s3-manager--upload-start (source uri key prefix &optional recursive)
  "Upload SOURCE to URI, refreshing PREFIX with point on KEY afterwards.
With RECURSIVE, SOURCE is a directory and its whole tree is sent."
  ;; Re-checked here rather than only at the prompt: a head-object round trip
  ;; and an unbounded `y-or-n-p' sit between the two, and a file removed in
  ;; that window would otherwise be reported as a partial transfer failure
  ;; for a file that was never opened.
  (unless (file-readable-p source)
    (user-error "%s is no longer readable" source))
  (let ((done (lambda () (s3-manager--after-upload prefix key recursive))))
    (s3-manager--transfer
     (s3-manager--upload-args source uri recursive)
     (format "uploading %s to %s" (abbreviate-file-name source) uri)
     done
     ;; Also on failure: `aws s3' exits 1 or 2 having done part of the work,
     ;; exactly as in `s3-manager--delete-prefix'.
     done)))

(defun s3-manager--upload-later (buffer thunk)
  "Run THUNK in BUFFER from a zero-second timer.
A prompt inside a process sentinel re-enters the minibuffer from
wherever Emacs happened to be; `s3-manager--profiles-resolved' takes the
same hop.  Both branches take it, so ordering does not depend on the
answer.  A `user-error' from THUNK is the user declining; anything else
is reported, since a signal inside a timer is easy to miss."
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
             (s3-manager--local-error "Upload" (error-message-string err))
             "upload"))))))))

(defun s3-manager--head-object-absent-p (err)
  "Return non-nil when ERR is `head-object' reporting that the key is absent.
An allowlist, never a denylist: 403 is a permission error, 255 an
unreachable endpoint, a timeout has no exit code, and reading any as
absence would silently overwrite an object.  Measured: absence is exit
254 plus this stderr, whose status is botocore's format string and so
identical across S3-compatible endpoints."
  (and (eq (nth 0 err) 's3-manager-cli-error)
       (eql (nth 2 err) 254)
       (string-match-p
        "An error occurred (404) when calling the HeadObject operation"
        (or (nth 3 err) ""))))

(defun s3-manager--upload-confirm-overwrite (response uri)
  "Confirm overwriting URI, which `head-object' RESPONSE says exists.
Signals a `user-error' when the answer is no."
  (unless (y-or-n-p
           (format "%s already exists (%s, modified %s).  Overwrite? "
                   uri
                   (s3-manager--format-size
                    (alist-get 'ContentLength response))
                   (s3-manager--format-date
                    (alist-get 'LastModified response))))
    (user-error "Upload aborted")))

(defun s3-manager--upload-probe (source uri key prefix)
  "Check whether KEY exists, then upload SOURCE to URI.

`aws s3 cp' overwrites without a word and has no flag that would stop
it, so `s3api head-object' is the only way to ask first."
  (let ((origin (current-buffer)))
    (message "S3: checking %s..." uri)
    (s3-manager--aws-async
     (list "s3api" "head-object"
           "--bucket" s3-manager--bucket "--key" key
           "--output" "json")
     :profile s3-manager--profile
     :buffer origin
     ;; No :register -- that slot belongs to the listing, and taking it would
     ;; orphan a fetch in flight and let `^' cancel this probe.  No
     ;; :generation either: the user asked for this upload and must get an
     ;; answer even if they have navigated since, which is also why URI, KEY
     ;; and PREFIX were captured before the call.
     :name "s3-head-object"
     :on-success
     (lambda (response)
       (s3-manager--upload-later
        origin
        (lambda ()
          (s3-manager--upload-confirm-overwrite response uri)
          (s3-manager--upload-start source uri key prefix))))
     :on-error
     (lambda (err)
       (if (s3-manager--head-object-absent-p err)
           (s3-manager--upload-later
            origin
            (lambda () (s3-manager--upload-start source uri key prefix)))
         ;; Not absence: the check itself failed.  Real AWS answers 403
         ;; rather than 404 for a missing key when the caller lacks
         ;; s3:ListBucket, so refusing outright would make upload useless
         ;; under a tight policy -- but proceeding silently would be an
         ;; unannounced overwrite.  Report it, then ask.
         (s3-manager--report-error err "head-object")
         (s3-manager--upload-later
          origin
          (lambda ()
            (unless (y-or-n-p
                     (format "Could not check whether %s exists.  Upload anyway? "
                             uri))
              (user-error "Upload aborted"))
            (s3-manager--upload-start source uri key prefix))))))))

(defun s3-manager-upload ()
  "Upload a local file or directory into the prefix being shown.

The destination is this listing's own prefix, under the source's own
name, regardless of where point is; the prompts name the full target
URI, so there is nothing to infer.  A directory is uploaded
recursively, after a typed confirmation."
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
          ;; objects is about to be written, no per-key overwrite check is
          ;; made -- one probe per file is unbounded too -- and this must not
          ;; ride on a single keystroke.
          (unless (yes-or-no-p
                   (format "Recursively upload everything under %s to %s%s? "
                           (abbreviate-file-name source) uri
                           (if s3-manager-upload-follow-symlinks
                               " (following symlinks)" "")))
            (user-error "Upload aborted"))
          (s3-manager--upload-start source uri key prefix t))
      (s3-manager--upload-probe source uri key prefix))))

(defun s3-manager-upload-dry-run ()
  "Show what uploading a local file or directory would write, without writing.

The preview a recursive upload deserves: it names every object that
would be created, before any of them are.  Symbolic links are resolved
here exactly as they would be by the upload itself, so a link to a large
tree shows up as the files it would really send.

No overwrite check.  `--dryrun' reports what would be sent, not what
would be replaced, and pretending otherwise would need one probe per
file."
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
