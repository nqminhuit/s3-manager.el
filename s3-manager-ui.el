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

;; The keymap binds commands from the files built on top of this one: they act
;; on the buffer defined here, so the dependency cannot be reversed.  A keymap
;; is the one place a lower layer must name its callers.
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

(defun s3-manager--mark-summary ()
  "Return what this buffer's marks add up to, or nil when there are none.
Counted through `s3-manager--entries-marked', the reader every batch
command uses, so the number shown cannot disagree with the number acted
on.  Shown at all because a mark is input to a command and can scroll
off screen -- state nobody can see must not be state a command acts on."
  (let ((marked (length (s3-manager--entries-marked s3-manager--mark-char)))
        (flagged (length (s3-manager--entries-marked
                          s3-manager--delete-char))))
    (when (or (> marked 0) (> flagged 0))
      (string-join
       (delq nil
             (list (when (> marked 0) (format "%d marked" marked))
                   ;; Named apart, as the two keys are: `x' acts on this
                   ;; number and on no part of the other.
                   (when (> flagged 0) (format "%d flagged" flagged))))
       ", "))))

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
                      "  \\[s3-manager-load-more] for more"))
                   (when-let* ((marks (s3-manager--mark-summary)))
                     (concat "  " marks)))))))))

(defun s3-manager--set-status (status)
  "Set this buffer's request STATUS and repaint the indicators."
  (setq s3-manager--status status)
  (s3-manager--update-header-line)
  (force-mode-line-update))


;;;; Major mode

