;;; s3-manager-core.el --- Options, state and error reporting  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Minh Nguyen

;; Author: Minh Nguyen <nqminhuit@gmail.com>
;; URL: https://github.com/nqminhuit/s3-manager.el

;; This file is not part of GNU Emacs.
;; Part of s3-manager.el.  GPL-3.0-or-later; see LICENSE.

;;; Commentary:

;; Customization group, error conditions, every buffer-local variable an S3
;; buffer carries, the pure formatters, and the failure report.  Knows nothing
;; about the rest of the package.

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
Passed as `--max-keys', which counts objects and prefixes together.
`--max-items' cannot be used in its place: it drops CommonPrefixes.
Measured in spec section 5.3.1."
  :type 'integer)

(defcustom s3-manager-download-directory "~/Downloads/"
  "Directory offered by default when downloading."
  :type 'directory)

(defcustom s3-manager-view-max-size (* 10 1024 1024)
  "Largest object, in bytes, that RET will open in a buffer.
RET is the most frequently pressed key here, so it must never be
unbounded.  Anything larger is refused with a pointer at
`s3-manager-get'."
  :type 'integer)

(defcustom s3-manager-large-transfer-size (* 100 1024 1024)
  "Transfers above this many bytes offer the command instead of running.
One answer to the offer is the `aws' command line to paste into a
terminal.  A recursive transfer always asks, whatever this is: nothing
here can know how much sits under a prefix.  Nil turns the offer off
entirely, recursive included."
  :type '(choice (integer :tag "Bytes")
                 (const :tag "Never offer" nil)))

