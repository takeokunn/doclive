;;; snapshot.el --- Benchmark doclive Org snapshots -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; See the snapshot benchmark section in README.org for usage.

;;; Code:

(progn
  (require (quote benchmark))
  (require (quote doclive))

  (defconst doclive-benchmark-input-bytes (* 100 1024)
    "Approximate size of the generated Org benchmark document.")

  (defconst doclive-benchmark-refresh-iterations 20
    "Number of unchanged snapshots measured by the benchmark.")

  (defun doclive-benchmark--fill-org-buffer ()
    "Fill the current buffer with deterministic Org benchmark input."
    (let ((index 0))
      (while (< (buffer-size) doclive-benchmark-input-bytes)
        (setq index (1+ index))
        (insert (format "* Section %04d\nA deterministic paragraph with *bold*, /italic/, and [[https://example.com][a link]].\n\n" index))))
    (org-mode))

  (defun doclive-benchmark-run ()
    "Measure initial Org export and unchanged snapshot refreshes."
    (let ((doclive--buffers (make-hash-table :test (quote equal)))
          (doclive--sse-clients (make-hash-table :test (quote equal)))
          (doclive--buffer-id-token-function (lambda () "benchmark-buffer"))
          (buffer (generate-new-buffer " *doclive-snapshot-benchmark*")))
      (unwind-protect
          (with-current-buffer buffer
            (doclive-benchmark--fill-org-buffer)
            (let* ((input-bytes (buffer-size))
                   (initial (benchmark-run 1
                              (doclive--snapshot-buffer buffer)))
                   (refresh (benchmark-run doclive-benchmark-refresh-iterations
                              (doclive--snapshot-buffer buffer))))
              (princ (format "input-bytes: %d\n" input-bytes))
              (princ (format "emacs-version: %s\n" emacs-version))
              (princ (format "org-version: %s\n" (org-version)))
              (princ (format "refresh-iterations: %d\n"
                             doclive-benchmark-refresh-iterations))
              (princ (format "initial-elapsed-seconds: %.6f\n" (car initial)))
              (princ (format "refresh-total-seconds: %.6f\n" (car refresh)))
              (princ (format "refresh-mean-seconds: %.9f\n"
                             (/ (car refresh)
                                (float doclive-benchmark-refresh-iterations))))))
        (when (buffer-live-p buffer)
          (kill-buffer buffer)))))

  (doclive-benchmark-run))

;;; snapshot.el ends here
