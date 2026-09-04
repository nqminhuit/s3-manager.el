;;; s3-manager-copy.el --- Copying between S3 locations  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Minh Nguyen

;; Author: Minh Nguyen <nqminhuit@gmail.com>
;; URL: https://github.com/nqminhuit/s3-manager.el

;; This file is not part of GNU Emacs.
;; Part of s3-manager.el.  GPL-3.0-or-later; see LICENSE.

;;; Commentary:

;; `c' copies the entry at point to another S3 location.  The service does the
;; work: the bytes never reach this machine, which is the whole point of not
;; spelling it as a download followed by an upload.
;;
;; The destination is guarded before anything is invoked -- see
;; `s3-manager--check-destination', which exists because `s3 cp' will happily
;; copy an object onto itself and `s3 mv' only catches some spellings of it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 's3-manager-core)
(require 's3-manager-process)
(require 's3-manager-model)
(require 's3-manager-ui)
(require 's3-manager-transfer)

;;;; The job

(cl-defstruct (s3-manager-copy-job (:constructor s3-manager-copy-job--create)
                                   (:copier nil)
                                   (:conc-name s3-manager-job-))
  "One server-side copy, fixed at the moment it was confirmed.

Every slot is recorded before the transfer starts.  A transfer outlives
navigation -- it takes neither `:register' nor `:generation' -- so what
the buffer is showing when the transfer lands need not be what was
copied, and the refresh afterwards must name the destination rather than
ask the buffer.  PROFILE travels too, which makes that refresh a pure
function of this struct."
  profile
  source-bucket source-key
  bucket key                            ; the destination
  recursive                             ; the source is a prefix
  move)                                 ; `s3 mv': the source is deleted

(defun s3-manager--job-source-uri (job)
  "Return JOB's source as an s3:// URI."
  (s3-manager--uri (s3-manager-job-source-bucket job)
                   (s3-manager-job-source-key job)))

(defun s3-manager--job-uri (job)
  "Return JOB's destination as an s3:// URI."
  (s3-manager--uri (s3-manager-job-bucket job) (s3-manager-job-key job)))

(defun s3-manager--job-describe (job)
  "Return a gerund clause naming JOB.
`s3-manager--transfer' reads it as \"S3: %s...\" and \"S3: %s -- done\"."
  (format "%s %s to %s"
          (if (s3-manager-job-move job) "moving" "copying")
          (s3-manager--job-source-uri job) (s3-manager--job-uri job)))

;;;; Prompting

(defun s3-manager--job-verb (job &optional capitalized)
  "Return \"copy\" or \"move\" for JOB, CAPITALIZED when asked."
  (let ((verb (if (s3-manager-job-move job) "move" "copy")))
    (if capitalized (capitalize verb) verb)))

(defun s3-manager--job-aborted (job)
  "Return the abort message for JOB.
A declined copy must not report itself as an aborted upload, nor a
declined move as a copy."
  (format "%s aborted" (s3-manager--job-verb job t)))

(defvar s3-manager--destination-history nil
  "Minibuffer history of s3:// destinations.")

