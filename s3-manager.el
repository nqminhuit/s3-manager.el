;;; s3-manager.el --- Manage S3 objects from Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Minh Nguyen

;; Author: Minh Nguyen <minh.q.nguyen@opswat.com>
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
;; This file currently contains only the transport layer: the asynchronous
;; primitive every other part of the package is built on.  See
;; doc/SPEC-v0.1.0.md for the full design; section references in the code below
;; point into it.
;;
;; The two properties the transport exists to guarantee:
;;
;;   * Emacs never blocks.  Every invocation is asynchronous.
;;   * The CLI's stderr survives intact, separated from stdout, so failures can
;;     be reported in the service's own words.
;;
;; Credentials are never read, parsed, stored or logged.  The package selects a
;; profile by name and lets the AWS CLI do everything else.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(unless (and (fboundp 'json-parse-buffer) (json-available-p))
  (error "s3-manager requires an Emacs built with native JSON support"))


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
  "Signal a `user-error' unless a usable AWS CLI is installed."
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

(provide 's3-manager)

;;; s3-manager.el ends here
