;;; s3-manager-process.el --- Asynchronous AWS CLI transport  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Minh Nguyen

;; Author: Minh Nguyen <nqminhuit@gmail.com>
;; URL: https://github.com/nqminhuit/s3-manager.el

;; This file is not part of GNU Emacs.
;; Part of s3-manager.el.  GPL-3.0-or-later; see LICENSE.

;;; Commentary:

;; Everything that runs the `aws' program: argument construction, the
;; subprocess primitive, and profile discovery.  See spec §4 for why the
;; transport looks the way it does.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'seq)
(require 's3-manager-core)

(defvar s3-manager--cli-version nil
  "Cons of (PROGRAM . VERSION) from the last successful version probe.
Successes only, and only for the program probed: the remedy for a
failure is to install the CLI or change `s3-manager-aws-program', and a
cached failure would make both ineffective until restart.")


;;;; AWS CLI discovery

(defun s3-manager--safe-directory ()
  "Return a guaranteed-local, guaranteed-existing directory.
Subprocesses bind `default-directory' to this: a remote one would run
the subprocess in $HOME without a word, and a deleted one makes
`make-process' signal `file-missing'.  Locality of execution comes from
`make-process' without :file-handler, not from this binding."
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
                 ;; `call-process' returns a string when the child is signalled
                 ;; and nil under `ignore-errors', so compare rather than
                 ;; `zerop'.
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
Presence only: `aws --version' costs 0.55s of Python startup, so
`s3-manager--check-version' confirms the version asynchronously."
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
     ;; Recorded, not reported: a failed probe is not worth interrupting for,
     ;; but it must not vanish either, or there is no way to find out why the
     ;; version warning never appeared.
     :on-error (lambda (err)
                 (s3-manager--record-error err "aws --version")))))


;;;; Command construction

(defun s3-manager--base-args (profile)
  "Return the global AWS CLI arguments for PROFILE.
PROFILE may be nil, meaning the CLI's own default profile.

`--no-cli-pager' and `--no-cli-auto-prompt' are unconditional: neither
should trigger on a pipe, but a user configuration that enables either
turns an invocation into an unrecoverable hang."
  (append (when profile (list "--profile" profile))
          (when-let* ((url (s3-manager--endpoint-for profile)))
            (list "--endpoint-url" url))
          (list "--no-cli-pager" "--no-cli-auto-prompt")))

(defun s3-manager--full-argv (profile args)
  "Return the complete argument vector for ARGS under PROFILE.
Program and global flags included, so what this returns is what runs.
Anything showing the user a command to paste builds it with this too --
a shown command differing from the run one is worse than none."
  (cons s3-manager-aws-program
        (append (s3-manager--base-args profile) args)))

(defun s3-manager--command-string (argv)
  "Render ARGV as a redacted, human-readable command line.
Never executed, but quoted anyway: it appears in
`s3-manager--error-buffer', and the natural next step is to paste it
into a shell to reproduce the failure."
  (s3-manager--redact (s3-manager--quote-argv argv)))


;;;; Output parsing

(defun s3-manager--parse-json (buffer)
  "Parse BUFFER as the JSON payload of one AWS CLI invocation.
An empty buffer yields nil: a prefix matching nothing produces no output
at all, and that is a listing of zero objects, not a failure.

Objects become alists with symbol keys, and null and false both become
nil -- so an absent key, a null and an empty collection cannot be told
apart, which is what every call site here wants."
  (with-current-buffer buffer
    (goto-char (point-min))
    (unless (looking-at-p "\\`[ \t\n\r]*\\'")
      (json-parse-buffer :object-type 'alist
                         :array-type 'list
                         :null-object nil
                         :false-object nil))))


;;;; The transport primitive