(defcustom s3-manager-cache-max-entries 200
  "Maximum number of listings held in the cache.
Bounds what a deep tree walk can retain.  Nothing expires on a timer;
this only decides what is dropped when the cap is reached."
  :type 'integer)

(defcustom s3-manager-timeout 120
  "Seconds before a listing or other metadata call is abandoned.
Set to nil to wait indefinitely.  Transfers use
`s3-manager-transfer-timeout' instead; see why there."
  :type '(choice (const :tag "No timeout" nil) integer))

(defcustom s3-manager-transfer-timeout nil
  "Seconds before a transfer is abandoned, or nil to wait indefinitely.
Nil by default because the timer measures total duration rather than
idle time, so any value kills a healthy transfer that is merely large
-- measured, mid-progress.  The CLI's own connect and read timeouts
still bound a transfer to a black hole."
  :type '(choice (const :tag "No timeout" nil) integer))

(defcustom s3-manager-upload-follow-symlinks t
  "Whether a recursive upload follows symbolic links.
The CLI follows them by default and detects no cycles, so a link into
its own parent does not terminate.  Following anyway is the lesser
failure -- `s3-manager-upload-dry-run' shows what would be sent -- but
set this to nil to pass `--no-follow-symlinks'."
  :type 'boolean)

(defcustom s3-manager-display-errors t
  "Whether a failure shows `s3-manager--error-buffer' as well as recording it.
Recorded either way; this only decides display.  Non-nil by default
because the echo-area summary is overwritten by the next `message'."
  :type 'boolean)

(defconst s3-manager-minimum-cli-version "2.13.0"
  "Oldest AWS CLI release this package supports.
2.13.0 is the first release honouring `endpoint_url' in ~/.aws/config;
older versions ignore it silently and send every request to AWS.")


;;;; Error conditions
;;
;; Errors reach callers through ON-ERROR rather than by `signal': a signal
;; raised inside a process sentinel is swallowed by Emacs.  The conditions give
;; the error object a shape callers can dispatch on.

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
;; Credentials never reach the command line.  The realistic leak is an endpoint
;; carrying embedded userinfo, plus whatever the service echoes back.

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
means the CLI resolves the endpoint itself, which is preferred."
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

(defun s3-manager--quote-argv (argv)
  "Render ARGV as a shell command line, quoting only what needs it.
Unredacted, unlike `s3-manager--command-string', so a caller can tell
whether redaction changed anything -- a masked command is not one the
user can paste."
  (mapconcat (lambda (a)
               (if (string-match-p "\\`[A-Za-z0-9_@%+=:,./-]+\\'" a)
                   a
                 (shell-quote-argument a)))
             argv " "))

(defun s3-manager--exit-code-gloss (code &optional detail)
  "Return a short parenthetical explanation of exit CODE.
DETAIL is the CLI's stderr, for a code that reads two ways on its own."
  (pcase code
    (0 "")
    (1 " (aws s3: one or more transfers failed)")
    (2 " (aws s3: one or more objects skipped)")
    (130 " (interrupted)")
    (252
     ;; 252 is "the CLI rejected the command line", which covers both an argv
     ;; this package built wrongly and the CLI refusing an operation it
     ;; considers unsafe.  Measured: `s3 mv' onto the same key is the second,
     ;; and glossing it as the first sends the user to file a bug here rather
     ;; than read the line printed directly above it.
     (if (and detail (string-match-p "Cannot mv a file onto itself" detail))
         " (aws s3 mv refused: source and destination are the same)"
       " (invalid command line -- likely an s3-manager bug)"))
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

The recording half of `s3-manager--report-error', so a probe the user
did not ask for still leaves a trace.  Appended, not replaced: the
previous failure often explains this one.  The CLI's stderr goes in
verbatim -- summarising someone else's error message is a guess."
  (with-current-buffer (get-buffer-create s3-manager--error-buffer)
    (let ((inhibit-read-only t))
      (unless (derived-mode-p 'special-mode) (special-mode))
      (goto-char (point-max))
      (insert (format "\n=== %s  %s\n"
                      (format-time-string "%F %T") (or context "")))
      (insert (format "condition : %s\n" (nth 0 err)))
      (insert (format "command   : %s\n" (nth 1 err)))
      (insert (format "exit code : %s%s\n" (nth 2 err)
                      (s3-manager--exit-code-gloss (nth 2 err) (nth 3 err))))
      (insert "stderr    :\n")
      (dolist (line (split-string (or (nth 3 err) "(none)") "\n"))
        (insert "  " line "\n")))
    (current-buffer)))

(defun s3-manager--local-error (context detail)
  "Return an error tuple describing a local failure in CONTEXT.
DETAIL is the message.  No exit code, but recorded beside the CLI's: a
temporary directory that could not be removed is as interesting as a
refused request and harder to notice."
  (list 's3-manager-error context nil detail))

(defun s3-manager--report-error (err &optional context)
  "Record ERR in `s3-manager--error-buffer' and tell the user about it.
CONTEXT, when given, is a short string naming the operation.

The echo-area summary always names the buffer holding the detail.  That
buffer is displayed when `s3-manager-display-errors' is non-nil, in
another window -- never stealing the selected one."
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
The weaker form of `s3-manager--restore-target', which compares whole
entries: an uploaded object's Size and LastModified are the server's, so
no entry for it can be synthesized in advance.  The key can.")

(defvar-local s3-manager--transfers 0
  "Number of transfers started from this buffer that are still running.
Counted rather than flagged so that finishing one does not hide the
progress of another still going.")

(defvar-local s3-manager--transfer-status nil
  "Most recent progress line from a running transfer, or nil.")

(defconst s3-manager--mark-char ?*
  "The general mark: what the transfer commands act on.
Dired's character, for Dired's reason -- it selects, it does not
commit.")

(defconst s3-manager--delete-char ?D
  "The deletion flag: the mark `s3-manager-execute' acts on, and nothing else.

Never the same character as `s3-manager--mark-char'.  Nothing in the
table records a verb, so \"execute the marks\" has no referent; conflate
the two and `x' deletes objects someone selected in order to copy.
See spec section 9.3.1.")

(defvar-local s3-manager--marks nil
  "Hash table mapping an S3 key to the mark character it carries.
Authoritative: `tabulated-list-print' erases the buffer's own
characters and its UPDATE argument leaves stale ones behind, so marks
are re-applied from here after every repaint.

The value is the character, not a flag, so a second kind of mark needs
no second table and no second code path.")

(defun s3-manager--strip-prefix (key prefix)
  "Return KEY with PREFIX removed from its front."
  (if (and prefix (not (string-empty-p prefix)) (string-prefix-p prefix key))
      (substring key (length prefix))
    key))

(defconst s3-manager--unsafe-leaf-names '("" "." "..")
  "Display names that cannot be used as a local file name.
Each of them names a directory rather than a file inside one.")

(defun s3-manager--safe-leaf-p (name)
  "Return non-nil when NAME can only name a file inside its own directory.
S3 keys are arbitrary, so a display name may legally be \"..\" or start
with a tilde, and `expand-file-name' resolves both somewhere other than
the directory it was handed -- measured in spec section 11.4.  A slash
is refused too, though the delimiter means one cannot appear today."
  (not (or (member name s3-manager--unsafe-leaf-names)
           (string-prefix-p "~" name)
           (string-search "/" name))))

(defun s3-manager--leaf-of (display-name)
  "Return the last segment of DISPLAY-NAME, without a trailing slash.
A zero-byte directory-marker object can carry one."
  (file-name-nondirectory (directory-file-name display-name)))

(defun s3-manager--safe-leaf (name)
  "Return NAME when `s3-manager--safe-leaf-p', else a fixed stand-in.
For a caller needing *a* name rather than the right one.  One writing
several files at once must refuse instead: two unsafe names would
collide on the stand-in."
  (if (s3-manager--safe-leaf-p name) name "s3-object"))

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
Only the date is shown, so the leading ten characters are taken
directly rather than parsed."
  (if (and (stringp timestamp) (>= (length timestamp) 10))
      (substring timestamp 0 10)
    "-"))

(defun s3-manager--buffer-name (profile &optional bucket)
  "Return the buffer name for PROFILE, and BUCKET when given.
One buffer per profile for the bucket list, one per bucket for browsing
it -- reused across prefixes, so the prefix is in the header line."
  (if bucket
      (format "*s3: %s/%s*" (or profile "default") bucket)
    (format "*s3: %s*" (or profile "default"))))

(defun s3-manager--format-progress (line)
  "Condense an `aws s3' progress LINE for display in a mode line.
The CLI's own line is far too long, so only the transferred amount and
the rate are kept."
  (if (string-match "\\`Completed \\([^(]*?\\) (\\([^)]*\\))" line)
      (format "%s %s" (string-trim (match-string 1 line))
              (match-string 2 line))
    (truncate-string-to-width (string-trim line) 40 nil nil t)))

(defun s3-manager--quote-percent (string)
  "Return STRING safe to put in a mode line or header line.
Those are format constructs, so a `%' in a key is interpreted:
\"sale-50%-off.png\" renders `%-' as padding to the right margin.  Keys
containing `%' are commonplace, URL-encoded ones especially."
  (replace-regexp-in-string "%" "%%" string t t))

(defun s3-manager--format-size (size)
  "Return SIZE in bytes as a readable string, or \"-\" when absent."
  (if (integerp size)
      (file-size-human-readable size 'iec " ")
    "-"))

(defconst s3-manager--dry-run-buffer "*S3 Manager Dry Run*"
  "Name of the buffer showing what an operation would do.")

(defconst s3-manager--command-buffer "*S3 Manager Command*"
  "Name of the buffer showing a command to run in a terminal.")

(defun s3-manager--show-commands (argvs)
  "Put ARGVS' command lines in the kill ring, one per line, and display them.

The block pastes into a shell as the sequence that would have run.  One
kill, not N: `kill-new' per command would leave the user yanking them
back one at a time in reverse.

A masked command is flagged rather than handed over quietly.  Nothing
here puts a credential on a command line, but an endpoint carrying
`user:pass@host' is one, and the string is then no longer the command."
  (let* ((commands (mapconcat #'s3-manager--quote-argv argvs "\n"))
         (masked (s3-manager--redact commands))
         (total (length argvs)))
    (kill-new masked)
    (s3-manager--show-report
     s3-manager--command-buffer
     (if (= total 1) "Run this in a terminal:" "Run these in a terminal:")
     (concat masked "\n"
             (unless (equal commands masked)
               (concat "\nCredential-shaped text was masked above, so this"
                       " is no longer\nthe command that would have run.\n"))))
    (message "S3: %d command%s copied to the kill ring"
             total (if (= total 1) "" "s"))))

(defun s3-manager--show-report (buffer heading body)
  "Display BODY under HEADING in BUFFER, replacing what was there.
Replaced, not appended as `s3-manager--error-buffer' is: each of these
answers one question about one target.  An empty BODY is spelled out,
since a blank buffer reads as a failure.  `display-buffer' leaves the
selected window alone -- the user is still in the listing."
  (with-current-buffer (get-buffer-create buffer)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert heading "\n\n")
      (insert (if (string-empty-p (string-trim (or body "")))
                  "(nothing)\n"
                body))
      (goto-char (point-min)))
    (unless (derived-mode-p 'special-mode) (special-mode))
    (display-buffer (current-buffer))))

(defun s3-manager--show-dry-run (heading output)
  "Display OUTPUT under HEADING in `s3-manager--dry-run-buffer'."
  (s3-manager--show-report s3-manager--dry-run-buffer heading output))

(defun s3-manager--uri (bucket key)
  "Return the s3:// URI for KEY in BUCKET."
  (format "s3://%s/%s" bucket key))

(defun s3-manager--s3-uri (key)
  "Return the s3:// URI for KEY in this buffer's bucket."
  (s3-manager--uri s3-manager--bucket key))

(defun s3-manager--parse-uri (uri)
  "Return (BUCKET . KEY) for URI, or signal a `user-error'.
KEY may be empty, meaning the bucket root.

Split rather than matched: a key may legally contain a newline, which
`.' does not match.  Bucket naming is the endpoint's business, so only
what would reach the CLI as a mystery is refused."
  (unless (string-prefix-p "s3://" uri)
    (user-error "Not an s3:// URI: %s" uri))
  (let* ((rest (substring uri 5))
         (slash (string-search "/" rest))
         (bucket (if slash (substring rest 0 slash) rest))
         (key (if slash (substring rest (1+ slash)) "")))
    (when (string-empty-p bucket)
      (user-error "No bucket in %s" uri))
    (when (string-match-p "[[:space:]]" bucket)
      (user-error "Not a bucket name: %s" bucket))
    (cons bucket key)))

(defun s3-manager--copy-key (typed leaf directory)
  "Return the destination key for TYPED, an S3 destination the user gave.
LEAF is the source's own last segment, DIRECTORY non-nil when the source
is a prefix rather than an object.

TYPED is honoured -- what the prompt showed is what happens -- bar two
normalisations neither of which can change a key that was meant: an
object aimed at a prefix goes into it under LEAF, and a prefix
destination always gains a trailing slash.  That slash is load-bearing
for `--recursive' and for `s3 mv' own self-copy guard, which compares
the two URIs as typed; both measured in spec section 11.10."
  (cond
   (directory
    (cond ((string-empty-p typed) typed) ; the bucket root, deliberately
          ((string-suffix-p "/" typed) typed)
          (t (concat typed "/"))))
   ((or (string-empty-p typed) (string-suffix-p "/" typed))
    (concat typed leaf))
   (t typed)))

(defun s3-manager--key-into (prefix leaf)
  "Return the key placing LEAF inside PREFIX.
The rule for \"copy this into that\", shared by `C' and by the
destination `c' offers for editing so the two cannot disagree.
`s3-manager--copy-key' deliberately does not do it: a rename means the
key as typed."
  (concat prefix leaf))

(defun s3-manager--plain-bucket-p (bucket)
  "Return non-nil when BUCKET is a plain bucket name.
An access point ARN or alias can resolve to the same bucket under
another name, which no string comparison can see -- and the CLI warns
that an `s3 mv' between two such names can delete the object.  Refusing
them costs no API call."
  (and (not (string-empty-p bucket))
       (not (string-search ":" bucket))
       (not (string-suffix-p "-s3alias" bucket))
       (not (string-suffix-p "--op-s3" bucket))))

(defun s3-manager--check-destination (source-bucket source-key bucket key
                                                    directory)
  "Signal unless KEY in BUCKET is a sane destination for SOURCE-KEY.
SOURCE-BUCKET holds the source; DIRECTORY is non-nil for a recursive
operation.  KEY has already been through `s3-manager--copy-key', which
is what makes the comparison meaningful.

Ours rather than the CLI's: `s3 cp' onto its own source exits 0 having
done nothing, and `s3 mv' catches only some spellings of it."
  (unless (s3-manager--plain-bucket-p bucket)
    (user-error "Refusing an access point or ARN as a destination: %s" bucket))
  (when (equal bucket source-bucket)
    (when (equal key source-key)
      (user-error "Source and destination are the same: %s"
                  (s3-manager--uri bucket key)))
    ;; Only prefixes can overlap; two object keys either match or do not.
    (when directory
      (when (string-prefix-p source-key key)
        (user-error "Destination %s is inside the source %s"
                    (s3-manager--uri bucket key)
                    (s3-manager--uri source-bucket source-key)))
      (when (string-prefix-p key source-key)
        (user-error "Source %s is inside the destination %s"
                    (s3-manager--uri source-bucket source-key)
                    (s3-manager--uri bucket key))))))

(provide 's3-manager-core)

;;; s3-manager-core.el ends here
