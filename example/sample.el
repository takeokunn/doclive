;;; sample.el --- doclive sample -*- lexical-binding: t; -*-

;; Usage:
;; emacs -Q -l example/sample.el

(let* ((sample-directory (file-name-directory (or load-file-name buffer-file-name)))
       (project-directory (expand-file-name ".." sample-directory)))
  (add-to-list 'load-path project-directory))
(let ((load-prefer-newer t))
  (require 'doclive))

(let ((sample-file (expand-file-name "sample.org" (file-name-directory (or load-file-name buffer-file-name)))))
  (find-file sample-file)
  (doclive-preview-buffer))
