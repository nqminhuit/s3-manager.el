;;; s3-manager-test.el --- Tests for s3-manager -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the transport layer.  Nothing here touches the network or reads
;; ~/.aws.
;;
;; The transport is the unit under test, so stubbing `s3-manager--aws-async'
;; would test nothing.  Instead `s3-manager-aws-program' is pointed at
;; test/fake-aws, a shell script whose stdout, stderr, exit code and delay are
;; driven by environment variables.  That exercises the real `make-process', the
;; real stderr pipe, the real completion barrier, the real coding systems and
;; the real buffer bookkeeping -- deterministically and offline.
;;
;; Tests tagged `cli' shell out to a real `aws' binary for offline argument
;; validation and are skipped when it is absent.  Run without them via:
;;
;;   emacs -Q --batch -L . -L test -l test/s3-manager-test.el \
;;         --eval '(ert-run-tests-batch-and-exit (quote (not (tag cli))))'

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 's3-manager)

(defconst s3-manager-test--dir
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory containing this test file.")

(defconst s3-manager-test--fake-aws
  (expand-file-name "fake-aws" s3-manager-test--dir)
  "Path to the AWS CLI test double.")

(defun s3-manager-test--fixture (name)
  "Return the contents of fixture NAME as a string."
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name (concat "fixtures/" name) s3-manager-test--dir))
    (buffer-string)))

(defun s3-manager-test--json (name)
  "Return fixture NAME parsed exactly as the transport would parse it."
  (with-temp-buffer
    (insert (s3-manager-test--fixture name))
    (s3-manager--parse-json (current-buffer))))

(defun s3-manager-test--argv-records (file)
  "Return the argument vectors the test double recorded in FILE.
One list per invocation, in order.  Commands that trigger a follow-up
call -- a delete refreshing its listing -- produce more than one."
  (with-temp-buffer
    (insert-file-contents file)
    (mapcar (lambda (record) (split-string record "\n" t))
            (split-string (buffer-string) "\n\n" t))))

(defun s3-manager-test--wait-for-argv (file count)
  "Wait until FILE holds at least COUNT recorded invocations, and return them.
Waiting on `s3-manager--status' does not work for commands that start
from an idle buffer: the status is already nil, so the predicate is
satisfied before the process has run at all."
  (s3-manager-test--wait
   (lambda () (>= (length (s3-manager-test--argv-records file)) count)))
  (s3-manager-test--argv-records file))

(defun s3-manager-test--scratch-buffers ()
  "Return the transport's scratch buffers that are currently alive."
  (seq-filter (lambda (b)
                (string-match-p "\\` \\*s3-aws.*-\\(out\\|err\\|stderr\\)\\*"
                                (buffer-name b)))
              (buffer-list)))

(defun s3-manager-test--wait (predicate &optional timeout)
  "Pump the event loop until PREDICATE holds or TIMEOUT seconds elapse."
  (let ((deadline (+ (float-time) (or timeout 10))))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (funcall predicate)))

