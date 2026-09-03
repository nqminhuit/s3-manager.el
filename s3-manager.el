;;; s3-manager.el --- Manage S3 objects from Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Minh Nguyen

;; Author: Minh Nguyen <nqminhuit@gmail.com>
;; URL: https://github.com/nqminhuit/s3-manager.el
;; Version: 0.1.0
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

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 'tabulated-list)

;; `json.el' is deliberately absent: `json-parse-buffer' is a native C
;; function, and requiring `json' would pull in a slow Lisp parser this
;; package never calls.

(unless (and (fboundp 'json-parse-buffer) (json-available-p))
  (error "Package s3-manager requires an Emacs built with native JSON support"))


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
Set to nil to wait indefinitely."
  :type '(choice (const :tag "No timeout" nil) integer))

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

(defvar s3-manager--cli-version nil
  "Cons of (PROGRAM . VERSION) from the last successful version probe.
Only successes are cached, and only for the program they were probed
with: the remedy `s3-manager--check-cli' suggests is to install the CLI
or change `s3-manager-aws-program', and caching the failure would make
both ineffective until Emacs restarted.")


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

(defun s3-manager--redact (string)
  "Mask credential-shaped material in STRING."
  (when string
    (dolist (rule s3-manager--redactions string)
      (setq string (replace-regexp-in-string (car rule) (cdr rule) string t)))))


;;;; AWS CLI discovery

(defun s3-manager--safe-directory ()
  "Return a guaranteed-local, guaranteed-existing directory.

Subprocesses are created with `default-directory' bound to this.  A
remote `default-directory' would leave the subprocess running in $HOME
with no warning, and a deleted one makes `make-process' signal
`file-missing'.  Note that locality of execution is guaranteed by using
`make-process' without :file-handler, not by this binding."
  (if (and default-directory
           (not (file-remote-p default-directory))
           (file-accessible-directory-p default-directory))
      default-directory
    (expand-file-name "~/")))

(defun s3-manager--cli-version ()
  "Return the AWS CLI version string, or the symbol `missing'."
  (if (and (consp s3-manager--cli-version)
           (equal (car s3-manager--cli-version) s3-manager-aws-program))
      (cdr s3-manager--cli-version)
    (let ((version
           (if (not (executable-find s3-manager-aws-program))
               'missing
             (with-temp-buffer
               (let ((default-directory (s3-manager--safe-directory)))
                 ;; The one synchronous invocation in the package: local, fast,
                 ;; and everything else depends on its answer.  `call-process'
                 ;; returns a string when the child is signalled and nil under
                 ;; `ignore-errors', so compare rather than use `zerop'.
                 (if (and (eql 0 (ignore-errors
                                   (call-process s3-manager-aws-program
                                                 nil t nil "--version")))
                          (progn (goto-char (point-min))
                                 (looking-at
                                  "aws-cli/\\([0-9]+\\(?:\\.[0-9]+\\)*\\)")))
                     (match-string 1)
                   'missing))))))
      (unless (eq version 'missing)
        (setq s3-manager--cli-version (cons s3-manager-aws-program version)))
      version)))

(defun s3-manager--check-cli ()
  "Signal a `user-error' unless a usable AWS CLI is installed.

Synchronous, and therefore not used on the interactive path: see
`s3-manager--check-executable'."
  (let ((version (s3-manager--cli-version)))
    (cond
     ((eq version 'missing)
      (user-error
       "S3 Manager: AWS CLI not found (%s).  Install AWS CLI v2, or set `s3-manager-aws-program'"
       s3-manager-aws-program))
     ((version< version s3-manager-minimum-cli-version)
      (user-error
       "S3 Manager: AWS CLI %s is too old; %s or newer is required"
       version s3-manager-minimum-cli-version)))
    version))

(defun s3-manager--check-executable ()
  "Signal a `user-error' unless the AWS CLI is on PATH.

Only the program's presence is checked, which is instant.  The version
is confirmed asynchronously by `s3-manager--check-version', because
`aws --version' costs about half a second of Python interpreter startup
-- measured at 0.55s -- and this runs on the very first keystroke.
Spending that synchronously would break the one promise the package
makes about never blocking Emacs."
  (unless (executable-find s3-manager-aws-program)
    (user-error
     "S3 Manager: AWS CLI not found (%s).  Install AWS CLI v2, or set `s3-manager-aws-program'"
     s3-manager-aws-program)))

(defun s3-manager--check-version ()
  "Confirm the AWS CLI version in the background, warning if it is too old.
Runs at most once per session for a given `s3-manager-aws-program'."
  (unless (and (consp s3-manager--cli-version)
               (equal (car s3-manager--cli-version) s3-manager-aws-program))
    (s3-manager--aws-async
     '("--version")
     :parse nil
     :name "s3-version"
     :on-success
     (lambda (output)
       (when (string-match "aws-cli/\\([0-9]+\\(?:\\.[0-9]+\\)*\\)"
                           (or output ""))
         (let ((version (match-string 1 output)))
           (setq s3-manager--cli-version
                 (cons s3-manager-aws-program version))
           (when (version< version s3-manager-minimum-cli-version)
             (display-warning
              's3-manager
              (format "AWS CLI %s is older than %s: `endpoint_url' in ~/.aws/config is ignored, so requests go to AWS rather than your configured endpoint"
                      version s3-manager-minimum-cli-version)
              :warning)))))
     ;; A failed probe is not worth interrupting the user for; the command
     ;; they actually asked for will report its own errors.
     :on-error #'ignore)))


