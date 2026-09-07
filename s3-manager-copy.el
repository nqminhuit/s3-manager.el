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
  move                                  ; `s3 mv': the source is deleted
  size)                                 ; source bytes, nil for a prefix

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

(defun s3-manager--job-verb (job &optional capitalized)
  "Return \"copy\" or \"move\" for JOB, CAPITALIZED when asked."
  (let ((verb (if (s3-manager-job-move job) "move" "copy")))
    (if capitalized (capitalize verb) verb)))

(defun s3-manager--job-aborted (job)
  "Return the abort message for JOB.
A declined copy must not report itself as an aborted upload, nor a
declined move as a copy."
  (format "%s aborted" (s3-manager--job-verb job t)))

;;;; Prompting

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

(defun s3-manager--as-prefix (typed)
  "Return TYPED as a prefix: empty, or ending in a slash.

A batch destination names a place rather than a key -- N objects cannot
share one key -- so the slash is supplied rather than demanded.  The
coercion `s3-manager--copy-key' already makes for a prefix source, and
load-bearing for the same measured reason: `s3 mv' compares the two URIs
as typed, so one dropped slash walks straight past its own guard."
  (if (or (string-empty-p typed) (string-suffix-p "/" typed))
      typed
    (concat typed "/")))

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
               (provided-mode-derived-p (buffer-local-value 'major-mode buffer)
                                        's3-manager-mode)
               (equal (buffer-local-value 's3-manager--profile buffer) profile)
               (equal (buffer-local-value 's3-manager--bucket buffer) bucket)
               (equal (buffer-local-value 's3-manager--prefix buffer) prefix))
      (with-current-buffer buffer
        (s3-manager--reload nil key)))))

(defun s3-manager--forget-mark (profile bucket prefix key)
  "Drop KEY's mark in any listing of PREFIX in BUCKET under PROFILE.
Either kind: the general mark as well as the deletion flag.

A moved object is gone, but its mark is keyed by name and outlives it:
marks are only cleared wholesale when the prefix changes, so renaming a
marked object and later creating something at the old key would give
that new object a mark the user never set -- one `x' would act on, or
one that would quietly enlarge the next batch.
`s3-manager--delete-finished' clears marks for the same reason."
  (dolist (buffer (buffer-list))
    (when (and (buffer-live-p buffer)
               (provided-mode-derived-p (buffer-local-value 'major-mode buffer)
                                        's3-manager-mode)
               (equal (buffer-local-value 's3-manager--profile buffer) profile)
               (equal (buffer-local-value 's3-manager--bucket buffer) bucket)
               (equal (buffer-local-value 's3-manager--prefix buffer) prefix))
      (with-current-buffer buffer
        (when s3-manager--marks (remhash key s3-manager--marks))
        ;; The count in the header names what a command would act on, so it
        ;; has to follow a mark that was dropped on the object's behalf and
        ;; not only one the user removed.
        (s3-manager--update-header-line)))))

(defun s3-manager--copy-targets (job)
  "Return the (BUCKET PREFIX CHILD) triples JOB changed, destination first.

CHILD is what appeared in, or vanished from, PREFIX at that level.
Destination first so that when a rename in place makes both ends the
same listing, point lands on what arrived rather than on what left --
`s3-manager--refresh-targets' keeps the first triple for a listing and
drops the rest.

Separate from the refreshing so a batch can union what its jobs touched
and re-read each listing once, rather than once per object."
  (let ((targets nil))
    (dolist (step (s3-manager--ancestor-steps (s3-manager-job-key job)))
      (push (list (s3-manager-job-bucket job) (car step) (cdr step)) targets))
    (when (s3-manager-job-move job)
      (dolist (step (s3-manager--ancestor-steps
                     (s3-manager-job-source-key job)))
        (push (list (s3-manager-job-source-bucket job) (car step) (cdr step))
              targets)))
    (nreverse targets)))

(defun s3-manager--refresh-targets (profile targets)
  "Drop and re-read PROFILE's TARGETS, each listing at most once.
Caches go first and the reloads second, or a reload would re-cache a
listing that is about to be dropped."
  (let ((seen nil))
    (dolist (target targets)
      (let ((where (cons (nth 0 target) (nth 1 target))))
        (unless (member where seen)
          (push where seen)
          (s3-manager--cache-invalidate
           (s3-manager--cache-key-for profile (nth 0 target) (nth 1 target)))
          (s3-manager--refresh-listing profile (nth 0 target) (nth 1 target)
                                       (nth 2 target)))))))

