;;; s3-manager-delete.el --- Removing objects and prefixes  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Minh Nguyen

;; Author: Minh Nguyen <nqminhuit@gmail.com>
;; URL: https://github.com/nqminhuit/s3-manager.el

;; This file is not part of GNU Emacs.
;; Part of s3-manager.el.  GPL-3.0-or-later; see LICENSE.

;;; Commentary:

;; Marked batches, one object, or a whole prefix.  The recursive form can
;; destroy an unbounded amount of data, so it demands a typed `yes' and offers
;; a dry run first.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 's3-manager-core)
(require 's3-manager-process)
(require 's3-manager-model)
(require 's3-manager-ui)

;;;; Deletion

(defun s3-manager--after-delete (&optional prefix)
  "Refresh after a deletion, invalidating the affected cache entries.
With PREFIX, everything at or beneath it is dropped, which is what a
recursive delete requires."
  ;; The listing on screen has changed by definition, so drop it first.  A
  ;; recursive delete does not imply this: the prefix removed sits *below*
  ;; the listing showing it, so purging at-and-under the prefix leaves the
  ;; parent cached and the refresh redisplays the prefix that no longer
  ;; exists.
  (s3-manager--cache-invalidate (s3-manager--cache-key))
  (when prefix
    (s3-manager--cache-purge s3-manager--profile
                             (s3-manager--endpoint-for s3-manager--profile)
                             s3-manager--bucket
                             prefix))
  (s3-manager--reload))

(defun s3-manager--delete-report-errors (errors)
  "Report per-key ERRORS from a `delete-objects' response."
  (s3-manager--report-error
   (list 's3-manager-partial-error
         (format "aws s3api delete-objects --bucket %s" s3-manager--bucket)
         0
         (mapconcat (lambda (failure)
                      (format "%s: %s (%s)"
                              (alist-get 'Key failure)
                              (alist-get 'Message failure)
                              (alist-get 'Code failure)))
                    errors "\n"))
   "delete-objects"))

(defun s3-manager--delete-finished (deleted errors)
  "Finish a batch deletion of DELETED keys with ERRORS."
  (s3-manager--clear-marks)
  (if errors
      (progn
        (s3-manager--delete-report-errors errors)
        (message "S3: deleted %d, %d failed -- see %s"
                 deleted (length errors) s3-manager--error-buffer))
    (message "S3: deleted %d object%s" deleted (if (= deleted 1) "" "s")))
  (s3-manager--after-delete))

(defun s3-manager--delete-payload (keys)
  "Return the --delete argument deleting KEYS.
Built with `json-serialize', which escapes the quotes and newlines an S3
key may legally contain; the result is one argv element, never shell
input."
  (json-serialize
   (list (cons 'Objects
               (vconcat (mapcar (lambda (key) (list (cons 'Key key)))
                                keys))))))

(defun s3-manager--delete-chunks (chunks deleted errors)
  "Delete CHUNKS of keys in sequence, accumulating DELETED and ERRORS."
  (if (null chunks)
      (s3-manager--delete-finished deleted errors)
    (let ((chunk (car chunks))
          (rest (cdr chunks)))
      (s3-manager--aws-async
       (list "s3api" "delete-objects"
             "--bucket" s3-manager--bucket
             "--delete" (s3-manager--delete-payload chunk)
             "--output" "json")
       :profile s3-manager--profile
       :buffer (current-buffer)
       :name "s3-delete-objects"
       :on-success
       (lambda (response)
         ;; delete-objects exits 0 even when individual keys fail, so the
         ;; Errors array has to be read on the success path.  Ignoring it
         ;; would silently report a partial deletion as a complete one.
         (s3-manager--delete-chunks
          rest
          (+ deleted (length (alist-get 'Deleted response)))
          (append errors (alist-get 'Errors response))))
       :on-error
       (lambda (err)
         (s3-manager--report-error err "delete-objects")
         (s3-manager--delete-finished deleted errors))))))

(defun s3-manager-execute ()
  "Delete the objects marked in this buffer."
  (interactive)
  (unless s3-manager--bucket
    (user-error "Not an object listing"))
  (let* ((keys (s3-manager--marked-keys))
         (count (length keys)))
    (when (zerop count)
      (user-error "No objects are marked"))
    (unless (y-or-n-p (format "Delete %d object%s? "
                              count (if (= count 1) "" "s")))
      (user-error "Deletion aborted"))
    (message "S3: deleting %d object%s..." count (if (= count 1) "" "s"))
    ;; delete-objects takes at most 1000 keys per call.
    (s3-manager--delete-chunks (seq-partition keys 1000) 0 nil)))

(defun s3-manager--delete-object (key)
  "Delete the single object KEY, after confirmation."
  (unless (y-or-n-p (format "Delete %s? " (s3-manager--s3-uri key)))
    (user-error "Deletion aborted"))
  (s3-manager--aws-async
   (list "s3api" "delete-object"
         "--bucket" s3-manager--bucket "--key" key
         "--output" "json")
   :profile s3-manager--profile
   :buffer (current-buffer)
   :name "s3-delete-object"
   :on-success (lambda (_response)
                 (message "S3: deleted %s" (s3-manager--s3-uri key))
                 (s3-manager--after-delete))
   :on-error (lambda (err)
               (s3-manager--report-error err "delete-object")
               (s3-manager--after-delete))))

(defun s3-manager--delete-prefix (prefix)
  "Delete every object under PREFIX, after emphatic confirmation."
  ;; `yes-or-no-p', not `y-or-n-p': this is the one operation in v0.1.0 that
  ;; can destroy an unbounded amount of data, and it must not be reachable by
  ;; a single keystroke.
  (unless (yes-or-no-p
           (format "Recursively delete ALL objects under %s? "
                   (s3-manager--s3-uri prefix)))
    (user-error "Deletion aborted"))
  (message "S3: deleting everything under %s..." (s3-manager--s3-uri prefix))
  (s3-manager--aws-async
   ;; `s3 rm --recursive' rather than one delete-object per key: the CLI
   ;; batches server-side, and enumerating would be orders of magnitude
   ;; slower.  --only-show-errors because it otherwise prints one line per
   ;; object deleted, which on a large prefix is a million lines of stdout.
   (list "s3" "rm" (s3-manager--s3-uri prefix)
         "--recursive" "--only-show-errors")
   :profile s3-manager--profile
   :buffer (current-buffer)
   :parse nil
   ;; Unbounded, like a transfer: `s3-manager-timeout' is measured from the
   ;; start, so a large prefix was killed mid-delete and reported as a
   ;; timeout for an operation that was working.
   :timeout s3-manager-transfer-timeout
   :name "s3-rm-recursive"
   :on-success (lambda (_output)
                 (message "S3: deleted everything under %s"
                          (s3-manager--s3-uri prefix))
                 (s3-manager--after-delete prefix))
   :on-error (lambda (err)
               (s3-manager--report-error err "s3 rm --recursive")
               ;; Exit 1 or 2 means some objects really were removed, so the
               ;; listing must be re-read even though the command failed.
               (s3-manager--after-delete prefix))))

(defun s3-manager-delete ()
  "Delete the object at point, or the prefix at point and everything under it."
  (interactive)
  (unless s3-manager--bucket
    (user-error "Not an object listing"))
  (let ((entry (s3-manager--entry-at-point)))
    (unless (s3-manager-entry-p entry)
      (user-error "Deleting buckets is not supported"))
    (if (eq (s3-manager-entry-type entry) 'directory)
        (s3-manager--delete-prefix (s3-manager-entry-key entry))
      (s3-manager--delete-object (s3-manager-entry-key entry)))))

(defun s3-manager-delete-recursive-dry-run ()
  "Show what deleting the prefix at point would remove, without removing it."
  (interactive)
  (unless s3-manager--bucket
    (user-error "Not an object listing"))
  (let ((entry (s3-manager--entry-at-point)))
    (unless (and (s3-manager-entry-p entry)
                 (eq (s3-manager-entry-type entry) 'directory))
      (user-error "Point is not on a prefix"))
    (let ((uri (s3-manager--s3-uri (s3-manager-entry-key entry))))
      (message "S3: listing what %s would delete..." uri)
      (s3-manager--aws-async
       (list "s3" "rm" uri "--recursive" "--dryrun")
       :profile s3-manager--profile
       :buffer (current-buffer)
       :parse nil
       ;; Enumerates every object under the prefix; no fixed deadline fits.
       :timeout s3-manager-transfer-timeout
       :name "s3-rm-dryrun"
       :on-success
       (lambda (output)
         (s3-manager--show-dry-run (format "Would delete under %s:" uri)
                                   output))
       :on-error (lambda (err)
                   (s3-manager--report-error err "s3 rm --dryrun"))))))

(provide 's3-manager-delete)

;;; s3-manager-delete.el ends here
