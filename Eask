;; -*- mode: eask; lexical-binding: t -*-

(package "s3-manager" "0.4.0" "Manage S3 objects from Emacs")

(website-url "https://github.com/nqminhuit/s3-manager.el")
(keywords "tools" "convenience")

(package-file "s3-manager.el")
;; Every file, not just the entry point: the package is loaded through
;; `s3-manager.el', which requires the rest.
(files "s3-manager*.el")

(script "test" "eask test ert ./test/s3-manager-test.el")

(source "gnu")

(depends-on "emacs" "29.1")

;; The package has no third-party dependencies, so a warning is always our own
;; defect rather than an upstream one.
(setq byte-compile-error-on-warn t)