(defun s3-manager--purge-subtrees (job)
  "Drop cached listings beneath JOB's ends.
Only a recursive job has any: a single object writes at its prefix, not
below it.  A move empties the source subtree as well as filling the
destination's."
  (when (s3-manager-job-recursive job)
    (let* ((profile (s3-manager-job-profile job))
           (endpoint (s3-manager--endpoint-for profile)))
      (s3-manager--cache-purge profile endpoint
                               (s3-manager-job-bucket job)
                               (s3-manager-job-key job))
      (when (s3-manager-job-move job)
        (s3-manager--cache-purge profile endpoint
                                 (s3-manager-job-source-bucket job)
                                 (s3-manager-job-source-key job))))))

(defun s3-manager--forget-source-mark (job)
  "Drop the mark on JOB's source when the source is gone.
Only a move takes it away; after a copy the mark still names something."
  (when (s3-manager-job-move job)
    (s3-manager--forget-mark (s3-manager-job-profile job)
                             (s3-manager-job-source-bucket job)
                             (s3-manager--parent-prefix
                              (s3-manager-job-source-key job))
                             (s3-manager-job-source-key job))))

(defun s3-manager--after-copy (job)
  "Refresh both of JOB's ends, whether it succeeded or failed part-way.
A move empties the source as well as filling the destination, and `aws
s3' exits 1 or 2 having done part of the work, so the listings have
changed either way."
  (s3-manager--after-copies (list job)))

(defun s3-manager--after-copies (jobs)
  "Refresh both ends of every job in JOBS, re-reading each listing once.

Not `s3-manager--after-copy' per job: it invalidates a listing and then
reloads it, so ten objects copied into one prefix would be ten real
re-fetches of that prefix -- and each reload would re-cache what the
next invalidation was about to drop.  Unioning the targets first is why
`s3-manager--copy-targets' is separate from the refreshing at all."
  ;; Every job, including one that failed.  A move that stopped part-way
  ;; leaves its source in place and its mark is dropped anyway, which is
  ;; the single-job behaviour `s3-manager--after-copy' has always had: the
  ;; refresh that follows shows what is really still there.  Forgetting
  ;; only the ones that landed would need `s3-manager--run-sequentially' to
  ;; report which those were, and that driver is shared with the uploads.
  (dolist (job jobs)
    (s3-manager--purge-subtrees job)
    (s3-manager--forget-source-mark job))
  (when jobs
    (s3-manager--refresh-targets
     (s3-manager-job-profile (car jobs))
     (mapcan #'s3-manager--copy-targets jobs))))

;;;; Running

(defun s3-manager--copy-args (job &optional dry-run)
  "Return the `s3 cp' or `s3 mv' arguments performing JOB.
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

(defun s3-manager--copy-start (job &optional done)
  "Run JOB, refreshing both ends when it stops, either way.
DONE replaces the refresh, for a batch that refreshes once at the end,
and is called on failure too -- the parameter `s3-manager--upload-start'
already carries, for the same reason."
  (s3-manager--transfer
   (s3-manager--copy-args job)
   (s3-manager--job-describe job)
   (lambda () (if done (funcall done t) (s3-manager--after-copy job)))
   (lambda ()
     ;; Also on failure: `aws s3' exits 1 or 2 having done part of the work,
     ;; exactly as in `s3-manager--delete-prefix', so both listings have
     ;; changed even though the command failed.
     (if done
         ;; And no part-way message either: the next job in the batch
         ;; announces itself immediately, so this one would be printed out
         ;; of order and then overwritten.  The summary counts the failures
         ;; and names the report that holds them.
         (funcall done nil)
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
        s3-manager--error-buffer)))))

(defun s3-manager--copy-batch (jobs lead)
  "Offer, probe, confirm and then run JOBS.  LEAD names the operation.

Every job shares one destination bucket by construction -- `C' takes the
other window's, `c' and `r' take the one typed once -- which is what
lets a single `s3-manager--probe-each' cover all of them.

Order is the one 0.4.0 settled, now over a list: offer, then probe, then
confirm, then run."
  (let ((total (length jobs))
        (origin (current-buffer)))
    (when (s3-manager--offer-commands
           (mapcar #'s3-manager--copy-args jobs) lead
           ;; The total, not the largest: the bytes never cross this machine
           ;; either way, so what the offer buys is duration, and duration
           ;; adds up.
           (seq-reduce (lambda (sum job)
                         (+ sum (or (s3-manager-job-size job) 0)))
                       jobs 0))
      (message "S3: checking %d destination%s..." total (if (= total 1) "" "s"))
      (s3-manager--probe-each
       (s3-manager-job-bucket (car jobs)) (mapcar #'s3-manager-job-key jobs)
       nil nil
       (lambda (existing unchecked)
         (s3-manager--prompt-later
          origin
          (lambda ()
            ;; One question for the batch: a probe per object is bounded, a
            ;; prompt per object is not.  `y-or-n-p' even for a move, as `x'
            ;; asks for N flagged objects: the destruction is bounded and
            ;; counted, and `yes-or-no-p' is reserved for the recursive
            ;; forms, whose extent nothing knows.
            (unless (y-or-n-p
                     (s3-manager--batch-question lead existing unchecked))
              (user-error "%s" (s3-manager--job-aborted (car jobs))))
            (s3-manager--run-copies jobs))
          (s3-manager--job-verb (car jobs) t)))))))

(defun s3-manager--run-copies (jobs)
  "Run JOBS one at a time, refreshing what they touched once at the end.

Sequential for `s3-manager--run-sequentially' reason: each job is an
`aws' process holding a pipe and two buffers, and one listing can hand
this every object it shows."
  (let ((total (length jobs)))
    (s3-manager--run-sequentially
     jobs
     (lambda (job done) (s3-manager--copy-start job done))
     (lambda (failed)
       (s3-manager--after-copies jobs)
       ;; The jobs' own verb: a batch of moves reported as "copied 3
       ;; objects" would say the sources are still there.
       (s3-manager--batch-summary
        (if (s3-manager-job-move (car jobs)) "moved" "copied")
        "object" total failed)))))

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
        ;; No command offer for a recursive job: it is about to demand a
        ;; typed `yes', and two questions for one action is worse than not
        ;; offering.  The typed `yes' is the one that cannot go -- it is
        ;; there because the operation is unbounded.
        (unless (yes-or-no-p
                 (format "Recursively %s everything under %s to %s%s? "
                         (s3-manager--job-verb job)
                         (s3-manager--job-source-uri job)
                         (s3-manager--job-uri job)
                         (if (s3-manager-job-move job)
                             ", deleting the originals" "")))
          (user-error "%s" (s3-manager--job-aborted job)))
        (s3-manager--copy-start job))
    ;; Ahead of the probe: the size is already in the job, so a user who
    ;; wants the command should not wait for a `head-object' round trip and
    ;; answer an overwrite question about a copy they will not run.
    ;;
    ;; The bytes never cross this machine either way, so what the offer buys
    ;; here is duration rather than bandwidth -- a long copy outlives an
    ;; Emacs session more often than it saturates anything.
    (when (s3-manager--offer-command
           (s3-manager--copy-args job) (s3-manager--job-describe job)
           (s3-manager-job-size job))
      (s3-manager--copy-probe job))))

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
     :move move
     :size (s3-manager-entry-size entry))))

(defun s3-manager-copy-to ()
  "Copy the marked objects, or the entry at point, to another S3 location.

The service copies them: the bytes never reach this machine.  The
destination is offered for editing, so what the prompt shows is what
happens, and an existing object there is named with its size and date
before it is replaced.

One object is copied to a key, so it can be renamed on the way; several
are copied into a prefix, keeping their own names, behind one
confirmation.

A prefix is copied recursively after a typed `yes', and its destination
is taken literally rather than gaining the source's own name -- see
`s3-manager--copy-confirm'.  Only the entry at point can be one: a
prefix cannot be marked."
  (interactive)
  (s3-manager--copy-command nil))

(defun s3-manager-rename ()
  "Rename the entry at point, or move it -- or the marked objects -- in S3.

With nothing marked, the entry's own key is offered for editing, so
changing the last segment renames it and changing the rest moves it.
With several marked there is no rename to offer -- renaming is one key
becoming another -- so what is read is a destination prefix and each
object keeps its own name.

The source is deleted only after it has been copied, one object at a
time -- that is `aws s3 mv' own description -- so a failure part-way
leaves anything it did not reach untouched at the source, and re-running
finishes the job."
  (interactive)
  (s3-manager--copy-command t))

(defun s3-manager--copy-one (entry move)
  "Copy ENTRY to a key read from the minibuffer, or with MOVE, move it."
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
    (s3-manager--copy-confirm job)))

(defun s3-manager--copy-many (entries move)
  "Copy ENTRIES into one destination prefix, or with MOVE, move them.

A prefix, not a key: N objects cannot share one key, so what is read
here names a place and each object keeps its own last segment.  That
also means `r' over a batch can only move, never rename -- renaming is
one key becoming another, and there is no such thing for several.

The prompt opens on this listing's own prefix, which every job would
then refuse as its own source.  That is the same starting point `c'
offers for one object, and it is the useful one: the edit is a segment
changed in the middle, not a URI typed from nothing."
  (let* ((verb (if move "Move" "Copy"))
         (total (length entries))
         (destination (s3-manager--read-destination
                       (format "%s %d objects to prefix: " verb total)
                       (s3-manager--uri s3-manager--bucket
                                        s3-manager--prefix)))
         (bucket (car destination))
         (prefix (s3-manager--as-prefix (cdr destination))))
    (s3-manager--copy-batch
     ;; Every job is built before any of them runs, so a destination
     ;; `s3-manager--check-destination' refuses stops the batch with nothing
     ;; written rather than part-way through.
     (mapcar (lambda (entry)
               (s3-manager--copy-job
                entry bucket
                (s3-manager--key-into
                 prefix (s3-manager-entry-display-name entry))
                move))
             entries)
     (format "%s %d objects to %s" verb total
             (s3-manager--uri bucket prefix)))))

(defun s3-manager--copy-command (move)
  "Copy the marked objects, or the entry at point, or with MOVE, move them."
  (unless s3-manager--bucket
    (user-error "Not an object listing"))
  (let ((entries (s3-manager--marked-entries)))
    (if (cdr entries)
        (s3-manager--copy-many entries move)
      (s3-manager--copy-one (car entries) move))))

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

(defun s3-manager--copy-into-job (entry target)
  "Return the job copying ENTRY into the listing TARGET is showing."
  (s3-manager--copy-job
   entry
   (buffer-local-value 's3-manager--bucket target)
   ;; The other window's prefix, under the source's own name -- the Dired
   ;; reading of "copy this there", and the reason `s3-manager--key-into' is
   ;; separate from `s3-manager--copy-key', which honours a typed key exactly.
   (s3-manager--key-into
    (buffer-local-value 's3-manager--prefix target)
    (s3-manager-entry-display-name entry))))

(defun s3-manager--copy-into-one (entry target)
  "Copy ENTRY into the listing TARGET is showing."
  (let ((job (s3-manager--copy-into-job entry target)))
    ;; `C' writes without having prompted for anywhere, so it confirms.  A
    ;; prefix is already about to face the typed `yes'.
    (unless (or (s3-manager-job-recursive job)
                (y-or-n-p (format "Copy %s to %s? "
                                  (s3-manager--job-source-uri job)
                                  (s3-manager--job-uri job))))
      (user-error "Copy aborted"))
    (s3-manager--copy-confirm job)))

(defun s3-manager--copy-into-batch (entries target)
  "Copy every entry in ENTRIES into the listing TARGET is showing.

Every job is built before any of them runs, so a destination
`s3-manager--check-destination' refuses -- copying a listing into
itself, above all -- stops the batch with nothing written rather than
part-way through.

No job here is ever recursive: a prefix cannot be marked, and the mark
reader filters for objects besides.  That is what keeps the typed `yes',
the `unbounded' sizing and the recursive cache purge on the at-point
path where they belong."
  (s3-manager--copy-batch
   (mapcar (lambda (entry) (s3-manager--copy-into-job entry target)) entries)
   (format "Copy %d objects to %s" (length entries)
           (s3-manager--uri (buffer-local-value 's3-manager--bucket target)
                            (buffer-local-value 's3-manager--prefix target)))))

(defun s3-manager--copy-into (target)
  "Copy into the listing TARGET is showing.
The marked objects when any are marked, else the entry at point."
  (let ((entries (s3-manager--marked-entries)))
    (if (cdr entries)
        (s3-manager--copy-into-batch entries target)
      (s3-manager--copy-into-one (car entries) target))))

(defun s3-manager-copy ()
  "Copy to whatever is in the other window.

Dired there means a download: of the marked objects, or of the entry at
point when none are marked, recursively for a prefix.  Another S3
listing means a server-side copy into its prefix -- of the marked
objects, or of the entry at point -- which is the one thing `G' and `R'
cannot do.  The mirror of
`s3-manager-dired-do-copy', so `C' means the same thing wherever it is
pressed."
  (interactive)
  (unless s3-manager--bucket
    (user-error "Not an object listing"))
  (if-let* ((target (s3-manager--copy-target)))
      (s3-manager--copy-into target)
    (let ((entries (s3-manager--marked-entries)))
      ;; Only the at-point fallback can be a prefix: marks are refused on
      ;; one, and the mark reader filters for objects besides.
      (if (and (null (cdr entries))
               (eq (s3-manager-entry-type (car entries)) 'directory))
          (s3-manager-get-recursive)
        (s3-manager--download entries)))))

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