(defvar-keymap s3-manager-mode-map
  :doc "Keymap for `s3-manager-mode'."
  :parent tabulated-list-mode-map
  ;; `q' arrives from `special-mode' and is deliberately not rebound.
  ;;
  ;; Nor are `s3-manager-get' and `s3-manager-get-recursive': `C' falls back
  ;; to them already, so a key each would only buy forcing a download past a
  ;; visible listing, and it would cost `G'.  Both remain available as `M-x'.
  "RET" #'s3-manager-open
  "^" #'s3-manager-up
  ;; `g' is a prefix, not a command -- the shape `evil-collection' gives
  ;; Dired.  Binding `g' itself would swallow `gg', which is bound here rather
  ;; than left to Evil so that it works without Evil too.
  ;;
  ;; Refresh is not left to `revert-buffer' either: its first argument is
  ;; IGNORE-AUTO, so `C-u' could never reach the whole-bucket purge.
  "g g" #'s3-manager-beginning-of-listing
  "g r" #'s3-manager-refresh
  "+" #'s3-manager-load-more
  "C" #'s3-manager-copy
  "c" #'s3-manager-copy-to
  "r" #'s3-manager-rename
  "m" #'s3-manager-mark
  "d" #'s3-manager-mark-delete
  "u" #'s3-manager-unmark
  "U" #'s3-manager-unmark-all
  "x" #'s3-manager-execute
  "D" #'s3-manager-delete
  "P" #'s3-manager-upload
  "!" #'s3-manager-show-errors)

;; Evil's state maps outrank a major-mode map and its normal state binds nearly
;; every key above, so without this the keymap is dead under Evil.  nil covers
;; every state; unbound keys still reach Evil.
;;
;; What it does NOT buy: precedence over an auxiliary map attached to another
;; keymap.  A user's own `m' prefix in `global-map' outranks `m' here and makes
;; `s3-manager-mark' unreachable -- measured, spec §18.9, and the fix is the
;; user's own binding as §11.9 has it.
(declare-function evil-make-overriding-map "evil-core"
                  (keymap &optional state copy))
(with-eval-after-load 'evil
  (evil-make-overriding-map s3-manager-mode-map nil))

(define-derived-mode s3-manager-mode tabulated-list-mode "S3"
  "Major mode for browsing S3 buckets and objects.

\\{s3-manager-mode-map}"
  ;; `tabulated-list-format' is deliberately NOT set here: one mode serves both
  ;; the bucket list and the object browser, and each setup function installs
  ;; its own layout.  The variable is buffer-local, so they cannot interfere.
  (setq tabulated-list-padding 2)  ; reserved for Dired-style marks
  (setq s3-manager--marks (make-hash-table :test #'equal))
  ;; Column titles go in the buffer, not the header line, which this mode
  ;; spends on the profile, the s3:// path and the status.  See §9.3.3.
  (setq-local tabulated-list-use-header-line nil)
  ;; Replaces the parent's synchronous `tabulated-list-revert', which would
  ;; repaint stale rows and never re-fetch.  Must run after the parent's setup.
  (setq-local revert-buffer-function #'s3-manager--revert)
  (setq-local mode-line-process '(:eval (s3-manager--mode-line-status)))
  ;; Killing the buffer mid-request would otherwise orphan an `aws' process
  ;; that :noquery t stops Emacs even asking about at exit.
  (add-hook 'kill-buffer-hook #'s3-manager--cancel nil t))


;;;; Finding listing buffers

(defun s3-manager--object-listing-p (buffer)
  "Return non-nil when BUFFER is showing the objects in a bucket."
  (buffer-local-value 's3-manager--bucket buffer))

(defun s3-manager--do-listings (profile bucket prefix function)
  "Call FUNCTION with no arguments in each buffer showing PREFIX.
PREFIX is the one in BUCKET under PROFILE.

Buffers are matched by what they are showing rather than looked up by
`s3-manager--buffer-name': the name is derived from the profile and
bucket, so the lookup would be wrong for any listing held in a buffer
this package did not create."
  (dolist (buffer (buffer-list))
    (when (and (buffer-live-p buffer)
               (provided-mode-derived-p (buffer-local-value 'major-mode buffer)
                                        's3-manager-mode)
               (equal (buffer-local-value 's3-manager--profile buffer) profile)
               (equal (buffer-local-value 's3-manager--bucket buffer) bucket)
               (equal (buffer-local-value 's3-manager--prefix buffer) prefix))
      (with-current-buffer buffer (funcall function)))))


;;;; Bucket listing

(defconst s3-manager--bucket-list-format
  [("Created" 12 t) ("Name" 63 t)]
  "Column layout for the bucket list.
Ordered like `s3-manager--object-list-format', for the same reason: a
bucket name may run to 63 characters and would misalign the date.
`Created' is ISO-8601, so it sorts correctly as a string.")

(defun s3-manager--print-list ()
  "Print the list, restoring point to the row that was asked for.
REMEMBER-POS matches the id already at point, which is useless when the
whole listing is replaced, so moving up supplies the row explicitly."
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
                    ;; The bucket name is the entry id: what every command
                    ;; here needs, and stable across a re-sort.
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
  ;; Also advances the generation, so a response already on its way is dropped
  ;; rather than rendered over the newer one.
  (s3-manager--cancel)
  ;; Both set unconditionally, so the newest reload owns the slots and an
  ;; earlier request cannot fire on this listing.
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
`g' means \"I do not trust what I see\", so this prefix's cached copy goes
first.  With a prefix argument WHOLE-BUCKET, drop every cached prefix of
the bucket."
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
    ;; Not `s3-manager--cancel': that advances the generation and there is
    ;; nothing worth killing.  Reusing it stops a stale page appending to a
    ;; newer listing.
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
Name last because `tabulated-list' does not truncate: a name wider than
its column pushes everything after it out of alignment, and S3 keys are
often long.  With the fixed-width columns first it can only run off the
right-hand end.")

(defun s3-manager--directory-rank (entry)
  "Return a sort rank for ENTRY placing directories before objects."
  (if (eq (s3-manager-entry-type entry) 'directory) 0 1))

(defun s3-manager--sort-by (a b accessor predicate)
  "Order rows A and B by ACCESSOR under PREDICATE, directories first.
A and B are whole `tabulated-list-entries' elements, but only their ids
are read: the displayed strings sort wrongly -- \"9 B\" comes after
\"1.8 GiB\" lexicographically."
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
          ;; Bucket-list ids are bare strings.
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
          ;; S3's own cursor, present exactly when IsTruncated is true.
          s3-manager--next-token (alist-get 'NextContinuationToken response)))
  (setq tabulated-list-entries
        (mapcar #'s3-manager--entry-row s3-manager--entries))
  ;; Token included, so returning to a partly-loaded prefix resumes rather
  ;; than starting over.
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

`--no-paginate' makes one invocation exactly one S3 request.  See
`s3-manager-page-size' for why `--max-items' cannot replace `--max-keys'."
  (append (list "s3api" "list-objects-v2" "--bucket" s3-manager--bucket)
          ;; Omitted at the bucket root: an empty --prefix says nothing.
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
      ;; So `s3-manager-up' can put point back on this row rather than at the
      ;; top of the parent listing.
      (push (cons s3-manager--prefix id) s3-manager--history)
      (s3-manager--set-prefix (s3-manager-entry-key id))
      (s3-manager--reload))
     (t
      (s3-manager-view)))))

(defun s3-manager-beginning-of-listing (&optional count)
  "Move to the first row of the listing, or to line COUNT.
Bound to `gg', and takes a count as Evil's own does, so `5gg' still goes
to line 5.

Without a count it does not go to line 1, which is what makes
`beginning-of-buffer' wrong here: the column names are a real line in
the buffer with no entry behind them, and every command in this map
refuses such a row."
  (interactive "P")
  (goto-char (point-min))
  (if count
      (forward-line (1- (prefix-numeric-value count)))
    (while (and (not (eobp)) (null (tabulated-list-get-id)))
      (forward-line 1))))

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
           ;; Arriving by any route but descending -- a refresh in the child,
           ;; say -- leaves no history, so synthesize the entry.  Structural
           ;; `equal' is what makes it match the real row.
           (target (or remembered
                       (s3-manager--directory-entry s3-manager--prefix
                                                    parent))))
      (s3-manager--set-prefix parent)
      (s3-manager--reload target)))))


;;;; Marks
;;
;; The hash table is authoritative, not the characters in the buffer:
;; `tabulated-list-print' erases everything and its UPDATE argument leaves
;; *stale* tags on unchanged rows.  Marks are keyed by S3 key so they survive
;; a re-sort, and live outside the entry struct because that struct is an
;; entry id compared with `equal'.

(defun s3-manager--put-tag (mark &optional advance)
  "Write MARK, a character or nil, in the padding column.
With ADVANCE, move down a line afterwards.  The one place that knows how
a mark renders."
  (tabulated-list-put-tag (if mark (char-to-string mark) "") advance))

(defun s3-manager--entries-marked (mark)
  "Return the objects carrying MARK, in listing order.
Directories are filtered out rather than merely never marked: a
zero-byte object whose key ends in a slash appears in `Contents' as well
as `CommonPrefixes', so the table can hold one."
  (seq-filter (lambda (entry)
                (and (eq (s3-manager-entry-type entry) 'object)
                     (eql mark (gethash (s3-manager-entry-key entry)
                                        s3-manager--marks))))
              s3-manager--entries))

(defun s3-manager--marked-keys ()
  "Return the S3 keys flagged for deletion, in listing order.
No fallback to point, unlike `s3-manager--marked-entries': `x' commits
to what was flagged, so an unflagged listing must refuse rather than
delete the row the cursor happens to be on."
  (mapcar #'s3-manager-entry-key
          (s3-manager--entries-marked s3-manager--delete-char)))

(defun s3-manager--marked-entries ()
  "Return the marked objects, or the entry at point when none are marked.
`dired-get-marked-files' fallback, which is what lets one key mean both
\"act on these\" and \"act on this\".  What is at point comes back
whatever it is, a prefix included."
  (or (s3-manager--entries-marked s3-manager--mark-char)
      (list (s3-manager--entry-at-point))))

(defun s3-manager--apply-marks ()
  "Re-apply marks to the buffer after a repaint."
  (when (and s3-manager--marks (> (hash-table-count s3-manager--marks) 0))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((id (tabulated-list-get-id)))
          (when (s3-manager-entry-p id)
            (when-let* ((mark (gethash (s3-manager-entry-key id)
                                       s3-manager--marks)))
              (s3-manager--put-tag mark))))
        (forward-line 1)))))

(defun s3-manager--clear-marks ()
  "Forget every mark in this buffer.
Called whenever the prefix changes: carrying marks into another listing
would leave invisible ones that `x' would still act on."
  (when s3-manager--marks (clrhash s3-manager--marks))
  (s3-manager--update-header-line))

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
             "Prefixes cannot be marked; commands act on the prefix at point")))
    entry))

(defun s3-manager--mark-hint (mark count)
  "Return the echo-area hint after COUNT objects carry MARK.
The operation a general mark feeds is named *afterwards*, so the keys
that name one have to be said out loud.  `substitute-command-keys', not
the characters spelled out, so a user who has rebound any of them --
which under Evil a global prefix can force for `m' -- is told their own."
  (substitute-command-keys
   (if (eql mark s3-manager--delete-char)
       (format "%d flagged -- \\[s3-manager-execute] deletes, \\[s3-manager-unmark] unmarks"
               count)
     (format (concat "%d marked -- \\[s3-manager-copy] to the other window,"
                     " \\[s3-manager-copy-to] copy, \\[s3-manager-rename] move,"
                     " \\[s3-manager-unmark] unmarks")
             count))))

(defun s3-manager--mark (mark)
  "Give the object at point MARK, then move down."
  (let ((entry (s3-manager--markable-entry-at-point)))
    (puthash (s3-manager-entry-key entry) mark s3-manager--marks)
    (s3-manager--put-tag mark t)
    (s3-manager--update-header-line)
    (message "S3: %s"
             (s3-manager--mark-hint
              mark (length (s3-manager--entries-marked mark))))))

(defun s3-manager-mark ()
  "Mark the object at point, then move down.
The transfer commands act on this mark; `s3-manager-execute' does not."
  (interactive)
  (s3-manager--mark s3-manager--mark-char))

(defun s3-manager-mark-delete ()
  "Flag the object at point for deletion, then move down."
  (interactive)
  (s3-manager--mark s3-manager--delete-char))

(defun s3-manager-unmark ()
  "Remove whichever mark the object at point carries, then move down."
  (interactive)
  (let ((entry (s3-manager--entry-at-point)))
    (when (s3-manager-entry-p entry)
      (remhash (s3-manager-entry-key entry) s3-manager--marks))
    (s3-manager--put-tag nil t)
    (s3-manager--update-header-line)))

(defun s3-manager-unmark-all ()
  "Remove every mark in this buffer."
  (interactive)
  (s3-manager--clear-marks)
  (save-excursion
    (goto-char (point-min))
    (while (not (eobp))
      (s3-manager--put-tag nil)
      (forward-line 1)))
  (message "S3: marks cleared"))

(defun s3-manager--entry-at-point ()
  "Return the entry on the current line, or signal a `user-error'.
The only supported way to obtain one: a placeholder row carries a nil
id, and every command must refuse it."
  (or (tabulated-list-get-id)
      (user-error "No S3 entry on this line")))

(provide 's3-manager-ui)

;;; s3-manager-ui.el ends here