(cl-defmacro s3-manager-test--with-fake-aws
    ((&key stdout stderr (exit 0) delay linger argv-file
           head-stdout head-stderr head-exit)
     &rest body)
  "Run BODY with the AWS CLI replaced by the test double.
STDOUT, STDERR, EXIT, DELAY and LINGER drive the double's behaviour;
ARGV-FILE, when given, is a file the double writes its arguments to.
LINGER keeps the process alive after writing, so a test can observe
transient state that completion would otherwise clear.

HEAD-STDOUT, HEAD-STDERR and HEAD-EXIT answer a `head-object'
invocation separately.  An upload probes and then transfers, and the
probe reporting 404 while the transfer succeeds is the ordinary case;
one exit code for both cannot express it."
  (declare (indent 1))
  `(let* ((s3-manager-aws-program s3-manager-test--fake-aws)
          (s3-manager-timeout 10)
          ;; The listing cache is global: without a fresh one per test, a
          ;; listing cached by an earlier test silently satisfies this
          ;; test's fetch and the request under test never happens.
          (s3-manager--cache (make-hash-table :test #'equal))
          (process-environment
           (append (list (concat "FAKE_AWS_STDOUT=" (or ,stdout ""))
                         (concat "FAKE_AWS_STDERR=" (or ,stderr ""))
                         (format "FAKE_AWS_EXIT=%s" ,exit)
                         (concat "FAKE_AWS_DELAY=" (or ,delay ""))
                         (concat "FAKE_AWS_LINGER=" (or ,linger ""))
                         (concat "FAKE_AWS_ARGV_FILE=" (or ,argv-file ""))
                         (concat "FAKE_AWS_HEAD_STDOUT=" (or ,head-stdout ""))
                         (concat "FAKE_AWS_HEAD_STDERR=" (or ,head-stderr ""))
                         (concat "FAKE_AWS_HEAD_EXIT="
                                 (if ,head-exit (format "%s" ,head-exit) "")))
                   process-environment)))
     ,@body))

(defmacro s3-manager-test--collect (result-var &rest body)
  "Run BODY, then wait until RESULT-VAR stops being `pending'."
  (declare (indent 1))
  `(progn ,@body
          (should (s3-manager-test--wait
                   (lambda () (not (eq ,result-var 'pending)))))))


;;;; Argument construction

(ert-deftest s3-manager-test-base-args-minimal ()
  "A profile with no endpoint override yields profile plus the two guards."
  (let ((s3-manager-endpoint-url nil)
        (s3-manager-endpoint-alist nil))
    (should (equal (s3-manager--base-args "production")
                   '("--profile" "production"
                     "--no-cli-pager" "--no-cli-auto-prompt")))))

(ert-deftest s3-manager-test-base-args-without-profile ()
  "A nil profile omits --profile but keeps the guards."
  (let ((s3-manager-endpoint-url nil)
        (s3-manager-endpoint-alist nil))
    (should (equal (s3-manager--base-args nil)
                   '("--no-cli-pager" "--no-cli-auto-prompt")))))

(ert-deftest s3-manager-test-base-args-scalar-endpoint ()
  (let ((s3-manager-endpoint-url "https://minio.example.com")
        (s3-manager-endpoint-alist nil))
    (should (equal (s3-manager--base-args "minio")
                   '("--profile" "minio"
                     "--endpoint-url" "https://minio.example.com"
                     "--no-cli-pager" "--no-cli-auto-prompt")))))

(ert-deftest s3-manager-test-endpoint-alist-beats-scalar ()
  "The per-profile alist wins; other profiles fall back to the scalar."
  (let ((s3-manager-endpoint-url "https://fallback.example.com")
        (s3-manager-endpoint-alist '(("minio" . "https://minio.example.com"))))
    (should (equal (s3-manager--endpoint-for "minio")
                   "https://minio.example.com"))
    (should (equal (s3-manager--endpoint-for "production")
                   "https://fallback.example.com"))))

(ert-deftest s3-manager-test-endpoint-defaults-to-nil ()
  "With nothing configured the CLI resolves the endpoint itself."
  (let ((s3-manager-endpoint-url nil)
        (s3-manager-endpoint-alist nil))
    (should (null (s3-manager--endpoint-for "production")))))

(ert-deftest s3-manager-test-argv-reaches-the-subprocess ()
  "Arguments arrive at the process verbatim, including awkward ones."
  (let ((argv-file (make-temp-file "s3-manager-argv"))
        (result 'pending))
    (unwind-protect
        (progn
          (s3-manager-test--with-fake-aws (:stdout "{}" :argv-file argv-file)
            (s3-manager-test--collect result
              (s3-manager--aws-async
               '("s3api" "list-objects-v2" "--bucket" "b"
                 "--prefix" "a dir/with \"quotes\"")
               :profile "production"
               :on-success (lambda (p) (setq result (list :ok p)))
               :on-error (lambda (e) (setq result (list :err e))))))
          (should (eq (car result) :ok))
          (should (equal (with-temp-buffer
                           (insert-file-contents argv-file)
                           (split-string (buffer-string) "\n" t))
                         '("--profile" "production"
                           "--no-cli-pager" "--no-cli-auto-prompt"
                           "s3api" "list-objects-v2" "--bucket" "b"
                           "--prefix" "a dir/with \"quotes\""))))
      (delete-file argv-file))))


;;;; JSON parsing

(ert-deftest s3-manager-test-parse-empty-stdout-is-not-an-error ()
  "A prefix matching nothing produces no output; that is zero results."
  (dolist (text '("" "   " "\n\n" " \t\r\n "))
    (with-temp-buffer
      (insert text)
      (should (null (s3-manager--parse-json (current-buffer)))))))

(ert-deftest s3-manager-test-parse-shapes ()
  "Objects become symbol-keyed alists; arrays become lists."
  (with-temp-buffer
    (insert "{\"Buckets\":[{\"Name\":\"media\"},{\"Name\":\"backups\"}]}")
    (let ((parsed (s3-manager--parse-json (current-buffer))))
      (should (equal (mapcar (lambda (b) (alist-get 'Name b))
                             (alist-get 'Buckets parsed))
                     '("media" "backups"))))))

(ert-deftest s3-manager-test-parse-null-and-false-collapse-to-nil ()
  "Absent, null and false are indistinguishable, which is what callers want."
  (with-temp-buffer
    (insert "{\"IsTruncated\":false,\"Prefix\":null}")
    (let ((parsed (s3-manager--parse-json (current-buffer))))
      (should (null (alist-get 'IsTruncated parsed)))
      (should (null (alist-get 'Prefix parsed)))
      (should (null (alist-get 'Contents parsed))))))

(ert-deftest s3-manager-test-parse-tolerates-trailing-whitespace ()
  (with-temp-buffer
    (insert "{\"a\":1}\n\n")
    (should (equal (alist-get 'a (s3-manager--parse-json (current-buffer))) 1))))

(ert-deftest s3-manager-test-parse-recorded-list-buckets ()
  "Parse a recorded `s3api list-buckets' response.
Guards the shape the next increment will consume: `Buckets' is a list of
alists, `Owner' is present and ignorable, and a JSON null field reads as
nil rather than as a sentinel."
  (with-temp-buffer
    (insert (s3-manager-test--fixture "list-buckets.json"))
    (let ((parsed (s3-manager--parse-json (current-buffer))))
      (should (equal (mapcar (lambda (b) (alist-get 'Name b))
                             (alist-get 'Buckets parsed))
                     '("media" "backups")))
      (should (equal (alist-get 'CreationDate
                                (car (alist-get 'Buckets parsed)))
                     "2026-08-01T10:22:31+00:00"))
      (should (null (alist-get 'Prefix parsed))))))

(ert-deftest s3-manager-test-parse-utf8-keys ()
  "S3 keys may be any UTF-8; the coding system must not mangle them."
  (with-temp-buffer
    (insert "{\"Key\":\"café/日本.txt\"}")
    (should (equal (alist-get 'Key (s3-manager--parse-json (current-buffer)))
                   "café/日本.txt"))))


;;;; Redaction

(ert-deftest s3-manager-test-redact-url-userinfo ()
  (let ((masked (s3-manager--redact
                 "Could not connect to https://key:hunter2@minio.example.com/b")))
    (should-not (string-match-p "hunter2" masked))
    (should (string-match-p "minio\\.example\\.com" masked))))

(ert-deftest s3-manager-test-redact-access-key-ids ()
  (dolist (key '("AKIAIOSFODNN7EXAMPLE" "ASIAIOSFODNN7EXAMPLE"))
    (let ((masked (s3-manager--redact (concat "User " key " denied"))))
      (should-not (string-match-p "IOSFODNN7EXAMPLE" masked))
      (should (string-match-p "\\*\\*\\*" masked)))))

(ert-deftest s3-manager-test-redact-signature-params ()
  (let ((masked (s3-manager--redact
                 "X-Amz-Signature=deadbeef1234 X-Amz-Security-Token=abc.def")))
    (should-not (string-match-p "deadbeef1234" masked))
    (should-not (string-match-p "abc\\.def" masked))))

(ert-deftest s3-manager-test-redact-handles-nil ()
  (should (null (s3-manager--redact nil))))


;;;; Error classification and reporting

(ert-deftest s3-manager-test-exit-code-gloss ()
  (should (string-match-p "service" (s3-manager--exit-code-gloss 254)))
  (should (string-match-p "aws s3" (s3-manager--exit-code-gloss 1)))
  (should (string-match-p "aws s3" (s3-manager--exit-code-gloss 2)))
  (should (string-match-p "s3-manager bug" (s3-manager--exit-code-gloss 252)))
  (should (equal "" (s3-manager--exit-code-gloss 0))))

(ert-deftest s3-manager-test-summarize-s3api-error ()
  "The useful line names the service error code and the operation."
  (should (equal
           (s3-manager--summarize-error
            (list 's3-manager-cli-error "aws s3api list-buckets" 254
                  (concat "\nAn error occurred (AccessDenied) when calling "
                          "the ListBuckets operation: User is not authorized")))
           "AccessDenied on ListBuckets")))

(ert-deftest s3-manager-test-summarize-operation-with-digits ()
  "Operation names contain digits; ListObjectsV2 must still be extracted.
Regression: an earlier pattern matched the operation as [A-Za-z]+ and
silently fell through to the generic first-line fallback for every
listing failure."
  (should (equal
           (s3-manager--summarize-error
            (list 's3-manager-cli-error "aws s3api list-objects-v2" 254
                  (concat "\nAn error occurred (NoSuchBucket) when calling "
                          "the ListObjectsV2 operation: The specified bucket "
                          "does not exist")))
           "NoSuchBucket on ListObjectsV2")))

(ert-deftest s3-manager-test-summarize-transfer-error ()
  (should (equal
           (s3-manager--summarize-error
            (list 's3-manager-cli-error "aws s3 cp" 1
                  "fatal error: An error occurred (404) calling HeadObject"))
           "An error occurred (404) calling HeadObject")))

(ert-deftest s3-manager-test-summarize-falls-back-to-first-line ()
  (should (equal (s3-manager--summarize-error
                  (list 's3-manager-cli-error "aws s3api list-buckets" 255
                        "\nUnable to locate credentials\n"))
                 "Unable to locate credentials")))

(ert-deftest s3-manager-test-error-buffer-is-populated ()
  (when (get-buffer "*S3 Manager Error*") (kill-buffer "*S3 Manager Error*"))
  (s3-manager--report-error
   (list 's3-manager-cli-error
         "aws --profile production s3api list-buckets" 254
         "An error occurred (AccessDenied) when calling the ListBuckets operation")
   "list-buckets")
  (with-current-buffer "*S3 Manager Error*"
    (let ((text (buffer-string)))
      (should (string-match-p "exit code : 254" text))
      (should (string-match-p "service returned an error" text))
      (should (string-match-p "AccessDenied" text))
      (should (string-match-p "list-buckets" text))))
  (kill-buffer "*S3 Manager Error*"))


(defmacro s3-manager-test--with-fresh-error-buffer (&rest body)
  "Run BODY with no accumulated error reports, and clean up afterwards."
  (declare (indent 0))
  `(progn
     (when (get-buffer s3-manager--error-buffer)
       (kill-buffer s3-manager--error-buffer))
     (unwind-protect (progn ,@body)
       (when (get-buffer s3-manager--error-buffer)
         (kill-buffer s3-manager--error-buffer)))))

(defun s3-manager-test--error-text ()
  "Return the accumulated error report text, or nil if there is none."
  (when-let* ((buffer (get-buffer s3-manager--error-buffer)))
    (with-current-buffer buffer (buffer-string))))

(ert-deftest s3-manager-test-error-report-keeps-stderr-verbatim ()
  "Every line of the CLI's stderr must survive, not just the summarised one.
Summarising is a guess at which line mattered; the report is where the
service's own words have to be recoverable in full."
  (s3-manager-test--with-fresh-error-buffer
    (s3-manager--report-error
     (list 's3-manager-cli-error "aws s3 cp x s3://b/k" 1
           (concat "upload failed: ./x to s3://b/k\n"
                   "An error occurred (SlowDown) when calling the PutObject"
                   " operation: Please reduce your request rate\n"
                   "completed 3 of 4 parts"))
     "s3 cp")
    (let ((text (s3-manager-test--error-text)))
      (should (string-match-p "upload failed: ./x to s3://b/k" text))
      (should (string-match-p "Please reduce your request rate" text))
      ;; The line the summariser ignored is retained too.
      (should (string-match-p "completed 3 of 4 parts" text))
      (should (string-match-p "one or more transfers failed" text)))))

(ert-deftest s3-manager-test-error-summary-names-the-report-buffer ()
  "The echo line is transient, so it must say where the detail lives."
  (s3-manager-test--with-fresh-error-buffer
    (let ((echoed nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (format &rest args)
                   (setq echoed (apply #'format format args))))
                ((symbol-function 'display-buffer) #'ignore))
        (s3-manager--report-error
         (list 's3-manager-cli-error "aws s3api head-object" 254
               "An error occurred (403) when calling the HeadObject operation")
         "head-object"))
      (should (string-match-p "403 on HeadObject" echoed))
      (should (string-match-p (regexp-quote s3-manager--error-buffer) echoed)))))

(ert-deftest s3-manager-test-errors-are-displayed-when-configured ()
  "`s3-manager-display-errors' decides display, never recording.
An error that is recorded but never shown is indistinguishable from one
that never happened, which is why the default is to show it."
  (s3-manager-test--with-fresh-error-buffer
    (let ((shown nil)
          (err (list 's3-manager-cli-error "aws s3api list-buckets" 255
                     "Unable to locate credentials")))
      (cl-letf (((symbol-function 'display-buffer)
                 (lambda (buffer &rest _) (push buffer shown)))
                ((symbol-function 'message) #'ignore))
        (let ((s3-manager-display-errors t))
          (s3-manager--report-error err "list-buckets"))
        (should (= 1 (length shown)))
        (let ((s3-manager-display-errors nil))
          (s3-manager--report-error err "list-buckets"))
        ;; Still one: the second call recorded without displaying.
        (should (= 1 (length shown))))
      ;; Both calls are in the report regardless of whether they were shown.
      (let ((text (s3-manager-test--error-text))
            (headers 0)
            (start 0))
        (while (string-match "^=== " text start)
          (setq headers (1+ headers)
                start (match-end 0)))
        (should (= 2 headers))))))

(ert-deftest s3-manager-test-version-probe-failure-is-recorded ()
  "A failed version probe must leave a trace instead of being dropped.
It was `:on-error #'ignore', so there was no way to discover why the
too-old-CLI warning never appeared.  It still must not interrupt: the
user did not ask for this call."
  (s3-manager-test--with-fresh-error-buffer
    (let ((echoed nil))
      (s3-manager-test--with-fake-aws (:stderr "boom" :exit 255)
        (let ((s3-manager--cli-version nil))
          (cl-letf (((symbol-function 'message)
                     (lambda (format &rest args)
                       (push (apply #'format format args) echoed))))
            (s3-manager--check-version)
            (should (s3-manager-test--wait
                     (lambda () (s3-manager-test--error-text)) 5)))))
      (should (string-match-p "boom" (s3-manager-test--error-text)))
      (should (string-match-p "aws --version" (s3-manager-test--error-text)))
      ;; Recorded, not reported: nothing was echoed about it.
      (should-not (seq-find (lambda (m) (string-match-p "boom" m)) echoed)))))

(ert-deftest s3-manager-test-directory-cleanup-failure-is-reported ()
  "A temp directory that cannot be removed must say so.
Silence would leave downloaded object bytes on disk while the package
behaved as though it had cleaned up."
  (s3-manager-test--with-fresh-error-buffer
    (cl-letf (((symbol-function 'delete-directory)
               (lambda (&rest _) (error "Permission denied")))
              ((symbol-function 'message) #'ignore))
      (s3-manager--discard-directory "/tmp/s3-manager-nonexistent-xyz"))
    (let ((text (s3-manager-test--error-text)))
      (should (string-match-p "Permission denied" text))
      (should (string-match-p "s3-manager-nonexistent-xyz" text))
      (should (string-match-p "view cleanup" text)))))

(ert-deftest s3-manager-test-view-discard-forgets-even-when-deletion-fails ()
  "The pending set must not grow when cleanup fails, or `kill-emacs-hook'
retries a directory forever."
  (s3-manager-test--with-fresh-error-buffer
    (let ((s3-manager--view-pending (list "/tmp/s3-manager-nonexistent-xyz")))
      (cl-letf (((symbol-function 'delete-directory)
                 (lambda (&rest _) (error "Permission denied")))
                ((symbol-function 'message) #'ignore))
        (s3-manager--view-discard "/tmp/s3-manager-nonexistent-xyz"))
      (should (null s3-manager--view-pending)))))

(ert-deftest s3-manager-test-interruption-is-announced ()
  "Exit 130 was an empty `cond' branch, so an interruption vanished.
It cannot be our own cancel -- that detaches the sentinels before
killing -- so it is a real interruption from outside and must be said
out loud.  It is still not a failure report: nothing went wrong."
  (s3-manager-test--with-fresh-error-buffer
    (let ((echoed nil)
          (called nil))
      (s3-manager-test--with-fake-aws (:exit 130)
        (cl-letf (((symbol-function 'message)
                   (lambda (format &rest args)
                     (push (apply #'format format args) echoed))))
          (s3-manager--aws-async '("s3api" "list-buckets")
                                 :on-success (lambda (_) (setq called 'success))
                                 :on-error (lambda (_) (setq called 'error)))
          (should (s3-manager-test--wait
                   (lambda () (seq-find (lambda (m)
                                          (string-match-p "interrupted" m))
                                        echoed))
                   5))))
      ;; Announced, but neither callback ran and nothing was reported.
      (should (null called))
      (should (null (s3-manager-test--error-text))))))

(ert-deftest s3-manager-test-callback-failure-survives-in-the-report ()
  "A signalling callback is a bug in this package, and must be recoverable.
It was only `message'd, so it was gone by the next keystroke."
  (s3-manager-test--with-fresh-error-buffer
    (cl-letf (((symbol-function 'message) #'ignore))
      (s3-manager--safe-funcall
       (lambda (_) (error "Deliberate callback bug")) nil "on-success"))
    (let ((text (s3-manager-test--error-text)))
      (should (string-match-p "Deliberate callback bug" text))
      (should (string-match-p "on-success callback" text)))))

(ert-deftest s3-manager-test-show-errors-without-any ()
  "`s3-manager-show-errors' must not create an empty report buffer."
  (s3-manager-test--with-fresh-error-buffer
    (let ((shown nil))
      (cl-letf (((symbol-function 'display-buffer)
                 (lambda (buffer &rest _) (push buffer shown)))
                ((symbol-function 'message) #'ignore))
        (s3-manager-show-errors)
        (should (null shown))
        (should (null (get-buffer s3-manager--error-buffer)))))))

(ert-deftest s3-manager-test-show-errors-key-is-bound ()
  (should (eq (keymap-lookup s3-manager-mode-map "!") #'s3-manager-show-errors)))


;;;; Transport: success paths

(ert-deftest s3-manager-test-transport-success ()
  (let ((before (length (s3-manager-test--scratch-buffers)))
        (result 'pending))
    (s3-manager-test--with-fake-aws (:stdout "{\"Buckets\":[{\"Name\":\"media\"}]}")
      (s3-manager-test--collect result
        (s3-manager--aws-async
         '("s3api" "list-buckets")
         :on-success (lambda (p) (setq result (list :ok p)))
         :on-error (lambda (e) (setq result (list :err e))))))
    (should (eq (car result) :ok))
    (should (equal (alist-get 'Name (car (alist-get 'Buckets (cadr result))))
                   "media"))
    (should (= before (length (s3-manager-test--scratch-buffers))))))

(ert-deftest s3-manager-test-transport-empty-stdout-succeeds ()
  "Exit 0 with no output is a successful empty result, not a parse error."
  (let ((result 'pending))
    (s3-manager-test--with-fake-aws (:stdout "")
      (s3-manager-test--collect result
        (s3-manager--aws-async
         '("s3api" "list-objects-v2" "--bucket" "b")
         :on-success (lambda (p) (setq result (list :ok p)))
         :on-error (lambda (e) (setq result (list :err e))))))
    (should (equal result '(:ok nil)))))

(ert-deftest s3-manager-test-transport-raw-parse ()
  "PARSE nil hands back the untouched stdout string."
  (let ((result 'pending))
    (s3-manager-test--with-fake-aws (:stdout "default\\nproduction\\n")
      (s3-manager-test--collect result
        (s3-manager--aws-async
         '("configure" "list-profiles")
         :parse nil
         :on-success (lambda (p) (setq result (list :ok p)))
         :on-error (lambda (e) (setq result (list :err e))))))
    (should (equal result '(:ok "default\nproduction\n")))))


;;;; Transport: the stderr traps

(ert-deftest s3-manager-test-transport-stderr-has-no-emacs-noise ()
  "Emacs must not inject its own status line into the captured stderr.
Passing a buffer to :stderr, or a pipe process without an explicit
sentinel, appends \"Process NAME stderr finished\" to the text this
package reports to the user verbatim."
  (let ((result 'pending))
    (s3-manager-test--with-fake-aws
        (:stderr "An error occurred (AccessDenied)\\n" :exit 254)
      (s3-manager-test--collect result
        (s3-manager--aws-async
         '("s3api" "list-buckets")
         :on-success (lambda (p) (setq result (list :ok p)))
         :on-error (lambda (e) (setq result (list :err e))))))
    (should (eq (car result) :err))
    (let ((stderr (nth 3 (cadr result))))
      (should (string-match-p "AccessDenied" stderr))
      (should-not (string-match-p "Process" stderr))
      (should-not (string-match-p "finished" stderr)))))

(ert-deftest s3-manager-test-transport-late-stderr-is-captured ()
  "The completion barrier: stderr written after stdout closes still arrives.
The two sentinels fire in an order that varies between runs, so
dispatching from the main sentinel alone loses stderr intermittently."
  (let ((result 'pending))
    (s3-manager-test--with-fake-aws
        (:stdout "" :stderr "late-diagnostic\\n" :exit 254 :delay "0.2")
      (s3-manager-test--collect result
        (s3-manager--aws-async
         '("s3api" "list-buckets")
         :on-success (lambda (p) (setq result (list :ok p)))
         :on-error (lambda (e) (setq result (list :err e))))))
    (should (eq (car result) :err))
    (should (string-match-p "late-diagnostic" (nth 3 (cadr result))))))

(ert-deftest s3-manager-test-transport-preserves-carriage-returns ()
  "Progress output is CR-delimited; the coding system must not rewrite it.
`utf-8' and `undecided' detect a CR-only stream as Mac line endings and
convert every \\r to \\n, which destroys progress parsing."
  (let ((result 'pending))
    (s3-manager-test--with-fake-aws
        (:stderr "Completed 1 of 2\\rCompleted 2 of 2\\r" :exit 254)
      (s3-manager-test--collect result
        (s3-manager--aws-async
         '("s3" "cp" "s3://b/k" "/tmp/k")
         :on-success (lambda (p) (setq result (list :ok p)))
         :on-error (lambda (e) (setq result (list :err e))))))
    (should (eq (car result) :err))
    (let ((stderr (nth 3 (cadr result))))
      (should (= 2 (cl-count ?\r stderr)))
      (should (= 0 (cl-count ?\n stderr))))))

(ert-deftest s3-manager-test-transport-progress-callback ()
  "Progress segments are delivered individually, latest last."
  (let ((segments nil)
        (result 'pending))
    (s3-manager-test--with-fake-aws
        (:stdout "Completed 1 of 2\\rCompleted 2 of 2\\rdownload: done\\n")
      (s3-manager-test--collect result
        (s3-manager--aws-async
         '("s3" "cp" "s3://b/k" "/tmp/k")
         :parse nil
         :on-progress (lambda (segment) (push segment segments))
         :on-success (lambda (p) (setq result (list :ok p)))
         :on-error (lambda (e) (setq result (list :err e))))))
    (should (eq (car result) :ok))
    ;; One report per chunk, carrying the most recent segment: earlier
    ;; progress lines in the same chunk have already been superseded.
    (should (equal segments '("download: done")))))

(ert-deftest s3-manager-test-transport-progress-final-partial-segment ()
  "A trailing segment with no delimiter must still be reported.
Progress lines overwrite one another, so holding a partial line back
means losing the last one the CLI ever emits."
  (let ((segments nil) (result 'pending))
    (s3-manager-test--with-fake-aws (:stdout "Completed 2 of 2")
      (s3-manager-test--collect result
        (s3-manager--aws-async '("s3" "cp" "s3://b/k" "/tmp/k")
                               :parse nil
                               :on-progress (lambda (x) (push x segments))
                               :on-success (lambda (p) (setq result (list :ok p)))
                               :on-error (lambda (e) (setq result (list :err e))))))
    (should (member "Completed 2 of 2" segments))))

(ert-deftest s3-manager-test-transport-progress-stream-override ()
  "`:progress-stream stderr' still works for callers that need it."
  (let ((segments nil) (result 'pending))
    (s3-manager-test--with-fake-aws (:stderr "tick one\\rtick two\\r")
      (s3-manager-test--collect result
        (s3-manager--aws-async '("s3" "cp" "s3://b/k" "/tmp/k")
                               :parse nil
                               :progress-stream 'stderr
                               :on-progress (lambda (x) (push x segments))
                               :on-success (lambda (p) (setq result (list :ok p)))
                               :on-error (lambda (e) (setq result (list :err e))))))
    (should (member "tick two" segments))))


;;;; Transport: exit-code classification

(ert-deftest s3-manager-test-transport-service-error ()
  (let ((result 'pending))
    (s3-manager-test--with-fake-aws (:stderr "AccessDenied\\n" :exit 254)
      (s3-manager-test--collect result
        (s3-manager--aws-async '("s3api" "list-buckets")
                               :on-success (lambda (p) (setq result (list :ok p)))
                               :on-error (lambda (e) (setq result (list :err e))))))
    (should (eq (nth 0 (cadr result)) 's3-manager-cli-error))
    (should (= 254 (nth 2 (cadr result))))))

(ert-deftest s3-manager-test-transport-partial-success ()
  "Exit 1 and 2 from `aws s3' mean partial success, not flat failure."
  (dolist (code '(1 2))
    (let ((result 'pending))
      (s3-manager-test--with-fake-aws (:stderr "one object failed\\n" :exit code)
        (s3-manager-test--collect result
          (s3-manager--aws-async '("s3" "rm" "s3://b/p" "--recursive")
                                 :on-success (lambda (p) (setq result (list :ok p)))
                                 :on-error (lambda (e) (setq result (list :err e))))))
      (should (eq (nth 0 (cadr result)) 's3-manager-partial-error))
      (should (= code (nth 2 (cadr result)))))))

(ert-deftest s3-manager-test-transport-partial-is-s3-only ()
  "Exit 1 and 2 are partial success for `aws s3' only.
For `s3api' they are ordinary failures and must not be softened."
  (dolist (code '(1 2))
    (let ((result 'pending))
      (s3-manager-test--with-fake-aws (:stderr "boom\\n" :exit code)
        (s3-manager-test--collect result
          (s3-manager--aws-async '("s3api" "list-buckets")
                                 :on-success (lambda (p) (setq result (list :ok p)))
                                 :on-error (lambda (e) (setq result (list :err e))))))
      (should (eq (nth 0 (cadr result)) 's3-manager-cli-error)))))

(ert-deftest s3-manager-test-transport-partial-with-realistic-argv ()
  "Partial-success detection must survive the global flags.

Regression: the service name was read as (car ARGS) while callers
prepended `s3-manager--base-args', so it was always \"--profile\" and
exit 1/2 from `aws s3' were never recognised.  The earlier tests missed
this by calling the transport with a bare argument list."
  (let ((result 'pending))
    (s3-manager-test--with-fake-aws (:stderr "one object failed\\n" :exit 1)
      (s3-manager-test--collect result
        (s3-manager--aws-async '("s3" "rm" "s3://b/p/" "--recursive")
                               :profile "production"
                               :on-success (lambda (p) (setq result (list :ok p)))
                               :on-error (lambda (e) (setq result (list :err e))))))
    (should (eq (nth 0 (cadr result)) 's3-manager-partial-error))))

(ert-deftest s3-manager-test-register-tracks-and-releases-the-process ()
  "`:register' is what makes a request cancellable, and it self-clears."
  (with-temp-buffer
    (let ((result 'pending))
      (s3-manager-test--with-fake-aws (:stdout "{}")
        (s3-manager--aws-async '("s3api" "list-buckets")
                               :buffer (current-buffer)
                               :register t
                               :on-success (lambda (p) (setq result (list :ok p))))
        (should (processp s3-manager--process))
        (should (s3-manager-test--wait
                 (lambda () (not (eq result 'pending))))))
      (should (null s3-manager--process))))
  ;; Without :register the slot is left alone, so a transfer survives
  ;; navigation instead of being cancelled by it.
  (with-temp-buffer
    (let ((result 'pending))
      (s3-manager-test--with-fake-aws (:stdout "{}")
        (s3-manager--aws-async '("s3" "cp" "s3://b/k" "/tmp/k")
                               :buffer (current-buffer)
                               :parse nil
                               :on-success (lambda (p) (setq result (list :ok p))))
        (should (null s3-manager--process))
        (should (s3-manager-test--wait
                 (lambda () (not (eq result 'pending)))))))))

(ert-deftest s3-manager-test-cancel-covers-the-post-exit-window ()
  "Cancelling must work after the process exits but before dispatch.

Dispatch waits for the stderr pipe as well as the process, so a request
can be past its main sentinel and still pending.  Guarding cancellation
on `process-live-p' skipped exactly that window.  The double holds its
stderr open past its own exit to reproduce it."
  (with-temp-buffer
    (let ((generation-before s3-manager--generation)
          (fired nil)
          proc)
      (let ((process-environment (cons "FAKE_AWS_HOLD_STDERR=3"
                                       process-environment)))
        (s3-manager-test--with-fake-aws (:stdout "{}")
          (s3-manager--aws-async '("s3api" "list-buckets")
                                 :buffer (current-buffer)
                                 :register t
                                 :generation s3-manager--generation
                                 :on-success (lambda (_) (setq fired 'success))
                                 :on-error (lambda (_) (setq fired 'error)))
          (setq proc s3-manager--process)
          ;; The process exits, but the stderr pipe is still held open.
          (should (s3-manager-test--wait
                   (lambda () (not (process-live-p proc)))))
          (should (null fired))          ; dispatch is genuinely still pending
          (s3-manager--cancel)
          (should (> s3-manager--generation generation-before))
          (s3-manager-test--wait #'ignore 0.5)))
      (should (null fired)))))

(ert-deftest s3-manager-test-cancel-bumps-generation-without-a-process ()
  "The generation guard must advance even when there is nothing to kill."
  (with-temp-buffer
    (let ((before s3-manager--generation))
      (s3-manager--cancel)
      (should (> s3-manager--generation before)))))

(ert-deftest s3-manager-test-timeout-when-stderr-outlives-the-process ()
  "The timeout is the only rescue when the stderr pipe never closes.

If the CLI exits while a grandchild holds its stderr open, the barrier
never completes.  Guarding the timer on process liveness meant it did
nothing precisely then, and the request hung forever."
  (let ((before (length (s3-manager-test--scratch-buffers)))
        (result 'pending))
    (let ((process-environment (cons "FAKE_AWS_HOLD_STDERR=10"
                                     process-environment)))
      (s3-manager-test--with-fake-aws (:stdout "{}")
        (let ((s3-manager-timeout 1))
          (s3-manager-test--collect result
            (s3-manager--aws-async
             '("s3api" "list-buckets")
             :on-success (lambda (p) (setq result (list :ok p)))
             :on-error (lambda (e) (setq result (list :err e))))))))
    (should (eq (nth 0 (cadr result)) 's3-manager-timeout-error))
    (should (= before (length (s3-manager-test--scratch-buffers))))))

(ert-deftest s3-manager-test-transport-signal-is-not-an-exit-code ()
  "A signalled process reports the signal number, not an AWS exit code.
Read as an exit code, SIGHUP and SIGINT would masquerade as the
\"partial success\" codes 1 and 2 and a failed transfer would be
reported as having partly worked."
  (let ((result 'pending) proc)
    (s3-manager-test--with-fake-aws (:delay "5")
      (setq proc (s3-manager--aws-async
                  '("s3" "cp" "s3://b/k" "/tmp/k")
                  :on-success (lambda (p) (setq result (list :ok p)))
                  :on-error (lambda (e) (setq result (list :err e)))))
      ;; SIGINT is signal 2, which is also the "objects skipped" exit code.
      (signal-process proc 2)
      (should (s3-manager-test--wait
               (lambda () (not (eq result 'pending))))))
    (should (eq (car result) :err))
    (should (eq (nth 0 (cadr result)) 's3-manager-cli-error))
    (should (equal (nth 2 (cadr result)) "signal 2"))))

(ert-deftest s3-manager-test-callback-error-is-reported-not-lost ()
  "A signal raised in a callback is discarded by Emacs' sentinel machinery.
It must be surfaced, and it must not prevent resource cleanup."
  (let ((before (length (s3-manager-test--scratch-buffers)))
        (messages nil)
        (done nil))
    (cl-letf (((symbol-function 'message)
               (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
      (s3-manager-test--with-fake-aws (:stdout "{}")
        (let ((proc (s3-manager--aws-async
                     '("s3api" "list-buckets")
                     :on-success (lambda (_) (error "deliberate callback bug")))))
          (s3-manager-test--wait (lambda () (not (process-live-p proc))))
          (s3-manager-test--wait (lambda () (setq done t) nil) 0.2))))
    (should done)
    (should (seq-find (lambda (m) (string-match-p "deliberate callback bug" m))
                      messages))
    (should (= before (length (s3-manager-test--scratch-buffers))))))

(ert-deftest s3-manager-test-transport-interrupt-runs-no-callbacks ()
  "Exit 130 must not surface as an error, nor run either callback.
It is announced in the echo area -- see
`s3-manager-test-interruption-is-announced' -- but an interruption is
not a failure, so nothing is reported and nothing downstream runs."
  (let ((fired nil))
    (s3-manager-test--with-fake-aws (:exit 130)
      (let ((proc (s3-manager--aws-async
                   '("s3api" "list-buckets")
                   :on-success (lambda (_) (setq fired 'success))
                   :on-error (lambda (_) (setq fired 'error)))))
        (s3-manager-test--wait (lambda () (not (process-live-p proc))))
        (s3-manager-test--wait #'ignore 0.3)))
    (should (null fired))))

(ert-deftest s3-manager-test-transport-invalid-json-is-an-error ()
  (let ((result 'pending))
    (s3-manager-test--with-fake-aws (:stdout "not json at all")
      (s3-manager-test--collect result
        (s3-manager--aws-async '("s3api" "list-buckets")
                               :on-success (lambda (p) (setq result (list :ok p)))
                               :on-error (lambda (e) (setq result (list :err e))))))
    (should (eq (nth 0 (cadr result)) 's3-manager-json-error))))


;;;; Transport: cancellation, staleness and resources

(ert-deftest s3-manager-test-transport-cancel-runs-no-callbacks ()
  "An abandoned request must not report an error the user did not cause."
  (let ((before (length (s3-manager-test--scratch-buffers)))
        (fired nil))
    (with-temp-buffer
      (s3-manager-test--with-fake-aws (:delay "5")
        (s3-manager--aws-async
         '("s3api" "list-buckets")
         :buffer (current-buffer)
         :register t
         :on-success (lambda (_) (setq fired 'success))
         :on-error (lambda (_) (setq fired 'error)))
        (should (process-live-p s3-manager--process))
        (s3-manager--cancel)
        (s3-manager-test--wait #'ignore 0.3)))
    (should (null fired))
    (should (= before (length (s3-manager-test--scratch-buffers))))))

(ert-deftest s3-manager-test-transport-stale-generation-is-dropped ()
  "A response for a superseded request changes nothing."
  (let ((fired nil))
    (with-temp-buffer
      (s3-manager-test--with-fake-aws (:stdout "{}")
        (let ((proc (s3-manager--aws-async
                     '("s3api" "list-buckets")
                     :buffer (current-buffer)
                     :generation 0
                     :on-success (lambda (_) (setq fired 'success))
                     :on-error (lambda (_) (setq fired 'error)))))
          ;; The user navigated away before the response arrived.
          (setq s3-manager--generation 1)
          (s3-manager-test--wait (lambda () (not (process-live-p proc))))
          (s3-manager-test--wait #'ignore 0.3))))
    (should (null fired))))

(ert-deftest s3-manager-test-transport-dead-buffer-is-survivable ()
  "Killing the origin buffer mid-flight must not error in the sentinel."
  (let ((before (length (s3-manager-test--scratch-buffers)))
        (buffer (generate-new-buffer "s3-test-doomed"))
        proc)
    (s3-manager-test--with-fake-aws (:stdout "{}" :delay "0.2")
      (setq proc (s3-manager--aws-async
                  '("s3api" "list-buckets")
                  :buffer buffer
                  :on-success #'ignore))
      (kill-buffer buffer)
      (should (s3-manager-test--wait (lambda () (not (process-live-p proc)))))
      (s3-manager-test--wait #'ignore 0.3))
    (should (= before (length (s3-manager-test--scratch-buffers))))))

(ert-deftest s3-manager-test-transport-no-leak-on-any-path ()
  "Success, service error and parse failure all release their buffers."
  (let ((before (length (s3-manager-test--scratch-buffers))))
    (dolist (spec '(("{}" "" 0) ("" "boom" 254) ("garbage" "" 0)))
      (let ((result 'pending))
        (s3-manager-test--with-fake-aws
            (:stdout (nth 0 spec) :stderr (nth 1 spec) :exit (nth 2 spec))
          (s3-manager-test--collect result
            (s3-manager--aws-async
             '("s3api" "list-buckets")
             :on-success (lambda (p) (setq result (list :ok p)))
             :on-error (lambda (e) (setq result (list :err e))))))))
    (should (= before (length (s3-manager-test--scratch-buffers))))))

(ert-deftest s3-manager-test-transport-timeout ()
  (let ((before (length (s3-manager-test--scratch-buffers)))
        (result 'pending))
    (s3-manager-test--with-fake-aws (:delay "5")
      (let ((s3-manager-timeout 1))
        (s3-manager-test--collect result
          (s3-manager--aws-async
           '("s3api" "list-buckets")
           :on-success (lambda (p) (setq result (list :ok p)))
           :on-error (lambda (e) (setq result (list :err e)))))))
    (should (eq (nth 0 (cadr result)) 's3-manager-timeout-error))
    (should (= before (length (s3-manager-test--scratch-buffers))))))


;;;; CLI discovery

(ert-deftest s3-manager-test-cli-version-parsing ()
  (let ((s3-manager--cli-version nil))
    (s3-manager-test--with-fake-aws
        (:stdout "aws-cli/2.33.30 Python/3.13.11 Linux/7.0 exe/x86_64\\n")
      (should (equal (s3-manager--cli-version) "2.33.30")))))

(ert-deftest s3-manager-test-cli-version-is-cached-per-program ()
  "A successful probe is cached, but only for the program it probed.
Caching a failure would make the remedy the error message suggests --
install the CLI, or set `s3-manager-aws-program' -- ineffective until
Emacs restarted."
  (let ((s3-manager--cli-version (cons "some-aws" "2.20.0")))
    (let ((s3-manager-aws-program "some-aws"))
      (should (equal (s3-manager--cli-version) "2.20.0")))
    ;; A different program must be probed afresh, not answered from cache.
    (let ((s3-manager-aws-program "s3-manager-no-such-program"))
      (should (eq (s3-manager--cli-version) 'missing)))))

(ert-deftest s3-manager-test-cli-missing-is-not-cached ()
  "After installing the CLI the next probe must succeed without a restart."
  (let ((s3-manager--cli-version nil))
    (let ((s3-manager-aws-program "s3-manager-no-such-program"))
      (should (eq (s3-manager--cli-version) 'missing)))
    (should (null s3-manager--cli-version))
    (s3-manager-test--with-fake-aws (:stdout "aws-cli/2.33.30 Python/3.13\\n")
      (should (equal (s3-manager--cli-version) "2.33.30")))))

(ert-deftest s3-manager-test-cli-missing-is-reported ()
  (let ((s3-manager--cli-version nil)
        (s3-manager-aws-program "s3-manager-no-such-program"))
    (should (eq (s3-manager--cli-version) 'missing))
    (should-error (s3-manager--check-cli) :type 'user-error)))

(ert-deftest s3-manager-test-check-executable-is-instant ()
  "The interactive path must not pay for `aws --version'.

Measured at 0.55s of Python interpreter startup, spent on the very first
keystroke, which would break the package's one promise about never
blocking Emacs.  Presence is checked here; the version is confirmed in
the background."
  (let ((s3-manager--cli-version nil)
        (start (float-time)))
    (s3-manager--check-executable)
    (should (< (- (float-time) start) 0.05)))
  (let ((s3-manager-aws-program "s3-manager-no-such-program"))
    (should-error (s3-manager--check-executable) :type 'user-error)))

(ert-deftest s3-manager-test-check-version-warns-when-too-old ()
  "An old CLI ignores endpoint_url silently, so say so -- in the background."
  (let ((s3-manager--cli-version nil)
        (warnings nil))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (_type message &rest _)
                 (push message warnings))))
      (s3-manager-test--with-fake-aws (:stdout "aws-cli/2.9.1 Python/3.13\\n")
        (s3-manager--check-version)
        (should (s3-manager-test--wait (lambda () warnings)))))
    (should (seq-find (lambda (w) (string-match-p "2\\.13\\.0" w)) warnings))
    (should (seq-find (lambda (w) (string-match-p "endpoint_url" w)) warnings))))

(ert-deftest s3-manager-test-check-version-is-quiet-when-current ()
  (let ((s3-manager--cli-version nil)
        (warnings nil))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (&rest args) (push args warnings))))
      (s3-manager-test--with-fake-aws (:stdout "aws-cli/2.33.30 Python/3.13\\n")
        (s3-manager--check-version)
        (should (s3-manager-test--wait
                 (lambda () (consp s3-manager--cli-version))))))
    (should (null warnings))
    (should (equal (cdr s3-manager--cli-version) "2.33.30"))))

(ert-deftest s3-manager-test-check-version-probes-once ()
  (let ((s3-manager--cli-version (cons s3-manager-aws-program "2.33.30"))
        (calls 0))
    (cl-letf* ((original (symbol-function 's3-manager--aws-async))
               ((symbol-function 's3-manager--aws-async)
                (lambda (&rest args) (cl-incf calls) (apply original args))))
      (s3-manager--check-version))
    (should (zerop calls))))

(ert-deftest s3-manager-test-cli-too-old-is-rejected ()
  "Below 2.13.0 the CLI ignores endpoint_url in ~/.aws/config silently."
  (let ((s3-manager--cli-version (cons s3-manager-aws-program "2.9.1")))
    (should-error (s3-manager--check-cli) :type 'user-error))
  (let ((s3-manager--cli-version (cons s3-manager-aws-program "2.13.0")))
    (should (equal (s3-manager--check-cli) "2.13.0"))))


;;;; Offline validation against the real AWS CLI

(ert-deftest s3-manager-test-argv-is-accepted-by-the-real-cli ()
  "The CLI parses our service arguments without any network access.

`--generate-cli-skeleton' runs the real argument parser and exits 0
without contacting anything, so a flag that does not exist on a
subcommand fails here rather than in production.

The pagination flags are excluded deliberately.  `--max-items',
`--page-size' and `--starting-token' are client-side options that
botocore turns into a `PaginationConfig' entry, which the skeleton
generator rejects with exit 252:

    Unknown parameter in input: \"PaginationConfig\"

So this technique validates the service-level arguments only.  Verified
that it still catches real mistakes: an invented flag exits 252 here."
  :tags '(cli)
  (skip-unless (executable-find "aws"))
  (let ((s3-manager-endpoint-url nil)
        (s3-manager-endpoint-alist nil))
    (should (= 0 (apply #'call-process "aws" nil nil nil
                        (append (s3-manager--base-args nil)
                                '("s3api" "list-objects-v2"
                                  "--bucket" "example"
                                  "--prefix" "p/"
                                  "--delimiter" "/"
                                  "--output" "json"
                                  "--generate-cli-skeleton" "output")))))
    ;; Guard the guard: prove the technique would fail on a bad flag.
    (should-not
     (= 0 (apply #'call-process "aws" nil nil nil
                 (append (s3-manager--base-args nil)
                         '("s3api" "list-objects-v2"
                           "--bucket" "example"
                           "--no-such-flag" "x"
                           "--generate-cli-skeleton" "output")))))))


;;;; Profile discovery and selection

(defmacro s3-manager-test--with-clean-profiles (&rest body)
  "Run BODY with the profile caches empty and restored afterwards."
  (declare (indent 0))
  `(let ((s3-manager--profiles nil)
         (s3-manager--profiles-waiting nil)
         (s3-manager--profile-history nil))
     ,@body))

(ert-deftest s3-manager-test-profiles-are-parsed ()
  "`configure list-profiles' emits bare names, one per line."
  (s3-manager-test--with-clean-profiles
    (let ((result 'pending))
      (s3-manager-test--with-fake-aws
          (:stdout "default\\nproduction\\nminio\\n")
        (s3-manager--with-profiles (lambda (p) (setq result p)))
        (should (s3-manager-test--wait
                 (lambda () (not (eq result 'pending))))))
      (should (equal result '("default" "production" "minio")))
      (should (equal s3-manager--profiles '("default" "production" "minio"))))))

(ert-deftest s3-manager-test-profiles-uses-no-profile-flag ()
  "Discovery must not pass --profile: it is what discovers them."
  (s3-manager-test--with-clean-profiles
    (let ((argv-file (make-temp-file "s3-profiles-argv"))
          (result 'pending))
      (unwind-protect
          (progn
            (s3-manager-test--with-fake-aws
                (:stdout "default\\n" :argv-file argv-file)
              (s3-manager--with-profiles (lambda (p) (setq result p)))
              (should (s3-manager-test--wait
                       (lambda () (not (eq result 'pending))))))
            (let ((argv (with-temp-buffer
                          (insert-file-contents argv-file)
                          (split-string (buffer-string) "\n" t))))
              (should (equal argv '("--no-cli-pager" "--no-cli-auto-prompt"
                                    "configure" "list-profiles")))
              (should-not (member "--profile" argv))))
        (delete-file argv-file)))))

(ert-deftest s3-manager-test-profiles-empty-is-not-an-error ()
  "A machine with no ~/.aws exits 0 with no output."
  (s3-manager-test--with-clean-profiles
    (let ((result 'pending))
      (s3-manager-test--with-fake-aws (:stdout "")
        (s3-manager--with-profiles (lambda (p) (setq result (list :got p))))
        (should (s3-manager-test--wait
                 (lambda () (not (eq result 'pending))))))
      (should (equal result '(:got nil)))
      ;; Not cached: the remedy is to run `aws configure', and the next
      ;; attempt should see that it was run.
      (should (null s3-manager--profiles)))))

(ert-deftest s3-manager-test-profiles-are-cached ()
  "A second lookup must not spawn a second process."
  (s3-manager-test--with-clean-profiles
    (let ((result 'pending))
      (s3-manager-test--with-fake-aws (:stdout "default\\n")
        (s3-manager--with-profiles (lambda (p) (setq result p)))
        (should (s3-manager-test--wait
                 (lambda () (not (eq result 'pending))))))
      ;; With the program pointed at something that cannot run, a cache miss
      ;; would fail loudly.
      (let ((s3-manager-aws-program "s3-manager-no-such-program")
            (again 'pending))
        (s3-manager--with-profiles (lambda (p) (setq again p)))
        (should (equal again '("default")))))))

(ert-deftest s3-manager-test-forget-profiles-forces-a-reread ()
  (s3-manager-test--with-clean-profiles
    (setq s3-manager--profiles '("stale"))
    (s3-manager-forget-profiles)
    (should (null s3-manager--profiles))))

(ert-deftest s3-manager-test-concurrent-lookups-share-one-process ()
  "Two callers must produce one subprocess and one prompt, not two."
  (s3-manager-test--with-clean-profiles
    (let ((argv-file (make-temp-file "s3-profiles-argv"))
          (calls 0)
          (first 'pending) (second 'pending))
      (unwind-protect
          (s3-manager-test--with-fake-aws
              (:stdout "default\\nproduction\\n" :delay "0.2"
               :argv-file argv-file)
            (cl-letf* ((original (symbol-function 's3-manager--aws-async))
                       ((symbol-function 's3-manager--aws-async)
                        (lambda (&rest args)
                          (cl-incf calls)
                          (apply original args))))
              (s3-manager--with-profiles (lambda (p) (setq first p)))
              (s3-manager--with-profiles (lambda (p) (setq second p)))
              (should (s3-manager-test--wait
                       (lambda () (not (or (eq first 'pending)
                                           (eq second 'pending))))))
              (should (= calls 1))
              (should (equal first '("default" "production")))
              (should (equal second first))))
        (delete-file argv-file)))))

(defvar s3-manager-test--inside-resolver nil
  "Bound to t only for the dynamic extent of the discovery resolver.")

(ert-deftest s3-manager-test-profile-callbacks-do-not-run-in-a-sentinel ()
  "Callbacks may prompt, so they must not run inside a process sentinel.

`completing-read' called from a sentinel reenters the minibuffer at an
arbitrary point in whatever Emacs happened to be doing.  Discovery hands
control back through a timer first, and this pins that: the resolver is
what the sentinel calls, so a callback observing its dynamic extent
would prove the hop had been removed.

Note that `inhibit-quit' cannot be used to detect this -- it is t inside
timers as well as sentinels."
  (s3-manager-test--with-clean-profiles
    (let ((observed 'unset) (result 'pending))
      (cl-letf* ((original (symbol-function 's3-manager--profiles-resolved))
                 ((symbol-function 's3-manager--profiles-resolved)
                  (lambda (&rest args)
                    (let ((s3-manager-test--inside-resolver t))
                      (apply original args)))))
        (s3-manager-test--with-fake-aws (:stdout "default\\n")
          (s3-manager--with-profiles
           (lambda (p)
             (setq observed s3-manager-test--inside-resolver
                   result p)))
          (should (s3-manager-test--wait
                   (lambda () (not (eq result 'pending)))))))
      (should (equal result '("default")))
      (should (null observed)))))

(ert-deftest s3-manager-test-cached-profiles-callback-is-synchronous ()
  "The cached path runs in the caller\='s own extent, so the prompt is normal."
  (s3-manager-test--with-clean-profiles
    (setq s3-manager--profiles '("default" "production"))
    (let ((ran nil))
      (s3-manager--with-profiles (lambda (_) (setq ran t)))
      ;; No event loop was pumped: this must already have happened.
      (should ran))))

(ert-deftest s3-manager-test-read-profile-prompts-and-passes-the-choice ()
  (s3-manager-test--with-clean-profiles
    (setq s3-manager--profiles '("default" "production"))
    (let (collection chosen)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt coll &rest _)
                   (setq collection coll)
                   "production")))
        (s3-manager-read-profile (lambda (p) (setq chosen p))))
      (should (equal collection '("default" "production")))
      (should (equal chosen "production")))))

(ert-deftest s3-manager-test-read-profile-with-none-configured ()
  "With no profiles there is nothing to prompt for; say so, do not prompt."
  (s3-manager-test--with-clean-profiles
    (let ((prompted nil) (chosen 'none) (messages nil))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (setq prompted t) ""))
                ((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (s3-manager-test--with-fake-aws (:stdout "")
          (s3-manager-read-profile (lambda (p) (setq chosen p)))
          (s3-manager-test--wait (lambda () messages) 2)))
      (should-not prompted)
      (should (eq chosen 'none))
      (should (seq-find (lambda (m) (string-match-p "aws configure" m))
                        messages)))))

(ert-deftest s3-manager-test-profile-discovery-failure-is-reported ()
  (s3-manager-test--with-clean-profiles
    (when (get-buffer "*S3 Manager Error*") (kill-buffer "*S3 Manager Error*"))
    (let ((called nil))
      (s3-manager-test--with-fake-aws
          (:stderr "Unable to parse config file\\n" :exit 255)
        (s3-manager--with-profiles (lambda (_) (setq called t)))
        (s3-manager-test--wait (lambda () (get-buffer "*S3 Manager Error*")) 2))
      (should-not called)
      (should (get-buffer "*S3 Manager Error*"))
      (with-current-buffer "*S3 Manager Error*"
        (should (string-match-p "list-profiles" (buffer-string))))
      (kill-buffer "*S3 Manager Error*"))))


;;;; Bucket listing and the major mode

;; Built rather than written out, so the tests carry no escaped JSON.
(defconst s3-manager-test--one-bucket-json
  (json-serialize
   '((Buckets . [((Name . "media")
                  (CreationDate . "2026-08-01T00:00:00+00:00"))])))
  "A `list-buckets' response holding a single bucket.")

(defconst s3-manager-test--no-buckets-json
  (json-serialize '((Buckets . [])))
  "A `list-buckets' response for an account with no buckets.")

(defmacro s3-manager-test--in-bucket-buffer (profile &rest body)
  "Run BODY in a fresh bucket-list buffer for PROFILE, then kill it."
  (declare (indent 1))
  `(let ((buffer (s3-manager--bucket-buffer ,profile)))
     (unwind-protect
         (with-current-buffer buffer ,@body)
       (kill-buffer buffer))))

(ert-deftest s3-manager-test-format-date ()
  (should (equal (s3-manager--format-date "2026-08-01T10:22:31+00:00")
                 "2026-08-01"))
  ;; Absent or malformed values must render, not signal.
  (should (equal (s3-manager--format-date nil) "-"))
  (should (equal (s3-manager--format-date "") "-"))
  (should (equal (s3-manager--format-date "2026-08") "-")))

(ert-deftest s3-manager-test-buffer-name ()
  (should (equal (s3-manager--buffer-name "production") "*s3: production*"))
  (should (equal (s3-manager--buffer-name "production" "media")
                 "*s3: production/media*"))
  (should (equal (s3-manager--buffer-name nil) "*s3: default*")))

(ert-deftest s3-manager-test-render-buckets-from-fixture ()
  "The recorded response renders in order, with names as entry ids."
  (with-temp-buffer
    (s3-manager-mode)
    (setq tabulated-list-format s3-manager--bucket-list-format)
    (tabulated-list-init-header)
    (s3-manager--render-buckets (s3-manager-test--json "list-buckets.json"))
    (should (equal (mapcar #'car tabulated-list-entries) '("media" "backups")))
    ;; Created first, Name last: see `s3-manager--bucket-list-format'.
    (should (equal (aref (cadr (assoc "media" tabulated-list-entries)) 0)
                   "2026-08-01"))
    (should (equal (aref (cadr (assoc "media" tabulated-list-entries)) 1)
                   "media"))
    ;; and it actually painted
    (should (string-match-p "media" (buffer-string)))
    (should (string-match-p "backups" (buffer-string)))))

(ert-deftest s3-manager-test-render-buckets-empty ()
  "An account with no buckets renders empty rather than signalling."
  (with-temp-buffer
    (s3-manager-mode)
    (setq tabulated-list-format s3-manager--bucket-list-format)
    (tabulated-list-init-header)
    (s3-manager--render-buckets nil)
    (should (null tabulated-list-entries))
    (should (string-match-p "empty" header-line-format))))

(ert-deftest s3-manager-test-bucket-buffer-end-to-end ()
  "A live-shaped round trip: request, render, header line, status."
  (s3-manager-test--with-fake-aws
      (:stdout s3-manager-test--one-bucket-json)
    (s3-manager-test--in-bucket-buffer "production"
      (should (derived-mode-p 's3-manager-mode))
      (should (equal s3-manager--profile "production"))
      (should (null s3-manager--bucket))
      (should (equal s3-manager--prefix ""))
      ;; The fetch is asynchronous, so it is still loading right now.
      (should (eq s3-manager--status 'loading))
      (should (string-match-p "loading" header-line-format))
      (should (s3-manager-test--wait (lambda () (null s3-manager--status))))
      (should (equal (mapcar #'car tabulated-list-entries) '("media")))
      (should (string-match-p "1 bucket" header-line-format))
      (should (string-match-p "production" header-line-format)))))

(ert-deftest s3-manager-test-bucket-buffer-is-named-per-profile ()
  (s3-manager-test--with-fake-aws (:stdout s3-manager-test--no-buckets-json)
    (s3-manager-test--in-bucket-buffer "staging"
      (should (equal (buffer-name) "*s3: staging*"))
      (should (s3-manager-test--wait (lambda () (null s3-manager--status)))))))

(ert-deftest s3-manager-test-bucket-listing-argv ()
  "The listing must ask for JSON and carry the chosen profile."
  (let ((argv-file (make-temp-file "s3-buckets-argv")))
    (unwind-protect
        (s3-manager-test--with-fake-aws
            (:stdout s3-manager-test--no-buckets-json :argv-file argv-file)
          (s3-manager-test--in-bucket-buffer "production"
            (should (s3-manager-test--wait
                     (lambda () (null s3-manager--status)))))
          (should (equal (with-temp-buffer
                           (insert-file-contents argv-file)
                           (split-string (buffer-string) "\n" t))
                         '("--profile" "production"
                           "--no-cli-pager" "--no-cli-auto-prompt"
                           "s3api" "list-buckets" "--output" "json"))))
      (delete-file argv-file))))

(ert-deftest s3-manager-test-bucket-listing-error-sets-status ()
  "A failure must leave the buffer usable and say so, not throw."
  (when (get-buffer "*S3 Manager Error*") (kill-buffer "*S3 Manager Error*"))
  (s3-manager-test--with-fake-aws
      (:stderr "\\nAn error occurred (AccessDenied) when calling the ListBuckets operation: nope\\n"
       :exit 254)
    (s3-manager-test--in-bucket-buffer "production"
      (should (s3-manager-test--wait (lambda () (eq s3-manager--status 'error))))
      (should (string-match-p "failed" header-line-format))
      (should (get-buffer "*S3 Manager Error*"))
      (with-current-buffer "*S3 Manager Error*"
        (should (string-match-p "AccessDenied" (buffer-string))))))
  (when (get-buffer "*S3 Manager Error*") (kill-buffer "*S3 Manager Error*")))

(ert-deftest s3-manager-test-refresh-refetches ()
  "`g' goes through `revert-buffer' and must issue a new request."
  (let ((calls 0))
    (s3-manager-test--with-fake-aws (:stdout s3-manager-test--no-buckets-json)
      (cl-letf* ((original (symbol-function 's3-manager--aws-async))
                 ((symbol-function 's3-manager--aws-async)
                  (lambda (&rest args) (cl-incf calls) (apply original args))))
        (s3-manager-test--in-bucket-buffer "production"
          (should (s3-manager-test--wait (lambda () (null s3-manager--status))))
          (should (= calls 1))
          ;; `g' is bound by `special-mode' to `revert-buffer', which this
          ;; mode redirects; exercise that path rather than calling reload.
          (revert-buffer)
          (should (s3-manager-test--wait (lambda () (null s3-manager--status))))
          (should (= calls 2)))))))

(ert-deftest s3-manager-test-revert-function-is-replaced ()
  "The parent mode's synchronous revert would never re-fetch."
  (with-temp-buffer
    (s3-manager-mode)
    (should (eq revert-buffer-function #'s3-manager--revert))
    ;; `revert-buffer' supplies three arguments; accepting fewer breaks `g'.
    (should (equal (func-arity #'s3-manager--revert) '(0 . 3)))))

(ert-deftest s3-manager-test-column-titles-are-visible ()
  "The column titles must survive this mode using the header line.

`tabulated-list-init-header' installs them into `header-line-format',
which is where the profile and s3:// path go, so the titles are rendered
into the buffer instead.  Asserting only on `header-line-format' hid
their loss entirely."
  (with-temp-buffer
    (s3-manager-mode)
    (setq tabulated-list-format s3-manager--bucket-list-format)
    (tabulated-list-init-header)
    (s3-manager--render-buckets (s3-manager-test--json "list-buckets.json"))
    (should (null tabulated-list-use-header-line))
    (let ((first-line (car (split-string (buffer-string) "\n"))))
      (should (string-match-p "Name" first-line))
      (should (string-match-p "Created" first-line)))
    ;; and the S3 context still owns the header line
    (should (string-match-p "buckets" header-line-format))))

(ert-deftest s3-manager-test-mode-reserves-a-mark-column ()
  "`tabulated-list-put-tag' silently does nothing when padding is 0."
  (with-temp-buffer
    (s3-manager-mode)
    (should (= tabulated-list-padding 2))))

(ert-deftest s3-manager-test-mode-cancels-on-kill ()
  "Killing a buffer mid-request must not orphan the process.
With :noquery t, Emacs would not even prompt about it at exit."
  (let ((buffer nil) (proc nil))
    (s3-manager-test--with-fake-aws (:stdout s3-manager-test--no-buckets-json :delay "5")
      (setq buffer (s3-manager--bucket-buffer "production"))
      (with-current-buffer buffer (setq proc s3-manager--process))
      (should (process-live-p proc))
      (kill-buffer buffer)
      (should-not (process-live-p proc)))))

(ert-deftest s3-manager-test-stale-listing-is-not-rendered ()
  "A response for a superseded request must not paint over a newer one."
  (s3-manager-test--with-fake-aws (:stdout s3-manager-test--no-buckets-json :delay "0.3")
    (let ((buffer (s3-manager--bucket-buffer "production")))
      (unwind-protect
          (with-current-buffer buffer
            (let ((first-process s3-manager--process))
              ;; Refresh before the first response lands.
              (s3-manager--reload)
              (should-not (eq s3-manager--process first-process))
              (should (s3-manager-test--wait
                       (lambda () (null s3-manager--status))))
              ;; One render, from the surviving request.
              (should (null tabulated-list-entries))))
        (kill-buffer buffer)))))

(ert-deftest s3-manager-test-refresh-outside-an-s3-buffer ()
  (with-temp-buffer
    (should-error (s3-manager-refresh) :type 'user-error)))

(ert-deftest s3-manager-test-entry-point-checks-the-cli ()
  "`s3-manager' must fail cleanly when the CLI is unusable."
  (let ((s3-manager--cli-version nil)
        (s3-manager-aws-program "s3-manager-no-such-program"))
    (should-error (s3-manager) :type 'user-error)))


;;;; Object listing

(ert-deftest s3-manager-test-strip-prefix ()
  (should (equal (s3-manager--strip-prefix "videos/2026/" "videos/") "2026/"))
  (should (equal (s3-manager--strip-prefix "README.md" "") "README.md"))
  (should (equal (s3-manager--strip-prefix "README.md" nil) "README.md"))
  ;; A key that does not start with the prefix is left alone.
  (should (equal (s3-manager--strip-prefix "other/x" "videos/") "other/x")))

(ert-deftest s3-manager-test-parent-prefix ()
  (should (equal (s3-manager--parent-prefix "videos/2026/") "videos/"))
  (should (equal (s3-manager--parent-prefix "videos/") ""))
  (should (equal (s3-manager--parent-prefix "") ""))
  (should (equal (s3-manager--parent-prefix "a/b/c/") "a/b/")))

(ert-deftest s3-manager-test-entries-from-root-listing ()
  "CommonPrefixes become directories, Contents become objects."
  (let ((entries (s3-manager--entries-from-listing
                  (s3-manager-test--json "list-objects-root.json") "")))
    (should (= (length entries) 3))
    (should (equal (mapcar #'s3-manager-entry-display-name entries)
                   '("images/" "videos/" "README.md")))
    (should (equal (mapcar #'s3-manager-entry-type entries)
                   '(directory directory object)))
    (let ((readme (nth 2 entries)))
      (should (equal (s3-manager-entry-key readme) "README.md"))
      (should (= (s3-manager-entry-size readme) 1234))
      (should (equal (s3-manager-entry-storage-class readme) "STANDARD")))))

(ert-deftest s3-manager-test-entries-strip-the-parent-prefix ()
  (let ((entries (s3-manager--entries-from-listing
                  (s3-manager-test--json "list-objects-nested.json") "videos/")))
    (should (member "2026/" (mapcar #'s3-manager-entry-display-name entries)))
    (should (member "old.mp4" (mapcar #'s3-manager-entry-display-name entries)))
    ;; Keys stay absolute even though the displayed names are relative.
    (should (member "videos/old.mp4" (mapcar #'s3-manager-entry-key entries)))))

(ert-deftest s3-manager-test-directory-marker-is-dropped ()
  "A zero-byte object whose key IS the prefix must not become a row.

The S3 console and several compatible servers create these; left in,
every directory shows a phantom blank-named file inside itself."
  (let* ((entries (s3-manager--entries-from-listing
                   (s3-manager-test--json "list-objects-nested.json") "videos/"))
         (names (mapcar #'s3-manager-entry-display-name entries)))
    (should-not (member "" names))
    (should-not (member "videos/" (mapcar #'s3-manager-entry-key
                                          (seq-filter
                                           (lambda (e)
                                             (eq (s3-manager-entry-type e)
                                                 'object))
                                           entries))))
    (should (= (length entries) 2))))

(ert-deftest s3-manager-test-entries-from-empty-listing ()
  "Contents and CommonPrefixes are absent, not empty, when nothing matches."
  (let ((response (s3-manager-test--json "list-objects-empty.json")))
    (should (null (alist-get 'Contents response)))
    (should (null (alist-get 'CommonPrefixes response)))
    (should (null (s3-manager--entries-from-listing response "zzz/")))))

(ert-deftest s3-manager-test-format-size ()
  (should (equal (s3-manager--format-size 0) "0 B"))
  (should (equal (s3-manager--format-size 1234) "1.2 KiB"))
  (should (equal (s3-manager--format-size 1932735283) "1.8 GiB"))
  ;; Directories carry no size.
  (should (equal (s3-manager--format-size nil) "-")))

(ert-deftest s3-manager-test-name-is-the-last-column ()
  "The variable-width column must come last in both layouts.

`tabulated-list' does not truncate, so a value wider than its column
pushes every column after it out of alignment.  Names are the only
unbounded field -- S3 keys are long and bucket names run to 63
characters -- so with them last an overlong one can only run off the
right-hand end."
  (dolist (format (list s3-manager--object-list-format
                        s3-manager--bucket-list-format))
    (let ((titles (mapcar #'car (append format nil))))
      (should (equal (car (last titles)) "Name"))
      ;; Every column before it is a fixed-width field.
      (should-not (member "Name" (butlast titles)))))
  ;; And the rows agree with the headers.
  (let ((row (s3-manager--entry-row
              (s3-manager-entry--create :type 'object :key "a/long-name.bin"
                                        :display-name "long-name.bin"
                                        :size 2048
                                        :last-modified "2026-09-01T00:00:00+00:00"))))
    (should (equal (aref (cadr row) 0) "2 KiB"))
    (should (equal (aref (cadr row) 1) "2026-09-01"))
    (should (equal (aref (cadr row) 2) "long-name.bin"))))

(ert-deftest s3-manager-test-a-long-name-cannot-misalign-a-row ()
  "A name far wider than its column leaves the other fields in place."
  (with-temp-buffer
    (s3-manager-mode)
    (setq s3-manager--bucket "media" s3-manager--prefix "")
    (setq tabulated-list-format s3-manager--object-list-format)
    (tabulated-list-init-header)
    (setq tabulated-list-entries
          (mapcar #'s3-manager--entry-row
                  (list (s3-manager-entry--create
                         :type 'object :key "short.txt" :display-name "short.txt"
                         :size 10 :last-modified "2026-09-01T00:00:00+00:00")
                        (s3-manager-entry--create
                         :type 'object
                         :key (concat (make-string 120 ?x) ".bin")
                         :display-name (concat (make-string 120 ?x) ".bin")
                         :size 20 :last-modified "2026-09-02T00:00:00+00:00"))))
    (tabulated-list-print)
    ;; Both dates start at the same column, whatever the name lengths.
    (goto-char (point-min))
    (let (date-columns)
      (while (not (eobp))
        (when (tabulated-list-get-id)
          (let ((line (buffer-substring (line-beginning-position)
                                        (line-end-position))))
            (push (string-match "2026-09-0" line) date-columns)))
        (forward-line 1))
      (should (= 2 (length date-columns)))
      (should (apply #'= date-columns)))))

(ert-deftest s3-manager-test-sorters-put-directories-first ()
  "Directories lead under every column, as in Dired."
  (let* ((entries (s3-manager--entries-from-listing
                   (s3-manager-test--json "list-objects-root.json") ""))
         (rows (mapcar #'s3-manager--entry-row entries)))
    (dolist (sorter (list #'s3-manager--sort-by-name
                          #'s3-manager--sort-by-size
                          #'s3-manager--sort-by-time))
      (let ((sorted (sort (copy-sequence rows) sorter)))
        (should (equal (mapcar (lambda (row)
                                 (s3-manager-entry-type (car row)))
                               sorted)
                       '(directory directory object)))))))

(ert-deftest s3-manager-test-size-sorts-numerically ()
  "The displayed size is a string in which \"9 B\" follows \"1.8 GiB\"."
  (let* ((small (s3-manager-entry--create :type 'object :key "a" :size 9))
         (large (s3-manager-entry--create :type 'object :key "b"
                                          :size 1932735283))
         (rows (list (s3-manager--entry-row large)
                     (s3-manager--entry-row small))))
    (should (equal (mapcar (lambda (row) (s3-manager-entry-size (car row)))
                           (sort rows #'s3-manager--sort-by-size))
                   '(9 1932735283)))
    ;; The lexicographic order the default sorter would have produced.
    (should (string< "1.8 GiB" "9 B"))))

(ert-deftest s3-manager-test-directory-entries-are-structurally-equal ()
  "Point restoration on `^' depends on a synthesized entry matching.

The entry is rebuilt rather than remembered when there is no history, so
it must compare `equal' to the row parsed from the listing.  Adding a
slot that a real entry fills and a synthetic one does not would break
this silently."
  (let* ((parsed (car (s3-manager--entries-from-listing
                       (s3-manager-test--json "list-objects-nested.json")
                       "videos/")))
         (synthetic (s3-manager--directory-entry "videos/2026/" "videos/")))
    (should (equal (s3-manager-entry-key parsed) "videos/2026/"))
    (should (equal parsed synthetic))
    (should-not (eq parsed synthetic))))

(ert-deftest s3-manager-test-list-objects-argv ()
  "The prefix is omitted at the root, and both paging flags are equal."
  (with-temp-buffer
    (s3-manager-mode)
    (setq s3-manager--bucket "media"
          s3-manager--prefix ""
          s3-manager-page-size 1000)
    (should (equal (s3-manager--list-objects-args)
                   '("s3api" "list-objects-v2" "--bucket" "media"
                     "--delimiter" "/"
                     "--no-paginate" "--max-keys" "1000"
                     "--output" "json")))
    (setq s3-manager--prefix "videos/2026/")
    (should (equal (s3-manager--list-objects-args)
                   '("s3api" "list-objects-v2" "--bucket" "media"
                     "--prefix" "videos/2026/"
                     "--delimiter" "/"
                     "--no-paginate" "--max-keys" "1000"
                     "--output" "json")))))

(ert-deftest s3-manager-test-listing-never-uses-max-items ()
  "`--max-items' drops CommonPrefixes from a truncated listing.

It counts only the primary result key, so a listing cut by it reports
zero prefixes and resuming never recovers them: every directory
disappears.  The raw API is used instead, where MaxKeys covers objects
and prefixes together."
  (with-temp-buffer
    (s3-manager-mode)
    (setq s3-manager--bucket "media"
          s3-manager--prefix ""
          s3-manager-page-size 250)
    (let ((args (s3-manager--list-objects-args "TOK")))
      (should-not (member "--max-items" args))
      (should-not (member "--page-size" args))
      (should-not (member "--starting-token" args))
      (should (member "--no-paginate" args))
      (should (equal (cadr (member "--max-keys" args)) "250"))
      (should (equal (cadr (member "--continuation-token" args)) "TOK")))))

(ert-deftest s3-manager-test-truncated-listing-is-flagged ()
  (with-temp-buffer
    (s3-manager-mode)
    (setq s3-manager--bucket "media" s3-manager--prefix "")
    (setq tabulated-list-format s3-manager--object-list-format)
    (tabulated-list-init-header)
    (s3-manager--render-objects
     (s3-manager-test--json "list-objects-truncated.json"))
    (should s3-manager--next-token)
    (should (string-match-p "for more" header-line-format))))


;;;; Navigation

(ert-deftest s3-manager-test-descend-and-ascend ()
  "RET into a prefix and `^' back out, with point restored."
  (s3-manager-test--with-fake-aws
      (:stdout (s3-manager-test--fixture "list-objects-root.json"))
    (let ((buffer (s3-manager--object-buffer "production" "media" "")))
      (unwind-protect
          (with-current-buffer buffer
            (should (s3-manager-test--wait (lambda () (null s3-manager--status))))
            (should (equal (buffer-name) "*s3: production/media*"))
            (should (equal s3-manager--prefix ""))
            ;; Move to the "videos/" row and enter it.
            (s3-manager--goto-entry
             (s3-manager--directory-entry "videos/" ""))
            (should (equal (s3-manager-entry-key (tabulated-list-get-id))
                           "videos/"))
            (s3-manager-open)
            (should (equal s3-manager--prefix "videos/"))
            (should (equal (caar s3-manager--history) ""))
            (should (s3-manager-test--wait (lambda () (null s3-manager--status))))
            ;; And back up, landing on the row we came from.
            (s3-manager-up)
            (should (equal s3-manager--prefix ""))
            (should (null s3-manager--history))
            (should (s3-manager-test--wait (lambda () (null s3-manager--status))))
            (should (equal (s3-manager-entry-key (tabulated-list-get-id))
                           "videos/")))
        (kill-buffer buffer)))))

(ert-deftest s3-manager-test-ascend-without-history ()
  "Arriving somewhere without descending still restores point.
The entry to land on is synthesized, which only works because struct
equality is structural."
  (s3-manager-test--with-fake-aws
      (:stdout (s3-manager-test--fixture "list-objects-root.json"))
    (let ((buffer (s3-manager--object-buffer "production" "media" "videos/")))
      (unwind-protect
          (with-current-buffer buffer
            (should (s3-manager-test--wait (lambda () (null s3-manager--status))))
            (should (null s3-manager--history))
            (s3-manager-up)
            (should (equal s3-manager--prefix ""))
            (should (s3-manager-test--wait (lambda () (null s3-manager--status))))
            (should (equal (s3-manager-entry-key (tabulated-list-get-id))
                           "videos/")))
        (kill-buffer buffer)))))

(ert-deftest s3-manager-test-up-from-root-returns-to-buckets ()
  (s3-manager-test--with-fake-aws (:stdout s3-manager-test--one-bucket-json)
    (let ((objects (s3-manager--object-buffer "production" "media" "")))
      (unwind-protect
          (with-current-buffer objects
            (should (s3-manager-test--wait (lambda () (null s3-manager--status))))
            (s3-manager-up)
            (let ((buckets (get-buffer "*s3: production*")))
              (should buckets)
              (with-current-buffer buckets
                (should (null s3-manager--bucket))
                (should (s3-manager-test--wait
                         (lambda () (null s3-manager--status))))
                ;; Point lands on the bucket just left, when it is listed.
                (should (equal (tabulated-list-get-id) "media")))
              (kill-buffer buckets)))
        (kill-buffer objects)))))

(ert-deftest s3-manager-test-up-from-the-bucket-list-refuses ()
  (with-temp-buffer
    (s3-manager-mode)
    (setq s3-manager--bucket nil)
    (should-error (s3-manager-up) :type 'user-error)))

(ert-deftest s3-manager-test-open-a-bucket ()
  "RET in the bucket list opens that bucket's object buffer."
  (s3-manager-test--with-fake-aws
      (:stdout (s3-manager-test--fixture "list-objects-root.json"))
    (let ((buckets (get-buffer-create "*s3: production*")))
      (unwind-protect
          (with-current-buffer buckets
            (s3-manager-mode)
            (setq s3-manager--profile "production" s3-manager--bucket nil)
            (setq tabulated-list-format s3-manager--bucket-list-format)
            (tabulated-list-init-header)
            (s3-manager--render-buckets
             (s3-manager-test--json "list-buckets.json"))
            (goto-char (point-min))
            (s3-manager--goto-entry "media")
            (s3-manager-open)
            (let ((objects (get-buffer "*s3: production/media*")))
              (should objects)
              (with-current-buffer objects
                (should (equal s3-manager--bucket "media"))
                (should (equal s3-manager--prefix ""))
                (should (s3-manager-test--wait
                         (lambda () (null s3-manager--status)))))
              (kill-buffer objects)))
        (kill-buffer buckets)))))

(ert-deftest s3-manager-test-entry-at-point-refuses-empty-rows ()
  (with-temp-buffer
    (s3-manager-mode)
    (setq tabulated-list-format s3-manager--object-list-format)
    (tabulated-list-init-header)
    (setq tabulated-list-entries nil)
    (tabulated-list-print)
    (should-error (s3-manager--entry-at-point) :type 'user-error)))

(ert-deftest s3-manager-test-object-buffer-is-reused-across-prefixes ()
  "One buffer per bucket, not one per prefix."
  (s3-manager-test--with-fake-aws
      (:stdout (s3-manager-test--fixture "list-objects-root.json"))
    (let ((buffer (s3-manager--object-buffer "production" "media" "")))
      (unwind-protect
          (with-current-buffer buffer
            (should (s3-manager-test--wait (lambda () (null s3-manager--status))))
            (s3-manager--goto-entry (s3-manager--directory-entry "videos/" ""))
            (s3-manager-open)
            (should (s3-manager-test--wait (lambda () (null s3-manager--status))))
            (should (eq (current-buffer) buffer))
            (should (= 1 (length (seq-filter
                                  (lambda (b)
                                    (string-prefix-p "*s3: production/"
                                                     (buffer-name b)))
                                  (buffer-list))))))
        (kill-buffer buffer)))))


(ert-deftest s3-manager-test-open-reuses-the-window ()
  "Entering a bucket must reuse the window, as `dired-find-file' does.
`pop-to-buffer' splits a single-window frame, which is how this first
shipped: the bucket list stayed on screen beside the bucket just entered,
and no Emacs file browser behaves that way."
  (s3-manager-test--with-fake-aws
      (:stdout s3-manager-test--one-bucket-json)
    (let ((bucket-buf (s3-manager--bucket-buffer "production"))
          (object-buf nil))
      (unwind-protect
          (progn
            (with-current-buffer bucket-buf
              (should (s3-manager-test--wait
                       (lambda ()
                         (and (null s3-manager--status)
                              tabulated-list-entries)))))
            (delete-other-windows)
            (switch-to-buffer bucket-buf)
            (should (= 1 (length (window-list))))
            (with-current-buffer bucket-buf
              (goto-char (point-min))
              ;; Row one is the column-title line: this mode renders it in
              ;; the buffer rather than the header line.
              (forward-line 1)
              (should (equal (tabulated-list-get-id) "media"))
              (s3-manager-open))
            (setq object-buf (get-buffer "*s3: production/media*"))
            (should (bufferp object-buf))
            (should (= 1 (length (window-list))))
            (should (eq (window-buffer (selected-window)) object-buf)))
        (when (buffer-live-p bucket-buf) (kill-buffer bucket-buf))
        (when (and object-buf (buffer-live-p object-buf))
          (kill-buffer object-buf))))))


;;;; Cache

(defmacro s3-manager-test--with-clean-cache (&rest body)
  "Run BODY against an empty listing cache."
  (declare (indent 0))
  `(let ((s3-manager--cache (make-hash-table :test #'equal))
         (s3-manager-cache-max-entries 200))
     ,@body))

(ert-deftest s3-manager-test-cache-key-includes-the-endpoint ()
  "The same bucket name on two endpoints is two different buckets."
  (with-temp-buffer
    (s3-manager-mode)
    (setq s3-manager--profile "p" s3-manager--bucket "media"
          s3-manager--prefix "x/")
    (let ((aws (let ((s3-manager-endpoint-url nil)
                     (s3-manager-endpoint-alist nil))
                 (s3-manager--cache-key)))
          (minio (let ((s3-manager-endpoint-url "https://minio.example.com")
                       (s3-manager-endpoint-alist nil))
                   (s3-manager--cache-key))))
      (should-not (equal aws minio))
      (should (equal aws '("p" nil "media" "x/"))))))

(ert-deftest s3-manager-test-cache-roundtrip-and-invalidate ()
  (s3-manager-test--with-clean-cache
    (let ((key '("p" nil "media" "")))
      (should (null (s3-manager--cache-get key)))
      (s3-manager--cache-put key '(row) '(entry) "tok")
      (let ((page (s3-manager--cache-get key)))
        (should (equal (s3-manager-page-rows page) '(row)))
        (should (equal (s3-manager-page-entries page) '(entry)))
        (should (equal (s3-manager-page-next-token page) "tok")))
      (s3-manager--cache-invalidate key)
      (should (null (s3-manager--cache-get key))))))

(ert-deftest s3-manager-test-cache-purge-whole-bucket ()
  (s3-manager-test--with-clean-cache
    (dolist (prefix '("" "a/" "a/b/" "c/"))
      (s3-manager--cache-put (list "p" nil "media" prefix) nil nil nil))
    (s3-manager--cache-put '("p" nil "other" "") nil nil nil)
    (s3-manager--cache-put '("q" nil "media" "") nil nil nil)
    (should (= 4 (s3-manager--cache-purge "p" nil "media")))
    ;; Other buckets and other profiles are untouched.
    (should (s3-manager--cache-get '("p" nil "other" "")))
    (should (s3-manager--cache-get '("q" nil "media" "")))))

(ert-deftest s3-manager-test-cache-purge-under-a-prefix ()
  "A recursive change invalidates a prefix and everything beneath it."
  (s3-manager-test--with-clean-cache
    (dolist (prefix '("" "a/" "a/b/" "a/b/c/" "ab/" "z/"))
      (s3-manager--cache-put (list "p" nil "media" prefix) nil nil nil))
    (should (= 3 (s3-manager--cache-purge "p" nil "media" "a/")))
    (should (null (s3-manager--cache-get '("p" nil "media" "a/"))))
    (should (null (s3-manager--cache-get '("p" nil "media" "a/b/c/"))))
    ;; "ab/" merely starts with "a", it is not under "a/".
    (should (s3-manager--cache-get '("p" nil "media" "ab/")))
    (should (s3-manager--cache-get '("p" nil "media" "")))
    (should (s3-manager--cache-get '("p" nil "media" "z/")))))

(ert-deftest s3-manager-test-cache-is-capped ()
  "A deep walk must not retain listings without bound."
  (let ((s3-manager--cache (make-hash-table :test #'equal))
        (s3-manager-cache-max-entries 3))
    (dotimes (i 10)
      (s3-manager--cache-put (list "p" nil "media" (format "%d/" i))
                             nil nil nil))
    (should (<= (hash-table-count s3-manager--cache) 3))
    ;; The most recent survive; the earliest are gone.
    (should (s3-manager--cache-get '("p" nil "media" "9/")))
    (should (null (s3-manager--cache-get '("p" nil "media" "0/"))))))

(ert-deftest s3-manager-test-clear-cache-command ()
  (s3-manager-test--with-clean-cache
    (s3-manager--cache-put '("p" nil "media" "") nil nil nil)
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (s3-manager-clear-cache))
      (should (zerop (hash-table-count s3-manager--cache))))))

(ert-deftest s3-manager-test-navigation-uses-the-cache ()
  "Descending and coming back must not re-issue a request."
  (s3-manager-test--with-clean-cache
    (let ((calls 0))
      (s3-manager-test--with-fake-aws
          (:stdout (s3-manager-test--fixture "list-objects-root.json"))
        (cl-letf* ((original (symbol-function 's3-manager--aws-async))
                   ((symbol-function 's3-manager--aws-async)
                    (lambda (&rest args) (cl-incf calls) (apply original args))))
          (let ((buffer (s3-manager--object-buffer "production" "media" "")))
            (unwind-protect
                (with-current-buffer buffer
                  (should (s3-manager-test--wait
                           (lambda () (null s3-manager--status))))
                  (should (= calls 1))
                  (s3-manager--goto-entry
                   (s3-manager--directory-entry "videos/" ""))
                  (s3-manager-open)
                  (should (s3-manager-test--wait
                           (lambda () (null s3-manager--status))))
                  (should (= calls 2))
                  ;; Back to a prefix already seen: served from cache, and
                  ;; synchronously, so no event loop is pumped at all.
                  (s3-manager-up)
                  (should (null s3-manager--status))
                  (should (= calls 2))
                  (should (equal s3-manager--prefix ""))
                  (should (equal (s3-manager-entry-key (tabulated-list-get-id))
                                 "videos/")))
              (kill-buffer buffer))))))))

(ert-deftest s3-manager-test-refresh-bypasses-the-cache ()
  "`g' means the cached copy is not to be trusted."
  (s3-manager-test--with-clean-cache
    (let ((calls 0))
      (s3-manager-test--with-fake-aws
          (:stdout (s3-manager-test--fixture "list-objects-root.json"))
        (cl-letf* ((original (symbol-function 's3-manager--aws-async))
                   ((symbol-function 's3-manager--aws-async)
                    (lambda (&rest args) (cl-incf calls) (apply original args))))
          (let ((buffer (s3-manager--object-buffer "production" "media" "")))
            (unwind-protect
                (with-current-buffer buffer
                  (should (s3-manager-test--wait
                           (lambda () (null s3-manager--status))))
                  (should (= calls 1))
                  (s3-manager-refresh)
                  (should (s3-manager-test--wait
                           (lambda () (null s3-manager--status))))
                  (should (= calls 2)))
              (kill-buffer buffer))))))))

(ert-deftest s3-manager-test-refresh-with-prefix-arg-purges-the-bucket ()
  (s3-manager-test--with-clean-cache
    (with-temp-buffer
      (s3-manager-mode)
      (setq s3-manager--profile "p" s3-manager--bucket "media"
            s3-manager--prefix "a/")
      (dolist (prefix '("" "a/" "b/"))
        (s3-manager--cache-put (list "p" nil "media" prefix) nil nil nil))
      (cl-letf (((symbol-function 's3-manager--reload) #'ignore)
                ((symbol-function 'message) #'ignore))
        ;; Without the argument only this prefix goes.
        (s3-manager-refresh)
        (should (= 2 (hash-table-count s3-manager--cache)))
        ;; With it, the whole bucket does.
        (s3-manager-refresh t)
        (should (zerop (hash-table-count s3-manager--cache)))))))


;;;; Pagination

(ert-deftest s3-manager-test-continuation-token-argv ()
  (with-temp-buffer
    (s3-manager-mode)
    (setq s3-manager--bucket "media" s3-manager--prefix ""
          s3-manager-page-size 1000)
    (let ((args (s3-manager--list-objects-args "TOKEN123")))
      (should (equal (cadr (member "--continuation-token" args)) "TOKEN123"))
      (should (equal (cadr (member "--max-keys" args)) "1000")))
    ;; Absent when there is nothing to resume from.
    (should-not (member "--continuation-token"
                        (s3-manager--list-objects-args)))))

(ert-deftest s3-manager-test-render-truncated-caches-the-token ()
  "A partly-loaded prefix resumes rather than restarting."
  (s3-manager-test--with-clean-cache
    (with-temp-buffer
      (s3-manager-mode)
      (setq s3-manager--profile "p" s3-manager--bucket "media"
            s3-manager--prefix "")
      (setq tabulated-list-format s3-manager--object-list-format)
      (tabulated-list-init-header)
      (s3-manager--render-objects
       (s3-manager-test--json "list-objects-truncated.json"))
      (let ((page (s3-manager--cache-get (s3-manager--cache-key))))
        (should page)
        (should (equal (s3-manager-page-next-token page)
                       s3-manager--next-token))
        (should (s3-manager-page-next-token page))
        (should (= 1 (length (s3-manager-page-entries page))))
        ;; Reinstalling the cached page restores the token, so `+' still
        ;; knows where to resume from.
        (setq s3-manager--next-token nil s3-manager--entries nil)
        (s3-manager--install-page page)
        (should s3-manager--next-token)
        (should (= 1 (length s3-manager--entries)))))))

(ert-deftest s3-manager-test-load-more-appends ()
  "The second page extends the listing instead of replacing it."
  (s3-manager-test--with-clean-cache
    (with-temp-buffer
      (s3-manager-mode)
      (setq s3-manager--profile "p" s3-manager--bucket "media"
            s3-manager--prefix "")
      (setq tabulated-list-format s3-manager--object-list-format)
      (tabulated-list-init-header)
      ;; First page, truncated.
      (s3-manager--render-objects
       (s3-manager-test--json "list-objects-truncated.json"))
      (should (= 1 (length s3-manager--entries)))
      (should s3-manager--next-token)
      ;; Second page, complete.
      (s3-manager--render-objects
       (s3-manager-test--json "list-objects-root.json") t)
      (should (= 4 (length s3-manager--entries)))
      (should (null s3-manager--next-token))
      (should (equal (mapcar #'s3-manager-entry-key s3-manager--entries)
                     '("a.txt" "images/" "videos/" "README.md")))
      ;; The header no longer offers more.
      (should-not (string-match-p "for more" header-line-format)))))

(ert-deftest s3-manager-test-load-more-sends-the-token ()
  (s3-manager-test--with-clean-cache
    (let ((argv-file (make-temp-file "s3-more-argv")))
      (unwind-protect
          (with-temp-buffer
            (s3-manager-mode)
            (setq s3-manager--profile "p" s3-manager--bucket "media"
                  s3-manager--prefix "")
            (setq tabulated-list-format s3-manager--object-list-format)
            (tabulated-list-init-header)
            (s3-manager--render-objects
             (s3-manager-test--json "list-objects-truncated.json"))
            (let ((token s3-manager--next-token))
              (s3-manager-test--with-fake-aws
                  (:stdout (s3-manager-test--fixture "list-objects-root.json")
                   :argv-file argv-file)
                (s3-manager-load-more)
                (should (s3-manager-test--wait
                         (lambda () (null s3-manager--status)))))
              (let ((argv (car (s3-manager-test--argv-records argv-file))))
                (should (equal (cadr (member "--continuation-token" argv))
                               token))))
            ;; And it appended.
            (should (= 4 (length s3-manager--entries))))
        (delete-file argv-file)))))

(ert-deftest s3-manager-test-load-more-refuses-when-complete ()
  (with-temp-buffer
    (s3-manager-mode)
    (setq s3-manager--bucket "media" s3-manager--next-token nil)
    (should-error (s3-manager-load-more) :type 'user-error)))

(ert-deftest s3-manager-test-load-more-refuses-in-the-bucket-list ()
  (with-temp-buffer
    (s3-manager-mode)
    (setq s3-manager--bucket nil s3-manager--next-token "tok")
    (should-error (s3-manager-load-more) :type 'user-error)))

(ert-deftest s3-manager-test-load-more-is-bound ()
  (should (eq (keymap-lookup s3-manager-mode-map "+") #'s3-manager-load-more))
  (should (eq (keymap-lookup s3-manager-mode-map "g") #'s3-manager-refresh)))


;;;; Transfers

(defmacro s3-manager-test--in-object-buffer (&rest body)
  "Run BODY in a buffer showing a rendered object listing."
  (declare (indent 0))
  `(with-temp-buffer
     (s3-manager-mode)
     (setq s3-manager--profile "production"
           s3-manager--bucket "media"
           s3-manager--prefix "")
     (setq tabulated-list-format s3-manager--object-list-format)
     (tabulated-list-init-header)
     (let ((s3-manager--cache (make-hash-table :test #'equal)))
       (s3-manager--render-objects
        (s3-manager-test--json "list-objects-root.json")))
     ,@body))

(defun s3-manager-test--goto-object ()
  "Put point on the first object row."
  (s3-manager--goto-entry
   (car (seq-filter (lambda (e) (eq (s3-manager-entry-type e) 'object))
                    s3-manager--entries))))

(defun s3-manager-test--goto-directory ()
  "Put point on the first directory row."
  (s3-manager--goto-entry
   (car (seq-filter (lambda (e) (eq (s3-manager-entry-type e) 'directory))
                    s3-manager--entries))))

(ert-deftest s3-manager-test-format-progress ()
  (should (equal (s3-manager--format-progress
                  "Completed 70.5 KiB/70.5 KiB (558.5 KiB/s) with 1 file(s) remaining")
                 "70.5 KiB/70.5 KiB 558.5 KiB/s"))
  ;; Anything unrecognised is truncated rather than dropped.
  (let ((formatted (s3-manager--format-progress (make-string 200 ?x))))
    (should (<= (length formatted) 40))))

(ert-deftest s3-manager-test-s3-uri ()
  (with-temp-buffer
    (s3-manager-mode)
    (setq s3-manager--bucket "media")
    (should (equal (s3-manager--s3-uri "videos/a.mp4") "s3://media/videos/a.mp4"))
    (should (equal (s3-manager--s3-uri "videos/") "s3://media/videos/"))))

(ert-deftest s3-manager-test-get-argv ()
  "Downloading uses `s3 cp', which does multipart and reports progress."
  (let ((argv-file (make-temp-file "s3-get-argv"))
        (destination (expand-file-name "README.md" (make-temp-file "s3dl" t))))
    (unwind-protect
        (s3-manager-test--in-object-buffer
          (s3-manager-test--goto-object)
          (cl-letf (((symbol-function 'read-file-name)
                     (lambda (&rest _) destination)))
            (s3-manager-test--with-fake-aws (:stdout "" :argv-file argv-file)
              (s3-manager-get)
              (should (s3-manager-test--wait
                       (lambda () (zerop s3-manager--transfers))))))
          (let ((argv (with-temp-buffer
                        (insert-file-contents argv-file)
                        (split-string (buffer-string) "\n" t))))
            (should (equal argv
                           (list "--profile" "production"
                                 "--no-cli-pager" "--no-cli-auto-prompt"
                                 "s3" "cp" "s3://media/README.md" destination
                                 "--progress-frequency" "1")))
            ;; Both of these suppress the progress output the mode line needs.
            (should-not (member "--quiet" argv))
            (should-not (member "--only-show-errors" argv))))
      (delete-file argv-file))))

(ert-deftest s3-manager-test-get-recursive-argv ()
  (let ((argv-file (make-temp-file "s3-getr-argv"))
        (destination (file-name-as-directory (make-temp-file "s3dlr" t))))
    (unwind-protect
        (s3-manager-test--in-object-buffer
          (s3-manager-test--goto-directory)
          (cl-letf (((symbol-function 'read-directory-name)
                     (lambda (&rest _) destination)))
            (s3-manager-test--with-fake-aws (:stdout "" :argv-file argv-file)
              (s3-manager-get-recursive)
              (should (s3-manager-test--wait
                       (lambda () (zerop s3-manager--transfers))))))
          (let ((argv (with-temp-buffer
                        (insert-file-contents argv-file)
                        (split-string (buffer-string) "\n" t))))
            (should (equal argv
                           (list "--profile" "production"
                                 "--no-cli-pager" "--no-cli-auto-prompt"
                                 "s3" "cp" "s3://media/images/" destination
                                 "--recursive" "--progress-frequency" "1")))))
      (delete-file argv-file))))

(ert-deftest s3-manager-test-get-refuses-a-prefix ()
  (s3-manager-test--in-object-buffer
    (s3-manager-test--goto-directory)
    (should-error (s3-manager-get) :type 'user-error)))

(ert-deftest s3-manager-test-get-recursive-refuses-an-object ()
  (s3-manager-test--in-object-buffer
    (s3-manager-test--goto-object)
    (should-error (s3-manager-get-recursive) :type 'user-error)))

(ert-deftest s3-manager-test-get-refuses-in-the-bucket-list ()
  (with-temp-buffer
    (s3-manager-mode)
    (setq s3-manager--bucket nil)
    (should-error (s3-manager-get) :type 'user-error)
    (should-error (s3-manager-get-recursive) :type 'user-error)))

(ert-deftest s3-manager-test-get-confirms-before-overwriting ()
  "`aws s3 cp' overwrites silently, so this is the only chance to ask."
  (let ((destination (make-temp-file "s3-existing")))
    (unwind-protect
        (s3-manager-test--in-object-buffer
          (s3-manager-test--goto-object)
          (cl-letf (((symbol-function 'read-file-name)
                     (lambda (&rest _) destination))
                    ((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
            (should-error (s3-manager-get) :type 'user-error))
          ;; Nothing was started.
          (should (zerop s3-manager--transfers)))
      (delete-file destination))))

(ert-deftest s3-manager-test-get-into-a-directory-uses-the-object-name ()
  (let ((directory (file-name-as-directory (make-temp-file "s3dldir" t)))
        (argv-file (make-temp-file "s3-getdir-argv")))
    (unwind-protect
        (s3-manager-test--in-object-buffer
          (s3-manager-test--goto-object)
          (cl-letf (((symbol-function 'read-file-name)
                     (lambda (&rest _) directory)))
            (s3-manager-test--with-fake-aws (:stdout "" :argv-file argv-file)
              (s3-manager-get)
              (should (s3-manager-test--wait
                       (lambda () (zerop s3-manager--transfers))))))
          (let ((argv (with-temp-buffer
                        (insert-file-contents argv-file)
                        (split-string (buffer-string) "\n" t))))
            (should (member (expand-file-name "README.md" directory) argv))))
      (delete-file argv-file))))

(ert-deftest s3-manager-test-transfer-is-not-cancellable-by-navigation ()
  "Pressing `^' must not abort a multi-gigabyte download.

A transfer is deliberately not registered in `s3-manager--process', so
`s3-manager--cancel' -- which every navigation runs -- cannot reach it."
  (let ((destination (expand-file-name "x" (make-temp-file "s3dl" t))))
    (s3-manager-test--in-object-buffer
      (s3-manager-test--goto-object)
      (cl-letf (((symbol-function 'read-file-name)
                 (lambda (&rest _) destination)))
        (s3-manager-test--with-fake-aws (:stdout "" :delay "1")
          (s3-manager-get)
          (should (= 1 s3-manager--transfers))
          ;; The slot the canceller consults stays empty.
          (should (null s3-manager--process))
          (s3-manager--cancel)
          (should (s3-manager-test--wait
                   (lambda () (zerop s3-manager--transfers))))
          ;; It ran to completion despite the cancel.
          (should (null s3-manager--transfer-status)))))))

(ert-deftest s3-manager-test-transfer-outlives-the-listing-timeout ()
  "A transfer must not be killed for being large.

`s3-manager-timeout' arms a timer for a total duration, not for a period
of silence, so before `s3-manager-transfer-timeout' existed any transfer
running longer than it was deleted mid-flight and reported as
`s3-manager-timeout-error' -- while the CLI was alive and still writing
progress.  Here the listing timeout is one second and the transfer takes
three."
  (let ((destination (expand-file-name "x" (make-temp-file "s3dl" t)))
        (reported nil))
    (s3-manager-test--in-object-buffer
      (s3-manager-test--goto-object)
      (cl-letf (((symbol-function 'read-file-name)
                 (lambda (&rest _) destination))
                ((symbol-function 's3-manager--report-error)
                 (lambda (err &rest _) (push (car err) reported))))
        (s3-manager-test--with-fake-aws (:stdout "" :delay "3")
          (let ((s3-manager-timeout 1)
                (s3-manager-transfer-timeout nil))
            (s3-manager-get)
            (should (s3-manager-test--wait
                     (lambda () (zerop s3-manager--transfers))
                     10)))))
      (should (null reported))
      (should (null s3-manager--transfer-status)))))

(ert-deftest s3-manager-test-transfer-timeout-is-honoured-when-set ()
  "Setting `s3-manager-transfer-timeout' must still bound a transfer.
The default is nil, but nil must be a choice rather than the only
behaviour -- otherwise the fix above is indistinguishable from deleting
the timeout code."
  (let ((destination (expand-file-name "x" (make-temp-file "s3dl" t)))
        (reported nil))
    (s3-manager-test--in-object-buffer
      (s3-manager-test--goto-object)
      (cl-letf (((symbol-function 'read-file-name)
                 (lambda (&rest _) destination))
                ((symbol-function 's3-manager--report-error)
                 (lambda (err &rest _) (push (car err) reported))))
        (s3-manager-test--with-fake-aws (:stdout "" :delay "3")
          (let ((s3-manager-transfer-timeout 1))
            (s3-manager-get)
            (should (s3-manager-test--wait
                     (lambda () reported) 10)))))
      (should (equal reported '(s3-manager-timeout-error))))))

(ert-deftest s3-manager-test-listings-still-time-out ()
  "The transfer fix must not disable the timeout everywhere.
A listing that never answers is stuck, and `s3-manager-timeout' is what
releases it."
  (let ((reported nil))
    (s3-manager-test--with-fake-aws (:stdout "" :delay "3")
      (with-temp-buffer
        (s3-manager-mode)
        (setq s3-manager--profile "production"
              s3-manager--bucket "media"
              s3-manager--prefix "")
        (let ((s3-manager-timeout 1))
          (cl-letf (((symbol-function 's3-manager--report-error)
                     (lambda (err &rest _) (push (car err) reported))))
            (s3-manager--fetch-listing)
            (should (s3-manager-test--wait (lambda () reported) 10))))
        (should (equal reported '(s3-manager-timeout-error)))))))

(ert-deftest s3-manager-test-transfer-progress-reaches-the-mode-line ()
  (let ((destination (expand-file-name "x" (make-temp-file "s3dl" t)))
        (seen nil))
    (s3-manager-test--in-object-buffer
      (s3-manager-test--goto-object)
      (cl-letf (((symbol-function 'read-file-name)
                 (lambda (&rest _) destination)))
        (s3-manager-test--with-fake-aws
            (:stdout "Completed 1.0 KiB/2.0 KiB (500 B/s) with 1 file(s) remaining\\r"
             :linger "0.5")
          (s3-manager-get)
          ;; Collect every status observed, since completion clears it.
          (s3-manager-test--wait
           (lambda ()
             (push s3-manager--transfer-status seen)
             (zerop s3-manager--transfers)))))
      (should (member "1.0 KiB/2.0 KiB 500 B/s" seen))
      ;; Cleared once nothing is running.
      (should (null s3-manager--transfer-status))
      (should (equal (s3-manager--mode-line-status) "")))))

(ert-deftest s3-manager-test-concurrent-transfers-are-counted ()
  "Finishing one transfer must not hide another still running."
  (let ((destination (expand-file-name "x" (make-temp-file "s3dl" t))))
    (s3-manager-test--in-object-buffer
      (s3-manager-test--goto-object)
      (cl-letf (((symbol-function 'read-file-name)
                 (lambda (&rest _) destination)))
        (s3-manager-test--with-fake-aws (:stdout "" :delay "0.4")
          (s3-manager-get)
          (s3-manager-get)
          (should (= 2 s3-manager--transfers))
          (should (string-match-p "2: " (s3-manager--mode-line-status)))
          (should (s3-manager-test--wait
                   (lambda () (zerop s3-manager--transfers))))
          (should (null s3-manager--transfer-status)))))))

(ert-deftest s3-manager-test-failed-transfer-reports-and-clears ()
  (when (get-buffer "*S3 Manager Error*") (kill-buffer "*S3 Manager Error*"))
  (let ((destination (expand-file-name "x" (make-temp-file "s3dl" t))))
    (s3-manager-test--in-object-buffer
      (s3-manager-test--goto-object)
      (cl-letf (((symbol-function 'read-file-name)
                 (lambda (&rest _) destination)))
        (s3-manager-test--with-fake-aws
            (:stderr "fatal error: An error occurred (404) calling HeadObject\\n"
             :exit 1)
          (s3-manager-get)
          (should (s3-manager-test--wait
                   (lambda () (zerop s3-manager--transfers))))))
      ;; The counter came back down and the indicator is gone.
      (should (null s3-manager--transfer-status))
      (should (get-buffer "*S3 Manager Error*"))
      (with-current-buffer "*S3 Manager Error*"
        ;; Exit 1 from `aws s3' is partial success, not a flat failure.
        (should (string-match-p "partial" (buffer-string))))))
  (when (get-buffer "*S3 Manager Error*") (kill-buffer "*S3 Manager Error*")))

(ert-deftest s3-manager-test-transfer-keys-are-bound ()
  (should (eq (keymap-lookup s3-manager-mode-map "G") #'s3-manager-get))
  (should (eq (keymap-lookup s3-manager-mode-map "R")
              #'s3-manager-get-recursive)))


;;;; Marks

(defmacro s3-manager-test--in-many-buffer (&rest body)
  "Run BODY in a buffer showing three objects and one prefix."
  (declare (indent 0))
  `(with-temp-buffer
     (s3-manager-mode)
     (setq s3-manager--profile "production"
           s3-manager--bucket "media"
           s3-manager--prefix "")
     (setq tabulated-list-format s3-manager--object-list-format)
     (tabulated-list-init-header)
     (let ((s3-manager--cache (make-hash-table :test #'equal)))
       (s3-manager--render-objects
        (s3-manager-test--json "list-objects-many.json")))
     ,@body))

(defun s3-manager-test--mark-line-chars ()
  "Return the mark column of every printed row, top to bottom."
  (save-excursion
    (goto-char (point-min))
    (let ((chars nil))
      (while (not (eobp))
        (push (buffer-substring (line-beginning-position)
                                (+ (line-beginning-position) 1))
              chars)
        (forward-line 1))
      (nreverse chars))))

(ert-deftest s3-manager-test-mark-and-unmark ()
  (s3-manager-test--in-many-buffer
    (s3-manager--goto-entry
     (car (seq-filter (lambda (e) (eq (s3-manager-entry-type e) 'object))
                      s3-manager--entries)))
    (s3-manager-mark-delete)
    (should (equal (s3-manager--marked-keys) '("a.txt")))
    ;; `d' advances, Dired-style, so a second one marks the next row.
    (s3-manager-mark-delete)
    (should (equal (s3-manager--marked-keys) '("a.txt" "b.txt")))
    ;; And `u' removes going back over them.
    (goto-char (point-min))
    (s3-manager--goto-entry
     (car (seq-filter (lambda (e) (equal (s3-manager-entry-key e) "a.txt"))
                      s3-manager--entries)))
    (s3-manager-unmark)
    (should (equal (s3-manager--marked-keys) '("b.txt")))))

(ert-deftest s3-manager-test-marks-appear-in-the-buffer ()
  "The reserved padding column is where the tag goes."
  (s3-manager-test--in-many-buffer
    (s3-manager--goto-entry
     (car (seq-filter (lambda (e) (equal (s3-manager-entry-key e) "b.txt"))
                      s3-manager--entries)))
    (s3-manager-mark-delete)
    (should (member "D" (s3-manager-test--mark-line-chars)))
    (should (= 1 (seq-count (lambda (c) (equal c "D"))
                            (s3-manager-test--mark-line-chars))))))

(ert-deftest s3-manager-test-marks-survive-a-repaint ()
  "`tabulated-list-print' erases the buffer, so marks must be re-applied.

Its UPDATE argument is no help: it leaves stale tags on unchanged rows
rather than preserving live ones."
  (s3-manager-test--in-many-buffer
    (s3-manager--goto-entry
     (car (seq-filter (lambda (e) (equal (s3-manager-entry-key e) "b.txt"))
                      s3-manager--entries)))
    (s3-manager-mark-delete)
    (should (member "D" (s3-manager-test--mark-line-chars)))
    (s3-manager--print-list)
    (should (equal (s3-manager--marked-keys) '("b.txt")))
    (should (member "D" (s3-manager-test--mark-line-chars)))))

(ert-deftest s3-manager-test-marks-survive-a-re-sort ()
  "Marks are keyed by S3 key, not by line, so sorting cannot move them."
  (s3-manager-test--in-many-buffer
    (s3-manager--goto-entry
     (car (seq-filter (lambda (e) (equal (s3-manager-entry-key e) "c.txt"))
                      s3-manager--entries)))
    (s3-manager-mark-delete)
    (setq tabulated-list-sort-key '("Size" . t))
    (s3-manager--print-list)
    (should (equal (s3-manager--marked-keys) '("c.txt")))
    (should (member "D" (s3-manager-test--mark-line-chars)))))

(ert-deftest s3-manager-test-unmark-all ()
  (s3-manager-test--in-many-buffer
    (s3-manager--goto-entry
     (car (seq-filter (lambda (e) (eq (s3-manager-entry-type e) 'object))
                      s3-manager--entries)))
    (s3-manager-mark-delete)
    (s3-manager-mark-delete)
    (should (= 2 (length (s3-manager--marked-keys))))
    (cl-letf (((symbol-function 'message) #'ignore))
      (s3-manager-unmark-all))
    (should (null (s3-manager--marked-keys)))
    (should-not (member "D" (s3-manager-test--mark-line-chars)))))

(ert-deftest s3-manager-test-prefixes-cannot-be-marked ()
  "Batch-deleting several prefixes behind one confirmation is too blunt."
  (s3-manager-test--in-many-buffer
    (s3-manager--goto-entry (s3-manager--directory-entry "sub/" ""))
    (should-error (s3-manager-mark-delete) :type 'user-error)
    (should (null (s3-manager--marked-keys)))))

(ert-deftest s3-manager-test-marks-are-dropped-when-the-prefix-changes ()
  "Marks name keys in one listing.

Carried into another prefix they would be invisible yet still acted on
by `x', which would delete objects the user cannot see."
  (s3-manager-test--in-many-buffer
    (s3-manager--goto-entry
     (car (seq-filter (lambda (e) (eq (s3-manager-entry-type e) 'object))
                      s3-manager--entries)))
    (s3-manager-mark-delete)
    (should (= 1 (hash-table-count s3-manager--marks)))
    (s3-manager--set-prefix "sub/")
    (should (zerop (hash-table-count s3-manager--marks)))
    ;; Re-showing the same prefix keeps them, as `g' should.
    (s3-manager--set-prefix "sub/")
    (should (zerop (hash-table-count s3-manager--marks)))))


;;;; Deletion

(ert-deftest s3-manager-test-delete-payload ()
  "The payload is JSON in one argv element, so keys need no escaping by us."
  (let ((payload (s3-manager--delete-payload '("a/b.txt" "we\"ird\nkey"))))
    (should (equal payload
                   "{\"Objects\":[{\"Key\":\"a/b.txt\"},{\"Key\":\"we\\\"ird\\nkey\"}]}"))))

(ert-deftest s3-manager-test-execute-argv ()
  (let ((argv-file (make-temp-file "s3-del-argv")))
    (unwind-protect
        (s3-manager-test--in-many-buffer
          (s3-manager--goto-entry
           (car (seq-filter (lambda (e) (equal (s3-manager-entry-key e) "a.txt"))
                            s3-manager--entries)))
          (s3-manager-mark-delete)
          (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                    ((symbol-function 'message) #'ignore))
            (s3-manager-test--with-fake-aws
                (:stdout (s3-manager-test--fixture "delete-objects-ok.json")
                 :argv-file argv-file)
              (s3-manager-execute)
              (should (s3-manager-test--wait
                       (lambda ()
                         (zerop (hash-table-count s3-manager--marks)))))))
          (let ((argv (car (s3-manager-test--argv-records argv-file))))
            (should (equal (seq-take argv 8)
                           '("--profile" "production"
                             "--no-cli-pager" "--no-cli-auto-prompt"
                             "s3api" "delete-objects" "--bucket" "media")))
            (should (equal (cadr (member "--delete" argv))
                           "{\"Objects\":[{\"Key\":\"a.txt\"}]}"))))
      (delete-file argv-file))))

(ert-deftest s3-manager-test-execute-refuses-without-marks ()
  (s3-manager-test--in-many-buffer
    (should-error (s3-manager-execute) :type 'user-error)))

(ert-deftest s3-manager-test-execute-aborts-on-refusal ()
  (s3-manager-test--in-many-buffer
    (s3-manager--goto-entry
     (car (seq-filter (lambda (e) (eq (s3-manager-entry-type e) 'object))
                      s3-manager--entries)))
    (s3-manager-mark-delete)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
      (should-error (s3-manager-execute) :type 'user-error))
    ;; The marks are still there, so the user can reconsider.
    (should (= 1 (length (s3-manager--marked-keys))))))

(ert-deftest s3-manager-test-partial-delete-is-not-reported-as-success ()
  "`delete-objects' exits 0 even when individual keys fail.

The Errors array has to be read on the success path; ignoring it would
report a partial deletion as a complete one."
  (when (get-buffer "*S3 Manager Error*") (kill-buffer "*S3 Manager Error*"))
  (let ((messages nil))
    (s3-manager-test--in-many-buffer
      (s3-manager--goto-entry
       (car (seq-filter (lambda (e) (eq (s3-manager-entry-type e) 'object))
                        s3-manager--entries)))
      (s3-manager-mark-delete)
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t))
                ((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (s3-manager-test--with-fake-aws
            (:stdout (s3-manager-test--fixture "delete-objects-partial.json"))
          (s3-manager-execute)
          (should (s3-manager-test--wait
                   (lambda () (seq-find (lambda (m) (string-match-p "failed" m))
                                        messages)))))))
    (should (seq-find (lambda (m) (string-match-p "deleted 2, 1 failed" m))
                      messages))
    (should (get-buffer "*S3 Manager Error*"))
    (with-current-buffer "*S3 Manager Error*"
      (should (string-match-p "AccessDenied" (buffer-string)))
      (should (string-match-p "c\\.txt" (buffer-string)))))
  (when (get-buffer "*S3 Manager Error*") (kill-buffer "*S3 Manager Error*")))

(ert-deftest s3-manager-test-execute-chunks-at-1000 ()
  "delete-objects takes at most 1000 keys per call."
  (let ((keys (mapcar (lambda (i) (format "k%d" i)) (number-sequence 1 2500))))
    (let ((chunks (seq-partition keys 1000)))
      (should (= 3 (length chunks)))
      (should (= 1000 (length (nth 0 chunks))))
      (should (= 1000 (length (nth 1 chunks))))
      (should (= 500 (length (nth 2 chunks)))))))

(ert-deftest s3-manager-test-delete-object-argv-and-confirmation ()
  (let ((argv-file (make-temp-file "s3-del1-argv"))
        (prompts nil))
    (unwind-protect
        (s3-manager-test--in-many-buffer
          (s3-manager--goto-entry
           (car (seq-filter (lambda (e) (equal (s3-manager-entry-key e) "b.txt"))
                            s3-manager--entries)))
          (cl-letf (((symbol-function 'y-or-n-p)
                     (lambda (prompt) (push prompt prompts) t))
                    ((symbol-function 'message) #'ignore))
            (s3-manager-test--with-fake-aws (:stdout "{}" :argv-file argv-file)
              (s3-manager-delete)
              (should (= 2 (length (s3-manager-test--wait-for-argv
                                    argv-file 2))))))
          ;; The prompt names the full URI, not a bare key.
          (should (seq-find (lambda (p) (string-match-p "s3://media/b\\.txt" p))
                            prompts))
          (let ((records (s3-manager-test--argv-records argv-file)))
            (should (equal (car records)
                           '("--profile" "production"
                             "--no-cli-pager" "--no-cli-auto-prompt"
                             "s3api" "delete-object"
                             "--bucket" "media" "--key" "b.txt"
                             "--output" "json")))
            ;; And the listing was re-read afterwards.
            (should (member "list-objects-v2" (cadr records)))))
      (delete-file argv-file))))

(ert-deftest s3-manager-test-recursive-delete-demands-a-typed-yes ()
  "The one unbounded destructive operation must not ride on one keystroke."
  (let ((argv-file (make-temp-file "s3-rm-argv"))
        (used-yes-or-no nil))
    (unwind-protect
        (s3-manager-test--in-many-buffer
          (s3-manager--goto-entry (s3-manager--directory-entry "sub/" ""))
          (cl-letf (((symbol-function 'y-or-n-p)
                     (lambda (&rest _) (error "y-or-n-p is too weak here")))
                    ((symbol-function 'yes-or-no-p)
                     (lambda (prompt) (setq used-yes-or-no prompt) t))
                    ((symbol-function 'message) #'ignore))
            (s3-manager-test--with-fake-aws (:stdout "" :argv-file argv-file)
              (s3-manager-delete)
              (should (s3-manager-test--wait-for-argv argv-file 1))))
          (should used-yes-or-no)
          (should (string-match-p "Recursively delete ALL" used-yes-or-no))
          (let ((records (s3-manager-test--argv-records argv-file)))
            (should (equal (car records)
                           '("--profile" "production"
                             "--no-cli-pager" "--no-cli-auto-prompt"
                             "s3" "rm" "s3://media/sub/"
                             "--recursive" "--only-show-errors")))))
      (delete-file argv-file))))

(ert-deftest s3-manager-test-recursive-delete-abort ()
  (s3-manager-test--in-many-buffer
    (s3-manager--goto-entry (s3-manager--directory-entry "sub/" ""))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
      (should-error (s3-manager-delete) :type 'user-error))))

(ert-deftest s3-manager-test-recursive-delete-purges-the-cache-below ()
  "Everything at or under the deleted prefix must be forgotten.

And so must the listing that was showing it.  The deleted prefix sits
*below* that listing, so purging at-and-under the prefix alone leaves
the parent cached -- and the refresh then redisplays a prefix that no
longer exists.  Found by watching a real recursive delete: every object
was gone from S3, yet the row was still on screen."
  (let ((s3-manager--cache (make-hash-table :test #'equal)))
    (with-temp-buffer
      (s3-manager-mode)
      (setq s3-manager--profile "p" s3-manager--bucket "media"
            s3-manager--prefix "")
      (dolist (prefix '("" "sub/" "sub/deep/" "other/"))
        (s3-manager--cache-put (list "p" nil "media" prefix) nil nil nil))
      (cl-letf (((symbol-function 's3-manager--reload) #'ignore))
        (s3-manager--after-delete "sub/"))
      (should (null (s3-manager--cache-get '("p" nil "media" "sub/"))))
      (should (null (s3-manager--cache-get '("p" nil "media" "sub/deep/"))))
      ;; The listing being shown, which contained the row.
      (should (null (s3-manager--cache-get '("p" nil "media" ""))))
      ;; Unrelated prefixes are untouched.
      (should (s3-manager--cache-get '("p" nil "media" "other/"))))))

(ert-deftest s3-manager-test-single-delete-invalidates-its-listing ()
  (let ((s3-manager--cache (make-hash-table :test #'equal)))
    (with-temp-buffer
      (s3-manager-mode)
      (setq s3-manager--profile "p" s3-manager--bucket "media"
            s3-manager--prefix "a/")
      (dolist (prefix '("" "a/" "b/"))
        (s3-manager--cache-put (list "p" nil "media" prefix) nil nil nil))
      (cl-letf (((symbol-function 's3-manager--reload) #'ignore))
        (s3-manager--after-delete))
      (should (null (s3-manager--cache-get '("p" nil "media" "a/"))))
      (should (s3-manager--cache-get '("p" nil "media" "")))
      (should (s3-manager--cache-get '("p" nil "media" "b/"))))))

(ert-deftest s3-manager-test-delete-refuses-in-the-bucket-list ()
  (with-temp-buffer
    (s3-manager-mode)
    (setq s3-manager--bucket nil)
    (should-error (s3-manager-delete) :type 'user-error)
    (should-error (s3-manager-execute) :type 'user-error)))

(ert-deftest s3-manager-test-delete-keys-are-bound ()
  (should (eq (keymap-lookup s3-manager-mode-map "d") #'s3-manager-mark-delete))
  (should (eq (keymap-lookup s3-manager-mode-map "u") #'s3-manager-unmark))
  (should (eq (keymap-lookup s3-manager-mode-map "U") #'s3-manager-unmark-all))
  (should (eq (keymap-lookup s3-manager-mode-map "x") #'s3-manager-execute))
  (should (eq (keymap-lookup s3-manager-mode-map "D") #'s3-manager-delete)))


;;;; Dired interoperability

(ert-deftest s3-manager-test-dwim-directory-follows-the-option ()
  "A visible Dired buffer decides the default, but only when
`dired-dwim-target' is on: nil there means the user does not want it."
  (skip-unless (require 'dired-aux nil t))
  (cl-letf (((symbol-function 'dired-dwim-target-directory)
             (lambda () "/tmp/from-dired/")))
    (let ((dired-dwim-target t))
      (should (equal (s3-manager--dwim-directory) "/tmp/from-dired/")))
    (let ((dired-dwim-target nil))
      (should (null (s3-manager--dwim-directory))))))

(ert-deftest s3-manager-test-local-default-prefers-the-dired-window ()
  "Both directions default to the other window, falling back to the
download directory when there is no Dired buffer to borrow from."
  (cl-letf (((symbol-function 's3-manager--dwim-directory)
             (lambda () "/tmp/from-dired")))
    (should (equal (s3-manager--local-default-directory) "/tmp/from-dired/")))
  (cl-letf (((symbol-function 's3-manager--dwim-directory) (lambda () nil)))
    (let ((s3-manager-download-directory "/tmp/downloads"))
      (should (equal (s3-manager--local-default-directory) "/tmp/downloads/")))))

(ert-deftest s3-manager-test-download-defaults-to-the-dired-window ()
  "`G' offers the Dired directory rather than `s3-manager-download-directory'."
  (let ((offered nil)
        (target (file-name-as-directory (make-temp-file "s3-dired" t))))
    (unwind-protect
        (cl-letf (((symbol-function 's3-manager--dwim-directory)
                   (lambda () target))
                  ((symbol-function 'read-file-name)
                   (lambda (_prompt dir &rest _)
                     (setq offered dir)
                     (expand-file-name "README.md" dir))))
          (let ((s3-manager-download-directory "/tmp/never-used/"))
            (s3-manager--read-destination-file "README.md"))
          (should (equal offered target)))
      (delete-directory target t))))

(ert-deftest s3-manager-test-upload-defaults-to-the-dired-window ()
  "`P' offers the same directory, so the two-window workflow is symmetric."
  (let ((offered nil)
        (source (make-temp-file "s3-upload" nil ".txt" "x\n")))
    (unwind-protect
        (cl-letf (((symbol-function 's3-manager--dwim-directory)
                   (lambda () "/tmp/from-dired"))
                  ((symbol-function 'read-file-name)
                   (lambda (_prompt dir &rest _) (setq offered dir) source)))
          (s3-manager--upload-source)
          (should (equal offered "/tmp/from-dired/")))
      (delete-file source))))


;;;; Upload

(defconst s3-manager-test--head-404
  (concat "An error occurred (404) when calling the HeadObject operation:"
          " Not Found")
  "The stderr the CLI produces for a key that does not exist.")

(defconst s3-manager-test--head-403
  (concat "An error occurred (403) when calling the HeadObject operation:"
          " Forbidden")
  "The stderr real AWS produces for a key the caller may not look at.")

(defmacro s3-manager-test--with-upload-source (var &rest body)
  "Bind VAR to a readable temporary file and run BODY, then remove it."
  (declare (indent 1))
  `(let ((,var (make-temp-file "s3-upload" nil ".txt" "payload\n")))
     (unwind-protect (progn ,@body)
       (when (file-exists-p ,var) (delete-file ,var)))))

(ert-deftest s3-manager-test-upload-key-name-derivation ()
  "The key is the source's leaf, and an unusable name is refused.
Refused rather than replaced with a fallback: inventing a name for a
downloaded copy costs nothing, whereas inventing one for an upload
writes the user's bytes to a key they never named."
  (should (equal (s3-manager--upload-key-name "/a/b/c.txt") "c.txt"))
  (should (equal (s3-manager--upload-key-name "/a/b/dir/") "dir"))
  (should (equal (s3-manager--upload-key-name "/a/b/has space.txt")
                 "has space.txt"))
  ;; A leading tilde needs no guard here: nothing expands it on the S3 side.
  (should (equal (s3-manager--upload-key-name "/a/b/~weird") "~weird"))
  (should-error (s3-manager--upload-key-name "/") :type 'user-error))

(ert-deftest s3-manager-test-upload-key-uses-the-listing-prefix ()
  "The destination is the prefix on screen, not the row point is on."
  (should (equal (s3-manager--upload-key "/home/u/a.txt" "docs/") "docs/a.txt"))
  (should (equal (s3-manager--upload-key "/home/u/a.txt" "") "a.txt")))

(ert-deftest s3-manager-test-upload-argv-probes-then-transfers ()
  "A single-file upload is one head-object probe and one `s3 cp'.
The probe is `s3api', so exits 1 and 2 stay hard errors there; the
transfer is `s3', where they mean partial success."
  (let ((argv-file (make-temp-file "s3-upload-argv")))
    (unwind-protect
        (s3-manager-test--with-upload-source source
          (s3-manager-test--in-object-buffer
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (&rest _) source))
                      ((symbol-function 'message) #'ignore))
              (s3-manager-test--with-fake-aws
                  (:stdout "" :argv-file argv-file
                   :head-exit 254 :head-stderr s3-manager-test--head-404)
                (s3-manager-upload)
                (should (s3-manager-test--wait
                         (lambda ()
                           (>= (length (s3-manager-test--argv-records argv-file))
                               2)))))))
          (let* ((records (s3-manager-test--argv-records argv-file))
                 (probe (nth 0 records))
                 (transfer (nth 1 records))
                 (name (file-name-nondirectory source)))
            (should (equal probe
                           (list "--profile" "production"
                                 "--no-cli-pager" "--no-cli-auto-prompt"
                                 "s3api" "head-object"
                                 "--bucket" "media" "--key" name
                                 "--output" "json")))
            (should (equal transfer
                           (list "--profile" "production"
                                 "--no-cli-pager" "--no-cli-auto-prompt"
                                 "s3" "cp" source (concat "s3://media/" name)
                                 "--progress-frequency" "1")))
            ;; Both suppress the progress the mode line needs.
            (should-not (member "--quiet" transfer))
            (should-not (member "--only-show-errors" transfer))
            (should-not (member "--recursive" transfer))))
      (delete-file argv-file))))

(ert-deftest s3-manager-test-upload-proceeds-when-the-key-is-absent ()
  "A 404 from the probe means nothing is being overwritten: no prompt."
  (let ((argv-file (make-temp-file "s3-upload-argv")))
    (unwind-protect
        (s3-manager-test--with-upload-source source
          (s3-manager-test--in-object-buffer
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (&rest _) source))
                      ((symbol-function 'y-or-n-p)
                       (lambda (&rest _) (error "Must not prompt when absent")))
                      ((symbol-function 'message) #'ignore))
              (s3-manager-test--with-fake-aws
                  (:stdout "" :argv-file argv-file
                   :head-exit 254 :head-stderr s3-manager-test--head-404)
                (s3-manager-upload)
                ;; The counter is transient -- the fake CLI can start and
                ;; finish between polls -- so wait on the invocations.
                (should (s3-manager-test--wait
                         (lambda ()
                           (>= (length (s3-manager-test--argv-records
                                        argv-file))
                               2)))))))
          (let ((records (s3-manager-test--argv-records argv-file)))
            (should (member "head-object" (nth 0 records)))
            (should (member "cp" (nth 1 records)))))
      (delete-file argv-file))))

(ert-deftest s3-manager-test-upload-confirms-before-overwriting ()
  "An existing key must be named, with its size and date, before it goes."
  (let ((prompt nil))
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (p) (setq prompt p) nil)))
      (should-error
       (s3-manager--upload-confirm-overwrite
        (s3-manager-test--json "head-object.json") "s3://media/README.md")
       :type 'user-error))
    (should (string-match-p "s3://media/README.md" prompt))
    (should (string-match-p "12 MiB" prompt))
    (should (string-match-p "2026-09-01" prompt))))

(ert-deftest s3-manager-test-upload-refusal-transfers-nothing ()
  "Declining the overwrite must leave the object untouched."
  (let ((argv-file (make-temp-file "s3-upload-argv")))
    (unwind-protect
        (s3-manager-test--with-upload-source source
          (s3-manager-test--in-object-buffer
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (&rest _) source))
                      ((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
                      ((symbol-function 'message) #'ignore))
              (s3-manager-test--with-fake-aws
                  (:stdout "" :argv-file argv-file
                   :head-exit 0
                   :head-stdout (json-serialize
                                 '((ContentLength . 10)
                                   (LastModified . "2026-09-01T00:00:00+00:00"))))
                (s3-manager-upload)
                ;; Let the probe land and the timer fire.
                (should (s3-manager-test--wait
                         (lambda ()
                           (= 1 (length (s3-manager-test--argv-records
                                         argv-file))))))
                (s3-manager-test--wait #'ignore 0.3))))
          ;; The probe ran; nothing else did.
          (should (= 1 (length (s3-manager-test--argv-records argv-file)))))
      (delete-file argv-file))))

(ert-deftest s3-manager-test-head-object-403-is-not-absence ()
  "Only a 404 means absent.  Everything else is a failed check.
Reading a 403 as absence would silently overwrite an object the user was
merely forbidden to look at."
  (should (s3-manager--head-object-absent-p
           (list 's3-manager-cli-error "aws s3api head-object" 254
                 s3-manager-test--head-404)))
  (should-not (s3-manager--head-object-absent-p
               (list 's3-manager-cli-error "aws s3api head-object" 254
                     s3-manager-test--head-403)))
  ;; Unreachable endpoint, and a timeout, which carries no exit code at all.
  (should-not (s3-manager--head-object-absent-p
               (list 's3-manager-cli-error "aws s3api head-object" 255
                     "Could not connect to the endpoint URL")))
  (should-not (s3-manager--head-object-absent-p
               (list 's3-manager-timeout-error "aws s3api head-object" nil
                     "No response after 120 seconds")))
  (should-not (s3-manager--head-object-absent-p
               (list 's3-manager-cli-error "aws s3api head-object" 254 nil))))

(ert-deftest s3-manager-test-upload-asks-when-the-check-fails ()
  "A failed check is reported and asked about, never assumed either way.
Real AWS answers 403 rather than 404 for a missing key when the caller
lacks s3:ListBucket, so refusing outright would make upload useless
under a tight policy -- and proceeding silently would be an unannounced
overwrite."
  (let ((asked nil))
    (s3-manager-test--with-fresh-error-buffer
      (s3-manager-test--with-upload-source source
        (s3-manager-test--in-object-buffer
          (cl-letf (((symbol-function 'read-file-name)
                     (lambda (&rest _) source))
                    ((symbol-function 'y-or-n-p)
                     (lambda (p) (setq asked p) nil))
                    ((symbol-function 'display-buffer) #'ignore)
                    ((symbol-function 'message) #'ignore))
            (s3-manager-test--with-fake-aws
                (:stdout "" :head-exit 254
                 :head-stderr s3-manager-test--head-403)
              (s3-manager-upload)
              (should (s3-manager-test--wait (lambda () asked)))))))
      ;; Asked, and the service's own words were recorded.
      (should (string-match-p "Upload anyway" asked))
      (should (string-match-p "403" (s3-manager-test--error-text))))))

(ert-deftest s3-manager-test-upload-refuses-in-the-bucket-list ()
  "There is no prefix to upload into, and the user must not be asked first."
  (let ((asked nil))
    (with-temp-buffer
      (s3-manager-mode)
      (setq s3-manager--bucket nil)
      (cl-letf (((symbol-function 'read-file-name)
                 (lambda (&rest _) (setq asked t) "/tmp/x")))
        (should-error (s3-manager-upload) :type 'user-error)
        (should (null asked))))))

(ert-deftest s3-manager-test-upload-refuses-an-unusable-source ()
  "A missing path, a directory, and an irregular file are all refused."
  (s3-manager-test--in-object-buffer
    (cl-letf (((symbol-function 'read-file-name)
               (lambda (&rest _) "/tmp/s3-manager-definitely-absent-xyz")))
      (should-error (s3-manager-upload) :type 'user-error))
    (let ((directory (make-temp-file "s3-upload-dir" t)))
      (unwind-protect
          (cl-letf (((symbol-function 'read-file-name)
                     (lambda (&rest _) directory)))
            (should-error (s3-manager-upload) :type 'user-error))
        (delete-directory directory t)))))

(ert-deftest s3-manager-test-upload-refuses-a-source-that-vanished ()
  "The window between the prompt and the transfer is real: a probe round
trip and an unbounded confirmation sit inside it."
  (let ((source (make-temp-file "s3-upload" nil ".txt" "x\n")))
    (delete-file source)
    (s3-manager-test--in-object-buffer
      (should-error
       (s3-manager--upload-start source "s3://media/x.txt" "x.txt" "")
       :type 'user-error)
      (should (zerop s3-manager--transfers)))))

(ert-deftest s3-manager-test-after-upload-invalidates-and-restores ()
  "The listing on screen has changed, so its cache entry must go first."
  (s3-manager-test--in-object-buffer
    (let ((s3-manager--cache (make-hash-table :test #'equal)))
      (s3-manager--cache-put (s3-manager--cache-key)
                             tabulated-list-entries s3-manager--entries nil)
      (s3-manager--cache-put (s3-manager--cache-key "other/") nil nil nil)
      (s3-manager--after-upload "" "README.md")
      ;; This prefix was dropped; an unrelated one was not.
      (should (null (s3-manager--cache-get (s3-manager--cache-key))))
      (should (s3-manager--cache-get (s3-manager--cache-key "other/"))))))

(ert-deftest s3-manager-test-after-upload-does-not-reload-a-buffer-that-moved-on ()
  "A transfer outlives navigation, so the refresh must name its own
destination rather than whatever is on screen when it lands."
  (s3-manager-test--in-object-buffer
    (let ((s3-manager--cache (make-hash-table :test #'equal))
          (reloaded nil))
      (s3-manager--cache-put (s3-manager--cache-key "docs/") nil nil nil)
      (setq s3-manager--prefix "elsewhere/")
      (cl-letf (((symbol-function 's3-manager--reload)
                 (lambda (&rest _) (setq reloaded t))))
        (s3-manager--after-upload "docs/" "docs/a.txt"))
      ;; Cache entry for the destination is gone, but the buffer showing
      ;; something else was left alone.
      (should (null (s3-manager--cache-get (s3-manager--cache-key "docs/"))))
      (should (null reloaded)))))

(defmacro s3-manager-test--with-upload-tree (var &rest body)
  "Bind VAR to a temporary directory holding a small tree, and run BODY."
  (declare (indent 1))
  `(let ((,var (make-temp-file "s3-upload-tree" t)))
     (unwind-protect
         (progn
           (write-region "a\n" nil (expand-file-name "a.txt" ,var) nil 'silent)
           (make-directory (expand-file-name "sub" ,var))
           (write-region "b\n" nil (expand-file-name "sub/b.txt" ,var)
                         nil 'silent)
           ,@body)
       (delete-directory ,var t))))

(ert-deftest s3-manager-test-upload-directory-key-keeps-the-leaf ()
  "A directory key must end in \"/\", or the tree is scattered flat.

`s3 cp DIR s3://B/PREFIX --recursive' maps DIR/a.txt onto PREFIX/a.txt
and drops the directory's own name -- measured against the CLI -- so
without the trailing leaf the contents land in the listing the user was
looking at rather than under a prefix of their own."
  (s3-manager-test--with-upload-tree tree
    (should (equal (s3-manager--upload-key tree "docs/")
                   (concat "docs/" (file-name-nondirectory tree) "/")))))

(ert-deftest s3-manager-test-upload-directory-argv ()
  "The recursive form: both paths end in a slash, and `--recursive'."
  (let ((argv-file (make-temp-file "s3-upload-argv")))
    (unwind-protect
        (s3-manager-test--with-upload-tree tree
          (s3-manager-test--in-object-buffer
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (&rest _) tree))
                      ((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                      ((symbol-function 'y-or-n-p)
                       (lambda (&rest _)
                         (error "A directory upload must not use y-or-n-p")))
                      ((symbol-function 'message) #'ignore))
              (s3-manager-test--with-fake-aws (:stdout "" :argv-file argv-file)
                (s3-manager-upload)
                (should (s3-manager-test--wait
                         (lambda ()
                           (s3-manager-test--argv-records argv-file))))))
            (let* ((records (s3-manager-test--argv-records argv-file))
                   (leaf (file-name-nondirectory tree)))
              ;; No probe: one call, straight to the transfer.
              (should-not (member "head-object" (nth 0 records)))
              (should (equal (nth 0 records)
                             (list "--profile" "production"
                                   "--no-cli-pager" "--no-cli-auto-prompt"
                                   "s3" "cp"
                                   (file-name-as-directory tree)
                                   (concat "s3://media/" leaf "/")
                                   "--recursive"
                                   "--progress-frequency" "1"))))))
      (delete-file argv-file))))

(ert-deftest s3-manager-test-upload-directory-demands-a-typed-yes ()
  "An unbounded write must not ride on a single keystroke.
The same reasoning as a recursive delete: no per-key overwrite check is
made, because one probe per file is unbounded too."
  (let ((prompt nil))
    (s3-manager-test--with-upload-tree tree
      (s3-manager-test--in-object-buffer
        (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) tree))
                  ((symbol-function 'yes-or-no-p)
                   (lambda (p) (setq prompt p) nil))
                  ((symbol-function 'message) #'ignore))
          (should-error (s3-manager-upload) :type 'user-error)
          (should (zerop s3-manager--transfers)))))
    (should (string-match-p "Recursively upload everything under" prompt))))

(ert-deftest s3-manager-test-upload-directory-refuses-an-empty-one ()
  "S3 has no directories, so an empty one would report success and do
nothing -- which reads as the feature being broken."
  (let ((empty (make-temp-file "s3-upload-empty" t)))
    (unwind-protect
        (s3-manager-test--in-object-buffer
          (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) empty))
                    ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
            (should-error (s3-manager-upload) :type 'user-error)
            (should (zerop s3-manager--transfers))))
      (delete-directory empty t))))

(ert-deftest s3-manager-test-upload-symlink-flag-is-configurable ()
  "The CLI follows symlinks by default; nil must pass the opposite flag."
  (let ((s3-manager-upload-follow-symlinks t))
    (should-not (member "--no-follow-symlinks"
                        (s3-manager--upload-args "/tmp/d" "s3://b/d/" t))))
  (let ((s3-manager-upload-follow-symlinks nil))
    (should (member "--no-follow-symlinks"
                    (s3-manager--upload-args "/tmp/d" "s3://b/d/" t)))
    ;; Only meaningful for a recursive upload.
    (should-not (member "--no-follow-symlinks"
                        (s3-manager--upload-args "/tmp/f" "s3://b/f" nil)))))

(ert-deftest s3-manager-test-after-upload-recursive-purges-beneath ()
  "A recursive upload creates keys under the new prefix, so a listing
cached from before describes a tree that no longer exists."
  (s3-manager-test--in-object-buffer
    (let ((s3-manager--cache (make-hash-table :test #'equal)))
      (s3-manager--cache-put (s3-manager--cache-key "") nil nil nil)
      (s3-manager--cache-put (s3-manager--cache-key "site/") nil nil nil)
      (s3-manager--cache-put (s3-manager--cache-key "site/img/") nil nil nil)
      (s3-manager--cache-put (s3-manager--cache-key "other/") nil nil nil)
      (cl-letf (((symbol-function 's3-manager--reload) #'ignore))
        (s3-manager--after-upload "" "site/" t))
      (should (null (s3-manager--cache-get (s3-manager--cache-key ""))))
      (should (null (s3-manager--cache-get (s3-manager--cache-key "site/"))))
      (should (null (s3-manager--cache-get (s3-manager--cache-key "site/img/"))))
      ;; An unrelated sibling survives.
      (should (s3-manager--cache-get (s3-manager--cache-key "other/"))))))

(ert-deftest s3-manager-test-overwrite-prompt-is-deferred-off-the-sentinel ()
  "The prompt must not run inside the process sentinel.

A sentinel runs at whatever point in the command loop Emacs had reached
when the pipe became readable -- inside another command, inside an
unrelated minibuffer read, inside redisplay -- and `y-or-n-p' there
re-enters the minibuffer from that arbitrary point.
`s3-manager--profiles-resolved' hands its prompt to a zero-second timer
for exactly this reason; upload takes the same hop.

`s3-manager-timeout' is nil here so the transport schedules no timer of
its own and the only thing captured is the hop under test."
  (let ((thunks nil)
        (prompted nil))
    (s3-manager-test--with-upload-source source
      (s3-manager-test--in-object-buffer
        (cl-letf (((symbol-function 'read-file-name)
                   (lambda (&rest _) source))
                  ((symbol-function 'y-or-n-p)
                   (lambda (&rest _) (setq prompted t) nil))
                  ((symbol-function 'run-at-time)
                   (lambda (delay _repeat fn &rest _)
                     (push (cons delay fn) thunks)
                     nil))
                  ((symbol-function 'message) #'ignore))
          (s3-manager-test--with-fake-aws
              (:stdout ""
               :head-exit 0
               :head-stdout (json-serialize
                             '((ContentLength . 10)
                               (LastModified . "2026-09-01T00:00:00+00:00"))))
            (let ((s3-manager-timeout nil))
              (s3-manager-upload)
              (should (s3-manager-test--wait (lambda () thunks)))))
          ;; The probe has answered and scheduled work, and has not prompted.
          (should (null prompted))
          (should (= 1 (length thunks)))
          (should (equal 0 (car (car thunks))))
          ;; The deferred thunk is what prompts.
          (funcall (cdr (car thunks)))
          (should prompted))))))

(ert-deftest s3-manager-test-upload-dry-run-argv ()
  "A preview transfers nothing: `--dryrun', and no progress to report on."
  (let ((argv-file (make-temp-file "s3-dryrun-argv")))
    (unwind-protect
        (s3-manager-test--with-upload-source source
          (s3-manager-test--with-fresh-dry-run-buffer
            (s3-manager-test--in-object-buffer
              (cl-letf (((symbol-function 'read-file-name)
                         (lambda (&rest _) source))
                        ((symbol-function 'display-buffer) #'ignore)
                        ((symbol-function 'message) #'ignore))
                (s3-manager-test--with-fake-aws
                    (:stdout "(dryrun) upload: ./x to s3://media/x\n"
                     :argv-file argv-file)
                  (s3-manager-upload-dry-run)
                  (should (s3-manager-test--wait
                           (lambda () (s3-manager-test--dry-run-text)))))))
            (let ((argv (car (s3-manager-test--argv-records argv-file)))
                  (name (file-name-nondirectory source)))
              (should (equal argv
                             (list "--profile" "production"
                                   "--no-cli-pager" "--no-cli-auto-prompt"
                                   "s3" "cp" source (concat "s3://media/" name)
                                   "--dryrun")))
              (should-not (member "--progress-frequency" argv))
              ;; A preview must not probe: it reports what would be sent,
              ;; not what would be replaced.
              (should-not (member "head-object" argv)))))
      (delete-file argv-file))))

(ert-deftest s3-manager-test-upload-dry-run-directory-argv ()
  "The recursive preview must describe the recursive upload exactly."
  (let ((argv-file (make-temp-file "s3-dryrun-argv")))
    (unwind-protect
        (s3-manager-test--with-upload-tree tree
          (s3-manager-test--with-fresh-dry-run-buffer
            (s3-manager-test--in-object-buffer
              (cl-letf (((symbol-function 'read-file-name)
                         (lambda (&rest _) tree))
                        ((symbol-function 'yes-or-no-p)
                         (lambda (&rest _)
                           (error "A preview must not ask for confirmation")))
                        ((symbol-function 'display-buffer) #'ignore)
                        ((symbol-function 'message) #'ignore))
                (s3-manager-test--with-fake-aws
                    (:stdout "(dryrun) upload: ./a.txt to s3://media/t/a.txt\n"
                     :argv-file argv-file)
                  (s3-manager-upload-dry-run)
                  (should (s3-manager-test--wait
                           (lambda () (s3-manager-test--dry-run-text)))))))
            (let ((argv (car (s3-manager-test--argv-records argv-file)))
                  (leaf (file-name-nondirectory tree)))
              (should (equal argv
                             (list "--profile" "production"
                                   "--no-cli-pager" "--no-cli-auto-prompt"
                                   "s3" "cp"
                                   (file-name-as-directory tree)
                                   (concat "s3://media/" leaf "/")
                                   "--recursive" "--dryrun"))))))
      (delete-file argv-file))))

(ert-deftest s3-manager-test-dry-run-matches-the-upload-it-previews ()
  "Every argument deciding *what* is sent must be identical in both forms.

The symlink decision leans on the preview: following links is the CLI's
default and can pull in a large tree, and the dry run is what makes that
visible beforehand.  A preview that could resolve links differently from
the upload would be worse than no preview at all."
  (dolist (follow '(t nil))
    (let* ((s3-manager-upload-follow-symlinks follow)
           (real (s3-manager--upload-args "/tmp/d" "s3://b/d/" t))
           (preview (s3-manager--upload-args "/tmp/d" "s3://b/d/" t t))
           (decisive (lambda (args)
                       (seq-remove
                        (lambda (a)
                          (member a '("--dryrun" "--progress-frequency" "1")))
                        args))))
      (should (equal (funcall decisive real) (funcall decisive preview)))
      (should (member "--dryrun" preview))
      (should-not (member "--dryrun" real))
      (should-not (member "--progress-frequency" preview)))))

(ert-deftest s3-manager-test-upload-dry-run-renders-and-writes-nothing ()
  "The preview lands in the shared dry-run buffer, and no transfer starts."
  (s3-manager-test--with-upload-source source
    (s3-manager-test--with-fresh-dry-run-buffer
      (s3-manager-test--in-object-buffer
        (cl-letf (((symbol-function 'read-file-name) (lambda (&rest _) source))
                  ((symbol-function 'display-buffer) #'ignore)
                  ((symbol-function 'message) #'ignore))
          (s3-manager-test--with-fake-aws
              (:stdout "(dryrun) upload: ./a to s3://media/a\n(dryrun) upload: ./b to s3://media/b\n")
            (s3-manager-upload-dry-run)
            (should (s3-manager-test--wait
                     (lambda () (s3-manager-test--dry-run-text))))))
        (should (zerop s3-manager--transfers)))
      (let ((text (s3-manager-test--dry-run-text)))
        (should (string-match-p "Would upload" text))
        (should (string-match-p "s3://media/a" text))
        (should (string-match-p "s3://media/b" text)))
      (with-current-buffer "*S3 Manager Dry Run*"
        (should (derived-mode-p 'special-mode))))))

(ert-deftest s3-manager-test-upload-dry-run-refuses-in-the-bucket-list ()
  (with-temp-buffer
    (s3-manager-mode)
    (setq s3-manager--bucket nil)
    (should-error (s3-manager-upload-dry-run) :type 'user-error)))

(ert-deftest s3-manager-test-upload-key-is-bound ()
  (should (eq (keymap-lookup s3-manager-mode-map "P") #'s3-manager-upload)))


;;;; Point restoration by key

(defun s3-manager-test--row-key-at-point ()
  "Return the S3 key of the row point is on, or nil."
  (let ((id (tabulated-list-get-id)))
    (and (s3-manager-entry-p id) (s3-manager-entry-key id))))

(ert-deftest s3-manager-test-goto-key-finds-the-row ()
  "A key is enough to place point, without the whole entry.
An uploaded object's Size and LastModified belong to the server, so the
struct-identity match `s3-manager--goto-entry' uses cannot be built in
advance."
  (s3-manager-test--in-object-buffer
    (goto-char (point-min))
    (s3-manager--goto-key "README.md")
    (should (equal (s3-manager-test--row-key-at-point) "README.md"))
    ;; Directory rows are reachable the same way; a recursive upload
    ;; restores onto one.
    (s3-manager--goto-key "images/")
    (should (equal (s3-manager-test--row-key-at-point) "images/"))))

(ert-deftest s3-manager-test-goto-key-leaves-point-alone-when-absent ()
  "A key that is not in the listing must not move point to the top.
An object can legitimately sort past the end of a truncated page, and
jerking point to `point-min' then is worse than leaving it where the
reprint put it -- which is what `s3-manager--goto-entry' would do."
  (s3-manager-test--in-object-buffer
    (s3-manager--goto-key "images/")
    (let ((before (point)))
      (s3-manager--goto-key "not-in-this-listing.txt")
      (should (= before (point)))
      (should (equal (s3-manager-test--row-key-at-point) "images/")))))

(ert-deftest s3-manager-test-goto-key-tolerates-a-bucket-list ()
  "Bucket-list ids are bare strings; the search must not assume entries."
  (with-temp-buffer
    (s3-manager-mode)
    (setq tabulated-list-format s3-manager--bucket-list-format)
    (tabulated-list-init-header)
    (let ((s3-manager--cache (make-hash-table :test #'equal)))
      (s3-manager--render-buckets (s3-manager-test--json "list-buckets.json")))
    (goto-char (point-min))
    (forward-line 1)                    ; row one is the column-title line
    (should (equal (tabulated-list-get-id) "media"))
    ;; No entry carries this key, so the search must walk the string ids
    ;; without signalling and must leave point exactly where it was.
    (let ((before (point)))
      (s3-manager--goto-key "media")
      (should (= before (point))))))

(ert-deftest s3-manager-test-reload-restores-point-by-key ()
  "`s3-manager--reload' accepts a key, and consumes it exactly once."
  (s3-manager-test--in-object-buffer
    (let ((s3-manager--cache (make-hash-table :test #'equal)))
      ;; Serve from the cache, so the reload needs no process.
      (s3-manager--cache-put (s3-manager--cache-key)
                             tabulated-list-entries s3-manager--entries nil)
      (goto-char (point-min))
      (s3-manager--reload nil "README.md")
      (should (equal (s3-manager-test--row-key-at-point) "README.md"))
      ;; Consumed: a later reload must not resurrect it.
      (should (null s3-manager--restore-key))
      (s3-manager--goto-key "images/")
      (s3-manager--reload)
      (should-not (equal (s3-manager-test--row-key-at-point) "README.md")))))

(ert-deftest s3-manager-test-reload-clears-a-stale-key-request ()
  "A reload with no key must cancel a key left over from an earlier one.
Both slots are set unconditionally so the newest reload owns them;
otherwise a request from a transfer that finished late would fire on an
unrelated listing."
  (s3-manager-test--in-object-buffer
    (let ((s3-manager--cache (make-hash-table :test #'equal)))
      (s3-manager--cache-put (s3-manager--cache-key)
                             tabulated-list-entries s3-manager--entries nil)
      (setq s3-manager--restore-key "README.md")
      (s3-manager--reload)
      (should (null s3-manager--restore-key)))))

(ert-deftest s3-manager-test-restore-target-wins-over-key ()
  "The exact entry is the stronger request when both are given."
  (s3-manager-test--in-object-buffer
    (let ((s3-manager--cache (make-hash-table :test #'equal))
          (target (s3-manager--directory-entry "images/" "")))
      (s3-manager--cache-put (s3-manager--cache-key)
                             tabulated-list-entries s3-manager--entries nil)
      (s3-manager--reload target "README.md")
      (should (equal (s3-manager-test--row-key-at-point) "images/")))))


;;;; Dry runs
;;
;; Characterisation tests, written against the behaviour as it stood before
;; the rendering was shared with the upload dry run.  They assert the
;; contract, not the implementation, so the extraction is provably a refactor
;; rather than an assertion that it was one.

(defun s3-manager-test--dry-run-text ()
  "Return the dry-run buffer's contents, or nil if it does not exist."
  (when-let* ((buffer (get-buffer "*S3 Manager Dry Run*")))
    (with-current-buffer buffer (buffer-string))))

(defmacro s3-manager-test--with-fresh-dry-run-buffer (&rest body)
  "Run BODY with no dry-run buffer present, and clean up afterwards."
  (declare (indent 0))
  `(progn
     (when (get-buffer "*S3 Manager Dry Run*")
       (kill-buffer "*S3 Manager Dry Run*"))
     (unwind-protect (progn ,@body)
       (when (get-buffer "*S3 Manager Dry Run*")
         (kill-buffer "*S3 Manager Dry Run*")))))

(ert-deftest s3-manager-test-delete-dry-run-argv ()
  "The preview must carry `--dryrun', or it is a recursive delete."
  (let ((argv-file (make-temp-file "s3-dryrun-argv")))
    (unwind-protect
        (s3-manager-test--with-fresh-dry-run-buffer
          (s3-manager-test--in-object-buffer
            (s3-manager-test--goto-directory)
            (cl-letf (((symbol-function 'display-buffer) #'ignore)
                      ((symbol-function 'message) #'ignore))
              (s3-manager-test--with-fake-aws
                  (:stdout "(dryrun) delete: s3://media/images/a.png\n"
                   :argv-file argv-file)
                (s3-manager-delete-recursive-dry-run)
                (should (s3-manager-test--wait
                         (lambda () (s3-manager-test--dry-run-text)))))))
          (should (equal (car (s3-manager-test--argv-records argv-file))
                         (list "--profile" "production"
                               "--no-cli-pager" "--no-cli-auto-prompt"
                               "s3" "rm" "s3://media/images/"
                               "--recursive" "--dryrun"))))
      (delete-file argv-file))))

(ert-deftest s3-manager-test-delete-dry-run-renders-the-output ()
  "The CLI's own lines are shown, under a heading naming the target."
  (s3-manager-test--with-fresh-dry-run-buffer
    (s3-manager-test--in-object-buffer
      (s3-manager-test--goto-directory)
      (cl-letf (((symbol-function 'display-buffer) #'ignore)
                ((symbol-function 'message) #'ignore))
        (s3-manager-test--with-fake-aws
            (:stdout "(dryrun) delete: s3://media/images/a.png\n(dryrun) delete: s3://media/images/b.png\n")
          (s3-manager-delete-recursive-dry-run)
          (should (s3-manager-test--wait
                   (lambda () (s3-manager-test--dry-run-text)))))))
    (let ((text (s3-manager-test--dry-run-text)))
      (should (string-match-p "Would delete under s3://media/images/" text))
      (should (string-match-p "a\\.png" text))
      (should (string-match-p "b\\.png" text)))
    (with-current-buffer "*S3 Manager Dry Run*"
      (should (derived-mode-p 'special-mode))
      (should (= (point) (point-min))))))

(ert-deftest s3-manager-test-delete-dry-run-empty-is-explicit ()
  "An empty result must say so rather than showing a blank buffer.
A blank buffer reads as a failure, and the difference matters when the
next keystroke would delete whatever this listed."
  (s3-manager-test--with-fresh-dry-run-buffer
    (s3-manager-test--in-object-buffer
      (s3-manager-test--goto-directory)
      (cl-letf (((symbol-function 'display-buffer) #'ignore)
                ((symbol-function 'message) #'ignore))
        (s3-manager-test--with-fake-aws (:stdout "   \n  ")
          (s3-manager-delete-recursive-dry-run)
          (should (s3-manager-test--wait
                   (lambda () (s3-manager-test--dry-run-text)))))))
    (should (string-match-p "(nothing)" (s3-manager-test--dry-run-text)))))

(ert-deftest s3-manager-test-delete-dry-run-replaces-previous-output ()
  "Two runs must not accumulate: a dry run has one current answer."
  (s3-manager-test--with-fresh-dry-run-buffer
    (s3-manager-test--in-object-buffer
      (cl-letf (((symbol-function 'display-buffer) #'ignore)
                ((symbol-function 'message) #'ignore))
        (s3-manager-test--goto-directory)
        (s3-manager-test--with-fake-aws (:stdout "first-answer\n")
          (s3-manager-delete-recursive-dry-run)
          (should (s3-manager-test--wait
                   (lambda () (s3-manager-test--dry-run-text)))))
        (s3-manager-test--with-fake-aws (:stdout "second-answer\n")
          (s3-manager-delete-recursive-dry-run)
          (should (s3-manager-test--wait
                   (lambda ()
                     (string-match-p "second-answer"
                                     (s3-manager-test--dry-run-text))))))))
    (let ((text (s3-manager-test--dry-run-text)))
      (should (string-match-p "second-answer" text))
      (should-not (string-match-p "first-answer" text)))))

(ert-deftest s3-manager-test-delete-dry-run-refuses-a-non-prefix ()
  "Only a prefix has anything to preview."
  (s3-manager-test--in-object-buffer
    (s3-manager-test--goto-object)
    (should-error (s3-manager-delete-recursive-dry-run) :type 'user-error))
  (with-temp-buffer
    (s3-manager-mode)
    (setq s3-manager--bucket nil)
    (should-error (s3-manager-delete-recursive-dry-run) :type 'user-error)))

(ert-deftest s3-manager-test-delete-dry-run-failure-is-reported ()
  "A failed preview reports rather than leaving a stale buffer on screen."
  (s3-manager-test--with-fresh-dry-run-buffer
    (s3-manager-test--with-fresh-error-buffer
      (s3-manager-test--in-object-buffer
        (s3-manager-test--goto-directory)
        (cl-letf (((symbol-function 'display-buffer) #'ignore)
                  ((symbol-function 'message) #'ignore))
          (s3-manager-test--with-fake-aws
              (:stderr "An error occurred (AccessDenied) when calling the ListObjectsV2 operation"
               :exit 254)
            (s3-manager-delete-recursive-dry-run)
            (should (s3-manager-test--wait
                     (lambda () (s3-manager-test--error-text)) 5)))))
      (should (string-match-p "AccessDenied" (s3-manager-test--error-text)))
      (should (string-match-p "s3 rm --dryrun" (s3-manager-test--error-text)))
      (should (null (s3-manager-test--dry-run-text))))))


;;;; Viewing

(ert-deftest s3-manager-test-view-file-name-cannot-escape ()
  "S3 keys may be or contain \"..\", which must not name a parent directory.

Building a temporary path from a key directly lets one escape the
directory it is meant to live in: `(expand-file-name \"../../etc/passwd\"
\"/tmp/root/\")' is \"/etc/passwd\"."
  (dolist (case '(("README.md" . "README.md")
                  ("a.tar.gz" . "a.tar.gz")
                  (".." . "s3-object")
                  ("." . "s3-object")
                  ("" . "s3-object")
                  ;; `expand-file-name' expands a leading tilde, so these
                  ;; would resolve to the user's home directory and to
                  ;; root's.  An object keyed "backups/~" is legal in S3.
                  ("~" . "s3-object")
                  ("~root" . "s3-object")
                  ;; Only the leaf is taken, so this reduces to "x", which
                  ;; is a plain name inside the view directory.
                  ("~/x" . "x")))
    (let ((entry (s3-manager-entry--create
                  :type 'object :key "k" :display-name (car case))))
      (should (equal (s3-manager--view-file-name entry) (cdr case)))))
  ;; Only the leaf is taken, so a separator in the name cannot reach past
  ;; the view directory: "a/../b" becomes the plain name "b".
  (let* ((entry (s3-manager-entry--create
                 :type 'object :key "k" :display-name "a/../b"))
         (name (s3-manager--view-file-name entry)))
    (should (equal name "b"))
    (should (equal (expand-file-name name "/tmp/root/") "/tmp/root/b"))))

(ert-deftest s3-manager-test-view-destination-is-inside-its-own-directory ()
  (let* ((s3-manager--view-pending nil)
         (entry (s3-manager-entry--create
                 :type 'object :key "x/README.md" :display-name "README.md"))
         (path (s3-manager--view-destination entry))
         (directory (file-name-directory path)))
    (unwind-protect
        (progn
          (should (equal (file-name-nondirectory path) "README.md"))
          (should (file-directory-p directory))
          (should (equal path (expand-file-name "README.md" directory)))
          ;; Registered for cleanup until a buffer takes it over.
          (should (member directory s3-manager--view-pending)))
      (ignore-errors (delete-directory directory t)))))

(ert-deftest s3-manager-test-view-destination-stays-inside-for-tilde-names ()
  "Even if the name guard were weakened, the path must not escape."
  (let* ((s3-manager--view-pending nil)
         (entry (s3-manager-entry--create
                 :type 'object :key "backups/~" :display-name "~"))
         (path (s3-manager--view-destination entry))
         (directory (file-name-directory path)))
    (unwind-protect
        (progn
          (should (string-prefix-p directory path))
          (should-not (equal path (expand-file-name "~"))))
      (ignore-errors (delete-directory directory t)))))

(ert-deftest s3-manager-test-percent-in-a-key-is-not-a-mode-line-spec ()
  "Header lines are format constructs, so a `%' in a key is interpreted."
  (should (equal (s3-manager--quote-percent "sale-50%-off.png")
                 "sale-50%%-off.png"))
  (should (equal (s3-manager--quote-percent "a%b.txt") "a%%b.txt"))
  (with-temp-buffer
    (s3-manager-mode)
    (setq s3-manager--profile "p" s3-manager--bucket "b"
          s3-manager--prefix "50%-off/")
    (s3-manager--update-header-line)
    (should (string-match-p "50%%-off/" header-line-format))))

(ert-deftest s3-manager-test-failed-view-releases-its-directory ()
  "A transfer that fails must not leave an empty view directory behind."
  (let ((s3-manager--view-pending nil))
    (s3-manager-test--in-many-buffer
      (s3-manager-test--goto-object)
      (cl-letf (((symbol-function 'message) #'ignore))
        (s3-manager-test--with-fake-aws (:stderr "fatal error: nope\\n" :exit 1)
          (s3-manager-view)
          (should (s3-manager-test--wait
                   (lambda () (zerop s3-manager--transfers))))))
      (should (null s3-manager--view-pending)))))

(ert-deftest s3-manager-test-pending-view-directories-are-swept ()
  "Killing the origin buffer mid-download suppresses both callbacks.
The sweep on `kill-emacs-hook' is the only thing left to recover it."
  (let* ((s3-manager--view-pending nil)
         (entry (s3-manager-entry--create
                 :type 'object :key "a.txt" :display-name "a.txt"))
         (path (s3-manager--view-destination entry))
         (directory (file-name-directory path)))
    (write-region "leaked object bytes\n" nil path nil 'silent)
    (should (file-exists-p path))
    (s3-manager--view-discard-all)
    (should-not (file-exists-p path))
    (should-not (file-directory-p directory))
    (should (null s3-manager--view-pending))))

(ert-deftest s3-manager-test-view-refuses-large-objects ()
  "RET is the most-pressed key and must never be unbounded."
  (s3-manager-test--in-many-buffer
    (let ((s3-manager-view-max-size 5))
      (s3-manager--goto-entry
       (car (seq-filter (lambda (e) (eq (s3-manager-entry-type e) 'object))
                        s3-manager--entries)))
      ;; a.txt is 10 bytes in the fixture, over the 5-byte limit here.
      (should-error (s3-manager-view) :type 'user-error)
      (should (zerop s3-manager--transfers)))))

(ert-deftest s3-manager-test-view-refuses-a-prefix ()
  (s3-manager-test--in-many-buffer
    (s3-manager--goto-entry (s3-manager--directory-entry "sub/" ""))
    (should-error (s3-manager-view) :type 'user-error)))

(ert-deftest s3-manager-test-view-refuses-in-the-bucket-list ()
  (with-temp-buffer
    (s3-manager-mode)
    (setq s3-manager--bucket nil)
    (should-error (s3-manager-view) :type 'user-error)))

(ert-deftest s3-manager-test-view-downloads-and-opens-read-only ()
  "The object is fetched to a private copy and shown read-only."
  (let ((argv-file (make-temp-file "s3-view-argv"))
        (view-buffer nil))
    (unwind-protect
        (s3-manager-test--in-many-buffer
          (s3-manager-test--goto-object)
          (cl-letf (((symbol-function 'pop-to-buffer-same-window)
                     (lambda (buffer &rest _) (setq view-buffer buffer)))
                    ((symbol-function 'message) #'ignore))
            ;; The double writes the object's contents to the destination
            ;; path, which is the last positional argument.
            (s3-manager-test--with-fake-aws (:stdout "" :argv-file argv-file)
              (cl-letf* ((original (symbol-function 's3-manager--transfer))
                         ((symbol-function 's3-manager--transfer)
                          (lambda (args description &optional on-done on-failure)
                            ;; Create the file the real CLI would have made.
                            (write-region "hello from s3\n" nil (nth 3 args)
                                          nil 'silent)
                            (funcall original args description
                                     on-done on-failure))))
                (s3-manager-view)
                (should (s3-manager-test--wait
                         (lambda () (buffer-live-p view-buffer)))))))
          (let ((argv (car (s3-manager-test--argv-records argv-file))))
            (should (member "s3://media/a.txt" argv))
            (should (member "cp" argv)))
          (with-current-buffer view-buffer
            (should buffer-read-only)
            (should (equal (buffer-string) "hello from s3\n"))
            (should (equal (buffer-name) "a.txt"))
            (should (string-match-p "s3://media/a\\.txt" header-line-format))
            (should s3-manager--view-file)))
      (when (buffer-live-p view-buffer) (kill-buffer view-buffer))
      (delete-file argv-file))))

(ert-deftest s3-manager-test-view-picks-a-major-mode-from-the-name ()
  "Visiting a real file is what buys normal mode detection.
The object keeps its own name, so `auto-mode-alist' applies as usual."
  (let* ((entry (s3-manager-entry--create
                 :type 'object :key "lib/thing.el" :display-name "thing.el"))
         (path (s3-manager--view-destination entry))
         (directory (file-name-directory path))
         (buffer nil))
    (unwind-protect
        (progn
          (write-region ";;; thing.el --- x\n(defun thing () nil)\n"
                        nil path nil 'silent)
          (cl-letf (((symbol-function 'pop-to-buffer-same-window)
                     (lambda (b &rest _) (setq buffer b))))
            (s3-manager--display-view path "s3://media/lib/thing.el"))
          (with-current-buffer buffer
            (should (eq major-mode 'emacs-lisp-mode))
            (should buffer-read-only)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (ignore-errors (delete-directory directory t)))))

(ert-deftest s3-manager-test-view-copy-is-removed-with-the-buffer ()
  "Downloaded object data must not be left lying in the temp directory.

Drives `s3-manager--display-view' rather than re-creating what it does:
setting the variable and adding the hook by hand would make the test
pass even if the production path stopped doing either -- which is the
regression it exists to catch."
  (let* ((s3-manager--view-pending nil)
         (entry (s3-manager-entry--create
                 :type 'object :key "a.txt" :display-name "a.txt"))
         (path (s3-manager--view-destination entry))
         (directory (file-name-directory path))
         (buffer nil))
    (write-region "data\n" nil path nil 'silent)
    (should (file-exists-p path))
    (cl-letf (((symbol-function 'pop-to-buffer-same-window)
               (lambda (b &rest _) (setq buffer b))))
      (s3-manager--display-view path "s3://media/a.txt"))
    ;; Ownership moved from the pending set to the buffer.
    (should (null s3-manager--view-pending))
    (kill-buffer buffer)
    (should-not (file-exists-p path))
    (should-not (file-directory-p directory))))

(ert-deftest s3-manager-test-ret-on-an-object-views-it ()
  "RET dispatches to viewing rather than reporting it unimplemented."
  (s3-manager-test--in-many-buffer
    (s3-manager-test--goto-object)
    (let ((called nil))
      (cl-letf (((symbol-function 's3-manager-view)
                 (lambda () (setq called t))))
        (s3-manager-open))
      (should called))))


;;;; Switching profile

(ert-deftest s3-manager-test-cache-purge-profile ()
  "Only the named profile's listings go."
  (s3-manager-test--with-clean-cache
    (dolist (key '(("a" nil "one" "") ("a" nil "two" "x/")
                   ("b" nil "one" "") ("b" nil "one" "y/")))
      (s3-manager--cache-put key nil nil nil))
    (should (= 2 (s3-manager--cache-purge-profile "a")))
    (should (null (s3-manager--cache-get '("a" nil "one" ""))))
    (should (s3-manager--cache-get '("b" nil "one" "")))
    (should (s3-manager--cache-get '("b" nil "one" "y/")))))

(ert-deftest s3-manager-test-switch-profile-opens-the-new-bucket-list ()
  (s3-manager-test--with-clean-profiles
    (setq s3-manager--profiles '("alpha" "beta"))
    (s3-manager-test--with-fake-aws (:stdout s3-manager-test--no-buckets-json)
      (let ((shown nil))
        (with-temp-buffer
          (s3-manager-mode)
          (setq s3-manager--profile "alpha")
          (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "beta"))
                    ((symbol-function 'pop-to-buffer-same-window)
                     (lambda (b &rest _) (setq shown b)))
                    ((symbol-function 'message) #'ignore))
            (s3-manager-switch-profile)))
        (should (bufferp shown))
        (should (equal (buffer-name shown) "*s3: beta*"))
        (with-current-buffer shown
          (should (equal s3-manager--profile "beta"))
          (should (null s3-manager--bucket))
          (should (s3-manager-test--wait
                   (lambda () (null s3-manager--status)))))
        (kill-buffer shown)))))

(ert-deftest s3-manager-test-switch-profile-purges-the-old-profile ()
  "Section 5.4's invalidation table promises this."
  (s3-manager-test--with-clean-profiles
    (setq s3-manager--profiles '("alpha" "beta"))
    (let ((s3-manager--cache (make-hash-table :test #'equal))
          (s3-manager-cache-max-entries 200)
          (shown nil))
      (dolist (key '(("alpha" nil "one" "") ("alpha" nil "one" "p/")
                     ("beta" nil "one" "")))
        (s3-manager--cache-put key nil nil nil))
      (with-temp-buffer
        (s3-manager-mode)
        (setq s3-manager--profile "alpha")
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "beta"))
                  ((symbol-function 's3-manager--bucket-buffer)
                   (lambda (&rest _) (current-buffer)))
                  ((symbol-function 'pop-to-buffer-same-window)
                   (lambda (b &rest _) (setq shown b)))
                  ((symbol-function 'message) #'ignore))
          (s3-manager-switch-profile)))
      (should (null (s3-manager--cache-get '("alpha" nil "one" ""))))
      (should (null (s3-manager--cache-get '("alpha" nil "one" "p/"))))
      ;; The profile switched to keeps whatever it had.
      (should (s3-manager--cache-get '("beta" nil "one" ""))))))

(ert-deftest s3-manager-test-switch-profile-to-the-same-one-keeps-the-cache ()
  (s3-manager-test--with-clean-profiles
    (setq s3-manager--profiles '("alpha"))
    (let ((s3-manager--cache (make-hash-table :test #'equal))
          (s3-manager-cache-max-entries 200))
      (s3-manager--cache-put '("alpha" nil "one" "") nil nil nil)
      (with-temp-buffer
        (s3-manager-mode)
        (setq s3-manager--profile "alpha")
        (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "alpha"))
                  ((symbol-function 's3-manager--bucket-buffer)
                   (lambda (&rest _) (current-buffer)))
                  ((symbol-function 'pop-to-buffer-same-window) #'ignore)
                  ((symbol-function 'message) #'ignore))
          (s3-manager-switch-profile)))
      (should (s3-manager--cache-get '("alpha" nil "one" ""))))))

(ert-deftest s3-manager-test-switch-profile-prefix-arg-rereads ()
  (s3-manager-test--with-clean-profiles
    (setq s3-manager--profiles '("stale"))
    (with-temp-buffer
      (s3-manager-mode)
      (cl-letf (((symbol-function 's3-manager-read-profile) #'ignore)
                ((symbol-function 's3-manager--check-version) #'ignore))
        (s3-manager-switch-profile t))
      (should (null s3-manager--profiles)))))

;;;; Source hygiene across the split

(defun s3-manager-test--source-files ()
  "Return the package's source files, or nil if they cannot be located."
  (when-let* ((dir (file-name-directory
                    (or (locate-library "s3-manager") ""))))
    (directory-files dir t "\\`s3-manager\\(-[a-z]+\\)?\\.el\\'")))

(ert-deftest s3-manager-test-no-accidental-file-local-variables ()
  "No source file may mention the file-local variables marker near its end.

Emacs scans the last 3000 characters of a file for that phrase, so a
comment about *disabling* it becomes a malformed declaration of it -- and
that is not hypothetical: splitting the package into smaller files moved
such a comment from the middle of a 2500-line file into the window, and
loading the result printed \"Local variables list is not properly
terminated\".  A test rather than a fixed comment, because the next split
would reintroduce it."
  (let ((files (s3-manager-test--source-files)))
    (skip-unless files)
    (dolist (file files)
      (let* ((text (with-temp-buffer
                     (insert-file-contents file)
                     (buffer-string)))
             (tail (substring text (max 0 (- (length text) 3000)))))
        (should-not
         (string-match-p (concat "[Ll]ocal " "[Vv]ariables:") tail))))))

(ert-deftest s3-manager-test-every-file-declares-lexical-binding ()
  "A missing cookie makes a file dynamically bound, silently."
  (let ((files (s3-manager-test--source-files)))
    (skip-unless files)
    (dolist (file files)
      (with-temp-buffer
        (insert-file-contents file nil 0 200)
        (should (string-match-p "lexical-binding: t" (buffer-string)))))))


;;;; Evil interoperability

;; Evil is not a dependency of the package -- these tests skip themselves when
;; it is absent, and are tagged so a hermetic run can exclude them.  The Eask
;; manifest lists it as a development dependency so CI does exercise them.

(defmacro s3-manager-test--with-evil-buffer (state &rest body)
  "Run BODY in an `s3-manager-mode' buffer under Evil in STATE.
Enables `evil-local-mode' rather than the global `evil-mode', so the rest
of the suite is unaffected by having run this one."
  (declare (indent 1))
  `(with-temp-buffer
     (s3-manager-mode)
     (evil-local-mode 1)
     (evil-change-state ,state)
     (evil-normalize-keymaps)
     ,@body))

(defun s3-manager-test--evil-shadowed-keys (state)
  "Return the keys of `s3-manager-mode-map' Evil steals in STATE."
  (s3-manager-test--with-evil-buffer state
    (seq-remove
     (lambda (key)
       (let ((command (key-binding (kbd key))))
         (and command
              (symbolp command)
              (string-prefix-p "s3-manager-" (symbol-name command)))))
     '("RET" "^" "g" "+" "G" "R" "d" "u" "U" "x" "D"))))

(ert-deftest s3-manager-test-evil-does-not-shadow-the-keymap ()
  "Every key this mode binds must survive Evil, in every state.

Evil installs its state keymaps through `emulation-mode-map-alists', which
outranks a major-mode map, and this mode appears in none of Evil's state
lists -- so it gets normal state, where `RET' is `evil-ret', `d' is
`evil-delete' and `g' is a prefix keymap.  Without the overriding-map
registration in the package, this test reports nine of the eleven keys as
shadowed and the browser is unusable under Evil."
  :tags '(evil)
  (skip-unless (ignore-errors (require 'evil nil t)))
  (dolist (state '(normal motion visual))
    (should (equal nil (s3-manager-test--evil-shadowed-keys state)))))

(ert-deftest s3-manager-test-evil-keeps-its-own-unbound-keys ()
  "Registering the map as overriding must not disable Evil wholesale.
Only the keys this mode actually binds may be taken; motion and `:' are
Evil's and must still reach it, or the fix trades one broken keymap for
another."
  :tags '(evil)
  (skip-unless (ignore-errors (require 'evil nil t)))
  (s3-manager-test--with-evil-buffer 'normal
    (should (eq (key-binding (kbd "j")) #'evil-next-line))
    (should (eq (key-binding (kbd "k")) #'evil-previous-line))
    (should (eq (key-binding (kbd ":")) #'evil-ex))
    ;; Inherited from the parent maps, and equally required by the manual.
    (should (eq (key-binding (kbd "n")) #'next-line))
    (should (eq (key-binding (kbd "p")) #'previous-line))
    (should (eq (key-binding (kbd "q")) #'quit-window))))

(ert-deftest s3-manager-test-evil-user-bindings-still-win ()
  "A user's own Evil binding must outrank the package's override.
`evil-make-overriding-map' ranks below custom state bindings; if that ever
changed, personal configuration would silently stop taking effect."
  :tags '(evil)
  (skip-unless (ignore-errors (require 'evil nil t)))
  (let ((map (copy-keymap s3-manager-mode-map)))
    (unwind-protect
        (progn
          (evil-define-key 'normal s3-manager-mode-map (kbd "RET") #'ignore)
          (s3-manager-test--with-evil-buffer 'normal
            (should (eq (key-binding (kbd "RET")) #'ignore))))
      (setq s3-manager-mode-map map)
      ;; `evil-define-key' caches an auxiliary keymap inside the map it was
      ;; given; drop Evil's copy of it too so later tests see a clean map.
      (evil-normalize-keymaps))))

(provide 's3-manager-test)

;;; s3-manager-test.el ends here
