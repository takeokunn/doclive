;;; doclive-test.el --- Tests for doclive -*- lexical-binding: t; -*-

;; Author: takeokunn

;;; Commentary:

;; Comprehensive test suite for doclive covering:
;; - Buffer identity and state tracking
;; - Markdown / Org JSON schema
;; - Org export safety and Babel non-execution
;; - Local linked document resolver behavior
;; - Preview HTML runtime hooks
;; - HTTP request parsing helpers

;;; Code:

(setq load-prefer-newer t)

(require 'cl-lib)
(require 'ert)
(require 'doclive)
(require 'doclive-test-helpers)

(defun doclive-test--markdown-snapshot-object ()
  "Return a JSON plist for a sample Markdown snapshot."
  (let ((f "/tmp/doclive-json.md"))
    (with-temp-buffer
      (setq buffer-file-name f)
      (insert "# Hello\n")
      (let* ((entry (doclive--snapshot-buffer (current-buffer)))
             (id (plist-get entry :id))
             (raw (doclive--json-for-id id))
              (obj (json-parse-string raw :object-type 'plist)))
        (list id (buffer-name (current-buffer)) obj)))))

(defun doclive-test--doclive-source ()
  "Return the contents of doclive.el."
  (let ((file (expand-file-name "doclive.el" default-directory)))
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

(defun doclive-test--commentary-section ()
  "Return the Commentary section from doclive.el."
  (with-temp-buffer
    (insert (doclive-test--doclive-source))
    (goto-char (point-min))
    (when (re-search-forward "^;;; Commentary:\n" nil t)
      (let ((beg (point)))
        (when (re-search-forward "^;;; Code:" nil t)
          (buffer-substring-no-properties beg (match-beginning 0)))))))

(defun doclive-test--preview-mode-source-docstring ()
  "Return the source docstring for `doclive-preview-mode'."
  (let ((source (doclive-test--doclive-source)))
    (when (string-match "(define-minor-mode doclive-preview-mode[[:space:]\n]+\"\\([^\"]+\\)\""
                        source)
      (match-string 1 source))))

;; Package metadata / documentation quality

(ert-deftest doclive-test-package-headers-use-specific-maintainers ()
  "Package headers should not use generic contributor placeholders."
  (let ((source (doclive-test--doclive-source)))
    (should-not (string-match-p (regexp-quote ";; Author: doclive contributors") source))
    (should-not (string-match-p (regexp-quote ";; Maintainer: doclive contributors") source))))

(ert-deftest doclive-test-commentary-section-describes-package ()
  "Commentary should contain a meaningful package description."
  (let* ((commentary (doclive-test--commentary-section))
         (lines (and commentary (split-string commentary "\n" t "[[:space:];]+"))))
    (should (stringp commentary))
    (should (> (length lines) 3))
    (should (string-match-p "live preview of Markdown and Org documents" commentary))
    (should (string-match-p "Server-Sent Events" commentary))))

(ert-deftest doclive-test-preview-mode-docstring-is-multiline ()
  "Preview mode docstring should explain behavior beyond one line."
  (let ((docstring (doclive-test--preview-mode-source-docstring)))
    (should (stringp docstring))
    (should (> (length (split-string docstring "\n" t)) 1))
    (should (string-match-p "preview" docstring))))

;; Buffer identity / state

(ert-deftest doclive-test-buffer-id-stable ()
  "Buffer ID should be stable for same file path."
  (let ((f "/tmp/doclive-id.md"))
    (with-temp-buffer
      (setq buffer-file-name f)
      (let ((id1 (doclive--buffer-id (current-buffer)))
            (id2 (doclive--buffer-id (current-buffer))))
        (should (stringp id1))
        (should (string= id1 id2))))))

;; JSON schema

(ert-deftest doclive-test-snapshot-json ()
  "Snapshot should be reflected in Markdown JSON payload."
  (pcase-let ((`(,id ,name ,obj) (doclive-test--markdown-snapshot-object)))
    (should (eq (plist-get obj :ok) t))
    (should (equal (plist-get obj :buffer_id) id))
    (should (equal (plist-get obj :name) name))
    (should (equal (plist-get obj :contentKind) "markdown"))
    (should (string-match-p "Hello" (plist-get obj :markdown)))
    (should-not (plist-member obj :file))
    (should-not (plist-member obj :html))))

(ert-deftest doclive-test-snapshot-json-markdown-content-kind ()
  "Markdown snapshots should use the markdown contentKind discriminator."
  (pcase-let ((`(,_id ,_name ,obj) (doclive-test--markdown-snapshot-object)))
    (should (equal (plist-get obj :contentKind) "markdown"))
    (should (string-match-p "# Hello" (plist-get obj :markdown)))))

(ert-deftest doclive-test-json-unknown-id ()
  "Unknown buffer ID should return an error payload."
  (let* ((raw (doclive--json-for-id "no-such-id"))
         (obj (doclive-test--json-plist raw)))
    (should (eq (plist-get obj :ok) :false))
    (should (stringp (plist-get obj :error)))))

(ert-deftest doclive-test-escape-html-pins-current-entities ()
  "HTML escaping should pin core entity replacements."
  (should (equal (doclive--escape-html "&") "&amp;"))
  (should (equal (doclive--escape-html "<") "&lt;"))
  (should (equal (doclive--escape-html ">") "&gt;"))
  (should (equal (doclive--escape-html "\"") "&quot;")))

(ert-deftest doclive-test-escape-html-attribute-escapes-single-quotes ()
  "HTML attribute escaping should also escape single quotes."
  (should (equal (doclive--escape-html-attribute "'&<>\"")
                 "&#39;&amp;&lt;&gt;&quot;")))

;; Org export safety

(ert-deftest doclive-test-org-snapshot-json ()
  "Org snapshots should export to an HTML fragment payload."
  (doclive-test--with-temp-org-file
   "#+TITLE: Org Fixture\n\n* Heading\n\n- item\n\n#+begin_src mermaid\ngraph TD; A-->B;\n#+end_src\n"
   (lambda (f)
     (let ((buf (find-file-noselect f)))
       (unwind-protect
           (let* ((entry (doclive--snapshot-buffer buf))
                  (id (plist-get entry :id))
                  (raw (doclive--json-for-id id))
                  (obj (doclive-test--json-plist raw))
                  (html (plist-get obj :html)))
             (should (eq (plist-get obj :ok) t))
             (should (equal (plist-get obj :contentKind) "org-html"))
             (should (stringp html))
             (should (string-match-p "Heading" html))
             (should (string-match-p "src-mermaid" html))
             (should-not (plist-member obj :markdown)))
         (when (buffer-live-p buf)
           (kill-buffer buf)))))))

(ert-deftest doclive-test-org-babel-not-executed ()
  "Org export should not execute Babel source blocks."
  (let ((side-effect (make-temp-file "doclive-babel-side-effect-")))
    (delete-file side-effect)
    (unwind-protect
        (doclive-test--with-temp-org-file
         (format "#+TITLE: Safe\n\n* Block\n\n#+begin_src emacs-lisp :results file\n(with-temp-file %S (insert \"boom\"))\n#+end_src\n"
                 side-effect)
         (lambda (f)
           (let ((buf (find-file-noselect f)))
             (unwind-protect
                 (progn
                   (doclive--snapshot-buffer buf)
                   (should-not (file-exists-p side-effect)))
                (when (buffer-live-p buf)
                  (kill-buffer buf))))))
      (when (file-exists-p side-effect)
        (delete-file side-effect)))))

(ert-deftest doclive-test-org-export-allows-unsafe-html-fixture ()
  "Org export can emit raw HTML that the browser runtime must sanitize."
  (let ((html (doclive--org-to-html
               "#+TITLE: Unsafe\n\n#+begin_export html\n<script>alert(1)</script>\n<iframe src='javascript:alert(1)'></iframe>\n<a href='javascript:alert(1)' onclick='boom()'>bad</a>\n#+end_export\n")))
    (should (string-match-p "<script>alert(1)</script>" html))
    (should (string-match-p "<iframe src='javascript:alert(1)'></iframe>" html))
    (should (string-match-p "onclick='boom\(\)'" html))))

;; Link resolver

(ert-deftest doclive-test-open-linked-markdown ()
  "Linked markdown endpoint helper should resolve and open target file."
  (doclive-test--with-temp-linked-files
   '(("a.md" . "# A\n\n[go](b.md)\n")
     ("b.md" . "# B\n"))
   (lambda (dir)
     (let ((buf (find-file-noselect (expand-file-name "a.md" dir))))
       (unwind-protect
           (let* ((_entry (doclive--snapshot-buffer buf))
                  (id (doclive--buffer-id buf))
                  (raw (doclive--open-linked-document id "b.md"))
                  (obj (doclive-test--json-plist raw)))
             (should (eq (plist-get obj :ok) t))
             (should (stringp (plist-get obj :buffer_id))))
         (when (buffer-live-p buf)
           (kill-buffer buf)))))))

(ert-deftest doclive-test-open-linked-org ()
  "Markdown links to Org documents should open successfully."
  (doclive-test--with-temp-linked-files
   '(("source.md" . "# Source\n\n[org](target.org#Heading)\n")
     ("target.org" . "#+TITLE: Target\n\n* Heading\n"))
   (lambda (dir)
     (let ((buf (find-file-noselect (expand-file-name "source.md" dir))))
       (unwind-protect
           (let* ((_entry (doclive--snapshot-buffer buf))
                  (id (doclive--buffer-id buf))
                  (raw (doclive--open-linked-document id "target.org#Heading"))
                  (obj (doclive-test--json-plist raw)))
             (should (eq (plist-get obj :ok) t))
             (should (stringp (plist-get obj :buffer_id))))
         (when (buffer-live-p buf)
           (kill-buffer buf)))))))

(ert-deftest doclive-test-open-linked-markdown-from-org ()
  "Org links to Markdown documents should open successfully."
  (doclive-test--with-temp-linked-files
   '(("source.org" . "#+TITLE: Source\n\n[[file:target.md][Markdown]]\n")
     ("target.md" . "# Target\n"))
   (lambda (dir)
     (let ((buf (find-file-noselect (expand-file-name "source.org" dir))))
       (unwind-protect
           (let* ((_entry (doclive--snapshot-buffer buf))
                  (id (doclive--buffer-id buf))
                  (raw (doclive--open-linked-document id "target.md?x=y#top"))
                  (obj (doclive-test--json-plist raw)))
             (should (eq (plist-get obj :ok) t))
             (should (stringp (plist-get obj :buffer_id))))
         (when (buffer-live-p buf)
           (kill-buffer buf)))))))

(ert-deftest doclive-test-open-linked-org-from-org ()
  "Org links to Org documents should open successfully."
  (doclive-test--with-temp-linked-files
   '(("source.org" . "#+TITLE: Source\n\n[[file:target.org][Org]]\n")
     ("target.org" . "#+TITLE: Target\n\n* Target\n"))
   (lambda (dir)
     (let ((buf (find-file-noselect (expand-file-name "source.org" dir))))
       (unwind-protect
           (let* ((_entry (doclive--snapshot-buffer buf))
                  (id (doclive--buffer-id buf))
                  (raw (doclive--open-linked-document id "target.org"))
                  (obj (doclive-test--json-plist raw)))
             (should (eq (plist-get obj :ok) t))
             (should (stringp (plist-get obj :buffer_id))))
         (when (buffer-live-p buf)
           (kill-buffer buf)))))))

(ert-deftest doclive-test-open-linked-org-via-html-target ()
  "Org-exported HTML links should resolve back to their source document."
  (doclive-test--with-temp-linked-files
   '(("source.org" . "#+TITLE: Source\n\n[[file:target.org][Org]]\n")
     ("target.org" . "#+TITLE: Target\n\n* Target\n")
     ("target.html" . "<p>Exported</p>\n"))
   (lambda (dir)
     (let ((buf (find-file-noselect (expand-file-name "source.org" dir))))
       (unwind-protect
           (let* ((_entry (doclive--snapshot-buffer buf))
                  (id (doclive--buffer-id buf))
                  (raw (doclive--open-linked-document id "target.html"))
                  (obj (doclive-test--json-plist raw)))
             (should (eq (plist-get obj :ok) t))
             (should (stringp (plist-get obj :buffer_id))))
         (when (buffer-live-p buf)
           (kill-buffer buf)))))))

(ert-deftest doclive-test-linked-document-resolves-html-to-source ()
  "HTML links should map back to the nearest source document."
  (doclive-test--with-temp-linked-files
   '(("source.org" . "#+TITLE: Source\n\n[[file:target.org][Org]]\n")
     ("target.org" . "#+TITLE: Target\n\n* Target\n")
     ("target.md" . "# Target\n")
     ("target.html" . "<p>Exported</p>\n"))
   (lambda (dir)
     (let* ((buf (find-file-noselect (expand-file-name "source.org" dir)))
            (entry (doclive--snapshot-buffer buf))
            (resolved (doclive--resolve-linked-document entry "target.html")))
       (unwind-protect
           (should (equal resolved (expand-file-name "target.org" dir)))
         (when (buffer-live-p buf)
           (kill-buffer buf)))))))

(ert-deftest doclive-test-open-linked-markdown-not-found ()
  "Opening a missing linked document should fail cleanly."
  (doclive-test--with-temp-markdown-file
   "# A\n\n[go](missing.md)\n"
   (lambda (f)
     (let ((buf (find-file-noselect f)))
       (unwind-protect
           (let* ((_entry (doclive--snapshot-buffer buf))
                  (id (doclive--buffer-id buf))
                  (raw (doclive--open-linked-document id "missing.md"))
                  (obj (doclive-test--json-plist raw)))
             (should (eq (plist-get obj :ok) :false))
             (should (string-match-p "linked document" (plist-get obj :error))))
         (when (buffer-live-p buf)
           (kill-buffer buf)))))))

(ert-deftest doclive-test-linked-document-rejects-unsupported ()
  "Resolver should reject unsupported extensions and remote URLs."
  (doclive-test--with-temp-linked-files
   '(("source.md" . "# Source\n")
     ("target.el" . "(message \"no\")\n")
     ("target.html" . "<h1>No</h1>\n")
     ("target.org" . "#+TITLE: OK\n"))
   (lambda (dir)
     (let* ((buf (find-file-noselect (expand-file-name "source.md" dir)))
            (entry (doclive--snapshot-buffer buf)))
       (unwind-protect
           (progn
             (should-not (doclive--resolve-linked-document entry "target.el"))
             (should-not (doclive--resolve-linked-document entry "orphan.html"))
             (should-not (doclive--resolve-linked-document entry "https://example.com/target.md"))
             (should-not (doclive--resolve-linked-document entry "//example.com/target.md"))
             (should-not (doclive--resolve-linked-document entry "file:target.md"))
             (should-not (doclive--resolve-linked-document entry "/tmp/target.md"))
             (should-not (doclive--resolve-linked-document entry "subdir\\target.md"))
             (should-not (doclive--resolve-linked-document entry "target.md\n"))
             (should (doclive--resolve-linked-document entry "target.org?x=y#heading")))
         (when (buffer-live-p buf)
           (kill-buffer buf)))))))

(ert-deftest doclive-test-linked-document-rejects-non-regular-targets ()
  "Resolver should not open directories masquerading as documents."
  (doclive-test--with-temp-linked-files
   '(("source.md" . "# Source\n"))
   (lambda (dir)
     (let* ((target (expand-file-name "target.md" dir))
            (html-source (expand-file-name "exported.org" dir))
            (buf (find-file-noselect (expand-file-name "source.md" dir)))
            (entry (doclive--snapshot-buffer buf)))
       (make-directory target)
       (make-directory html-source)
       (unwind-protect
           (progn
             (should-not (doclive--resolve-linked-document entry "target.md"))
             (should-not (doclive--resolve-linked-document entry "exported.html")))
         (when (buffer-live-p buf)
           (kill-buffer buf)))))))

(ert-deftest doclive-test-linked-document-stays-under-source-directory ()
  "Resolver should reject parent-directory traversal by default."
  (doclive-test--with-temp-linked-files
   '(("docs/source.md" . "# Source\n")
     ("docs/target.md" . "# Target\n")
     ("secret.md" . "# Secret\n"))
   (lambda (dir)
     (let* ((buf (find-file-noselect (expand-file-name "docs/source.md" dir)))
            (entry (doclive--snapshot-buffer buf)))
       (unwind-protect
           (progn
             (should (doclive--resolve-linked-document entry "target.md"))
             (should-not (doclive--resolve-linked-document entry "../secret.md"))
             (let ((doclive-allow-linked-document-parent-directory t))
               (should (doclive--resolve-linked-document entry "../secret.md"))))
         (when (buffer-live-p buf)
           (kill-buffer buf)))))))

(ert-deftest doclive-test-supported-document-file-p ()
  "Supported document check should allow only Markdown and Org files."
  (should (doclive--supported-document-file-p "README.md"))
  (should (doclive--supported-document-file-p "notes.ORG"))
  (should-not (doclive--supported-document-file-p "init.el"))
  (should-not (doclive--supported-document-file-p "README")))

(ert-deftest doclive-test-open-linked-document-disables-local-eval ()
  "Linked document opening should disable local variables and eval."
  (let ((seen-enable-local-variables :unset)
        (seen-enable-local-eval :unset)
        (opened-buf nil)
        (file "/tmp/doclive-linked-target.md"))
    (with-temp-file file
      (insert "# Target\n"))
    (let ((real-get-entry (symbol-function 'doclive--get-entry))
          (real-find-file-noselect (symbol-function 'find-file-noselect)))
      (cl-letf (((symbol-function 'doclive--get-entry)
                 (lambda (id)
                   (if (equal id "fake-id")
                       '(:file "/tmp/doclive-linked-source.md")
                     (funcall real-get-entry id))))
                ((symbol-function 'doclive--resolve-linked-document)
                 (lambda (_entry _rel) file))
                ((symbol-function 'find-file-noselect)
                 (lambda (path &rest args)
                   (setq seen-enable-local-variables enable-local-variables
                         seen-enable-local-eval enable-local-eval)
                   (setq opened-buf (apply real-find-file-noselect path args))
                   opened-buf)))
        (unwind-protect
            (progn
              (let* ((raw (doclive--open-linked-document "fake-id" "target.md"))
                     (obj (doclive-test--json-plist raw)))
                (should (eq (plist-get obj :ok) t))
                (should (stringp (plist-get obj :buffer_id)))
                (should (equal seen-enable-local-variables nil))
                (should (equal seen-enable-local-eval nil))))
          (when (buffer-live-p opened-buf)
            (kill-buffer opened-buf))
          (when (file-exists-p file)
            (delete-file file)))))))

;; Preview HTML runtime hooks

(ert-deftest doclive-test-open-url-prefers-xwidget ()
  "URL opener should use xwidget WebKit when available."
  (let ((opened nil)
        (external-opened nil))
    (cl-letf (((symbol-function 'doclive-xwidget-available-p)
               (lambda () t))
              ((symbol-function 'doclive-open-url-in-xwidget)
               (lambda (url) (setq opened url)))
              ((symbol-function 'browse-url)
               (lambda (url &rest _) (setq external-opened url))))
      (doclive-open-url "http://127.0.0.1:39123/preview?id=abc"))
    (should (equal opened "http://127.0.0.1:39123/preview?id=abc"))
    (should-not external-opened)))

(ert-deftest doclive-test-open-url-falls-back-to-browse-url ()
  "URL opener should fall back to browse-url when xwidget is unavailable."
  (let ((opened nil))
    (cl-letf (((symbol-function 'doclive-xwidget-available-p)
               (lambda () nil))
              ((symbol-function 'browse-url)
               (lambda (url &rest _) (setq opened url))))
      (doclive-open-url "http://127.0.0.1:39123/preview?id=abc"))
    (should (equal opened "http://127.0.0.1:39123/preview?id=abc"))))

(ert-deftest doclive-test-preview-html-includes-core-hooks ()
  "Preview HTML should contain core runtime hooks."
  (let ((html (doclive--preview-html)))
    (should (string-match-p "EventSource" html))
    (should (string-match-p "function pushNav" html))
    (should (string-match-p "mermaid" html))
    (should (string-match-p "katex" (downcase html)))))

(ert-deftest doclive-test-preview-html-disables-referrers ()
  "Preview HTML should prevent token-bearing URLs from leaking as referrers."
  (let ((html (doclive--preview-html)))
    (should (string-match-p
             (regexp-quote "<meta name='referrer' content='no-referrer'>")
             html))))

(ert-deftest doclive-test-preview-html-includes-expected-libraries ()
  "Preview HTML should include the expected browser preview libraries."
  (let ((html (doclive--preview-html)))
    (should (string-match-p "mermaid" html))
    (should (string-match-p "katex" (downcase html)))
    (should (string-match-p "highlight.js" html))
    (should (string-match-p "marked" html))
    (should (string-match-p "EventSource" html))))

(ert-deftest doclive-test-preview-html-honors-asset-overrides ()
  "Preview HTML should use overridden asset URLs from customization."
  (let ((doclive-preview-asset-urls
         '((highlight-css . "https://example.invalid/highlight.css")
           (katex-css . "https://example.invalid/katex.css")
           (marked-script . "https://example.invalid/marked.js")
           (highlight-script . "https://example.invalid/highlight.js")
           (katex-script . "https://example.invalid/katex.js")
           (katex-auto-render-script . "https://example.invalid/auto-render.js")
           (mermaid-script . "https://example.invalid/mermaid.js"))))
    (let ((html (doclive--preview-html)))
      (should (string-match-p (regexp-quote "https://example.invalid/highlight.css") html))
      (should (string-match-p (regexp-quote "https://example.invalid/katex.css") html))
      (should (string-match-p (regexp-quote "https://example.invalid/marked.js") html))
      (should (string-match-p (regexp-quote "https://example.invalid/highlight.js") html))
      (should (string-match-p (regexp-quote "https://example.invalid/katex.js") html))
      (should (string-match-p (regexp-quote "https://example.invalid/auto-render.js") html))
      (should (string-match-p (regexp-quote "https://example.invalid/mermaid.js") html))
      (should-not (string-match-p "cdnjs.cloudflare.com" html))
      (should-not (string-match-p "cdn.jsdelivr.net" html)))))

(ert-deftest doclive-test-preview-html-escapes-asset-overrides ()
  "Preview HTML should escape customized asset URLs before HTML embedding."
  (let ((doclive-preview-asset-urls
         '((highlight-css . "https://example.invalid/highlight.css?x=1&y='bad")
           (katex-css . "https://example.invalid/katex.css")
           (marked-script . "https://example.invalid/marked.js")
           (highlight-script . "https://example.invalid/highlight.js")
           (katex-script . "https://example.invalid/katex.js")
           (katex-auto-render-script . "https://example.invalid/auto-render.js")
           (mermaid-script . "https://example.invalid/mermaid.js"))))
    (let ((html (doclive--preview-html)))
      (should (string-match-p
               (regexp-quote "https://example.invalid/highlight.css?x=1&amp;y=&#39;bad")
               html))
      (should-not (string-match-p
                   (regexp-quote "https://example.invalid/highlight.css?x=1&y='bad")
                   html)))))

(ert-deftest doclive-test-preview-html-rejects-dangerous-asset-overrides ()
  "Preview HTML should reject asset URLs with active content schemes."
  (let ((doclive-preview-asset-urls
         '((highlight-css . "https://example.invalid/highlight.css")
           (katex-css . "https://example.invalid/katex.css")
           (marked-script . "javascript:alert(1)")
           (highlight-script . "https://example.invalid/highlight.js")
           (katex-script . "https://example.invalid/katex.js")
           (katex-auto-render-script . "https://example.invalid/auto-render.js")
           (mermaid-script . "https://example.invalid/mermaid.js"))))
    (should-error (doclive--preview-html) :type 'error)))

(ert-deftest doclive-test-preview-asset-url-safety-rejects-non-web-schemes ()
  "Asset URL validation should reject local and ambiguous schemes."
  (dolist (url '("file:///tmp/marked.js"
                 "ftp://example.invalid/marked.js"
                 "//cdn.example.invalid/marked.js"
                 "\\\\cdn.example.invalid\\marked.js"
                 "/vendor\\marked.js"
                 "https://example.invalid/marked.js\nbad"
                 "https://example.invalid;script-src/marked.js"
                 "https://example.invalid:bad/marked.js"
                 "https://-example.invalid/marked.js"
                 "https://example-.invalid/marked.js"
                 "https://example..invalid/marked.js"
                 "https://user@example.invalid/marked.js"
                 "https:///marked.js"))
    (should-not (doclive--safe-asset-url-p url)))
  (dolist (url '("https://example.invalid/marked.js"
                 "http://127.0.0.1:8000/marked.js"
                 "http://[::1]:8000/marked.js"
                 "/vendor/marked.js"
                 "vendor/marked.js"))
    (should (doclive--safe-asset-url-p url))))

(ert-deftest doclive-test-preview-html-loads-katex-before-autorender ()
  "Preview HTML should not defer KaTeX scripts that autorender depends on."
  (let ((html (doclive--preview-html)))
    (should (string-match-p (regexp-quote "<script src='") html))
    (should-not
     (string-match-p
      (regexp-quote "<script defer src='https://cdn.jsdelivr.net/npm/katex@0.17.0/dist/katex.min.js'")
      html))
    (should-not
     (string-match-p
      (regexp-quote "<script defer src='https://cdn.jsdelivr.net/npm/katex@0.17.0/dist/contrib/auto-render.min.js'")
      html))))

(ert-deftest doclive-test-default-preview-assets-use-exact-versions ()
  "Default browser assets should use immutable, exact upstream versions."
  (dolist (url (mapcar #'cdr doclive-preview-asset-urls))
    (should (string-match-p "@[0-9]+\\.[0-9]+\\.[0-9]+" url))
    (should-not (string-match-p "\\(?:@latest\\|mermaid@11/\\|/marked/marked\\.min\\.js\\)" url))))

(ert-deftest doclive-test-preview-html-includes-content-kind-branch ()
  "Preview HTML should branch by contentKind for Markdown and Org HTML."
  (let ((html (doclive--preview-html)))
    (should (string-match-p "contentKind" html))
    (should (string-match-p "org-html" html))
    (should (string-match-p "j.html" html))
    (should (string-match-p "marked.parse" html))))

(ert-deftest doclive-test-preview-html-uses-highlight-js-dom-api ()
  "Preview HTML should use highlight.js DOM API compatible with modern Marked."
  (let ((html (doclive--preview-html)))
    (should (string-match-p "function highlightCodeBlocks" html))
    (should (string-match-p "hljs.highlightElement(code)" html))
    (should (string-match-p
             (regexp-quote "marked.setOptions({gfm:true,breaks:true});")
             html))
    (should-not (string-match-p "highlight:(code,lang)" html))))

(ert-deftest doclive-test-preview-html-post-process-base-after-render ()
  "Preview HTML should store highlight base after post-processing."
  (let ((html (doclive--preview-html)))
    (should (string-match-p "pre.src-mermaid" html))
    (should (string-match-p "data-base-html" html))
    (should (string-match-p "setAttribute('data-base-html',mdEl.innerHTML)" html))
    (should (string-match-p "wireDocumentLinkNavigation" html))))

(ert-deftest doclive-test-preview-html-includes-sanitizer-guards ()
  "Preview HTML should include browser-side sanitization guards."
  (let ((html (doclive--preview-html)))
    (should (string-match-p "function sanitizeHtml" html))
    (should (string-match-p "function escapeHtml" html))
    (should (string-match-p (regexp-quote "querySelectorAll('script,iframe,object,embed,link,meta,base')") html))
    (should (string-match-p (regexp-quote "/^on/i") html))
    (should (string-match-p (regexp-quote "/^[a-z][a-z0-9+.-]*:/") html))
    (should (string-match-p (regexp-quote "/^(https?:|mailto:)/") html))
    (should (string-match-p "xlink:href" html))
    (should (string-match-p (regexp-quote "lower==='style'") html))
    (should (string-match-p (regexp-quote "lower==='srcset'") html))
    (should (string-match-p (regexp-quote "el.setAttribute('rel','noopener noreferrer')") html))
    (should (string-match-p (regexp-quote "return '&#39;'") html))
    (should-not (string-match-p (regexp-quote ",:'&#39;'") html))))

(ert-deftest doclive-test-preview-html-sanitizes-dangerous-content-urls ()
  "Preview HTML should reject unsafe URL attributes in rendered documents."
  (let ((html (doclive--preview-html)))
    (should (string-match-p (regexp-quote "folded.startsWith('//')") html))
    (should (string-match-p
             (regexp-quote "raw.indexOf(String.fromCharCode(92))!==-1")
             html))
    (should (string-match-p
             (regexp-quote "if(/[\\u0000-\\u001F\\u007F]/.test(raw)) return '';")
             html))
    (should (string-match-p (regexp-quote "return raw.trim();") html))
    (should (string-match-p
             (regexp-quote "/^(href|src|xlink:href|formaction|action|poster)$/i")
             html))
    (should (string-match-p
             (regexp-quote
              "href.indexOf(String.fromCharCode(92))!==-1")
             html))
    (should (string-match-p
             (regexp-quote
              "if(/^[a-z][a-z0-9+.-]*:/.test(folded)&&!/^(https?:|mailto:)/.test(folded)) return '';")
             html))))

(ert-deftest doclive-test-preview-html-includes-csp-nonce ()
  "Preview HTML should nonce the inline runtime script."
  (let* ((doclive--server-token "abc123_-")
         (html (doclive--preview-html "nonce123_-")))
    (should (string-match-p (regexp-quote "<script nonce='nonce123_-'>") html))
    (should-not (string-match-p (regexp-quote "<script nonce='abc123_-'>") html))
    (should-not (string-match-p (regexp-quote "<script>") html))))

(ert-deftest doclive-test-preview-html-omits-unsafe-nonce ()
  "Preview HTML should not embed tokens unsafe for CSP header use."
  (let ((html (doclive--preview-html "bad token\r\n")))
    (should (string-match-p (regexp-quote "<script>") html))
    (should-not (string-match-p (regexp-quote "bad token") html))))

(ert-deftest doclive-test-preview-html-normalizes-theme-value ()
  "Theme selection should reject persisted values outside the supported set."
  (let ((html (doclive--preview-html)))
    (should (string-match-p "function normalizeTheme" html))
    (should (string-match-p (regexp-quote "theme=normalizeTheme(theme)") html))
    (should (string-match-p (regexp-quote "return theme==='light'?'light':'dark'") html))))

(ert-deftest doclive-test-preview-html-escapes-frontmatter-cells ()
  "Frontmatter rows should escape keys and values before HTML insertion."
  (let ((html (doclive--preview-html)))
    (should (string-match-p (regexp-quote "${escapeHtml(k)}") html))
    (should (string-match-p (regexp-quote "${escapeHtml(v)}") html))
    (should-not (string-match-p (regexp-quote "<tr><th>${k}</th><td>${v}</td></tr>") html))))

(ert-deftest doclive-test-preview-html-sanitizes-before-innerhtml-post-processing ()
  "Preview HTML should sanitize generated HTML before DOM insertion and render hooks."
  (let ((html (doclive--preview-html)))
    (should
     (string-match-p
      (regexp-quote
       "html=sanitizeHtml(html); mdEl.setAttribute('data-content-kind',kind); mdEl.innerHTML=html; wireCopy(); renderMath(); await renderMermaid(); buildToc();")
      html))))

(ert-deftest doclive-test-preview-html-renders-pinned-chips-with-dom-apis ()
  "Pinned chips should render term labels with DOM APIs only."
  (let ((html (doclive--preview-html)))
    (should
     (string-match-p
      (regexp-quote
       "const label=document.createElement('b'); label.textContent=term; el.appendChild(label);")
      html))
    (should-not
     (string-match-p
      (regexp-quote "el.innerHTML=`<b>${term}</b>`")
      html))))

(ert-deftest doclive-test-preview-html-sanitizes-mermaid-svg-before-insertion ()
  "Mermaid output should use strict security and sanitize SVG before insertion."
  (let ((html (doclive--preview-html)))
    (should (string-match-p "securityLevel:'strict'" html))
    (should-not (string-match-p "securityLevel:'loose'" html))
    (should (string-match-p "function setSanitizedSvg" html))
    (should
     (string-match-p
      (regexp-quote "tpl.innerHTML=sanitizeHtml(svg||'');")
      html))
    (should
     (string-match-p
      (regexp-quote "root.tagName.toLowerCase()!=='svg'")
      html))
    (should
     (string-match-p
      (regexp-quote "setSanitizedSvg(holder,out.svg);")
      html))))

(ert-deftest doclive-test-preview-html-applycontent-reuses-highlight-link-wiring ()
  "applyContent should rely on applyHighlights for document-link rewiring."
  (let ((html (doclive--preview-html))
        (count 0)
        (start 0)
        (needle (regexp-quote "wireDocumentLinkNavigation(")))
    (should
     (string-match-p
      (regexp-quote "applyHighlights(); applyZoom(); pushNav")
      html))
    (should-not
     (string-match-p
      (regexp-quote "wireDocumentLinkNavigation(j.file||'')")
      html))
    (while (string-match needle html start)
      (setq count (1+ count)
            start (match-end 0)))
    (should (= count 2))))

(ert-deftest doclive-test-preview-html-wires-html-links ()
  "Preview HTML should intercept Org-exported HTML document links."
  (let ((html (doclive--preview-html)))
    (should (string-match-p (regexp-quote "href.startsWith('//')") html))
    (should (string-match-p (regexp-quote "\\.(md|org|html)($|#|\\?)") html))))

(ert-deftest doclive-test-preview-html-uses-token-for-server-calls ()
  "Preview HTML should send the session token on local server requests."
  (let ((html (doclive--preview-html)))
    (should (string-match-p "currentToken=qs.get('token')" html))
    (should (string-match-p "function authedPath" html))
    (should (string-match-p
             (regexp-quote "fetch(authedPath('/content?id='+encodeURIComponent(currentId))")
             html))
    (should (string-match-p
             (regexp-quote "fetch(authedPath('/open?id='+encodeURIComponent(currentId)+'&path='+encodeURIComponent(href))")
             html))
    (should (string-match-p
             (regexp-quote "new EventSource(authedPath('/events?id='+encodeURIComponent(currentId)))")
             html))
    (should (string-match-p
             (regexp-quote "history.replaceState({id:currentId},'',`?id=${encodeURIComponent(currentId)}`)")
             html))
    (should-not
     (string-match-p
      (regexp-quote "history.replaceState({id:currentId},'',`?id=${encodeURIComponent(currentId)}&token=${encodeURIComponent(currentToken)}`)")
      html))))

(ert-deftest doclive-test-preview-html-scrubs-token-from-history ()
  "Preview HTML should remove bearer tokens from the visible browser URL."
  (let ((html (doclive--preview-html)))
    (should (string-match-p "function scrubTokenFromLocation" html))
    (should (string-match-p (regexp-quote "clean.delete('token')") html))
    (should (string-match-p (regexp-quote "scrubTokenFromLocation();") html))
    (should (string-match-p
             (regexp-quote "history.replaceState({id:currentId},'',q?'?'+q:location.pathname)")
             html))))

(ert-deftest doclive-test-example-links ()
  "Example Markdown and Org fixtures should link to each other."
  (let ((md (expand-file-name "example/sample.md" default-directory))
        (org (expand-file-name "example/sample.org" default-directory)))
    (should (file-exists-p md))
    (should (file-exists-p org))
    (with-temp-buffer
      (insert-file-contents md)
      (should (string-match-p "sample.org" (buffer-string))))
    (with-temp-buffer
      (insert-file-contents org)
      (should (string-match-p "sample.md" (buffer-string))))))

;; Request parsing

(ert-deftest doclive-test-parse-request-path ()
  "HTTP request line parser should extract path."
  (should (equal (doclive--parse-request-path "GET /content?id=abc HTTP/1.1")
                 "/content?id=abc"))
  (should (equal (doclive--parse-request-path "GET / HTTP/1.1") "/"))
  (should (equal (doclive--parse-request-path (concat "GET / HTTP/1.1" "\r")) "/"))
  (should-not (doclive--parse-request-path "POST /x HTTP/1.1"))
  (should-not (doclive--parse-request-path "GET / HTTP/1.1 trailing"))
  (should-not (doclive--parse-request-path "GET  HTTP/1.1"))
  (should-not (doclive--parse-request-path "GET / HTTP/1"))
  (should-not (doclive--parse-request-path "GET http://127.0.0.1/preview HTTP/1.1"))
  (should-not (doclive--parse-request-path "GET * HTTP/1.1"))
  (should-not (doclive--parse-request-path "GET /preview#token HTTP/1.1")))

(ert-deftest doclive-test-valid-request-line ()
  "Request line validator should reject malformed or ambiguous input."
  (should (doclive--valid-request-line-p "GET /preview?id=x HTTP/1.1"))
  (should (doclive--valid-request-line-p (concat "GET /preview?id=x HTTP/1.1" "\r")))
  (should-not (doclive--valid-request-line-p "POST /preview?id=x HTTP/1.1"))
  (should-not (doclive--valid-request-line-p "GET /preview?id=x HTTP/1.1 extra"))
  (should-not (doclive--valid-request-line-p "GET /preview?id=x HTTP/1"))
  (should-not (doclive--valid-request-line-p "GET http://127.0.0.1/preview HTTP/1.1"))
  (should-not (doclive--valid-request-line-p "GET * HTTP/1.1"))
  (should-not (doclive--valid-request-line-p "GET /preview#token HTTP/1.1"))
  (should-not (doclive--valid-request-line-p nil)))

(ert-deftest doclive-test-query-param ()
  "Query parameter parser should decode values."
  (should (equal (doclive--query-param "/content?id=abc" "id") "abc"))
  (should (equal (doclive--query-param "/open?id=a&path=qa-b.md" "path") "qa-b.md"))
  (should (equal (doclive--query-param "/open?id=a&path=target+file.md" "path")
                 "target file.md"))
  (should (equal (doclive--query-param "/open?id=a&path=target.md%3Fx%3Dy%23heading" "path")
                 "target.md?x=y#heading"))
  (should-not (doclive--query-param "/content?id=abc" "x")))

(ert-deftest doclive-test-query-param-rejects-malformed-percent-encoding ()
  "Query parameter parser should fail closed on malformed percent encoding."
  (should-not (doclive--query-param "/content?id=%ZZ" "id"))
  (should-not (doclive--query-param "/content?%ZZ=value&id=abc" "id"))
  (should-not (doclive--query-param "/content?%ZZ&id=abc" "id"))
  (should-not (doclive--query-param "/content?token=%ZZ&token=secret" "token")))

(ert-deftest doclive-test-random-token-uses-openssl-rand ()
  "Token generation should prefer OS-backed random bytes when available."
  (let ((called nil))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (program) (and (equal program "openssl") "/bin/openssl")))
              ((symbol-function 'process-file)
               (lambda (program infile destination display &rest args)
                 (setq called (list program infile destination display args))
                 (insert
                  "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\n")
                 0)))
      (should
       (equal (doclive--random-token)
              "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
      (should (equal called '("/bin/openssl" nil t nil ("rand" "-hex" "32")))))))

(ert-deftest doclive-test-random-token-falls-back-when-openssl-unavailable ()
  "Token generation should keep working without openssl."
  (cl-letf (((symbol-function 'executable-find) (lambda (_program) nil))
            ((symbol-function 'file-readable-p)
             (lambda (file) (not (equal file "/dev/urandom")))))
    (let ((token (doclive--random-token)))
      (should (string-match-p "\\`[0-9a-f]\\{64\\}\\'" token)))))

(ert-deftest doclive-test-random-token-uses-dev-urandom-without-openssl ()
  "Token generation should use /dev/urandom when openssl is unavailable."
  (let ((bytes (apply #'unibyte-string (number-sequence 0 31))))
    (cl-letf (((symbol-function 'executable-find) (lambda (_program) nil))
              ((symbol-function 'file-readable-p)
               (lambda (file) (equal file "/dev/urandom")))
              ((symbol-function 'insert-file-contents-literally)
               (lambda (file &optional _visit _beg _end _replace)
                 (should (equal file "/dev/urandom"))
                 (insert bytes)
                 (list file (length bytes)))))
      (should
       (equal (doclive--random-token)
              "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")))))

(ert-deftest doclive-test-random-token-falls-back-when-openssl-errors ()
  "Token generation should survive openssl invocation failures."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (program) (and (equal program "openssl") "/bin/openssl")))
            ((symbol-function 'process-file)
             (lambda (&rest _args)
               (error "openssl failed")))
            ((symbol-function 'file-readable-p)
             (lambda (file) (not (equal file "/dev/urandom")))))
    (let ((token (doclive--random-token)))
      (should (string-match-p "\\`[0-9a-f]\\{64\\}\\'" token)))))

(ert-deftest doclive-test-ensure-server-token-reuses-current-token ()
  "Server token generation should happen once per session."
  (let ((doclive--server-token nil)
        (calls 0))
    (cl-letf (((symbol-function 'doclive--random-token)
               (lambda ()
                 (cl-incf calls)
                 "session-token")))
      (should (equal (doclive--ensure-server-token) "session-token"))
      (should (equal (doclive--ensure-server-token) "session-token"))
      (should (= calls 1)))))

(ert-deftest doclive-test-preview-url-includes-session-token ()
  "Preview URL should include the server token required by local routes."
  (let ((doclive-host "127.0.0.1")
        (doclive-port 39123)
        (doclive--server-token nil))
    (with-temp-buffer
      (let ((url (doclive--preview-url (current-buffer))))
        (should doclive--server-token)
        (should (string-match-p
                 (regexp-quote (concat "token=" (url-hexify-string doclive--server-token)))
                 url))
        (should (string-match-p
                 (regexp-quote (concat "id=" (url-hexify-string (doclive--buffer-id (current-buffer)))))
                 url))))))

(ert-deftest doclive-test-stop-server-clears-session-token ()
  "Stopping the server should invalidate URLs from the old session."
  (let ((doclive--server nil)
        (doclive--server-token "old-token")
        (doclive--change-timers (make-hash-table :test #'equal))
        (doclive--sse-clients (make-hash-table :test #'equal)))
    (cl-letf (((symbol-function 'message)
               (lambda (&rest _args) nil)))
      (doclive-stop-server))
    (should-not doclive--server-token)))

(ert-deftest doclive-test-start-server-validates-host-and-port ()
  "Server startup should reject malformed local server settings."
  (let ((doclive-host "127.0.0.1/path")
        (doclive-port 39123)
        (doclive--server nil))
    (should-error (doclive-start-server) :type 'user-error))
  (let ((doclive-host "127.0.0.1")
        (doclive-port 70000)
        (doclive--server nil))
    (should-error (doclive-start-server) :type 'user-error)))

(ert-deftest doclive-test-http-response-sets-security-headers ()
  "HTTP responses should set browser hardening headers."
  (let ((response (doclive--http-response "200 OK" "text/plain" "body")))
    (should (string-match-p "Cache-Control: no-store\r\n" response))
    (should (string-match-p "Referrer-Policy: no-referrer\r\n" response))
    (should (string-match-p "X-Content-Type-Options: nosniff\r\n" response))
    (should (string-match-p "X-Frame-Options: DENY\r\n" response))
    (should (string-match-p "Content-Security-Policy: default-src 'none';" response))
    (should (string-match-p "base-uri 'none';" response))
    (should (string-match-p "form-action 'none';" response))
    (should (string-match-p "frame-ancestors 'none';" response))
    (should (string-match-p "object-src 'none';" response))
    (should (string-match-p "connect-src 'self'\r\n" response))
    (should (string-match-p "Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=()\r\n" response))))

(ert-deftest doclive-test-http-response-encodes-body-before-length ()
  "Content-Length should describe the emitted UTF-8 response bytes."
  (let* ((body "日本語🙂")
         (encoded-body (encode-coding-string body 'utf-8-unix t))
         (response (doclive--http-response "200 OK" "text/plain" body))
         (body-start (string-match-p "\r\n\r\n" response)))
    (should body-start)
    (should (string-match-p
             (format "Content-Length: %d\r\n" (string-bytes encoded-body))
             response))
    (should (equal (substring response (+ body-start 4)) encoded-body))
    (should (equal (decode-coding-string (substring response (+ body-start 4))
                                         'utf-8-unix t)
                   body))))

(ert-deftest doclive-test-http-response-csp-includes-custom-asset-origins ()
  "CSP should allow configured asset origins and same-origin mirrors."
  (let ((doclive-preview-asset-urls
         '((highlight-css . "https://assets.example.invalid/highlight.css")
           (katex-css . "/vendor/katex.css")
           (marked-script . "http://127.0.0.1:8000/marked.js")
           (highlight-script . "https://assets.example.invalid/highlight.js")
           (katex-script . "/vendor/katex.js")
           (katex-auto-render-script . "/vendor/auto-render.js")
           (mermaid-script . "https://diagrams.example.invalid/mermaid.js")))
        (doclive--server-token "abc123_-"))
    (let ((response (doclive--http-response "200 OK" "text/plain" "body" "nonce123_-")))
      (should (string-match-p
               (regexp-quote "https://assets.example.invalid")
               response))
      (should (string-match-p
               (regexp-quote "http://127.0.0.1:8000")
               response))
      (should (string-match-p
               (regexp-quote "https://diagrams.example.invalid")
               response))
      (should (string-match-p
               "script-src .*'self'.*http://127\\.0\\.0\\.1:8000.*https://diagrams\\.example\\.invalid.*'nonce-nonce123_-'"
               response))
      (should-not (string-match-p (regexp-quote "'nonce-abc123_-'") response))
      (should-not (string-match-p "script-src .*'unsafe-inline'" response))
      (should (string-match-p "connect-src 'self'\r\n" response)))))

(ert-deftest doclive-test-http-response-csp-rejects-malformed-asset-origins ()
  "CSP should not include malformed asset authorities."
  (let ((doclive-preview-asset-urls
         '((highlight-css . "https://assets.example.invalid;style-src/highlight.css")
           (katex-css . "https://assets.example.invalid:bad/katex.css")
           (marked-script . "https://user@assets.example.invalid/marked.js")
           (highlight-script . "https:///highlight.js")
           (katex-script . "https://assets-.example.invalid/katex.js")
           (katex-auto-render-script . "/vendor/auto-render.js")
           (mermaid-script . "https://diagrams.example.invalid/mermaid.js"))))
    (let ((response (doclive--http-response "200 OK" "text/plain" "body" "nonce123_-")))
      (should-not (string-match-p "assets\\.example\\.invalid" response))
      (should (string-match-p
               (regexp-quote "https://diagrams.example.invalid")
               response)))))

(ert-deftest doclive-test-sse-handshake-sets-security-headers ()
  "SSE responses should set the same browser hardening headers."
  (let ((response (doclive--sse-handshake)))
    (should (string-match-p "Cache-Control: no-cache, no-store\r\n" response))
    (should (string-match-p "Referrer-Policy: no-referrer\r\n" response))
    (should (string-match-p "X-Content-Type-Options: nosniff\r\n" response))
    (should (string-match-p "X-Frame-Options: DENY\r\n" response))
    (should (string-match-p "Content-Security-Policy: default-src 'none';" response))
    (should (string-match-p "Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=()\r\n" response))))

(ert-deftest doclive-test-validated-debounce-seconds ()
  "Debounce conversion should reject non-positive or non-numeric values."
  (let ((doclive-change-debounce-ms 250))
    (should (= (doclive--validated-debounce-seconds) 0.25)))
  (let ((doclive-change-debounce-ms 0))
    (should-error (doclive--validated-debounce-seconds) :type 'user-error))
  (let ((doclive-change-debounce-ms "fast"))
    (should-error (doclive--validated-debounce-seconds) :type 'user-error)))

(ert-deftest doclive-test-secure-string-equal-p ()
  "Token comparison should handle equality and mismatches without type coercion."
  (should (doclive--secure-string-equal-p "secret" "secret"))
  (should (doclive--secure-string-equal-p "" ""))
  (should-not (doclive--secure-string-equal-p "secret" "secreu"))
  (should-not (doclive--secure-string-equal-p "secret" "secret-suffix"))
  (should-not (doclive--secure-string-equal-p "secret" nil))
  (should-not (doclive--secure-string-equal-p nil "secret")))

(ert-deftest doclive-test-authorized-request-requires-current-token ()
  "Route authorization should require the current session token."
  (let ((doclive--server-token "secret token"))
    (should (doclive--authorized-request-p "/content?id=abc&token=secret+token"))
    (should-not (doclive--authorized-request-p "/content?id=abc"))
    (should-not (doclive--authorized-request-p "/content?id=abc&token=wrong"))
    (should-not (doclive--authorized-request-p "/content?id=abc&token=%ZZ"))
    (should-not (doclive--authorized-request-p "/content?id=abc&token=%ZZ&token=secret+token"))))

(ert-deftest doclive-test-authorized-request-uses-secure-token-compare ()
  "Route authorization should use the hardened token comparison helper."
  (let ((doclive--server-token "secret")
        (seen nil))
    (cl-letf (((symbol-function 'doclive--secure-string-equal-p)
               (lambda (left right)
                 (setq seen (list left right))
                 t)))
      (should (doclive--authorized-request-p "/content?id=abc&token=provided"))
      (should (equal seen '("provided" "secret"))))))

(ert-deftest doclive-test-route-request-rejects-prefix-collisions ()
  "HTTP routes should not match prefixed paths."
  (let ((sent nil)
        (deleted nil)
        (called nil))
    (cl-letf (((symbol-function 'doclive--json-for-id)
               (lambda (_id)
                 (setq called t)
                 (error "should not reach content handler")))
              ((symbol-function 'process-send-string)
               (lambda (_proc string)
                 (push string sent)))
              ((symbol-function 'delete-process)
               (lambda (_proc)
                 (setq deleted t))))
      (doclive--route-request 'fake-proc "/contentx?id=abc")
      (should-not called)
      (should deleted)
      (should (string-match-p "404 Not Found" (mapconcat #'identity sent "")))
      (should (string-match-p "Not Found" (mapconcat #'identity sent ""))))))

(ert-deftest doclive-test-route-request-rejects-unauthorized-content ()
  "Protected routes should reject requests without the current token."
  (let ((doclive--server-token "secret")
        (sent nil)
        (deleted nil)
        (called nil))
    (cl-letf (((symbol-function 'doclive--json-for-id)
               (lambda (_id)
                 (setq called t)
                 (error "should not reach content handler")))
              ((symbol-function 'process-send-string)
               (lambda (_proc string)
                 (push string sent)))
              ((symbol-function 'delete-process)
               (lambda (_proc)
                 (setq deleted t))))
      (doclive--route-request 'fake-proc "/content?id=abc")
      (should-not called)
      (should deleted)
      (should (string-match-p "403 Forbidden" (mapconcat #'identity sent "")))
      (should (string-match-p "Forbidden" (mapconcat #'identity sent ""))))))

(ert-deftest doclive-test-route-request-allows-authorized-root-with-query ()
  "Root route should accept a token query parameter."
  (let ((doclive--server-token "secret")
        (sent nil)
        (deleted nil))
    (cl-letf (((symbol-function 'doclive--preview-html)
               (lambda (&optional _script-nonce) "preview"))
              ((symbol-function 'process-send-string)
               (lambda (_proc string)
                 (push string sent)))
              ((symbol-function 'delete-process)
               (lambda (_proc)
                 (setq deleted t))))
      (doclive--route-request 'fake-proc "/?token=secret")
      (should deleted)
      (should (string-match-p "200 OK" (mapconcat #'identity sent "")))
      (should (string-match-p "preview" (mapconcat #'identity sent ""))))))

(ert-deftest doclive-test-route-request-uses-response-nonce-not-token ()
  "Preview responses should not reuse the bearer token as the CSP nonce."
  (let ((doclive--server-token "secret")
        (sent nil)
        (deleted nil))
    (cl-letf (((symbol-function 'doclive--random-token)
               (lambda () "route-nonce"))
              ((symbol-function 'process-send-string)
               (lambda (_proc string)
                 (push string sent)))
              ((symbol-function 'delete-process)
               (lambda (_proc)
                 (setq deleted t))))
      (doclive--route-request 'fake-proc "/preview?token=secret")
      (let ((response (mapconcat #'identity sent "")))
        (should deleted)
        (should (string-match-p "200 OK" response))
        (should (string-match-p (regexp-quote "<script nonce='route-nonce'>") response))
        (should (string-match-p (regexp-quote "'nonce-route-nonce'") response))
        (should-not (string-match-p (regexp-quote "<script nonce='secret'>") response))
        (should-not (string-match-p (regexp-quote "'nonce-secret'") response))))))

(ert-deftest doclive-test-preview-file-rejects-unsupported-extension ()
  "Preview command should reject files outside the supported document set."
  (let ((file (make-temp-file "doclive-preview-" nil ".txt")))
    (unwind-protect
        (cl-letf (((symbol-function 'find-file)
                   (lambda (&rest _)
                     (error "find-file should not be called")))
                  ((symbol-function 'doclive-preview-buffer)
                   (lambda (&rest _)
                     (error "doclive-preview-buffer should not be called"))))
          (should-error (doclive-preview-file file) :type 'user-error))
      (when (file-exists-p file)
        (delete-file file)))))

(ert-deftest doclive-test-preview-file-rejects-missing-file ()
  "Preview command should reject supported paths that do not exist."
  (let ((file (make-temp-file "doclive-preview-missing-" nil ".md")))
    (delete-file file)
    (cl-letf (((symbol-function 'find-file)
               (lambda (&rest _)
                 (error "find-file should not be called")))
              ((symbol-function 'doclive-preview-buffer)
               (lambda (&rest _)
                 (error "doclive-preview-buffer should not be called"))))
      (should-error (doclive-preview-file file) :type 'user-error))))

(ert-deftest doclive-test-preview-file-rejects-directories ()
  "Preview command should reject directories even when their names look supported."
  (let ((dir (make-temp-file "doclive-preview-dir-" t ".md")))
    (unwind-protect
        (cl-letf (((symbol-function 'find-file)
                   (lambda (&rest _)
                     (error "find-file should not be called")))
                  ((symbol-function 'doclive-preview-buffer)
                   (lambda (&rest _)
                     (error "doclive-preview-buffer should not be called"))))
          (should-error (doclive-preview-file dir) :type 'user-error))
      (when (file-directory-p dir)
        (delete-directory dir)))))

(ert-deftest doclive-test-preview-file-disables-local-eval ()
  "Preview command should disable local variables and eval while opening FILE."
  (let ((file (make-temp-file "doclive-preview-local-vars-" nil ".md"))
        (seen-enable-local-variables :unset)
        (seen-enable-local-eval :unset)
        (opened nil))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# Local Vars\n"))
          (cl-letf (((symbol-function 'find-file)
                     (lambda (path &rest _args)
                       (setq seen-enable-local-variables enable-local-variables
                             seen-enable-local-eval enable-local-eval
                             opened path)))
                    ((symbol-function 'doclive-preview-buffer)
                     (lambda (&rest _args)
                       nil)))
            (doclive-preview-file file)
            (should (equal opened file))
            (should (equal seen-enable-local-variables nil))
            (should (equal seen-enable-local-eval nil))))
      (when (file-exists-p file)
        (delete-file file)))))

(ert-deftest doclive-test-route-request-rejects-invalid-events-id ()
  "SSE route should reject missing or unknown buffer ids."
  (let ((doclive--server-token "secret")
        (sent nil)
        (deleted nil)
        (registered nil))
    (cl-letf (((symbol-function 'doclive--get-entry)
               (lambda (_id) nil))
              ((symbol-function 'doclive--sse-clients-for)
               (lambda (_id)
                 (error "should not register SSE clients")))
              ((symbol-function 'doclive--set-sse-clients-for)
               (lambda (_id _clients)
                 (setq registered t)))
              ((symbol-function 'process-send-string)
               (lambda (_proc string)
                 (push string sent)))
              ((symbol-function 'delete-process)
               (lambda (_proc)
                 (setq deleted t))))
      (doclive--route-request 'fake-proc "/events?id=missing&token=secret")
      (should deleted)
      (should-not registered)
      (should (string-match-p "400 Bad Request" (mapconcat #'identity sent "")))
      (should (string-match-p "Missing or unknown buffer id" (mapconcat #'identity sent ""))))))

(ert-deftest doclive-test-broadcast-revision-prunes-failed-sse-clients ()
  "Broadcasting should drop clients that fail writes without aborting."
  (let ((doclive--sse-clients (make-hash-table :test #'equal))
        (sent nil)
        (deleted nil))
    (puthash "buffer-id" '(failing-client healthy-client) doclive--sse-clients)
    (cl-letf (((symbol-function 'process-live-p)
               (lambda (proc)
                 (memq proc '(failing-client healthy-client))))
              ((symbol-function 'process-send-string)
               (lambda (proc string)
                 (if (eq proc 'failing-client)
                     (error "simulated SSE write failure")
                   (push (cons proc string) sent))))
              ((symbol-function 'delete-process)
               (lambda (proc)
                 (push proc deleted))))
      (doclive--broadcast-revision "buffer-id" 42)
      (should (equal sent
                     '((healthy-client . "event: revision\ndata: {\"revision\":42}\n\n"))))
      (should (equal deleted '(failing-client)))
      (should (equal (gethash "buffer-id" doclive--sse-clients)
                     '(healthy-client))))))

(ert-deftest doclive-test-set-sse-clients-removes-empty-client-sets ()
  "Empty SSE client lists should not leave stale hash entries."
  (let ((doclive--sse-clients (make-hash-table :test #'equal)))
    (puthash "buffer-id" '(dead-client) doclive--sse-clients)
    (cl-letf (((symbol-function 'process-live-p)
               (lambda (_proc) nil)))
      (doclive--set-sse-clients-for "buffer-id" '(dead-client))
      (should-not (gethash "buffer-id" doclive--sse-clients)))))

(ert-deftest doclive-test-cleanup-stale-entries-removes-dead-buffers ()
  "Stale buffer entries should be pruned on demand."
  (let* ((buf (generate-new-buffer " *doclive-stale*"))
         (id "stale-buffer-id")
         (entry (list :id id
                      :buffer buf
                      :name "stale"
                      :file nil
                      :revision 0
                      :content-kind "markdown"
                      :markdown ""
                      :html "")))
    (unwind-protect
        (progn
          (doclive--put-entry id entry)
          (kill-buffer buf)
          (doclive--cleanup-stale-entries)
          (should-not (doclive--get-entry id)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest doclive-test-preview-mode-disable-removes-served-buffer ()
  "Disabling preview mode should stop serving the buffer immediately."
  (let ((doclive--buffers (make-hash-table :test #'equal))
        (doclive--change-timers (make-hash-table :test #'equal))
        (doclive--sse-clients (make-hash-table :test #'equal))
        (canceled nil))
    (cl-letf (((symbol-function 'cancel-timer)
               (lambda (timer)
                 (push timer canceled))))
      (with-temp-buffer
        (setq buffer-file-name "/tmp/doclive-disable.md")
        (insert "# Disable\n")
        (doclive-preview-mode 1)
        (let ((id (doclive--buffer-id (current-buffer))))
          (should (doclive--get-entry id))
          (puthash id 'timer-before-disable doclive--change-timers)
          (doclive-preview-mode -1)
          (should-not (doclive--get-entry id))
          (should-not (gethash id doclive--change-timers))
          (should (equal canceled '(timer-before-disable))))))))

(ert-deftest doclive-test-change-timers-are-buffer-local ()
  "Debounced change timers should not overwrite each other across buffers."
  (let ((doclive--change-timers (make-hash-table :test #'equal))
        (canceled nil)
        (counter 0))
    (cl-letf (((symbol-function 'run-with-timer)
               (lambda (&rest _args)
                 (intern (format "timer-%d" (cl-incf counter)))))
              ((symbol-function 'cancel-timer)
               (lambda (timer)
                 (push timer canceled))))
      (let ((buf-a (generate-new-buffer " *doclive-a*"))
            (buf-b (generate-new-buffer " *doclive-b*")))
        (unwind-protect
            (progn
              (with-current-buffer buf-a
                (setq buffer-file-name "/tmp/doclive-a.md")
                (setq-local doclive-preview-mode t)
                (doclive--on-change))
              (with-current-buffer buf-b
                (setq buffer-file-name "/tmp/doclive-b.md")
                (setq-local doclive-preview-mode t)
                (doclive--on-change))
              (should (equal (gethash (doclive--buffer-id buf-a) doclive--change-timers)
                             'timer-1))
              (should (equal (gethash (doclive--buffer-id buf-b) doclive--change-timers)
                             'timer-2))
              (with-current-buffer buf-a
                (doclive--on-change))
              (should (equal canceled '(timer-1)))
              (should (equal (gethash (doclive--buffer-id buf-a) doclive--change-timers)
                             'timer-3))
              (should (equal (gethash (doclive--buffer-id buf-b) doclive--change-timers)
                             'timer-2)))
          (when (buffer-live-p buf-a)
            (kill-buffer buf-a))
          (when (buffer-live-p buf-b)
            (kill-buffer buf-b)))))))

(ert-deftest doclive-test-stop-server-cancels-pending-change-timers ()
  "Stopping the server should cancel pending debounce timers."
  (let ((doclive--change-timers (make-hash-table :test #'equal))
        (doclive--sse-clients (make-hash-table :test #'equal))
        (doclive--server nil)
        (canceled nil))
    (puthash "a" 'timer-a doclive--change-timers)
    (puthash "b" 'timer-b doclive--change-timers)
    (cl-letf (((symbol-function 'cancel-timer)
               (lambda (timer)
                 (push timer canceled)))
              ((symbol-function 'message)
               (lambda (&rest _args) nil)))
      (doclive-stop-server)
      (should (equal (sort canceled (lambda (left right)
                                     (string< (symbol-name left)
                                              (symbol-name right))))
                     '(timer-a timer-b)))
      (should (= (hash-table-count doclive--change-timers) 0)))))

(ert-deftest doclive-test-connection-filter-buffers-partial-requests ()
  "Connection filter should wait until the full HTTP header block arrives."
  (let ((routed nil)
        (proc (make-process :name "doclive-test-filter"
                            :buffer nil
                            :command '("cat")
                            :noquery t)))
    (unwind-protect
        (cl-letf (((symbol-function 'doclive--route-request)
                   (lambda (_proc path)
                     (setq routed path))))
          (doclive--connection-filter proc "GET /preview?id=abc HTTP/1.1\r\nHo")
          (should-not routed)
          (should (equal (process-get proc 'doclive-request-buffer)
                         "GET /preview?id=abc HTTP/1.1\r\nHo"))
          (doclive--connection-filter proc "st: example\r\nUser-Agent: test\r\n\r\n")
          (should (equal routed "/preview?id=abc"))
          (should-not (process-get proc 'doclive-request-buffer)))
      (when (process-live-p proc)
        (delete-process proc)))))

(ert-deftest doclive-test-connection-filter-rejects-invalid-methods ()
  "Connection filter should reject non-GET requests instead of routing them."
  (let ((sent nil)
        (deleted nil)
        (routed nil)
        (proc (make-process :name "doclive-test-invalid-method"
                            :buffer nil
                            :command '("cat")
                            :noquery t)))
    (unwind-protect
        (cl-letf (((symbol-function 'doclive--route-request)
                   (lambda (_proc _path)
                     (setq routed t)))
                  ((symbol-function 'process-send-string)
                   (lambda (_proc string)
                     (push string sent)))
                  ((symbol-function 'delete-process)
                   (lambda (_proc)
                     (setq deleted t))))
          (doclive--connection-filter proc "POST /?token=secret HTTP/1.1\r\nHost: example\r\n\r\n")
          (should deleted)
          (should-not routed)
          (should (string-match-p "400 Bad Request" (mapconcat #'identity sent ""))))
      (when (process-live-p proc)
        (delete-process proc)))))

(ert-deftest doclive-test-connection-filter-rejects-oversized-requests ()
  "Connection filter should drop oversized request headers with 413."
  (let ((sent nil)
        (deleted nil)
        (routed nil)
        (proc (make-process :name "doclive-test-oversized"
                            :buffer nil
                            :command '("cat")
                            :noquery t))
        (doclive--max-request-bytes 32))
    (unwind-protect
        (cl-letf (((symbol-function 'doclive--route-request)
                   (lambda (_proc _path)
                     (setq routed t)))
                  ((symbol-function 'process-send-string)
                   (lambda (_proc string)
                     (push string sent)))
                  ((symbol-function 'delete-process)
                   (lambda (_proc)
                     (setq deleted t))))
          (doclive--connection-filter proc "GET /content?id=abc HTTP/1.1\r\nX: 123")
          (doclive--connection-filter proc "456789012345678901234567890123456\r\n\r\n")
          (should deleted)
          (should-not routed)
          (should (string-match-p "413 Payload Too Large" (mapconcat #'identity sent "")))
          (should (string-match-p "Request header too large" (mapconcat #'identity sent ""))))
      (when (process-live-p proc)
        (delete-process proc)))))

(provide 'doclive-test)

;;; doclive-test.el ends here
