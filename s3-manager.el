;;; s3-manager.el --- Manage S3 objects from Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Minh Nguyen

;; Author: Minh Nguyen <nqminhuit@gmail.com>
;; URL: https://github.com/nqminhuit/s3-manager.el
;; Version: 0.1.1
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, convenience

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

;; Browse and manage objects on AWS S3 and S3-compatible services through the
;; `aws' command line client.
;;
;; Usage:
;;
;;   M-x s3-manager        choose a profile, list its buckets
;;   C-u M-x s3-manager    re-read the profile list first
;;
;; In an S3 buffer: RET enters a bucket or prefix, or opens a small object
;; read-only; `^' goes up a level; `+' loads the next page of a truncated
;; listing; `G' downloads the object at point and `R' a prefix recursively;
;; `d' marks an object for deletion and `x' deletes everything marked; `D'
;; deletes the object or prefix at point outright; `g' refreshes and `q'
;; buries the buffer.
;;
;; Two properties are treated as non-negotiable throughout:
;;
;;   * Emacs never blocks.  Every invocation is asynchronous.
;;   * The CLI's stderr survives intact, separated from stdout, so failures can
;;     be reported in the service's own words.
;;
;; Credentials are never read, parsed, stored or logged.  The package selects a
;; profile by name and lets the AWS CLI do everything else.
;;
;; Requires AWS CLI 2.13.0 or newer: earlier releases ignore the `endpoint_url'
;; key in ~/.aws/config, which silently sends every request to AWS instead of
;; the configured S3-compatible endpoint.
;;
;; See doc/SPEC-v0.1.0.md for the full design; section references in the code
;; below point into it.

;;; Code:

(require 's3-manager-core)
(require 's3-manager-process)
(require 's3-manager-model)
(require 's3-manager-ui)
(require 's3-manager-transfer)
(require 's3-manager-view)
(require 's3-manager-delete)

;;;###autoload
(defun s3-manager (&optional reread-profiles)
  "Browse S3 buckets for a profile chosen in the minibuffer.

With a prefix argument REREAD-PROFILES, discard the cached profile list
and ask the AWS CLI for it again."
  (interactive "P")
  (s3-manager--check-executable)
  (s3-manager--check-version)
  (when reread-profiles
    (setq s3-manager--profiles nil))
  (s3-manager-read-profile
   (lambda (profile)
     (pop-to-buffer-same-window (s3-manager--bucket-buffer profile)))))

;;;###autoload
(defun s3-manager-switch-profile (&optional reread-profiles)
  "Choose a different AWS profile and show its buckets.

Opens the chosen profile's bucket list rather than re-pointing this
buffer: buffer names carry the profile, and a bucket present under one
profile need not exist under another.

Listings cached for the profile being left are dropped.  They cannot be
served wrongly -- the cache key includes the profile -- but a profile
switch usually means that account is no longer what is being worked on,
so keeping them only costs room in a capped table.

With a prefix argument REREAD-PROFILES, ask the CLI for the profile list
again first, for a profile added since the list was cached."
  (interactive "P")
  (s3-manager--check-executable)
  (s3-manager--check-version)
  (when reread-profiles
    (setq s3-manager--profiles nil))
  (let ((previous s3-manager--profile))
    (s3-manager-read-profile
     (lambda (profile)
       (when (and previous (not (equal profile previous)))
         (let ((dropped (s3-manager--cache-purge-profile previous)))
           (unless (zerop dropped)
             (message "S3: dropped %d cached listing%s for %s"
                      dropped (if (= dropped 1) "" "s") previous))))
       (pop-to-buffer-same-window (s3-manager--bucket-buffer profile))))))

(provide 's3-manager)

;;; s3-manager.el ends here
