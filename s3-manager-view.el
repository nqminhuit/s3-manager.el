;;; s3-manager-view.el --- Reading a small object in a buffer  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Minh Nguyen

;; Author: Minh Nguyen <nqminhuit@gmail.com>
;; URL: https://github.com/nqminhuit/s3-manager.el

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `RET' on a small object downloads it to a temporary directory and shows the
;; copy read-only.  The bytes come from S3 and are not trusted: local variables
;; are disabled while visiting, and the file name is derived from the key's leaf
;; only, since a key may legally be or contain "..".

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 's3-manager-core)
(require 's3-manager-process)
(require 's3-manager-model)
(require 's3-manager-ui)
(require 's3-manager-transfer)

;;;; Viewing

(defvar-local s3-manager--view-file nil
  "Local copy this buffer is displaying, deleted when the buffer dies.")

(defvar s3-manager--view-pending nil
  "View directories not yet handed to a buffer that will clean them up.

A directory is created when the download starts and passes to the
buffer's `kill-buffer-hook' once one exists.  Every other outcome --- a
failed or timed-out transfer, or an origin buffer killed mid-download,
which suppresses the callbacks entirely --- would otherwise leave the
object's bytes in the temporary directory.")

(defun s3-manager--discard-directory (directory)
  "Delete DIRECTORY and its contents, reporting a failure rather than hiding it.
Silence here would leave downloaded object bytes in the temporary
directory while the package behaved as though it had cleaned up."
  (condition-case err
      (delete-directory directory t)
    (error
     (s3-manager--record-error
      (s3-manager--local-error (format "delete-directory %s" directory)
                               (error-message-string err))
      "view cleanup")
     (message "S3: could not remove %s -- see %s"
              directory s3-manager--error-buffer))))

(defun s3-manager--view-discard (directory)
  "Delete a pending view DIRECTORY and forget it."
  (setq s3-manager--view-pending (delete directory s3-manager--view-pending))
  (s3-manager--discard-directory directory))

(defun s3-manager--view-discard-all ()
  "Delete every view directory still awaiting a buffer.
Installed on `kill-emacs-hook': it is the only thing that can recover a
download whose origin buffer was killed before it finished, since that
suppresses the callbacks."
  (mapc #'s3-manager--discard-directory s3-manager--view-pending)
  (setq s3-manager--view-pending nil))

(add-hook 'kill-emacs-hook #'s3-manager--view-discard-all)

(defun s3-manager--view-file-name (entry)
  "Return a safe leaf file name for viewing ENTRY.

S3 keys are arbitrary strings and may legally be or contain \"..\", so
the name is taken from the leaf only and rejected outright if it could
name anything other than a file inside its own directory.  Building a
path from a key directly would let one escape the temporary directory."
  (let ((name (file-name-nondirectory
               (directory-file-name (s3-manager-entry-display-name entry)))))
    (if (or (member name '("" "." ".."))
            ;; A leading tilde is the escape that matters: `expand-file-name'
            ;; expands it, so "~" resolves to the user's home directory and
            ;; "~root" to root's.  An object with the key "backups/~" would
            ;; otherwise have Emacs visit $HOME itself.
            (string-prefix-p "~" name))
        "s3-object"
      name)))

(defun s3-manager--view-destination (entry)
  "Return a fresh temporary path to download ENTRY to.
A directory of its own per view, so that objects of the same name in
different prefixes cannot collide and the buffer keeps the object's own
name."
  ;; `file-name-concat' rather than `expand-file-name': it performs no tilde
  ;; expansion, so the result cannot leave the directory even if the guard
  ;; above is ever weakened.
  (let ((directory (file-name-as-directory
                    (make-temp-file "s3-manager-view-" t))))
    (push directory s3-manager--view-pending)
    (file-name-concat directory (s3-manager--view-file-name entry))))

(defun s3-manager--view-cleanup ()
  "Delete the local copy behind the current buffer."
  (when s3-manager--view-file
    ;; Recursive, so an auto-save or backup file landing beside the copy
    ;; cannot leave the directory behind.  Only ever this view's own
    ;; directory, which holds nothing else.
    (s3-manager--view-discard (file-name-directory s3-manager--view-file))))

(defun s3-manager--display-view (file uri)
  "Show FILE, a local copy of URI, in a read-only buffer."
  (let ((buffer
         ;; The bytes came from S3 and are not trusted: a `-*- ... -*-'
         ;; cookie or a file-local variables section in them would otherwise
         ;; be applied.  (Spelled out rather than quoted verbatim: Emacs scans
         ;; the last 3000 characters of a file for that exact phrase, and in a
         ;; file this size a comment mentioning it lands inside the window.)
         ;; And the size cap sits above `large-file-warning-threshold', so
         ;; without silencing it an object between the two would prompt from
         ;; inside a process callback.
         (let ((enable-local-variables nil)
               (large-file-warning-threshold nil))
           (find-file-noselect file))))
    (with-current-buffer buffer
      (setq s3-manager--view-file file)
      ;; This buffer now owns the directory; drop it from the pending set.
      (setq s3-manager--view-pending
            (delete (file-name-directory file) s3-manager--view-pending))
      (setq-local header-line-format
                  (format " %s  (read-only copy)"
                          (s3-manager--quote-percent uri)))
      ;; The copy is disposable: remove it with the buffer rather than
      ;; leaving downloaded object data lying in the temporary directory.
      (add-hook 'kill-buffer-hook #'s3-manager--view-cleanup nil t)
      (read-only-mode 1))
    ;; Same window, like `dired-find-file': `RET' is one key for both
    ;; descending and viewing, so the two must not display differently.
    (pop-to-buffer-same-window buffer)))

(defun s3-manager-view ()
  "Open the object at point in a read-only buffer."
  (interactive)
  (unless s3-manager--bucket
    (user-error "Not an object listing"))
  (let ((entry (s3-manager--entry-at-point)))
    (unless (and (s3-manager-entry-p entry)
                 (eq (s3-manager-entry-type entry) 'object))
      (user-error "Point is not on an object"))
    (let ((size (or (s3-manager-entry-size entry) 0)))
      (when (> size s3-manager-view-max-size)
        (user-error
         "%s"
         (substitute-command-keys
          (format "%s is %s -- too large to open; \\[s3-manager-get] downloads it"
                  (s3-manager-entry-display-name entry)
                  (s3-manager--format-size size)))))
      (let* ((key (s3-manager-entry-key entry))
             (uri (s3-manager--s3-uri key))
             (destination (s3-manager--view-destination entry)))
        (s3-manager--transfer
         (list "s3" "cp" uri destination "--progress-frequency" "1")
         (format "opening %s" key)
         (lambda () (s3-manager--display-view destination uri))
         (lambda ()
           (s3-manager--view-discard (file-name-directory destination))))))))

(provide 's3-manager-view)

;;; s3-manager-view.el ends here
