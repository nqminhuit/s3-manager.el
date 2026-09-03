;;; s3-manager-core.el --- Options, state and error reporting  -*- lexical-binding: t; -*-

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

;; The foundation every other file rests on, and deliberately the only one
;; that knows nothing about the rest.  It holds the customization group, the
;; error conditions, every buffer-local variable an S3 buffer carries, the
;; small pure formatters, and the failure report.
;;
;; Buffer-local state lives here rather than beside the code that uses it so
;; that the whole of what an S3 buffer *is* can be read in one place.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)

;;;; Customization

(defgroup s3-manager nil
  "Manage S3 objects from Emacs."
  :group 'tools
  :prefix "s3-manager-")

(defcustom s3-manager-aws-program "aws"
  "Path to the AWS CLI executable."
  :type 'file)

(defcustom s3-manager-endpoint-url nil
  "Endpoint URL to pass to every AWS CLI invocation.
When nil, the endpoint configured for the profile is used."
  :type '(choice (const :tag "Use profile configuration" nil) string))

(defcustom s3-manager-endpoint-alist nil
  "Alist mapping profile name to endpoint URL.
Takes precedence over `s3-manager-endpoint-url' for matching profiles."
  :type '(alist :key-type string :value-type string))

(defcustom s3-manager-page-size 1000
  "Number of entries fetched per listing request.

Passed as `--max-keys', which is the S3 API's own MaxKeys and counts
objects and prefixes together.

The CLI's documented paging flags are not used, because `--max-items'
counts only the primary result key.  A listing truncated by it reports
*zero* CommonPrefixes and resuming never recovers them, so every
directory silently disappears from a paginated listing.  Measured
against a prefix holding three objects and one sub-prefix:
`--max-items 3' returned the three objects, no prefixes, and a
continuation token; following that token returned nothing further.
`--max-keys 2' with `--continuation-token' returned all four across two
pages."
  :type 'integer)

(defcustom s3-manager-download-directory "~/Downloads/"
  "Directory offered by default when downloading."
  :type 'directory)

(defcustom s3-manager-view-max-size (* 10 1024 1024)
  "Largest object, in bytes, that RET will open in a buffer.

RET is the most frequently pressed key in the listing, so it must never
be an unbounded operation.  Anything larger is refused with its size and
a pointer at `s3-manager-get'."
  :type 'integer)

(defcustom s3-manager-cache-max-entries 200
  "Maximum number of listings held in the cache.
Bounds what a deep tree walk can retain.  Nothing expires on a timer;
this only decides what is dropped when the cap is reached."
  :type 'integer)

(defcustom s3-manager-timeout 120
  "Seconds before an AWS CLI invocation is abandoned.
Set to nil to wait indefinitely.

Governs listings and other metadata calls.  Transfers use
`s3-manager-transfer-timeout' instead; see why there."
  :type '(choice (const :tag "No timeout" nil) integer))

(defcustom s3-manager-transfer-timeout nil
  "Seconds before a transfer is abandoned, or nil to wait indefinitely.

Separate from `s3-manager-timeout' because the two measure different
things.  A listing that has not answered in two minutes is stuck; a
transfer that has been running for two minutes may simply be large.
The timer in `s3-manager--aws-async' is armed once for a total
duration rather than reset by activity, so any wall-clock value kills a
healthy transfer that is merely big -- measured, with the CLI still
running and reporting progress at the moment it was killed.

nil is therefore the only correct default until there is a watchdog
measuring silence rather than elapsed time.  The CLI's own connect and
read timeouts still apply, so a transfer to a black hole does not hang
forever."
  :type '(choice (const :tag "No timeout" nil) integer))

(defcustom s3-manager-upload-follow-symlinks t
  "Whether a recursive upload follows symbolic links.

The AWS CLI follows them by default and does not detect cycles, so a
link pointing at a large tree uploads that tree, and one pointing into
its own parent does not terminate.  The default follows anyway, because
silently *skipping* files the user asked to upload is the worse failure
of the two, and `s3-manager-upload-dry-run' enumerates exactly what
would be sent before a byte moves.  Set this to nil to pass
`--no-follow-symlinks'."
  :type 'boolean)

(defcustom s3-manager-display-errors t
  "Whether a failure shows `s3-manager--error-buffer' as well as recording it.

Every failure is recorded either way, with the CLI's own stderr intact;
this only decides whether the report is put on screen.  The default is
non-nil because the echo-area summary is transient -- the next `message'
overwrites it, which during a transfer is under a second -- and an error
the user never saw is indistinguishable from one that never happened."
  :type 'boolean)

(defconst s3-manager-minimum-cli-version "2.13.0"
  "Oldest AWS CLI release this package supports.
2.13.0 is the first release honouring `endpoint_url' in ~/.aws/config;
older versions ignore it silently and send every request to AWS.")


;;;; Error conditions
;;
;; Errors travel to callers through the ON-ERROR callback rather than by
;; `signal', because a signal raised inside a process sentinel is swallowed by
;; Emacs.  The conditions exist to give the error object a structured shape that
;; callers can dispatch on and that `error-message-string' renders.

(define-error 's3-manager-error "S3 Manager error")
(define-error 's3-manager-cli-error "AWS CLI command failed"
              's3-manager-error)
(define-error 's3-manager-json-error "Unparseable AWS CLI output"
              's3-manager-error)
(define-error 's3-manager-timeout-error "AWS CLI command timed out"
              's3-manager-error)
(define-error 's3-manager-partial-error "AWS CLI partially succeeded"
              's3-manager-error)


;;;; Buffer-local state
;;
;; Only the two variables the transport's own contract refers to are defined
;; here.  Everything the major mode owns arrives with the major mode.

(defvar-local s3-manager--generation 0
  "Monotonic counter of requests issued from this buffer.
Callbacks captured at generation N do nothing once this has moved past
N, which is what makes rapid navigation safe.  See spec section 4.6.")

(defvar-local s3-manager--process nil
  "The AWS CLI process currently servicing this buffer, or nil.")


;;;; Redaction
;;
;; Credentials never reach the command line -- only a profile name and possibly
;; an endpoint URL.  The realistic leak is an endpoint carrying embedded
;; userinfo, plus whatever the service chooses to echo back in an error.

(defconst s3-manager--redactions
  '(("\\(://[^/@[:space:]]+\\):[^/@[:space:]]+@" . "\\1:***@")
    ("\\(X-Amz-Signature=\\)[0-9a-fA-F]+" . "\\1***")
    ("\\(X-Amz-Credential=\\)[^&[:space:]]+" . "\\1***")
    ("\\(X-Amz-Security-Token=\\)[^&[:space:]]+" . "\\1***")
    ("\\(\\(?:aws_\\)?secret_access_key[[:space:]]*[=:][[:space:]]*\\)[^[:space:]]+"
     . "\\1***")
    ("\\(AWS_SESSION_TOKEN[[:space:]]*=[[:space:]]*\\)[^[:space:]]+" . "\\1***")
    ("\\(A[SK]IA\\)[0-9A-Z]\\{12,\\}" . "\\1************"))
  "Regexp/replacement pairs applied to anything shown to the user.")

(defun s3-manager--endpoint-for (profile)
  "Return the endpoint URL override for PROFILE, or nil.
`s3-manager-endpoint-alist' wins over `s3-manager-endpoint-url'.  Nil
means no override: the CLI resolves the endpoint from its own
configuration, which is the preferred arrangement."
  (or (and profile (cdr (assoc profile s3-manager-endpoint-alist)))
      s3-manager-endpoint-url))

(defun s3-manager--redact (string)
  "Mask credential-shaped material in STRING."
  (when string
    (dolist (rule s3-manager--redactions string)
      (setq string (replace-regexp-in-string (car rule) (cdr rule) string t)))))


;;;; Error reporting

(defconst s3-manager--error-buffer "*S3 Manager Error*"
  "Name of the buffer accumulating AWS CLI failure reports.")

(defun s3-manager--exit-code-gloss (code)
  "Return a short parenthetical explanation of exit CODE."
  (pcase code
    (0 "")
    (1 " (aws s3: one or more transfers failed)")
    (2 " (aws s3: one or more objects skipped)")
    (130 " (interrupted)")
    (252 " (invalid command line -- likely an s3-manager bug)")
    (253 " (invalid environment or configuration)")
    (254 " (service returned an error)")
    (255 " (general error -- often a bad profile or unreachable endpoint)")
    (_ "")))

(defun s3-manager--summarize-error (err)
  "Return a one-line summary of ERR for the echo area.
ERR is (CONDITION COMMAND EXIT-CODE DETAIL)."
  (let ((detail (nth 3 err)))
    (or
     ;; The useful line in an s3api failure names the error code and operation.
     (and detail
          (string-match
           ;; Operation names carry digits: ListObjectsV2, CopyObjectV2.
           "An error occurred (\\([A-Za-z0-9]+\\)) when calling the \\([A-Za-z0-9]+\\) operation"
           detail)
          (format "%s on %s"
                  (match-string 1 detail) (match-string 2 detail)))
     ;; `aws s3' failures are prefixed but otherwise free-form.
     (and detail
          (string-match "^fatal error: \\(.*\\)$" detail)
          (match-string 1 detail))
     (and detail
          (car (seq-remove #'string-empty-p
                           (split-string (string-trim detail) "\n"))))
     (format "exit %s" (nth 2 err)))))

(defun s3-manager--record-error (err &optional context)
  "Append ERR to `s3-manager--error-buffer' without disturbing the user.
CONTEXT, when given, is a short string naming the operation.

The recording half of `s3-manager--report-error', separate so that a
background probe the user did not ask for can still leave a trace
instead of being dropped.  The buffer is appended to rather than
replaced: the previous failure is often what explains this one, and the
CLI's stderr is reproduced verbatim, line for line, because a summary
of someone else's error message is a guess."
  (with-current-buffer (get-buffer-create s3-manager--error-buffer)
    (let ((inhibit-read-only t))
      (unless (derived-mode-p 'special-mode) (special-mode))
      (goto-char (point-max))
      (insert (format "\n=== %s  %s\n"
                      (format-time-string "%F %T") (or context "")))
      (insert (format "condition : %s\n" (nth 0 err)))
      (insert (format "command   : %s\n" (nth 1 err)))
      (insert (format "exit code : %s%s\n" (nth 2 err)
                      (s3-manager--exit-code-gloss (nth 2 err))))
      (insert "stderr    :\n")
      (dolist (line (split-string (or (nth 3 err) "(none)") "\n"))
        (insert "  " line "\n")))
    (current-buffer)))

(defun s3-manager--local-error (context detail)
  "Return an error tuple describing a local failure in CONTEXT.
DETAIL is the message.  Local failures have no exit code, but they are
worth recording in the same place as the CLI's: a temporary directory
that could not be removed is exactly as interesting as a refused
request, and rather harder to notice."
  (list 's3-manager-error context nil detail))

(defun s3-manager--report-error (err &optional context)
  "Record ERR in `s3-manager--error-buffer' and tell the user about it.
CONTEXT, when given, is a short string naming the operation.

The echo area gets a one-line summary that always names the buffer
holding the detail, and the buffer itself is displayed when
`s3-manager-display-errors' is non-nil -- in another window, the way
`compile' surfaces a failure, never stealing the selected one."
  (let ((buffer (s3-manager--record-error err context))
        (summary (s3-manager--summarize-error err)))
    (when s3-manager-display-errors
      (display-buffer buffer))
    (message "S3: %s -- see %s" summary s3-manager--error-buffer)
    summary))

;;;###autoload
(defun s3-manager-show-errors ()
  "Display the accumulated AWS CLI failure reports."
  (interactive)
  (if-let* ((buffer (get-buffer s3-manager--error-buffer)))
      (display-buffer buffer)
    (message "S3: no errors recorded this session")))

;;;; Buffer-local state

(defvar-local s3-manager--profile nil
  "AWS CLI profile this buffer is showing, or nil for the CLI default.")

(defvar-local s3-manager--bucket nil
  "Bucket this buffer is showing.  Nil means it shows the bucket list.")

(defvar-local s3-manager--prefix ""
  "Current prefix.  Either the empty string or a string ending in \"/\".")

(defvar-local s3-manager--status nil
  "Request state of this buffer: nil, `loading' or `error'.")

(defvar-local s3-manager--entries nil
  "List of `s3-manager-entry' for the current prefix, in arrival order.
The source of truth; `tabulated-list-entries' is derived from it.")

(defvar-local s3-manager--next-token nil
  "Opaque continuation token for the next page, or nil when complete.")

(defvar-local s3-manager--history nil
  "Stack of (PREFIX . ENTRY) recording the way down to here.
PREFIX is the prefix being left and ENTRY is the row point was on, so
`s3-manager-up' can restore both.")

(defvar-local s3-manager--restore-target nil
  "Entry to put point on once the pending listing arrives.")

(defvar-local s3-manager--restore-key nil
  "S3 key to put point on once the pending listing arrives.

`s3-manager--restore-target' cannot serve here.  It holds an
`s3-manager-entry', which is compared with `equal', and only a
*directory* entry can be synthesized in advance -- see the struct's own
docstring.  An object that has just been uploaded cannot: its Size and
LastModified belong to the server, not to the local file, so an entry
built from what is known locally would match nothing and point would
silently fall back to the top of the buffer.

A key is the one part of the row that is known before the listing comes
back, so this is the weaker request: match on the key alone.  It sits
beside the struct-identity rule rather than weakening it.")

(defvar-local s3-manager--transfers 0
  "Number of transfers started from this buffer that are still running.
Counted rather than flagged so that finishing one does not hide the
progress of another still going.")

(defvar-local s3-manager--transfer-status nil
  "Most recent progress line from a running transfer, or nil.")

(defvar-local s3-manager--marks nil
  "Hash table of S3 keys marked for deletion in this buffer.
Authoritative: `tabulated-list-print' erases the characters in the
buffer, and its UPDATE argument leaves stale tags behind rather than
preserving them, so marks are re-applied from here after every repaint.")

(defun s3-manager--strip-prefix (key prefix)
  "Return KEY with PREFIX removed from its front."
  (if (and prefix (not (string-empty-p prefix)) (string-prefix-p prefix key))
      (substring key (length prefix))
    key))

(defun s3-manager--parent-prefix (prefix)
  "Return the prefix one level above PREFIX, or the empty string."
  (if (string-empty-p prefix)
      ""
    ;; Drop the trailing slash first, then everything after the last one.
    (let ((trimmed (substring prefix 0 (1- (length prefix)))))
      (if (string-match "\\`\\(.*/\\)[^/]*\\'" trimmed)
          (match-string 1 trimmed)
        ""))))


;;;; Rendering helpers

(defun s3-manager--format-date (timestamp)
  "Return the calendar date of ISO-8601 TIMESTAMP, or \"-\" if absent.

S3 renders timestamps with a numeric offset rather than a Z suffix, for
example \"2026-08-01T10:22:31+00:00\".  Only the date is displayed, so
the leading ten characters are taken directly instead of parsing."
  (if (and (stringp timestamp) (>= (length timestamp) 10))
      (substring timestamp 0 10)
    "-"))

(defun s3-manager--buffer-name (profile &optional bucket)
  "Return the buffer name for PROFILE, and BUCKET when given.

One buffer per profile for the bucket list, and one per bucket for
browsing it -- reused across prefixes, which is why the prefix appears
in the header line rather than here."
  (if bucket
      (format "*s3: %s/%s*" (or profile "default") bucket)
    (format "*s3: %s*" (or profile "default"))))

(defun s3-manager--format-progress (line)
  "Condense an `aws s3' progress LINE for display in a mode line.

The CLI emits lines like \"Completed 70.5 KiB/70.5 KiB (558.5 KiB/s)
with 1 file(s) remaining\", which is far too long, so the transferred
amount and the rate are pulled out of it."
  (if (string-match "\\`Completed \\([^(]*?\\) (\\([^)]*\\))" line)
      (format "%s %s" (string-trim (match-string 1 line))
              (match-string 2 line))
    (truncate-string-to-width (string-trim line) 40 nil nil t)))

(defun s3-manager--quote-percent (string)
  "Return STRING safe to put in a mode line or header line.

Those are format constructs, not literal text, so a `%' in an S3 key is
interpreted: \"sale-50%-off.png\" renders `%-' as padding to the right
margin and \"a%b.txt\" renders `%b' as the buffer name.  Keys containing
`%' are commonplace, URL-encoded ones especially."
  (replace-regexp-in-string "%" "%%" string t t))

(defun s3-manager--format-size (size)
  "Return SIZE in bytes as a readable string, or \"-\" when absent."
  (if (integerp size)
      (file-size-human-readable size 'iec " ")
    "-"))

(defconst s3-manager--dry-run-buffer "*S3 Manager Dry Run*"
  "Name of the buffer showing what an operation would do.")

(defun s3-manager--show-dry-run (heading output)
  "Display OUTPUT under HEADING in `s3-manager--dry-run-buffer'.

Replaced rather than appended, unlike `s3-manager--error-buffer': a dry
run is a question with exactly one current answer, and the previous
answer described a different target.  Empty output is spelled out
rather than left blank, because a blank buffer reads as a failure and
the difference matters when the next keystroke acts on what this
listed."
  (with-current-buffer (get-buffer-create s3-manager--dry-run-buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert heading "\n\n")
      (insert (if (string-empty-p (string-trim (or output "")))
                  "(nothing)\n"
                output))
      (goto-char (point-min)))
    (unless (derived-mode-p 'special-mode) (special-mode))
    (display-buffer (current-buffer))))

(defun s3-manager--s3-uri (key)
  "Return the s3:// URI for KEY in this buffer's bucket."
  (format "s3://%s/%s" s3-manager--bucket key))

(provide 's3-manager-core)

;;; s3-manager-core.el ends here