(defun s3-manager--safe-funcall (fn arg what)
  "Call FN with ARG, reporting rather than losing any error it signals.
Callbacks run from a process sentinel, and Emacs discards a signal
raised there: the request would appear to hang forever.  WHAT names the
callback for the report."
  (when fn
    (condition-case err
        (funcall fn arg)
      (error
       ;; Recorded as well as messaged: this is our bug, not the service's,
       ;; and an echo-area line is gone by the next keystroke.
       (s3-manager--record-error
        (s3-manager--local-error (format "%s callback" what)
                                 (error-message-string err))
        "internal")
       (message "s3-manager: %s callback failed: %s -- see %s"
                what (error-message-string err)
                s3-manager--error-buffer)))))

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
    ;; Bumped even with no process to kill: dispatch waits for the stderr pipe
    ;; too, so a request can be past its main sentinel and still pending.
    (cl-incf s3-manager--generation)
    (when proc
      ;; Detach the sentinels *before* killing, or the kill arrives as a
      ;; failure and reports an error for a request the user abandoned.  Emacs
      ;; resolves the sentinel at delivery time, so this wins even after the
      ;; process has exited -- which is the case being guarded.  Do not add a
      ;; `process-live-p' test here.
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
CALLBACK runs in BUFFER, and only while BUFFER is at GENERATION, so a
transfer whose origin moved on stops repainting it.

The CLI overwrites one progress line with carriage returns, so input is
split on both delimiters and only the last segment reported.  Chunk
boundaries do not align with segment boundaries, so an unterminated tail
carries into the next call."
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
        ;; The trailing partial segment counts too: progress lines overwrite
        ;; one another, so a briefly truncated one costs nothing, while
        ;; holding it back loses the last segment when the CLI leaves it
        ;; unterminated.
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

ARGS is the service invocation only, e.g. (\"s3api\" \"list-buckets\").
PROFILE's global flags are prepended here, so (car ARGS) is always the
service name -- which is what exit codes 1 and 2 are classified against.
It is an argument vector, so quote nothing.

REGISTER records the process for `s3-manager--cancel'.  Listings pass
it; transfers must not, or navigating away would abort a download.

ON-SUCCESS gets the stdout on exit 0: an alist when PARSE, else a string.
ON-ERROR gets (CONDITION COMMAND EXIT-CODE DETAIL) otherwise, where
EXIT-CODE is an integer, nil for a timeout, or \"signal 9\".  Failures are
delivered rather than signalled: a signal in a sentinel is swallowed.
ON-PROGRESS gets the latest segment of PROGRESS-STREAM, `stdout' or
`stderr'; only `aws s3' transfers emit any.

BUFFER and GENERATION gate every callback.  NAME labels the process.
TIMEOUT is seconds, or nil to wait indefinitely."
  (let* ((argv (s3-manager--full-argv profile args))
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
           ;; Only once both the process and its stderr pipe have finished.
           ;; Their sentinels fire in an order that varies run to run, so
           ;; dispatching from the main one alone would report an empty stderr
           ;; for exactly the failures stderr exists to report.
           (when (and main-done stderr-done (not dispatched))
             (setq dispatched t)
             (let ((stderr (s3-manager--redact (text stderr-buffer)))
                   (command (s3-manager--command-string argv)))
               (unwind-protect
                   (cond
                    ;; Killed by a signal.  `process-exit-status' then returns
                    ;; the signal number, not an exit code: read as one, SIGHUP
                    ;; and SIGINT become the "partial success" codes 1 and 2.
                    (exit-signalled
                     (deliver (list 's3-manager-cli-error command
                                    (format "signal %s" exit-code)
                                    (if (string-empty-p stderr)
                                        (format "Terminated by signal %s"
                                                exit-code)
                                      stderr))
                              nil))
                    ((eql exit-code 130)
                     ;; The CLI's SIGINT status -- not our own cancel, which
                     ;; detaches sentinels first.  Delivered as a failure, not
                     ;; swallowed: callers release their state on that path,
                     ;; and skipping it left transfers counted forever and
                     ;; listings stuck loading.
                     (message "S3: interrupted (%s)" (car args))
                     (deliver (list 's3-manager-cli-error command exit-code
                                    (if (string-empty-p stderr)
                                        "Interrupted"
                                      stderr))
                              nil))
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
      ;; Explicit pipe and sentinel: a buffer for :stderr, or no sentinel,
      ;; makes Emacs insert "Process ... finished" into text we report
      ;; verbatim.  :coding is not inherited -- without it CRs become newlines
      ;; and progress parsing breaks.
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
            ;; The dispatch flag, not process liveness: if the CLI exits while
            ;; a grandchild holds its stderr open the pipe never closes, the
            ;; barrier never completes, and this timer is all that is left.
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
;; ~/.aws is never read here.  The CLI is asked for the profile names and the
;; chosen one goes back with --profile; credentials stay its business.

(defvar s3-manager--profiles nil
  "Cached list of AWS CLI profile names, or nil if not yet discovered.
An empty result is never cached: the natural response to \"no profiles
found\" is to run `aws configure', and the next attempt should see it.")

(defvar s3-manager--profiles-waiting nil
  "Callbacks awaiting the in-flight profile discovery.
Non-nil also means one is running, so concurrent callers share a
subprocess and produce one prompt.")

(defvar s3-manager--profile-history nil
  "Minibuffer history of chosen AWS profiles.")

(defun s3-manager--profiles-resolved (profiles err)
  "Hand PROFILES, or report ERR, to everything waiting on discovery."
  (let ((waiting (nreverse s3-manager--profiles-waiting)))
    (setq s3-manager--profiles-waiting nil
          s3-manager--profiles profiles)
    (if err
        (s3-manager--report-error err "configure list-profiles")
      ;; Leave the sentinel before running callbacks: they prompt, and
      ;; `completing-read' in a sentinel reenters the minibuffer from
      ;; wherever Emacs happened to be.
      (run-at-time
       0 nil
       (lambda ()
         (dolist (callback waiting)
           (funcall callback profiles)))))))

(defun s3-manager--with-profiles (callback)
  "Call CALLBACK with the list of AWS profile names.
Immediately when the list is known, otherwise from a timer once the CLI
has answered -- never from the sentinel, so it is safe to prompt."
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
Reports and does nothing when none are configured.  The default is the
last profile chosen, so repeat use is one RET.  The prompt names
`s3-manager-forget-profiles', since the list is cached for the session."
  (s3-manager--with-profiles
   (lambda (profiles)
     (if (null profiles)
         (message
          "S3: no AWS profiles found.  Run `aws configure' to create one")
       (funcall
        callback
        (completing-read
         "S3 profile (missing one? M-x s3-manager-forget-profiles): "
         profiles nil t nil 's3-manager--profile-history
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

(provide 's3-manager-process)

;;; s3-manager-process.el ends here
