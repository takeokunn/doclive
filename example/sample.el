;;; sample.el --- md-live sample -*- lexical-binding: t; -*-

;; Usage:
;; emacs -Q -l sample.el

(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'md-live)

(let ((sample-file (expand-file-name "sample.org" (file-name-directory (or load-file-name buffer-file-name)))))
  (find-file sample-file)
  (md-live-preview-buffer))