;;;; Command construction

(defun s3-manager--endpoint-for (profile)
  "Return the endpoint URL override for PROFILE, or nil.
`s3-manager-endpoint-alist' wins over `s3-manager-endpoint-url'.  Nil
means no override: the CLI resolves the endpoint from its own
configuration, which is the preferred arrangement."
  (or (and profile (cdr (assoc profile s3-manager-endpoint-alist)))
      s3-manager-endpoint-url))

(defun s3-manager--base-args (profile)
  "Return the global AWS CLI arguments for PROFILE.

PROFILE may be nil, meaning the CLI's own default profile.

`--no-cli-pager' and `--no-cli-auto-prompt' are unconditional.  Neither
should trigger when stdout is a pipe, but a user configuration enabling
the pager or auto-prompt turns an invocation into an unrecoverable hang,
and these two strings cost nothing."
  (append (when profile (list "--profile" profile))
          (when-let* ((url (s3-manager--endpoint-for profile)))
            (list "--endpoint-url" url))
          (list "--no-cli-pager" "--no-cli-auto-prompt")))

(defun s3-manager--command-string (argv)
  "Render ARGV as a redacted, human-readable command line.

The package never executes this string.  It is quoted anyway, because it
is shown to the user in `s3-manager--error-buffer' and the natural next
step is to paste it into a shell to reproduce the failure."
  (s3-manager--redact
   (mapconcat (lambda (a)
                (if (string-match-p "\\`[A-Za-z0-9_@%+=:,./-]+\\'" a)
                    a
                  (shell-quote-argument a)))
              argv " ")))


;;;; Output parsing

(defun s3-manager--parse-json (buffer)
  "Parse BUFFER as the JSON payload of one AWS CLI invocation.

An empty buffer yields nil rather than an error: a prefix matching
nothing produces no output at all, and that is a successful listing of
zero objects, not a failure.

Objects become alists with symbol keys.  JSON null and false both become
nil, so an absent key, a null and an empty collection are
indistinguishable -- which is what every call site in this package
wants."
  (with-current-buffer buffer
    (goto-char (point-min))
    (unless (looking-at-p "\\`[ \t\n\r]*\\'")
      (json-parse-buffer :object-type 'alist
                         :array-type 'list
                         :null-object nil
                         :false-object nil))))


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

(defun s3-manager--report-error (err &optional context)
  "Record ERR in `s3-manager--error-buffer' and summarize it in the echo area.
CONTEXT, when given, is a short string naming the operation.

The buffer is appended to rather than replaced, and is never displayed
automatically: a permission error on one object during a browse should
not steal the user's window."
  (let ((summary (s3-manager--summarize-error err)))
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
          (insert "  " line "\n"))))
    (message "S3: %s" summary)
    summary))


;;;; The transport primitive

