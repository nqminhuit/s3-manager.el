;;; s3-manager-model.el --- Entries and the listing cache  -*- lexical-binding: t; -*-

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

;; The data an S3 listing is made of, and the cache that keeps it.
;;
;; `s3-manager-entry' instances double as `tabulated-list' ids and are compared
;; with `equal', which is why every slot must be a pure function of the S3
;; response; the struct's own docstring is the binding constraint.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 's3-manager-core)

;;;; Data model

(cl-defstruct (s3-manager-entry (:constructor s3-manager-entry--create)
                                (:copier nil))
  "One row of an S3 listing: a prefix or an object.

IMPORTANT: instances are used directly as `tabulated-list' entry ids and
are compared with `equal', which on records is structural rather than
identity-based.  Every slot must therefore be a pure function of the S3
response.  Never add mutable state -- a mark, a download progress
figure, a fetch timestamp -- because changing any slot changes the
entry's identity, and point restoration across a refresh silently stops
working.  Marks live in a separate table for exactly this reason.

Restoring point after `s3-manager-up' relies on a synthesized directory
entry comparing `equal' to the real one, so directory entries must leave
SIZE, LAST-MODIFIED and STORAGE-CLASS nil."
  type            ; `directory' or `object'
  key             ; full S3 key; a directory's key ends in "/"
  display-name    ; KEY with the parent prefix removed
  size            ; integer bytes, or nil for a directory
  last-modified   ; ISO-8601 string, or nil for a directory
  storage-class)  ; string, or nil

(defun s3-manager--directory-entry (key prefix)
  "Return a directory entry for KEY as displayed under PREFIX.
Used both when parsing a listing and when synthesizing the entry to put
point on after moving up a level; the two must stay identical, since
they are compared with `equal'."
  (s3-manager-entry--create
   :type 'directory
   :key key
   :display-name (s3-manager--strip-prefix key prefix)))

(defun s3-manager--entries-from-listing (response prefix)
  "Convert a `list-objects-v2' RESPONSE taken at PREFIX into entries.

`CommonPrefixes' and `Contents' are both absent rather than empty when
they do not apply, so neither key may be assumed to exist."
  (append
   (mapcar (lambda (common)
             (s3-manager--directory-entry (alist-get 'Prefix common) prefix))
           (alist-get 'CommonPrefixes response))
   (mapcar
    (lambda (object)
      (s3-manager-entry--create
       :type 'object
       :key (alist-get 'Key object)
       :display-name (s3-manager--strip-prefix (alist-get 'Key object) prefix)
       :size (alist-get 'Size object)
       :last-modified (alist-get 'LastModified object)
       :storage-class (alist-get 'StorageClass object)))
    ;; A zero-byte "directory marker" object -- created by the S3 console and
    ;; by several S3-compatible servers -- has a key equal to the prefix
    ;; itself.  Left in, every directory shows a phantom blank-named file.
    (seq-remove (lambda (object) (equal (alist-get 'Key object) prefix))
                (alist-get 'Contents response)))))


;;;; Listing cache
;;
;; Keyed on the resolved endpoint as well as the profile: the same bucket name
;; on MinIO and on AWS are different buckets, and conflating them would be a
;; correctness bug for exactly the S3-compatible case this package exists for.
;;
;; Invalidation is explicit only.  Nothing expires on a timer, because a UI
;; that disagrees with itself depending on wall-clock time is worse than one
;; that is stale until asked -- and `g' is one keystroke, which is the
;; convention every other Emacs listing follows.

(cl-defstruct (s3-manager-page (:constructor s3-manager-page--create)
                               (:copier nil))
  "A cached listing: what was rendered, and where it stopped."
  rows          ; `tabulated-list-entries', ready to install
  entries       ; list of `s3-manager-entry', nil for a bucket list
  next-token    ; continuation token, or nil when the listing is complete
  time)         ; `float-time' of caching; orders eviction, never expires

(defvar s3-manager--cache (make-hash-table :test #'equal)
  "Maps (PROFILE ENDPOINT BUCKET PREFIX) to a `s3-manager-page'.

Global rather than buffer-local so that quitting a listing and coming
back is instant, which is the most common thing a user does with one.")

(defun s3-manager--cache-key (&optional prefix)
  "Return the cache key for this buffer, at PREFIX if given."
  (list s3-manager--profile
        (s3-manager--endpoint-for s3-manager--profile)
        s3-manager--bucket
        (or prefix s3-manager--prefix)))

(defun s3-manager--cache-get (key)
  "Return the cached page for KEY, or nil."
  (gethash key s3-manager--cache))

(defun s3-manager--cache-evict ()
  "Drop the oldest cached pages until the table is within its cap."
  (while (> (hash-table-count s3-manager--cache) s3-manager-cache-max-entries)
    (let ((oldest nil) (oldest-time nil))
      (maphash (lambda (key page)
                 (let ((time (s3-manager-page-time page)))
                   (when (or (null oldest-time) (< time oldest-time))
                     (setq oldest key oldest-time time))))
               s3-manager--cache)
      (if oldest
          (remhash oldest s3-manager--cache)
        ;; Nothing to drop; stop rather than spin.
        (setq s3-manager-cache-max-entries
              (hash-table-count s3-manager--cache))))))

(defun s3-manager--cache-put (key rows entries next-token)
  "Cache ROWS, ENTRIES and NEXT-TOKEN under KEY."
  (puthash key (s3-manager-page--create :rows rows
                                        :entries entries
                                        :next-token next-token
                                        :time (float-time))
           s3-manager--cache)
  (s3-manager--cache-evict))

(defun s3-manager--cache-invalidate (key)
  "Forget the cached listing for KEY."
  (remhash key s3-manager--cache))

(defun s3-manager--cache-purge-profile (profile)
  "Forget every cached listing belonging to PROFILE.  Return the count.
Keys are collected before removal: `remhash' during `maphash' is not
documented as safe."
  (let ((doomed nil))
    (maphash (lambda (key _page)
               (when (equal (nth 0 key) profile)
                 (push key doomed)))
             s3-manager--cache)
    (mapc (lambda (key) (remhash key s3-manager--cache)) doomed)
    (length doomed)))

(defun s3-manager--cache-purge (profile endpoint bucket &optional prefix)
  "Forget cached listings for BUCKET under PROFILE and ENDPOINT.
With PREFIX, forget only that prefix and everything beneath it.  Return
the number of entries dropped.

Keys are collected before being removed: `remhash' during `maphash' is
not documented as safe."
  (let ((doomed nil))
    (maphash (lambda (key _page)
               (when (and (equal (nth 0 key) profile)
                          (equal (nth 1 key) endpoint)
                          (equal (nth 2 key) bucket)
                          (or (null prefix)
                              (string-prefix-p prefix (nth 3 key))))
                 (push key doomed)))
             s3-manager--cache)
    (mapc (lambda (key) (remhash key s3-manager--cache)) doomed)
    (length doomed)))

;;;###autoload
(defun s3-manager-clear-cache ()
  "Forget every cached S3 listing."
  (interactive)
  (let ((n (hash-table-count s3-manager--cache)))
    (clrhash s3-manager--cache)
    (message "S3: cleared %d cached listing%s" n (if (= n 1) "" "s"))))

(provide 's3-manager-model)

;;; s3-manager-model.el ends here
