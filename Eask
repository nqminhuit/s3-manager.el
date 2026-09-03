;; -*- mode: eask; lexical-binding: t -*-

(package "s3-manager" "0.1.0" "Manage S3 objects from Emacs")

(website-url "https://github.com/nqminhuit/s3-manager.el")
(keywords "tools" "convenience")

(package-file "s3-manager.el")
(files "s3-manager.el")

(script "test" "eask test ert ./test/s3-manager-test.el")

(source "gnu")
;; For the Evil integration tests only -- Evil comes from NonGNU ELPA.
(source "nongnu")

(depends-on "emacs" "29.1")

;; The package itself depends on nothing but Emacs.  Evil is a test-only
;; dependency: the mode's keymap has to be registered as overriding or Evil's
;; normal state swallows it, and that is worth verifying rather than assuming.
(development
 (depends-on "evil"))

;; The package has no third-party dependencies, so a warning is always our own
;; defect rather than an upstream one.
(setq byte-compile-error-on-warn t)