(defun s3-manager--safe-funcall (fn arg what)
  "Call FN with ARG, reporting rather than losing any error it signals.

Callbacks run from a process sentinel, and a signal raised in a sentinel
is discarded by Emacs: the request would simply appear to hang forever.
WHAT names the callback for the report."
  (when fn
    (condition-case err
        (funcall fn arg)
      (error
       (message "s3-manager: %s callback failed: %s"
                what (error-message-string err))))))

(defun s3-manager--kill-buffer-safely (buffer)
  "Kill BUFFER if it is still live."
  (when (buffer-live-p buffer) (kill-buffer buffer)))

(defun s3-manager--cleanup (proc)
  "Release every resource attached to PROC.
Safe to call more than once, and safe to call on a process that never
started."
  (when proc
    (when-let* ((timer (process-get proc 's3-timer)))
      (cancel-timer timer)
      (process-put proc 's3-timer nil))
    (s3-manager--kill-buffer-safely (process-get proc 's3-stdout-buffer))
    (s3-manager--kill-buffer-safely (process-get proc 's3-stderr-buffer))
    (process-put proc 's3-stdout-buffer nil)
    (process-put proc 's3-stderr-buffer nil)))

(defun s3-manager--cancel ()
  "Abandon this buffer's in-flight request without running its callbacks."
  (let ((proc s3-manager--process))
    (setq s3-manager--process nil)
    ;; Bump the generation even when there is no process to kill.  Dispatch
    ;; waits for both the process and its stderr pipe, so a request can be
    ;; past its main sentinel and still pending; the generation guard is what
    ;; covers that window.
    (cl-incf s3-manager--generation)
    (when proc
      ;; Detach the sentinels *before* killing, or the kill is delivered as a
      ;; failure and the user gets an error report for a request they
      ;; deliberately abandoned.  Emacs looks the sentinel up at delivery time,
      ;; so replacing it wins even if the process has already exited -- which
      ;; is precisely the case this guards, so do not test `process-live-p'.
      (when-let* ((errproc (process-get proc 's3-stderr-process)))
        (set-process-sentinel errproc #'ignore)
        (set-process-filter errproc #'ignore))
      (set-process-sentinel proc #'ignore)
      (set-process-filter proc #'ignore)
      (when (process-live-p proc) (delete-process proc))
      (s3-manager--cleanup proc))))

(defun s3-manager--current-p (buffer generation)
  "Return non-nil if BUFFER is live and still at GENERATION.
A nil GENERATION means the caller opted out of staleness checking."
  (and (buffer-live-p buffer)
       (or (null generation)
           (eql generation (buffer-local-value 's3-manager--generation buffer)))))

(defun s3-manager--make-progress-filter (callback buffer generation)
  "Return a process filter delivering progress segments to CALLBACK.

CALLBACK runs in BUFFER, and only while BUFFER is still at GENERATION,
so a transfer whose origin has moved on stops repainting it.

The AWS CLI overwrites a single progress line using carriage returns, so
input is split on both delimiters and only the final segment is
reported.  Chunk boundaries do not align with segment boundaries, so an
unterminated tail is carried into the next call."
  (let ((carry ""))
    (lambda (proc chunk)
      ;; Keep the buffer contents intact for error reporting.
      (when (buffer-live-p (process-buffer proc))
        (with-current-buffer (process-buffer proc)
          (goto-char (point-max))
          (insert chunk)))
      (let* ((segments (split-string (concat carry chunk) "[\r\n]"))
             (complete (butlast segments)))
        (setq carry (car (last segments)))
        ;; Report the trailing partial segment too.  Progress lines overwrite
        ;; one another, so a briefly truncated line costs nothing, whereas
        ;; holding it back drops the final segment entirely when the CLI does
        ;; not terminate it.
        (when-let* ((latest (car (last (seq-remove #'string-empty-p
                                                  (append complete
                                                          (list carry)))))))
          (when (s3-manager--current-p buffer generation)
            (with-current-buffer buffer
              (s3-manager--safe-funcall callback latest "on-progress"))))))))

(cl-defun s3-manager--aws-async (args
                                 &key profile register
                                 on-success on-error on-progress
                                 (parse t) (progress-stream 'stdout)
                                 name buffer generation
                                 (timeout s3-manager-timeout))
  "Run the AWS CLI with ARGS asynchronously.  Return the process.

ARGS is the service invocation only, such as (\"s3api\" \"list-buckets\").
The global flags for PROFILE are prepended here rather than by the
caller, so that the service name is always (car ARGS): the classification
of exit codes 1 and 2 depends on knowing whether this is an `aws s3'
command, and a caller-assembled vector begins with a global flag instead.

ARGS is passed as an argument vector.  No shell is involved, so callers
must not quote anything: object keys may legally contain spaces, quotes
and newlines.

REGISTER, when non-nil, records the process in `s3-manager--process' of
the origin buffer so `s3-manager--cancel' can abandon it.  Listings pass
it; transfers must not, or navigating away would abort a download.

ON-SUCCESS is called with the parsed stdout when the CLI exits 0 --- an
alist when PARSE is non-nil, otherwise the raw string.

ON-ERROR is called with an error object (CONDITION COMMAND EXIT-CODE
DETAIL) on any other exit.  EXIT-CODE is the CLI's integer exit status,
nil for a timeout, or a string such as \"signal 9\" when the process was
killed.  It defaults to `s3-manager--report-error'.
Errors are delivered this way rather than signalled because a signal
raised in a sentinel is swallowed by Emacs.

ON-PROGRESS, when given, is called with the most recent progress segment
from PROGRESS-STREAM, which is `stdout' (the default) or `stderr'.  The
default is stdout because that is the only stream that ever carries
progress: the `aws s3' transfer commands write it there, and `s3api'
commands emit none at all.

BUFFER and GENERATION gate every callback: nothing runs if BUFFER has
died or its `s3-manager--generation' has moved on.  NAME labels the
process.  TIMEOUT is in seconds, or nil to wait indefinitely."
  (let* ((argv (cons s3-manager-aws-program
                     (append (s3-manager--base-args profile) args)))
         (label (or name "s3-aws"))
         (origin (or buffer (current-buffer)))
         (stdout-buffer (generate-new-buffer (format " *%s-out*" label) t))
         (stderr-buffer (generate-new-buffer (format " *%s-err*" label) t))
         (default-directory (s3-manager--safe-directory))
         (process-environment (append '("AWS_PAGER="
                                        "AWS_CLI_AUTO_PROMPT=off")
                                      process-environment))
         (exit-code nil)
         (exit-signalled nil)
         ;; Exit codes 1 and 2 mean "partial success" for the `aws s3'
         ;; transfer commands only; for `s3api' they are ordinary failures.
         (transfer-command (equal (car args) "s3"))
         (main-done nil)
         (stderr-done nil)
         (dispatched nil)
         proc stderr-proc)
    (cl-labels
        ((text (buf)
           (if (buffer-live-p buf)
               (with-current-buffer buf (buffer-string))
             ""))
         (deliver (err payload)
           (when (s3-manager--current-p origin generation)
             (with-current-buffer origin
               (if err
                   (s3-manager--safe-funcall
                    (or on-error #'s3-manager--report-error) err "on-error")
                 (s3-manager--safe-funcall on-success payload "on-success")))))
         (dispatch ()
           ;; Runs only once both the process and its stderr pipe have
           ;; finished.  Their sentinels fire in an order that varies from run
           ;; to run, so dispatching from the main sentinel alone would report
           ;; an empty stderr for exactly the failures stderr exists to report.
           (when (and main-done stderr-done (not dispatched))
             (setq dispatched t)
             (let ((stderr (s3-manager--redact (text stderr-buffer)))
                   (command (s3-manager--command-string argv)))
               (unwind-protect
                   (cond
                    ;; Killed by a signal.  `process-exit-status' then returns
                    ;; the signal number, which is not an AWS CLI exit code:
                    ;; reading it as one would report SIGHUP and SIGINT as the
                    ;; "partial success" codes 1 and 2.
                    (exit-signalled
                     (deliver (list 's3-manager-cli-error command
                                    (format "signal %s" exit-code)
                                    (if (string-empty-p stderr)
                                        (format "Terminated by signal %s"
                                                exit-code)
                                      stderr))
                              nil))
                    ((eql exit-code 130)) ; the CLI's own SIGINT status
                    ((eql exit-code 0)
                     (condition-case parse-err
                         (deliver nil (if parse
                                          (s3-manager--parse-json stdout-buffer)
                                        (text stdout-buffer)))
                       (json-error
                        (deliver (list 's3-manager-json-error command 0
                                       (s3-manager--redact
                                        (error-message-string parse-err)))
                                 nil))))
                    (t
                     (deliver (list (if (and transfer-command
                                             (memq exit-code '(1 2)))
                                        's3-manager-partial-error
                                      's3-manager-cli-error)
                                    command exit-code stderr)
                              nil)))
                 (when (and (buffer-live-p origin)
                            (eq (buffer-local-value 's3-manager--process origin)
                                proc))
                   (with-current-buffer origin (setq s3-manager--process nil)))
                 (s3-manager--cleanup proc))))))
      ;; The stderr pipe is constructed explicitly and given an explicit
      ;; sentinel.  Passing a buffer to :stderr, or omitting the sentinel here,
      ;; makes Emacs insert its own "Process ... finished" line into the text we
      ;; are trying to report verbatim.  The :coding is not inherited from the
      ;; main process and must be spelled out: any coding system without an
      ;; explicit EOL suffix rewrites carriage returns to newlines and destroys
      ;; progress output.
      (setq stderr-proc
            (make-pipe-process
             :name (format " *%s-stderr*" label)
             :buffer stderr-buffer
             :noquery t
             :coding 'utf-8-unix
             :filter (if (and on-progress (eq progress-stream 'stderr))
                         (s3-manager--make-progress-filter
                          on-progress origin generation)
                       #'internal-default-process-filter)
             :sentinel (lambda (p _event)
                         (when (memq (process-status p)
                                     '(closed failed exit signal))
                           (setq stderr-done t)
                           (dispatch)))))
      (condition-case err
          (setq proc
                (make-process
                 :name label
                 :buffer stdout-buffer
                 :command argv
                 :stderr stderr-proc
                 :connection-type 'pipe
                 :noquery t
                 :coding '(utf-8-unix . utf-8-unix)
                 :filter (if (and on-progress (eq progress-stream 'stdout))
                             (s3-manager--make-progress-filter
                              on-progress origin generation)
                           #'internal-default-process-filter)
                 :sentinel (lambda (p _event)
                             (let ((status (process-status p)))
                               (when (memq status '(exit signal))
                                 (setq exit-code (process-exit-status p)
                                       exit-signalled (eq status 'signal)
                                       main-done t)
                                 (dispatch))))))
        (error
         ;; The process never started, so no sentinel will ever run.
         (delete-process stderr-proc)
         (s3-manager--kill-buffer-safely stdout-buffer)
         (s3-manager--kill-buffer-safely stderr-buffer)
         (signal (car err) (cdr err))))
      (process-put proc 's3-stdout-buffer stdout-buffer)
      (process-put proc 's3-stderr-buffer stderr-buffer)
      (process-put proc 's3-stderr-process stderr-proc)
      (when (and register (buffer-live-p origin))
        (with-current-buffer origin (setq s3-manager--process proc)))
      (when timeout
        (process-put
         proc 's3-timer
         (run-at-time
          timeout nil
          (lambda ()
            ;; Guard on the dispatch flag, not on process liveness.  If the
            ;; CLI exits while a grandchild holds its stderr open, the pipe
            ;; never closes, the barrier never completes, and this timer is
            ;; the only thing left to release the request.
            (unless dispatched
              (let ((command (s3-manager--command-string argv)))
                (set-process-sentinel proc #'ignore)
                (set-process-filter proc #'ignore)
                (set-process-sentinel stderr-proc #'ignore)
                (set-process-filter stderr-proc #'ignore)
                (when (process-live-p proc) (delete-process proc))
                (setq dispatched t)
                (deliver (list 's3-manager-timeout-error command nil
                               (format "No response after %s seconds" timeout))
                         nil)
                (when (and (buffer-live-p origin)
                           (eq (buffer-local-value 's3-manager--process origin)
                               proc))
                  (with-current-buffer origin (setq s3-manager--process nil)))
                (s3-manager--cleanup proc)))))))
      proc)))

;;;; Profiles
;;
;; The package never reads ~/.aws itself.  It asks the CLI for the profile
;; names and passes the chosen one back with --profile; credentials are the
;; CLI's business throughout.

(defvar s3-manager--profiles nil
  "Cached list of AWS CLI profile names, or nil if not yet discovered.
An empty result is deliberately not cached: the natural response to
\"no profiles found\" is to run `aws configure', and the next attempt
should see the result of having done so.")

(defvar s3-manager--profiles-waiting nil
  "Callbacks awaiting the in-flight profile discovery.
Non-nil also means a discovery is running, so concurrent callers share
one subprocess and produce one prompt rather than several.")

(defvar s3-manager--profile-history nil
  "Minibuffer history of chosen AWS profiles.")

(defun s3-manager--profiles-resolved (profiles err)
  "Hand PROFILES, or report ERR, to everything waiting on discovery."
  (let ((waiting (nreverse s3-manager--profiles-waiting)))
    (setq s3-manager--profiles-waiting nil
          s3-manager--profiles profiles)
    (if err
        (s3-manager--report-error err "configure list-profiles")
      ;; Leave the sentinel before running callbacks.  They prompt, and
      ;; `completing-read' inside a process sentinel reenters the minibuffer
      ;; from arbitrary points in whatever Emacs was doing at the time.
      (run-at-time
       0 nil
       (lambda ()
         (dolist (callback waiting)
           (funcall callback profiles)))))))

(defun s3-manager--with-profiles (callback)
  "Call CALLBACK with the list of AWS profile names.

CALLBACK runs immediately when the list is already known, and otherwise
from a timer once the CLI has answered -- never from inside the process
sentinel, so it is safe for it to prompt."
  (cond
   (s3-manager--profiles (funcall callback s3-manager--profiles))
   (s3-manager--profiles-waiting (push callback s3-manager--profiles-waiting))
   (t
    (setq s3-manager--profiles-waiting (list callback))
    (s3-manager--aws-async
     '("configure" "list-profiles")
     :parse nil
     :name "s3-profiles"
     :on-success (lambda (output)
                   (s3-manager--profiles-resolved
                    (split-string (or output "") "\n" t) nil))
     :on-error (lambda (err) (s3-manager--profiles-resolved nil err))))))

(defun s3-manager-read-profile (callback)
  "Prompt for an AWS profile and call CALLBACK with the chosen name.

Does nothing but report when no profiles are configured.  The default is
the most recently chosen profile, so repeat use is a single RET."
  (s3-manager--with-profiles
   (lambda (profiles)
     (if (null profiles)
         (message
          "S3: no AWS profiles found.  Run `aws configure' to create one")
       (funcall callback
                (completing-read "S3 profile: " profiles nil t nil
                                 's3-manager--profile-history
                                 (car s3-manager--profile-history)))))))

;;;###autoload
(defun s3-manager-forget-profiles ()
  "Discard the cached AWS profile list so it is read again."
  (interactive)
  (setq s3-manager--profiles nil)
  (message "S3: profile list will be re-read"))

;;;###autoload
(defun s3-manager-list-profiles ()
  "Report the AWS profiles the CLI knows about."
  (interactive)
  (s3-manager--check-executable)
  (s3-manager--check-version)
  (s3-manager--with-profiles
   (lambda (profiles)
     (if profiles
         (message "S3 profiles: %s" (string-join profiles ", "))
       (message
        "S3: no AWS profiles found.  Run `aws configure' to create one")))))

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
             s3-manager--transfer-status))))

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
  "G" #'s3-manager-get
  "R" #'s3-manager-get-recursive
  "d" #'s3-manager-mark-delete
  "u" #'s3-manager-unmark
  "U" #'s3-manager-unmark-all
  "x" #'s3-manager-execute
  "D" #'s3-manager-delete)

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
  "Print the list, restoring point to `s3-manager--restore-target' if set.
`tabulated-list-print' REMEMBER-POS matches the id already at point,
which is useless when the whole listing is being replaced, so moving up
a level supplies the row to land on explicitly."
  (let ((target s3-manager--restore-target))
    (setq s3-manager--restore-target nil)
    (tabulated-list-print (null target))
    (s3-manager--apply-marks)
    (when target (s3-manager--goto-entry target))))

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

(defun s3-manager--reload (&optional target)
  "Re-fetch whatever the current buffer is showing.
TARGET, when given, is the entry to put point on once it arrives."
  (unless (derived-mode-p 's3-manager-mode)
    (user-error "Not an S3 Manager buffer"))
  ;; Abandon any request still in flight; this also advances the generation,
  ;; so a response already on its way is dropped rather than rendered over
  ;; the newer one.
  (s3-manager--cancel)
  (setq s3-manager--restore-target target)
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
  "Face for prefixes, which stand in for directories, in an S3 listing.")

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

(defun s3-manager--format-size (size)
  "Return SIZE in bytes as a readable string, or \"-\" when absent."
  (if (integerp size)
      (file-size-human-readable size 'iec " ")
    "-"))

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
      (pop-to-buffer (s3-manager--object-buffer s3-manager--profile id "")))
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
      (pop-to-buffer (s3-manager--bucket-buffer s3-manager--profile bucket))))
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

(defun s3-manager--view-discard (directory)
  "Delete a pending view DIRECTORY and forget it."
  (setq s3-manager--view-pending (delete directory s3-manager--view-pending))
  (ignore-errors (delete-directory directory t)))

(defun s3-manager--view-discard-all ()
  "Delete every view directory still awaiting a buffer.
Installed on `kill-emacs-hook': it is the only thing that can recover a
download whose origin buffer was killed before it finished, since that
suppresses the callbacks."
  (mapc (lambda (directory) (ignore-errors (delete-directory directory t)))
        s3-manager--view-pending)
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
         ;; The bytes came from S3 and are not trusted: a `-*- ... -*-' or
         ;; `Local Variables:' section in them would otherwise be applied.
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
    (pop-to-buffer buffer)))

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
       :name "s3-rm-dryrun"
       :on-success
       (lambda (output)
         (with-current-buffer (get-buffer-create "*S3 Manager Dry Run*")
           (let ((inhibit-read-only t))
             (erase-buffer)
             (insert (format "Would delete under %s:\n\n" uri))
             (insert (if (string-empty-p (string-trim (or output "")))
                         "(nothing)\n"
                       output))
             (goto-char (point-min)))
           (unless (derived-mode-p 'special-mode) (special-mode))
           (display-buffer (current-buffer))))
       :on-error (lambda (err)
                   (s3-manager--report-error err "s3 rm --dryrun"))))))


;;;; Transfers
;;
;; Bytes move with `aws s3 cp' rather than `s3api get-object': it performs a
;; multipart parallel download above 8MB, reports progress, and preserves the
;; object's modification time, none of which get-object does.

(defun s3-manager--s3-uri (key)
  "Return the s3:// URI for KEY in this buffer's bucket."
  (format "s3://%s/%s" s3-manager--bucket key))

(defun s3-manager--transfer-finished ()
  "Note that one transfer in this buffer has stopped."
  (setq s3-manager--transfers (max 0 (1- s3-manager--transfers)))
  (when (zerop s3-manager--transfers)
    (setq s3-manager--transfer-status nil))
  (force-mode-line-update))

(defun s3-manager--transfer (args description &optional on-done on-failure)
  "Run the transfer ARGS, reporting progress in the current buffer.
DESCRIPTION names the operation in messages and error reports.
ON-DONE, when given, is called with no arguments after it succeeds.
ON-FAILURE likewise after it fails, for releasing anything the caller
set up in advance."
  (cl-incf s3-manager--transfers)
  (setq s3-manager--transfer-status "starting")
  (force-mode-line-update)
  (message "S3: %s..." description)
  (s3-manager--aws-async
   args
   :profile s3-manager--profile
   :buffer (current-buffer)
   ;; Deliberately neither :register nor :generation.  Registering would let
   ;; navigation cancel the transfer, and aborting a multi-gigabyte download
   ;; because the user pressed `^' would be indefensible.  Omitting the
   ;; generation keeps progress reporting into the buffer that started it even
   ;; after that buffer has moved on, which is what the user wants to see.
   :parse nil
   :progress-stream 'stdout
   ;; No --quiet and no --only-show-errors: both suppress the progress this
   ;; depends on.  --progress-frequency throttles it at the source.
   :on-progress (lambda (segment)
                  (setq s3-manager--transfer-status
                        (s3-manager--format-progress segment))
                  (force-mode-line-update))
   :on-success (lambda (_output)
                 (s3-manager--transfer-finished)
                 (message "S3: %s -- done" description)
                 (when on-done (funcall on-done)))
   :on-error (lambda (err)
               (s3-manager--transfer-finished)
               (s3-manager--report-error err description)
               (when on-failure (funcall on-failure)))))

(defun s3-manager--read-destination-file (name)
  "Read a local destination for an object called NAME."
  (let* ((directory (file-name-as-directory
                     (expand-file-name s3-manager-download-directory)))
         (chosen (expand-file-name
                  (read-file-name (format "Download %s to: " name)
                                  directory nil nil name)))
         ;; Naming a directory means "into it, under the object's own name".
         (destination (if (file-directory-p chosen)
                          (expand-file-name name chosen)
                        chosen)))
    ;; `aws s3 cp' overwrites without asking, so this is the only chance.
    (when (and (file-exists-p destination)
               (not (y-or-n-p (format "%s exists.  Overwrite? " destination))))
      (user-error "Download aborted"))
    (let ((parent (file-name-directory destination)))
      (unless (file-directory-p parent)
        (make-directory parent t)))
    destination))

(defun s3-manager-get ()
  "Download the object at point."
  (interactive)
  (unless s3-manager--bucket
    (user-error "Not an object listing"))
  (let ((entry (s3-manager--entry-at-point)))
    (unless (eq (s3-manager-entry-type entry) 'object)
      (user-error "%s"
                  (substitute-command-keys
                   "That is a prefix; use \\[s3-manager-get-recursive]")))
    (let* ((key (s3-manager-entry-key entry))
           (destination (s3-manager--read-destination-file
                         (s3-manager-entry-display-name entry))))
      (s3-manager--transfer
       (list "s3" "cp" (s3-manager--s3-uri key) destination
             "--progress-frequency" "1")
       (format "downloading %s to %s" key (abbreviate-file-name destination))))))

(defun s3-manager-get-recursive ()
  "Download every object under the prefix at point."
  (interactive)
  (unless s3-manager--bucket
    (user-error "Not an object listing"))
  (let ((entry (s3-manager--entry-at-point)))
    (unless (eq (s3-manager-entry-type entry) 'directory)
      (user-error "%s"
                  (substitute-command-keys
                   "That is an object; use \\[s3-manager-get]")))
    (let* ((prefix (s3-manager-entry-key entry))
           (leaf (directory-file-name (s3-manager-entry-display-name entry)))
           (default (expand-file-name
                     leaf (expand-file-name s3-manager-download-directory)))
           (destination (file-name-as-directory
                         (expand-file-name
                          (read-directory-name
                           (format "Download %s recursively to: " prefix)
                           default nil nil)))))
      (unless (file-directory-p destination)
        (unless (y-or-n-p (format "Create %s? " destination))
          (user-error "Download aborted"))
        (make-directory destination t))
      (s3-manager--transfer
       (list "s3" "cp" (s3-manager--s3-uri prefix) destination
             "--recursive" "--progress-frequency" "1")
       (format "downloading %s to %s"
               prefix (abbreviate-file-name destination))))))

(defun s3-manager--entry-at-point ()
  "Return the entry on the current line, or signal a `user-error'.
The only supported way for a command to obtain an entry: rows such as a
placeholder carry a nil id, and every command must refuse them."
  (or (tabulated-list-get-id)
      (user-error "No S3 entry on this line")))

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
     (pop-to-buffer (s3-manager--bucket-buffer profile)))))

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
       (pop-to-buffer (s3-manager--bucket-buffer profile))))))

(provide 's3-manager)

;;; s3-manager.el ends here
