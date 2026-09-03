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
    ((&key stdout stderr (exit 0) delay argv-file) &rest body)
  "Run BODY with the AWS CLI replaced by the test double.
STDOUT, STDERR, EXIT and DELAY drive the double's behaviour; ARGV-FILE,
when given, is a file the double writes its arguments to."
  (declare (indent 1))
  `(let* ((s3-manager-aws-program s3-manager-test--fake-aws)
          (s3-manager-timeout 10)
          (process-environment
           (append (list (concat "FAKE_AWS_STDOUT=" (or ,stdout ""))
                         (concat "FAKE_AWS_STDERR=" (or ,stderr ""))
                         (format "FAKE_AWS_EXIT=%s" ,exit)
                         (concat "FAKE_AWS_DELAY=" (or ,delay ""))
                         (concat "FAKE_AWS_ARGV_FILE=" (or ,argv-file "")))
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

(ert-deftest s3-manager-test-transport-interrupt-is-silent ()
  "Exit 130 is our own cancellation; it must not surface as an error."
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

(provide 's3-manager-test)

;;; s3-manager-test.el ends here
