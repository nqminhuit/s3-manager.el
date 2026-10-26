;;; s3-manager-folder.el --- Create S3 folders -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Minh Nguyen
;; Author: Minh Nguyen <nqminhuit@gmail.com>
;; URL: https://github.com/nqminhuit/s3-manager.el
;; This file is not part of GNU Emacs.
;; Part of s3-manager.el.  GPL-3.0-or-later; see LICENSE.

;;; Commentary:

;; Empty folders are zero-byte objects with a trailing slash in their key.
;; One marker suffices for a nested path: S3 supplies its ancestor prefixes.

;;; Code:

(require 'subr-x)
(require 'seq)
(require 's3-manager-core)
(require 's3-manager-process)
(require 's3-manager-ui)
(require 's3-manager-transfer)
(require 's3-manager-copy)

(defun s3-manager--directory-key (name prefix)
  "Return the folder key for relative NAME under PREFIX.
Reject empty path components, absolute paths and dot components rather
than silently changing the name the user entered."
  (let ((path (string-remove-suffix "/" name)))
    (when (or (string-empty-p (string-trim path))
              (seq-some (lambda (part) (member part '("" "." "..")))
                        (split-string path "/" nil)))
      (user-error "Enter a relative folder path with nonempty components"))
    (concat prefix path "/")))

(defun s3-manager--after-create-directory (profile bucket key)
  "Refresh the listings affected by creating KEY in BUCKET under PROFILE."
  (s3-manager--refresh-targets
   profile
   (mapcar (lambda (step) (list bucket (car step) (cdr step)))
           (s3-manager--ancestor-steps key))))

(defun s3-manager-create-directory ()
  "Create a folder under the prefix being shown.
Read a relative path, allowing nested folders such as photos/2026.
Store an empty object whose key ends in a slash.  An existing object at
that key is left intact.  No local directory or temporary file is needed."
  (interactive)
  (unless s3-manager--bucket
    (user-error "%s" (substitute-command-keys
                      "Not an object listing; \\[s3-manager-open] a bucket first")))
  (let* ((profile s3-manager--profile)
         (bucket s3-manager--bucket)
         (prefix s3-manager--prefix)
         (key (s3-manager--directory-key
               (read-string (format "Create folder in %s: "
                                    (s3-manager--uri bucket prefix)))
               prefix))
         (uri (s3-manager--uri bucket key)))
    (s3-manager--head-object
     bucket key
     (lambda (_response)
       (message "S3: %s already exists; left unchanged" uri)
       (s3-manager--after-create-directory profile bucket key))
     (lambda ()
       (s3-manager--aws-async
        (list "s3api" "put-object" "--bucket" bucket "--key" key)
        :profile profile :buffer (current-buffer) :parse nil
        ;; No listing registration or generation: navigation must not cancel
        ;; the write or redirect its completion to a different prefix.
        :name "s3-create-directory"
        :on-success
        (lambda (_output)
          (message "S3: created %s" uri)
          (s3-manager--after-create-directory profile bucket key))))
     (lambda ()
       (message "S3: could not check %s; folder creation aborted" uri)))))

(provide 's3-manager-folder)

;;; s3-manager-folder.el ends here