(defun s3-manager--read-destination (prompt initial)
  "Read an s3:// destination after PROMPT, returning (BUCKET . KEY).
INITIAL is offered as editable text rather than as a default value: the
useful edit is one segment changed in the middle of a key, which a
default cannot express.

`read-string' rather than `completing-read': the candidate set is every
prefix of every bucket, and enumerating it would cost a request per
keystroke.  The answer is trimmed, since a pasted URI carrying a stray
space is far commoner than a key that really ends in one."
  (s3-manager--parse-uri
   (string-trim
    (read-string prompt initial 's3-manager--destination-history))))

;;;; Refreshing both ends

(defun s3-manager--ancestor-steps (key)
  "Return (PREFIX . CHILD) from KEY's own parent up to the bucket root.
CHILD is what appears in, or vanishes from, PREFIX at that level.

Every level, not merely the immediate parent.  S3 has no directories, so
a key names whatever prefixes it happens to contain, and writing one can
bring a row into existence at each level above it: a/b/c.txt adds
`c.txt' to a/b/, `b/' to a/, and `a/' to the bucket root.

Caught live -- a recursive copy into backup/src/ left the listing that
was actually on screen, the prefix above backup/, showing no `backup/'
at all."
  (let ((child key) (steps nil) (done nil))
    (while (not done)
      (let ((prefix (s3-manager--parent-prefix child)))
        (push (cons prefix child) steps)
        (setq done (string-empty-p prefix)
              child prefix)))
    (nreverse steps)))

(defun s3-manager--refresh-listing (profile bucket prefix key)
  "Re-read any listing of PREFIX in BUCKET under PROFILE, point on KEY.
Does nothing when none is on screen: the cache entry has already gone,
so the next visit re-reads.

Buffers are matched by what they are showing rather than looked up by
`s3-manager--buffer-name'.  The name is derived from the profile and
bucket, so the lookup would be right for every buffer this package
creates and wrong for any other -- including the one that started the
copy, if a caller ever holds a listing in a buffer of its own."
  (dolist (buffer (buffer-list))
    (when (and (buffer-live-p buffer)
               (equal (buffer-local-value 'major-mode buffer) 's3-manager-mode)
               (equal (buffer-local-value 's3-manager--profile buffer) profile)
               (equal (buffer-local-value 's3-manager--bucket buffer) bucket)
               (equal (buffer-local-value 's3-manager--prefix buffer) prefix))
      (with-current-buffer buffer
        (s3-manager--reload nil key)))))

(defun s3-manager--after-copy (job)
  "Refresh both of JOB's ends, whether it succeeded or failed part-way.
A move empties the source as well as filling the destination, and `aws
s3' exits 1 or 2 having done part of the work, so the listings have
changed either way.

Caches go first and the reloads second, or a reload would re-cache a
listing that is about to be dropped."
  (let* ((profile (s3-manager-job-profile job))
         (endpoint (s3-manager--endpoint-for profile))
         (bucket (s3-manager-job-bucket job))
         (key (s3-manager-job-key job))
         (move (s3-manager-job-move job))
         (recursive (s3-manager-job-recursive job))
         (source-bucket (s3-manager-job-source-bucket job))
         (source-key (s3-manager-job-source-key job))
         (targets nil))
    ;; Subtrees first: a recursive transfer writes, and a move empties,
    ;; below the prefix as well as at it.
    (when recursive
      (s3-manager--cache-purge profile endpoint bucket key)
      (when move
        (s3-manager--cache-purge profile endpoint source-bucket source-key)))
    ;; The destination is collected first, so that when a rename in place
    ;; makes both ends the same listing, point lands on what arrived rather
    ;; than on what left.
    (dolist (step (s3-manager--ancestor-steps key))
      (push (list bucket (car step) (cdr step)) targets))
    (when move
      (dolist (step (s3-manager--ancestor-steps source-key))
        (push (list source-bucket (car step) (cdr step)) targets)))
    (setq targets (nreverse targets))
    (let ((seen nil))
      (dolist (target targets)
        (let ((where (cons (nth 0 target) (nth 1 target))))
          (unless (member where seen)
            (push where seen)
            (s3-manager--cache-invalidate
             (s3-manager--cache-key-for profile (nth 0 target) (nth 1 target)))
            (s3-manager--refresh-listing profile (nth 0 target) (nth 1 target)
                                         (nth 2 target))))))))

;;;; Running

(defun s3-manager--copy-args (job &optional dry-run)
  "Return the `s3 cp' arguments performing JOB.
With DRY-RUN nothing is written and the CLI reports what it would do.
The verb, both URIs and `--recursive' are shared between the two forms,
so a preview cannot describe something other than what it previews.

`--copy-props' is not passed: its default already copies tags and the
metadata directive, which is what copying an object means, and naming
the default would only pin us to it."
  (append (list "s3" (if (s3-manager-job-move job) "mv" "cp")
                (s3-manager--job-source-uri job) (s3-manager--job-uri job))
          (when (s3-manager-job-recursive job) '("--recursive"))
          (if dry-run
              '("--dryrun")
            ;; No --quiet and no --only-show-errors: both suppress the
            ;; progress the mode line depends on.
            '("--progress-frequency" "1"))))

(defun s3-manager--copy-start (job)
  "Run JOB, refreshing both ends when it stops, either way."
  (s3-manager--transfer
   (s3-manager--copy-args job)
   (s3-manager--job-describe job)
   (lambda () (s3-manager--after-copy job))
   (lambda ()
     ;; Also on failure: `aws s3' exits 1 or 2 having done part of the work,
     ;; exactly as in `s3-manager--delete-prefix', so both listings have
     ;; changed even though the command failed.
     (s3-manager--after-copy job)
     ;; `s3-manager--transfer' has already reported the CLI's own stderr
     ;; verbatim.  This says what state the two ends are left in, which the
     ;; stderr does not, and names the report again because this `message'
     ;; overwrites the summary that named it.
     (message
      "S3: %s stopped part-way -- %s; see %s"
      (s3-manager--job-describe job)
      (if (s3-manager-job-move job)
          ;; `aws s3 mv' copies and deletes one object at a time -- the CLI's
          ;; own wording -- so a key it did not reach is untouched at the
          ;; source and re-running finishes the job.
          "anything not moved is still at the source"
        "some objects were copied")
      s3-manager--error-buffer))))

(defun s3-manager--copy-confirm (job)
  "Confirm JOB, then run it.

A prefix takes a typed `yes', the bar a recursive upload and a recursive
delete already set, and is not probed: one `head-object' per key is
unbounded, and §11.8 rejected that for the recursive upload for the same
reason.  The question names both URIs in full, because the destination
is taken literally -- `s3 cp' flattens a prefix into whatever it is
given, so copying videos/ to backup/ puts the objects in backup/, and
putting them in backup/videos/ means saying so at the prompt."
  (if (s3-manager-job-recursive job)
      (progn
        (unless (yes-or-no-p
                 (format "Recursively %s everything under %s to %s%s? "
                         (s3-manager--job-verb job)
                         (s3-manager--job-source-uri job)
                         (s3-manager--job-uri job)
                         (if (s3-manager-job-move job)
                             ", deleting the originals" "")))
          (user-error "%s" (s3-manager--job-aborted job)))
        (s3-manager--copy-start job))
    (s3-manager--copy-probe job)))

(defun s3-manager--copy-probe (job)
  "Check whether JOB's destination exists, then run it.
`aws s3 cp' between two S3 locations overwrites without a word, exactly
as it does from a local file, so `s3api head-object' is the only way to
ask first -- against the destination's bucket, which need not be the one
on screen."
  (let ((uri (s3-manager--job-uri job)))
    (message "S3: checking %s..." uri)
    (s3-manager--head-object
     (s3-manager-job-bucket job) (s3-manager-job-key job)
     (lambda (response)
       (s3-manager--confirm-overwrite response uri
                                      (s3-manager--job-aborted job))
       (s3-manager--copy-start job))
     (lambda () (s3-manager--copy-start job))
     (lambda ()
       (unless (y-or-n-p
                (format "Could not check whether %s exists.  %s anyway? "
                        uri (s3-manager--job-verb job t)))
         (user-error "%s" (s3-manager--job-aborted job)))
       (s3-manager--copy-start job)))))

;;;; The command

(defun s3-manager--copy-job (entry bucket typed &optional move)
  "Return the job copying ENTRY to TYPED in BUCKET, or signal.
With MOVE the source is deleted afterwards, by `s3 mv'.
TYPED is the destination key as the user gave it; the guards run on the
normalised form, which is what makes them complete."
  (let* ((directory (eq (s3-manager-entry-type entry) 'directory))
         (key (s3-manager--copy-key typed
                                    (s3-manager-entry-display-name entry)
                                    directory)))
    (s3-manager--check-destination s3-manager--bucket
                                   (s3-manager-entry-key entry)
                                   bucket key directory)
    (s3-manager-copy-job--create
     :profile s3-manager--profile
     :source-bucket s3-manager--bucket
     :source-key (s3-manager-entry-key entry)
     :bucket bucket :key key
     :recursive directory
     :move move)))

;;;###autoload
(defun s3-manager-copy-to ()
  "Copy the entry at point to another S3 location.

The service copies it: the bytes never reach this machine.  The
destination is offered for editing, so what the prompt shows is what
happens, and an existing object there is named with its size and date
before it is replaced.

A prefix is copied recursively after a typed `yes', and its destination
is taken literally rather than gaining the source's own name -- see
`s3-manager--copy-confirm'."
  (interactive)
  (s3-manager--copy-command nil))

;;;###autoload
(defun s3-manager-rename ()
  "Rename the entry at point, or move it elsewhere in S3.

Its own key is offered for editing, so changing the last segment renames
it and changing the rest moves it.

The source is deleted only after it has been copied, one object at a
time -- that is `aws s3 mv' own description -- so a failure part-way
leaves anything it did not reach untouched at the source, and re-running
finishes the job."
  (interactive)
  (s3-manager--copy-command t))

(defun s3-manager--copy-command (move)
  "Copy the entry at point, or with MOVE, move it."
  (unless s3-manager--bucket
    (user-error "Not an object listing"))
  (let ((entry (s3-manager--entry-at-point)))
    (unless (s3-manager-entry-p entry)
      (user-error "%s buckets is not supported"
                  (if move "Renaming" "Copying")))
    (let* ((destination
            (s3-manager--read-destination
             (format "%s %s to: " (if move "Move" "Copy")
                     (s3-manager-entry-display-name entry))
             (s3-manager--uri s3-manager--bucket
                              (s3-manager--key-into
                               s3-manager--prefix
                               (s3-manager-entry-display-name entry)))))
           (job (s3-manager--copy-job entry (car destination)
                                      (cdr destination) move)))
      (s3-manager--copy-confirm job))))

(defun s3-manager--same-profile-p (buffer)
  "Return non-nil when BUFFER speaks to the same account as this one.
One `aws' invocation carries one --profile, and the endpoint follows
from the profile through `s3-manager--endpoint-for', so a server-side
copy across two of them is not a command that can be constructed."
  (equal s3-manager--profile
         (buffer-local-value 's3-manager--profile buffer)))

(defun s3-manager--copy-target ()
  "Return the S3 listing `C' should copy into, or nil for a download.

The nearest other window decides, not merely whether a listing is on
screen anywhere: with Dired beside this listing and a second listing in
a third window, `C' must still mean the window being aimed at.
`s3-manager--visible-listing' answers the broader question, which is the
one `s3-manager-dired-do-copy' needs.

Signals rather than falling back when that window is another profile: a
download is not what was asked for, and the CLI's own failure would be
mystifying."
  (let ((buffer (seq-some
                 (lambda (window)
                   (let ((b (window-buffer window)))
                     (and (or (buffer-local-value 's3-manager--bucket b)
                              (provided-mode-derived-p
                               (buffer-local-value 'major-mode b) 'dired-mode))
                          b)))
                 (cdr (window-list nil nil (selected-window))))))
    (when (and buffer (buffer-local-value 's3-manager--bucket buffer))
      (unless (s3-manager--same-profile-p buffer)
        (user-error "Cannot copy across profiles: this listing is %s, %s is %s"
                    (or s3-manager--profile "default")
                    (buffer-name buffer)
                    (or (buffer-local-value 's3-manager--profile buffer)
                        "default")))
      buffer)))

(defun s3-manager--copy-into (target)
  "Copy the entry at point into the listing TARGET is showing."
  (let* ((entry (s3-manager--entry-at-point))
         (job (s3-manager--copy-job
               entry
               (buffer-local-value 's3-manager--bucket target)
               ;; The other window's prefix, under the source's own name --
               ;; the Dired reading of "copy this there", and the reason
               ;; `s3-manager--key-into' is separate from
               ;; `s3-manager--copy-key', which honours a typed key exactly.
               (s3-manager--key-into
                (buffer-local-value 's3-manager--prefix target)
                (s3-manager-entry-display-name entry)))))
    ;; `C' writes without having prompted for anywhere, so it confirms.  A
    ;; prefix is already about to face the typed `yes'.
    (unless (or (s3-manager-job-recursive job)
                (y-or-n-p (format "Copy %s to %s? "
                                  (s3-manager--job-source-uri job)
                                  (s3-manager--job-uri job))))
      (user-error "Copy aborted"))
    (s3-manager--copy-confirm job)))

;;;###autoload
(defun s3-manager-copy ()
  "Copy the entry at point to whatever is in the other window.

Dired there means a download, recursively for a prefix.  Another S3
listing means a server-side copy into its prefix, which is the one thing
`G' and `R' cannot do.  The mirror of `s3-manager-dired-do-copy', so
`C' means the same thing wherever it is pressed."
  (interactive)
  (unless s3-manager--bucket
    (user-error "Not an object listing"))
  (if-let* ((target (s3-manager--copy-target)))
      (s3-manager--copy-into target)
    (if (eq (s3-manager-entry-type (s3-manager--entry-at-point)) 'directory)
        (s3-manager-get-recursive)
      (s3-manager-get))))

;;;###autoload
(defun s3-manager-copy-dry-run (&optional move)
  "Show what copying the entry at point elsewhere would do, doing nothing.
With a prefix argument MOVE, preview a move instead.

The preview a recursive transfer deserves, and most of all a recursive
move: it names every object that would be written, before any source is
deleted.  The destination is asked for the same way the transfer would
ask, or this would be previewing a different operation, and the guards
run first, so a self-move is refused here too.

No overwrite check.  `--dryrun' reports what would be sent, not what
would be replaced, and pretending otherwise would need one probe per
key -- the same caveat `s3-manager-upload-dry-run' carries."
  (interactive "P")
  (unless s3-manager--bucket
    (user-error "Not an object listing"))
  (let ((entry (s3-manager--entry-at-point)))
    (unless (s3-manager-entry-p entry)
      (user-error "Buckets cannot be copied"))
    (let* ((destination
            (s3-manager--read-destination
             (format "Preview %s of %s to: "
                     (if move "move" "copy")
                     (s3-manager-entry-display-name entry))
             (s3-manager--uri s3-manager--bucket
                              (s3-manager--key-into
                               s3-manager--prefix
                               (s3-manager-entry-display-name entry)))))
           (job (s3-manager--copy-job entry (car destination)
                                      (cdr destination) move)))
      (message "S3: listing what %s would do..." (s3-manager--job-describe job))
      (s3-manager--aws-async
       (s3-manager--copy-args job t)
       :profile s3-manager--profile
       :buffer (current-buffer)
       :parse nil
       ;; Enumerates the whole prefix; no fixed deadline fits one.
       :timeout s3-manager-transfer-timeout
       :name "s3-copy-dryrun"
       :on-success
       (lambda (output)
         (s3-manager--show-dry-run
          (format "Would %s %s to %s:"
                  (s3-manager--job-verb job)
                  (s3-manager--job-source-uri job)
                  (s3-manager--job-uri job))
          output))
       :on-error
       (lambda (err)
         (s3-manager--report-error
          err (format "s3 %s --dryrun"
                      (if (s3-manager-job-move job) "mv" "cp"))))))))

(provide 's3-manager-copy)

;;; s3-manager-copy.el ends here
