;;; doclive-test-helpers.el --- Test helpers for doclive -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'json)

(defun doclive-test--with-temp-markdown-file (contents fn)
  "Create temporary markdown file with CONTENTS and call FN with path."
  (let ((file (make-temp-file "doclive-" nil ".md")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert contents))
          (funcall fn file))
      (when (file-exists-p file)
        (delete-file file)))))

(defun doclive-test--with-temp-org-file (contents fn)
  "Create temporary Org file with CONTENTS and call FN with path."
  (let ((file (make-temp-file "doclive-" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert contents))
          (funcall fn file))
      (when (file-exists-p file)
        (delete-file file)))))

(defun doclive-test--with-temp-linked-files (files fn)
  "Create FILES in a temporary directory and call FN with that directory.
FILES is an alist of relative file names to contents."
  (let ((dir (make-temp-file "doclive-links-" t)))
    (unwind-protect
        (progn
          (dolist (file files)
            (let ((path (expand-file-name (car file) dir)))
              (make-directory (file-name-directory path) t)
              (with-temp-file path
                (insert (cdr file)))))
          (funcall fn dir))
      (when (file-directory-p dir)
        (delete-directory dir t)))))

(defun doclive-test--json-plist (json)
  "Parse JSON string to plist."
  (json-parse-string json :object-type 'plist))

(provide 'doclive-test-helpers)

;;; doclive-test-helpers.el ends here
