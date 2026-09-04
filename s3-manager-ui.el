;;; s3-manager-ui.el --- Major mode, rendering and navigation  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Minh Nguyen

;; Author: Minh Nguyen <nqminhuit@gmail.com>
;; URL: https://github.com/nqminhuit/s3-manager.el

;; This file is not part of GNU Emacs.
;; Part of s3-manager.el.  GPL-3.0-or-later; see LICENSE.

;;; Commentary:

;; Major mode and keymap, the two column layouts, listing requests,
;; pagination, marks and movement.  One mode serves both the bucket list and
;; the object browser; each setup function installs its own layout.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'tabulated-list)
(require 's3-manager-core)
(require 's3-manager-process)
(require 's3-manager-model)

;; The keymap below binds commands that live in the files built on top of this
;; one -- they operate on the buffer this file defines, so the dependency runs
;; that way round and cannot be reversed.  Declared rather than reordered
;; because a keymap is the one place a lower layer must name its callers.
(declare-function s3-manager-copy "s3-manager-copy" ())
(declare-function s3-manager-copy-to "s3-manager-copy" ())
(declare-function s3-manager-rename "s3-manager-copy" ())
(declare-function s3-manager-get "s3-manager-transfer" ())
(declare-function s3-manager-get-recursive "s3-manager-transfer" ())
(declare-function s3-manager-upload "s3-manager-transfer" ())
(declare-function s3-manager-delete "s3-manager-delete" ())
(declare-function s3-manager-execute "s3-manager-delete" ())
(declare-function s3-manager-view "s3-manager-view" ())

(defun s3-manager--mode-line-status ()
  "Return the `mode-line-process' fragment for this buffer."
  (concat
   (pcase s3-manager--status
     ('loading " [loading]")
     ('error (propertize " [error]" 'face 'error))
     (_ ""))
   (when (and (> s3-manager--transfers 0) s3-manager--transfer-status)
     (format " [%s%s]"
             (if (> s3-manager--transfers 1)
                 (format "%d: " s3-manager--transfers)
               "")
             ;; `mode-line-process' re-reads a string from :eval as a
             ;; construct, and progress lines carry object keys: an upload of
             ;; "sale-50%-off.png" would render `%-' as padding.
             (s3-manager--quote-percent s3-manager--transfer-status)))))

(defun s3-manager--update-header-line ()
  "Refresh the header line from this buffer's state."
  (setq-local
   header-line-format
   (concat " " (s3-manager--quote-percent (or s3-manager--profile "default"))
           (if s3-manager--bucket
               (s3-manager--quote-percent
                (format "  s3://%s/%s" s3-manager--bucket s3-manager--prefix))
             "  buckets")
           "   "
           (pcase s3-manager--status
             ('loading "loading…")
             ('error "failed — see *S3 Manager Error*")
             (_ (let ((n (length tabulated-list-entries)))
                  (concat
                   (if (zerop n)
                       "empty"
                     (format "%d %s" n
                             (if s3-manager--bucket
                                 (if (= n 1) "entry" "entries")
                               (if (= n 1) "bucket" "buckets"))))
                   ;; The listing was capped by `s3-manager-page-size'.
                   (when s3-manager--next-token
                     (substitute-command-keys
                      "  \\[s3-manager-load-more] for more")))))))))

(defun s3-manager--set-status (status)
  "Set this buffer's request STATUS and repaint the indicators."
  (setq s3-manager--status status)
  (s3-manager--update-header-line)
  (force-mode-line-update))


;;;; Major mode

(defvar-keymap s3-manager-mode-map
  :doc "Keymap for `s3-manager-mode'."
  :parent tabulated-list-mode-map
  ;; `g' and `q' arrive from `special-mode' via the replaced
  ;; `revert-buffer-function', so they are deliberately not rebound here.
  "RET" #'s3-manager-open
  "^" #'s3-manager-up
  ;; `g' is bound explicitly, not left to `special-mode' -> `revert-buffer',
  ;; whose first argument is IGNORE-AUTO -- so `C-u g' could never reach the
  ;; whole-bucket purge.  `revert-buffer-function' still works for M-x.
  "g" #'s3-manager-refresh
  "+" #'s3-manager-load-more
  "C" #'s3-manager-copy
  "c" #'s3-manager-copy-to
  "r" #'s3-manager-rename
  "G" #'s3-manager-get
  "R" #'s3-manager-get-recursive
  "d" #'s3-manager-mark-delete
  "u" #'s3-manager-unmark
  "U" #'s3-manager-unmark-all
  "x" #'s3-manager-execute
  "D" #'s3-manager-delete
  "P" #'s3-manager-upload
  "!" #'s3-manager-show-errors)

;; Evil's state maps outrank a major-mode map, and its normal state binds
;; nearly every key above, so without this the keymap is dead under Evil.  nil
;; covers every state; unbound keys still reach Evil, and a user's own
;; `evil-define-key' still outranks this.
(declare-function evil-make-overriding-map "evil-core"
                  (keymap &optional state copy))
(with-eval-after-load 'evil
  (evil-make-overriding-map s3-manager-mode-map nil))

(define-derived-mode s3-manager-mode tabulated-list-mode "S3"
  "Major mode for browsing S3 buckets and objects.

\\{s3-manager-mode-map}"
  ;; `tabulated-list-format' is deliberately NOT set here.  This one mode
  ;; serves both the bucket list and the object browser, whose columns
  ;; differ; each setup function installs its own layout and calls
  ;; `tabulated-list-init-header'.  The variable is buffer-local, so the two
  ;; cannot interfere.
  (setq tabulated-list-padding 2)  ; reserved for Dired-style marks
  (setq s3-manager--marks (make-hash-table :test #'equal))
  ;; Render the column titles as the first line of the buffer instead of in
  ;; the header line.  `tabulated-list-init-header' would otherwise claim
  ;; `header-line-format', which this mode uses for the profile, the current
  ;; s3:// path and the request status -- and the columns would vanish.
  (setq-local tabulated-list-use-header-line nil)
  ;; `tabulated-list-mode' installs the synchronous `tabulated-list-revert',
  ;; which would repaint stale rows and never re-fetch.  This must therefore
  ;; be replaced after the parent's setup has run, i.e. here.
  (setq-local revert-buffer-function #'s3-manager--revert)
  (setq-local mode-line-process '(:eval (s3-manager--mode-line-status)))
  ;; Without this, killing the buffer mid-request orphans an `aws' process
  ;; that :noquery t stops Emacs from even asking about at exit.
  (add-hook 'kill-buffer-hook #'s3-manager--cancel nil t))


;;;; Bucket listing

(defconst s3-manager--bucket-list-format
  [("Created" 12 t) ("Name" 63 t)]
  "Column layout for the bucket list.

Ordered like `s3-manager--object-list-format', and for the same reason:
a bucket name may be up to 63 characters, so putting it first would
misalign the date.  `Created' is an ISO-8601 date and therefore sorts
correctly as a string.")

(defun s3-manager--print-list ()
  "Print the list, restoring point to the row that was asked for.
REMEMBER-POS matches the id already at point, which is useless when the
whole listing is replaced -- so moving up supplies the row explicitly.
It stays on for a by-key request, whose key may not be in the listing."
  (let ((target s3-manager--restore-target)
        (key s3-manager--restore-key))
    (setq s3-manager--restore-target nil
          s3-manager--restore-key nil)
    (tabulated-list-print (null target))
    (s3-manager--apply-marks)
    (cond (target (s3-manager--goto-entry target))
          (key (s3-manager--goto-key key)))))

(defun s3-manager--render-buckets (response)
  "Render the `s3api list-buckets' RESPONSE into the current buffer."
  (setq s3-manager--next-token nil)
  (setq tabulated-list-entries
        (mapcar (lambda (bucket)
                  (let ((name (alist-get 'Name bucket)))
                    ;; The bucket name is the entry id: it is what every
                    ;; command on this buffer needs, and it is stable across
                    ;; a re-sort so point survives one.
                    (list name
                          (vector (s3-manager--format-date
                                   (alist-get 'CreationDate bucket))
                                  name))))
                (alist-get 'Buckets response)))
  (s3-manager--cache-put (s3-manager--cache-key)
                         tabulated-list-entries nil nil)
  (s3-manager--set-status nil)
  (s3-manager--print-list)
  (s3-manager--update-header-line))

(defun s3-manager--reload (&optional target key)
  "Re-fetch whatever the current buffer is showing.
TARGET, when given, is the entry to put point on once it arrives.  KEY
is the same request for a row whose entry cannot be synthesized in
advance; TARGET wins when both are given."
  (unless (derived-mode-p 's3-manager-mode)
    (user-error "Not an S3 Manager buffer"))
  ;; Abandon any request still in flight; this also advances the generation,
  ;; so a response already on its way is dropped rather than rendered over
  ;; the newer one.
  (s3-manager--cancel)
  ;; Both are set unconditionally, so the newest reload owns the slots and a
  ;; request left over from an earlier one cannot fire on this listing.
  (setq s3-manager--restore-target target
        s3-manager--restore-key key)
  (let ((page (s3-manager--cache-get (s3-manager--cache-key))))
    (if page
        (s3-manager--install-page page)
      (s3-manager--set-status 'loading)
      (s3-manager--fetch-listing))))

(defun s3-manager--install-page (page)
  "Render a cached PAGE without touching the network."
  (setq s3-manager--entries (s3-manager-page-entries page)
        s3-manager--next-token (s3-manager-page-next-token page)
        tabulated-list-entries (s3-manager-page-rows page))
  (s3-manager--set-status nil)
  (s3-manager--print-list)
  (s3-manager--update-header-line))

(defun s3-manager--fetch-listing ()
  "Issue the request for whatever the current buffer is showing."
  (let* ((origin (current-buffer))
         (generation s3-manager--generation)
         (objects s3-manager--bucket)
         (context (if objects "list-objects-v2" "list-buckets")))
    (s3-manager--aws-async
     (if objects
         (s3-manager--list-objects-args)
       '("s3api" "list-buckets" "--output" "json"))
     :profile s3-manager--profile
     :buffer origin
     :generation generation
     :register t
     :name (if objects "s3-objects" "s3-buckets")
     :on-success (if objects
                     #'s3-manager--render-objects
                   #'s3-manager--render-buckets)
     :on-error (lambda (err)
                 (s3-manager--set-status 'error)
                 (s3-manager--report-error err context)))))

(defun s3-manager--revert (&optional _ignore-auto _noconfirm _preserve-modes)
  "Re-fetch the listing.  The `revert-buffer-function' for this mode.
Accepts and ignores the three arguments `revert-buffer' supplies."
  (s3-manager--cache-invalidate (s3-manager--cache-key))
  (s3-manager--reload))

(defun s3-manager-refresh (&optional whole-bucket)
  "Re-read the current listing from S3, bypassing the cache.

`g' means \"I do not trust what I see\", so the cached copy of this
prefix is dropped first.  With a prefix argument WHOLE-BUCKET, drop every
cached prefix of this bucket -- for after something changed it wholesale."
  (interactive "P")
  (unless (derived-mode-p 's3-manager-mode)
    (user-error "Not an S3 Manager buffer"))
  (if whole-bucket
      (let ((n (s3-manager--cache-purge
                s3-manager--profile
                (s3-manager--endpoint-for s3-manager--profile)
                s3-manager--bucket)))
        (message "S3: dropped %d cached listing%s" n (if (= n 1) "" "s")))
    (s3-manager--cache-invalidate (s3-manager--cache-key)))
  (s3-manager--reload))

(defun s3-manager-load-more ()
  "Fetch the next page of the current listing and append it."
  (interactive)
  (unless (derived-mode-p 's3-manager-mode)
    (user-error "Not an S3 Manager buffer"))
  (unless s3-manager--bucket
    (user-error "The bucket list is never paginated"))
  (unless s3-manager--next-token
    (user-error "Listing is already complete"))
  (when (eq s3-manager--status 'loading)
    (user-error "Still loading"))
  (let ((token s3-manager--next-token)
        (origin (current-buffer)))
    ;; Deliberately not `s3-manager--cancel': that would advance the
    ;; generation and there is nothing in flight worth killing.  Reuse the
    ;; current generation so a stale page cannot append to a newer listing.
    (s3-manager--set-status 'loading)
    (setq s3-manager--process
          (s3-manager--aws-async
           (s3-manager--list-objects-args token)
           :profile s3-manager--profile
           :buffer origin
           :generation s3-manager--generation
           :name "s3-objects-more"
           :on-success (lambda (response)
                         (s3-manager--render-objects response t))
           :on-error (lambda (err)
                       (s3-manager--set-status 'error)
                       (s3-manager--report-error err "list-objects-v2"))))))

(defun s3-manager--bucket-buffer (profile &optional target)
  "Return a bucket-list buffer for PROFILE, with a fetch under way.
TARGET, when given, is the bucket name to put point on once it lands."
  (let ((buffer (get-buffer-create (s3-manager--buffer-name profile))))
    (with-current-buffer buffer
      (unless (derived-mode-p 's3-manager-mode)
        (s3-manager-mode))
      (setq s3-manager--profile profile
            s3-manager--bucket nil
            s3-manager--prefix "")
      (setq tabulated-list-format s3-manager--bucket-list-format
            tabulated-list-sort-key '("Name" . nil))
      (tabulated-list-init-header)
      (s3-manager--reload target))
    buffer))

;;;; Object listing

(defface s3-manager-directory
  '((t :inherit font-lock-function-name-face))
  "Face for prefixes, which stand in for directories, in an S3 listing."
  :group 's3-manager)

(defconst s3-manager--object-list-format
  [("Size" 10 s3-manager--sort-by-size :right-align t)
   ("Modified" 12 s3-manager--sort-by-time)
   ("Name" 44 s3-manager--sort-by-name)]
  "Column layout for the object browser.

Name comes last because `tabulated-list' does not truncate: a name
wider than its column pushes everything after it out of alignment, and
S3 keys are frequently long.  With the two fixed-width columns first,
an overlong name can only run off the right-hand end, which costs
nothing.  Truncating instead would hide the part of a file name that
distinguishes it.")

(defun s3-manager--directory-rank (entry)
  "Return a sort rank for ENTRY placing directories before objects."
  (if (eq (s3-manager-entry-type entry) 'directory) 0 1))

(defun s3-manager--sort-by (a b accessor predicate)
  "Order rows A and B by ACCESSOR under PREDICATE, directories first.

A and B are whole `tabulated-list-entries' elements.  Only their ids are
read: with the UPDATE argument `tabulated-list-print' synthesizes the
rest, and the displayed strings would sort wrongly anyway -- \"9 B\"
comes after \"1.8 GiB\" lexicographically."
  (let* ((ea (car a))
         (eb (car b))
         (ra (s3-manager--directory-rank ea))
         (rb (s3-manager--directory-rank eb)))
    (if (/= ra rb)
        (< ra rb)
      (funcall predicate (funcall accessor ea) (funcall accessor eb)))))

(defun s3-manager--sort-by-name (a b)
  "Order rows A and B by name, directories first."
  (s3-manager--sort-by a b #'s3-manager-entry-display-name #'string<))

(defun s3-manager--sort-by-size (a b)
  "Order rows A and B by size, directories first."
  (s3-manager--sort-by a b
                       (lambda (entry) (or (s3-manager-entry-size entry) -1))
                       #'<))

(defun s3-manager--sort-by-time (a b)
  "Order rows A and B by modification time, directories first.
The timestamps are ISO-8601, so they order correctly as strings."
  (s3-manager--sort-by a b
                       (lambda (entry)
                         (or (s3-manager-entry-last-modified entry) ""))
                       #'string<))

(defun s3-manager--entry-row (entry)
  "Return the `tabulated-list-entries' element for ENTRY."
  (let ((directory (eq (s3-manager-entry-type entry) 'directory)))
    (list entry
          (vector (if directory "-" (s3-manager--format-size
                                     (s3-manager-entry-size entry)))
                  (if directory "-" (s3-manager--format-date
                                     (s3-manager-entry-last-modified entry)))
                  (if directory
                      (propertize (s3-manager-entry-display-name entry)
                                  'face 's3-manager-directory)
                    (s3-manager-entry-display-name entry))))))

(defun s3-manager--goto-entry (id)
  "Put point on the row whose id is `equal' to ID."
  (goto-char (point-min))
  (let ((found nil))
    (while (and (not found) (not (eobp)))
      (if (equal id (tabulated-list-get-id))
          (setq found t)
        (forward-line 1)))
    (unless found (goto-char (point-min)))))

(defun s3-manager--goto-key (key)
  "Put point on the row whose entry has KEY, or leave point alone.
No `point-min' fallback, unlike `s3-manager--goto-entry': a key absent
from a truncated listing is ordinary, and jumping to the top is worse."
  (let ((found nil))
    (save-excursion
      (goto-char (point-min))
      (while (and (not found) (not (eobp)))
        (let ((id (tabulated-list-get-id)))
          ;; Bucket-list ids are bare strings, not entries.
          (if (and (s3-manager-entry-p id)
                   (equal key (s3-manager-entry-key id)))
              (setq found (point))
            (forward-line 1)))))
    (when found (goto-char found))))

(defun s3-manager--render-objects (response &optional append)
  "Render a `list-objects-v2' RESPONSE into the current buffer.
With APPEND, add to what is already shown instead of replacing it, which
is how `s3-manager-load-more' extends a truncated listing."
  (let ((new (s3-manager--entries-from-listing response s3-manager--prefix)))
    (setq s3-manager--entries (if append
                                  (append s3-manager--entries new)
                                new)
          ;; Raw response, so this is S3's own cursor -- present exactly
          ;; when IsTruncated is true.
          s3-manager--next-token (alist-get 'NextContinuationToken response)))
  (setq tabulated-list-entries
        (mapcar #'s3-manager--entry-row s3-manager--entries))
  ;; Cache the accumulation, token included, so returning to a
  ;; partly-loaded prefix resumes rather than starting over.
  (s3-manager--cache-put (s3-manager--cache-key)
                         tabulated-list-entries
                         s3-manager--entries
                         s3-manager--next-token)
  (s3-manager--set-status nil)
  (s3-manager--print-list)
  (s3-manager--update-header-line))

(defun s3-manager--list-objects-args (&optional continuation-token)
  "Return the service arguments listing the current bucket and prefix.
CONTINUATION-TOKEN, when given, resumes a truncated listing.

`--no-paginate' turns off the CLI's own aggregation so that one
invocation is exactly one S3 request, and `--max-keys' is the API's own
MaxKeys.  See `s3-manager-page-size' for why the documented
`--max-items' cannot be used: it drops CommonPrefixes."
  (append (list "s3api" "list-objects-v2" "--bucket" s3-manager--bucket)
          ;; Omitted entirely at the bucket root: an empty --prefix is
          ;; accepted but says nothing.
          (unless (string-empty-p s3-manager--prefix)
            (list "--prefix" s3-manager--prefix))
          (list "--delimiter" "/"
                "--no-paginate"
                "--max-keys" (number-to-string s3-manager-page-size))
          (when continuation-token
            (list "--continuation-token" continuation-token))
          (list "--output" "json")))


;;;; Navigation

(defun s3-manager--object-buffer (profile bucket prefix &optional target)
  "Return a buffer browsing BUCKET at PREFIX for PROFILE, fetching now.
TARGET, when given, is the entry to put point on once the listing lands."
  (let ((buffer (get-buffer-create (s3-manager--buffer-name profile bucket))))
    (with-current-buffer buffer
      (unless (derived-mode-p 's3-manager-mode)
        (s3-manager-mode))
      (setq s3-manager--profile profile
            s3-manager--bucket bucket)
      (s3-manager--set-prefix prefix)
      (setq tabulated-list-format s3-manager--object-list-format)
      (unless tabulated-list-sort-key
        (setq tabulated-list-sort-key '("Name" . nil)))
      (tabulated-list-init-header)
      (s3-manager--reload target))
    buffer))

(defun s3-manager-open ()
  "Enter the directory at point, or open the bucket at point."
  (interactive)
  (let ((id (s3-manager--entry-at-point)))
    (cond
     ;; In the bucket list the id is the bucket name.
     ((null s3-manager--bucket)
      (pop-to-buffer-same-window (s3-manager--object-buffer s3-manager--profile id "")))
     ((eq (s3-manager-entry-type id) 'directory)
      ;; Remember where we were so `s3-manager-up' can put point back on
      ;; this row rather than at the top of the parent listing.
      (push (cons s3-manager--prefix id) s3-manager--history)
      (s3-manager--set-prefix (s3-manager-entry-key id))
      (s3-manager--reload))
     (t
      (s3-manager-view)))))

(defun s3-manager-up ()
  "Move to the parent prefix, or back to the bucket list."
  (interactive)
  (unless (derived-mode-p 's3-manager-mode)
    (user-error "Not an S3 Manager buffer"))
  (cond
   ((null s3-manager--bucket)
    (user-error "Already at the bucket list"))
   ((string-empty-p s3-manager--prefix)
    (let ((bucket s3-manager--bucket))
      (pop-to-buffer-same-window (s3-manager--bucket-buffer s3-manager--profile bucket))))
   (t
    (let* ((parent (s3-manager--parent-prefix s3-manager--prefix))
           (remembered (and (equal (caar s3-manager--history) parent)
                            (cdr (pop s3-manager--history))))
           ;; Arriving here by any route other than descending -- a refresh
           ;; in the child, say -- leaves no history, so synthesize the entry
           ;; we are returning to.  Structural `equal' on the struct is what
           ;; makes the synthesized one match the real row.
           (target (or remembered
                       (s3-manager--directory-entry s3-manager--prefix
                                                    parent))))
      (s3-manager--set-prefix parent)
      (s3-manager--reload target)))))


;;;; Marks
;;
;; The hash table is authoritative, not the characters in the buffer:
;; `tabulated-list-print' erases everything, and its UPDATE argument is no
;; help because it leaves *stale* tags on rows that did not change.  Marks are
;; keyed by S3 key so they survive a re-sort, and they are stored outside the
;; entry struct because that struct is an entry id compared with `equal' --
;; mutating it would break point restoration.

(defun s3-manager--marked-keys ()
  "Return the S3 keys marked for deletion, in listing order."
  (let ((marked nil))
    (dolist (entry s3-manager--entries (nreverse marked))
      (let ((key (s3-manager-entry-key entry)))
        (when (gethash key s3-manager--marks)
          (push key marked))))))

(defun s3-manager--apply-marks ()
  "Re-apply marks to the buffer after a repaint."
  (when (and s3-manager--marks (> (hash-table-count s3-manager--marks) 0))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((id (tabulated-list-get-id)))
          (when (and (s3-manager-entry-p id)
                     (gethash (s3-manager-entry-key id) s3-manager--marks))
            (tabulated-list-put-tag "D")))
        (forward-line 1)))))

(defun s3-manager--clear-marks ()
  "Forget every mark in this buffer.
Called whenever the prefix changes: marks name keys in one listing, and
carrying them into another would leave invisible marks that `x' would
nonetheless act on."
  (when s3-manager--marks (clrhash s3-manager--marks)))

(defun s3-manager--set-prefix (prefix)
  "Show PREFIX in this buffer, discarding marks that belonged to the old one."
  (unless (equal prefix s3-manager--prefix)
    (s3-manager--clear-marks))
  (setq s3-manager--prefix prefix))

(defun s3-manager--markable-entry-at-point ()
  "Return the object at point, refusing anything that cannot be marked."
  (let ((entry (s3-manager--entry-at-point)))
    (unless (s3-manager-entry-p entry)
      (user-error "Marks apply to objects, not buckets"))
    (unless (eq (s3-manager-entry-type entry) 'object)
      (user-error
       "%s" (substitute-command-keys
             "Prefixes cannot be marked; \\[s3-manager-delete] deletes one recursively")))
    entry))

(defun s3-manager-mark-delete ()
  "Mark the object at point for deletion, then move down."
  (interactive)
  (let ((entry (s3-manager--markable-entry-at-point)))
    (puthash (s3-manager-entry-key entry) t s3-manager--marks)
    (tabulated-list-put-tag "D" t)))

(defun s3-manager-unmark ()
  "Remove the mark from the object at point, then move down."
  (interactive)
  (let ((entry (s3-manager--entry-at-point)))
    (when (s3-manager-entry-p entry)
      (remhash (s3-manager-entry-key entry) s3-manager--marks))
    (tabulated-list-put-tag "" t)))

(defun s3-manager-unmark-all ()
  "Remove every mark in this buffer."
  (interactive)
  (s3-manager--clear-marks)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (tabulated-list-put-tag "")
      (forward-line 1)))
  (message "S3: marks cleared"))

(defun s3-manager--entry-at-point ()
  "Return the entry on the current line, or signal a `user-error'.
The only supported way for a command to obtain an entry: rows such as a
placeholder carry a nil id, and every command must refuse them."
  (or (tabulated-list-get-id)
      (user-error "No S3 entry on this line")))

(provide 's3-manager-ui)

;;; s3-manager-ui.el ends here
