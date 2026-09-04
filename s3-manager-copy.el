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
  recursive)                            ; the source is a prefix

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
  (format "copying %s to %s"
          (s3-manager--job-source-uri job) (s3-manager--job-uri job)))

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

;;;; Refreshing both ends

(defun s3-manager--invalidate-ancestors (profile bucket key)
  "Drop PROFILE's cached listings for every prefix above KEY in BUCKET.
Not merely its parent: S3 has no directories, so a key names whatever
prefixes it happens to contain, and writing one can bring several rows
into existence at once.  Copying to a/b/c.txt adds the row `b/' to the
listing of a/ and the row `a/' to the listing of the bucket root."
  (let ((prefix (s3-manager--parent-prefix key)))
    (s3-manager--cache-invalidate
     (s3-manager--cache-key-for profile bucket prefix))
    (while (not (string-empty-p prefix))
      (setq prefix (s3-manager--parent-prefix prefix))
      (s3-manager--cache-invalidate
       (s3-manager--cache-key-for profile bucket prefix)))))

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
  "Refresh JOB's destination, whether it succeeded or failed part-way.
Caches go first and the reload second, or the reload would re-cache a
listing that is about to be dropped."
  (let ((profile (s3-manager-job-profile job))
        (bucket (s3-manager-job-bucket job))
        (key (s3-manager-job-key job)))
    (s3-manager--invalidate-ancestors profile bucket key)
    (when (s3-manager-job-recursive job)
      (s3-manager--cache-purge profile (s3-manager--endpoint-for profile)
                               bucket key))
    (s3-manager--refresh-listing profile bucket
                                 (s3-manager--parent-prefix key) key)))

;;;; Running

(defun s3-manager--copy-args (job &optional dry-run)
  "Return the `s3 cp' arguments performing JOB.
With DRY-RUN nothing is written and the CLI reports what it would do.
The verb, both URIs and `--recursive' are shared between the two forms,
so a preview cannot describe something other than what it previews.

`--copy-props' is not passed: its default already copies tags and the
metadata directive, which is what copying an object means, and naming
the default would only pin us to it."
  (append (list "s3" "cp"
                (s3-manager--job-source-uri job) (s3-manager--job-uri job))
          (when (s3-manager-job-recursive job) '("--recursive"))
          (if dry-run
              '("--dryrun")
            ;; No --quiet and no --only-show-errors: both suppress the
            ;; progress the mode line depends on.
            '("--progress-frequency" "1"))))

(defun s3-manager--copy-start (job)
  "Run JOB, refreshing its destination when it stops, either way."
  (let ((finish (lambda ()
                  ;; Also on failure: `aws s3' exits 1 or 2 having done part
                  ;; of the work, exactly as in `s3-manager--delete-prefix',
                  ;; so the listing has changed even though the command
                  ;; failed.
                  (s3-manager--after-copy job))))
    (s3-manager--transfer (s3-manager--copy-args job)
                          (s3-manager--job-describe job)
                          finish finish)))

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
       (s3-manager--confirm-overwrite response uri "Copy aborted")
       (s3-manager--copy-start job))
     (lambda () (s3-manager--copy-start job))
     (lambda ()
       (unless (y-or-n-p
                (format "Could not check whether %s exists.  Copy anyway? "
                        uri))
         (user-error "Copy aborted"))
       (s3-manager--copy-start job)))))

;;;; The command

(defun s3-manager--copy-job (entry bucket typed)
  "Return the job copying ENTRY to TYPED in BUCKET, or signal.
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
     :recursive directory)))

;;;###autoload
(defun s3-manager-copy-to ()
  "Copy the object at point to another S3 location.

The service copies it: the bytes never reach this machine.  The
destination is offered for editing, so what the prompt shows is what
happens, and an existing object there is named with its size and date
before it is replaced."
  (interactive)
  (unless s3-manager--bucket
    (user-error "Not an object listing"))
  (let ((entry (s3-manager--entry-at-point)))
    (unless (s3-manager-entry-p entry)
      (user-error "Copying buckets is not supported"))
    (when (eq (s3-manager-entry-type entry) 'directory)
      (user-error "Copying a prefix is not supported yet"))
    (let* ((destination
            (s3-manager--read-destination
             (format "Copy %s to: " (s3-manager-entry-display-name entry))
             (s3-manager--uri s3-manager--bucket
                              (s3-manager--key-into
                               s3-manager--prefix
                               (s3-manager-entry-display-name entry)))))
           (job (s3-manager--copy-job entry (car destination)
                                      (cdr destination))))
      (s3-manager--copy-probe job))))

(provide 's3-manager-copy)

;;; s3-manager-copy.el ends here
