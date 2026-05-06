;;; md-live-test.el --- Tests for md-live -*- lexical-binding: t; -*-

;; Author: md-live contributors

;;; Commentary:

;; Comprehensive test suite for md-live covering:
;; - Buffer identity and state tracking
;; - Markdown / Org JSON schema
;; - Org export safety and Babel non-execution
;; - Local linked document resolver behavior
;; - Preview HTML runtime hooks
;; - HTTP request parsing helpers

;;; Code:

(setq load-prefer-newer t)

(require 'ert)
(require 'md-live)
(require 'md-live-test-helpers)

(defun md-live-test--markdown-snapshot-object ()
  "Return a JSON plist for a sample Markdown snapshot."
  (let ((f "/tmp/md-live-json.md"))
    (with-temp-buffer
      (setq buffer-file-name f)
      (insert "# Hello\n")
      (let* ((entry (md-live--snapshot-buffer (current-buffer)))
             (id (plist-get entry :id))
             (raw (md-live--json-for-id id))
             (obj (json-parse-string raw :object-type 'plist)))
        (list id (buffer-name (current-buffer)) obj)))))

;; Buffer identity / state

(ert-deftest md-live-test-buffer-id-stable ()
  "Buffer ID should be stable for same file path."
  (let ((f "/tmp/md-live-id.md"))
    (with-temp-buffer
      (setq buffer-file-name f)
      (let ((id1 (md-live--buffer-id (current-buffer)))
            (id2 (md-live--buffer-id (current-buffer))))
        (should (stringp id1))
        (should (string= id1 id2))))))

;; JSON schema

(ert-deftest md-live-test-snapshot-json ()
  "Snapshot should be reflected in Markdown JSON payload."
  (pcase-let ((`(,id ,name ,obj) (md-live-test--markdown-snapshot-object)))
    (should (eq (plist-get obj :ok) t))
    (should (equal (plist-get obj :buffer_id) id))
    (should (equal (plist-get obj :name) name))
    (should (equal (plist-get obj :contentKind) "markdown"))
    (should (string-match-p "Hello" (plist-get obj :markdown)))
    (should-not (plist-member obj :html))))

(ert-deftest md-live-test-snapshot-json-markdown-content-kind ()
  "Markdown snapshots should use the markdown contentKind discriminator."
  (pcase-let ((`(,_id ,_name ,obj) (md-live-test--markdown-snapshot-object)))
    (should (equal (plist-get obj :contentKind) "markdown"))
    (should (string-match-p "# Hello" (plist-get obj :markdown)))))

(ert-deftest md-live-test-json-unknown-id ()
  "Unknown buffer ID should return an error payload."
  (let* ((raw (md-live--json-for-id "no-such-id"))
         (obj (md-live-test--json-plist raw)))
    (should (eq (plist-get obj :ok) :false))
    (should (stringp (plist-get obj :error)))))

;; Org export safety

(ert-deftest md-live-test-org-snapshot-json ()
  "Org snapshots should export to an HTML fragment payload."
  (md-live-test--with-temp-org-file
   "#+TITLE: Org Fixture\n\n* Heading\n\n- item\n\n#+begin_src mermaid\ngraph TD; A-->B;\n#+end_src\n"
   (lambda (f)
     (let ((buf (find-file-noselect f)))
       (unwind-protect
           (let* ((entry (md-live--snapshot-buffer buf))
                  (id (plist-get entry :id))
                  (raw (md-live--json-for-id id))
                  (obj (md-live-test--json-plist raw))
                  (html (plist-get obj :html)))
             (should (eq (plist-get obj :ok) t))
             (should (equal (plist-get obj :contentKind) "org-html"))
             (should (stringp html))
             (should (string-match-p "Heading" html))
             (should (string-match-p "src-mermaid" html))
             (should-not (plist-member obj :markdown)))
         (when (buffer-live-p buf)
           (kill-buffer buf)))))))

(ert-deftest md-live-test-org-babel-not-executed ()
  "Org export should not execute Babel source blocks."
  (let ((side-effect (make-temp-file "md-live-babel-side-effect-")))
    (delete-file side-effect)
    (unwind-protect
        (md-live-test--with-temp-org-file
         (format "#+TITLE: Safe\n\n* Block\n\n#+begin_src emacs-lisp :results file\n(with-temp-file %S (insert \"boom\"))\n#+end_src\n"
                 side-effect)
         (lambda (f)
           (let ((buf (find-file-noselect f)))
             (unwind-protect
                 (progn
                   (md-live--snapshot-buffer buf)
                   (should-not (file-exists-p side-effect)))
                (when (buffer-live-p buf)
                  (kill-buffer buf))))))
      (when (file-exists-p side-effect)
        (delete-file side-effect)))))

(ert-deftest md-live-test-org-export-allows-unsafe-html-fixture ()
  "Org export can emit raw HTML that the browser runtime must sanitize."
  (let ((html (md-live--org-to-html
               "#+TITLE: Unsafe\n\n#+begin_export html\n<script>alert(1)</script>\n<iframe src='javascript:alert(1)'></iframe>\n<a href='javascript:alert(1)' onclick='boom()'>bad</a>\n#+end_export\n")))
    (should (string-match-p "<script>alert(1)</script>" html))
    (should (string-match-p "<iframe src='javascript:alert(1)'></iframe>" html))
    (should (string-match-p "onclick='boom\(\)'" html))))

;; Link resolver

(ert-deftest md-live-test-open-linked-markdown ()
  "Linked markdown endpoint helper should resolve and open target file."
  (md-live-test--with-temp-linked-files
   '(("a.md" . "# A\n\n[go](b.md)\n")
     ("b.md" . "# B\n"))
   (lambda (dir)
     (let ((buf (find-file-noselect (expand-file-name "a.md" dir))))
       (unwind-protect
           (let* ((_entry (md-live--snapshot-buffer buf))
                  (id (md-live--buffer-id buf))
                  (raw (md-live--open-linked-document id "b.md"))
                  (obj (md-live-test--json-plist raw)))
             (should (eq (plist-get obj :ok) t))
             (should (stringp (plist-get obj :buffer_id))))
         (when (buffer-live-p buf)
           (kill-buffer buf)))))))

(ert-deftest md-live-test-open-linked-org ()
  "Markdown links to Org documents should open successfully."
  (md-live-test--with-temp-linked-files
   '(("source.md" . "# Source\n\n[org](target.org#Heading)\n")
     ("target.org" . "#+TITLE: Target\n\n* Heading\n"))
   (lambda (dir)
     (let ((buf (find-file-noselect (expand-file-name "source.md" dir))))
       (unwind-protect
           (let* ((_entry (md-live--snapshot-buffer buf))
                  (id (md-live--buffer-id buf))
                  (raw (md-live--open-linked-document id "target.org#Heading"))
                  (obj (md-live-test--json-plist raw)))
             (should (eq (plist-get obj :ok) t))
             (should (stringp (plist-get obj :buffer_id))))
         (when (buffer-live-p buf)
           (kill-buffer buf)))))))

(ert-deftest md-live-test-open-linked-markdown-from-org ()
  "Org links to Markdown documents should open successfully."
  (md-live-test--with-temp-linked-files
   '(("source.org" . "#+TITLE: Source\n\n[[file:target.md][Markdown]]\n")
     ("target.md" . "# Target\n"))
   (lambda (dir)
     (let ((buf (find-file-noselect (expand-file-name "source.org" dir))))
       (unwind-protect
           (let* ((_entry (md-live--snapshot-buffer buf))
                  (id (md-live--buffer-id buf))
                  (raw (md-live--open-linked-document id "target.md?x=y#top"))
                  (obj (md-live-test--json-plist raw)))
             (should (eq (plist-get obj :ok) t))
             (should (stringp (plist-get obj :buffer_id))))
         (when (buffer-live-p buf)
           (kill-buffer buf)))))))

(ert-deftest md-live-test-open-linked-org-from-org ()
  "Org links to Org documents should open successfully."
  (md-live-test--with-temp-linked-files
   '(("source.org" . "#+TITLE: Source\n\n[[file:target.org][Org]]\n")
     ("target.org" . "#+TITLE: Target\n\n* Target\n"))
   (lambda (dir)
     (let ((buf (find-file-noselect (expand-file-name "source.org" dir))))
       (unwind-protect
           (let* ((_entry (md-live--snapshot-buffer buf))
                  (id (md-live--buffer-id buf))
                  (raw (md-live--open-linked-document id "target.org"))
                  (obj (md-live-test--json-plist raw)))
             (should (eq (plist-get obj :ok) t))
             (should (stringp (plist-get obj :buffer_id))))
         (when (buffer-live-p buf)
           (kill-buffer buf)))))))

(ert-deftest md-live-test-open-linked-markdown-not-found ()
  "Opening a missing linked document should fail cleanly."
  (md-live-test--with-temp-markdown-file
   "# A\n\n[go](missing.md)\n"
   (lambda (f)
     (let ((buf (find-file-noselect f)))
       (unwind-protect
           (let* ((_entry (md-live--snapshot-buffer buf))
                  (id (md-live--buffer-id buf))
                  (raw (md-live--open-linked-document id "missing.md"))
                  (obj (md-live-test--json-plist raw)))
             (should (eq (plist-get obj :ok) :false))
             (should (string-match-p "linked document" (plist-get obj :error))))
         (when (buffer-live-p buf)
           (kill-buffer buf)))))))

(ert-deftest md-live-test-linked-document-rejects-unsupported ()
  "Resolver should reject unsupported extensions and remote URLs."
  (md-live-test--with-temp-linked-files
   '(("source.md" . "# Source\n")
     ("target.el" . "(message \"no\")\n")
     ("target.html" . "<h1>No</h1>\n")
     ("target.org" . "#+TITLE: OK\n"))
   (lambda (dir)
     (let* ((buf (find-file-noselect (expand-file-name "source.md" dir)))
            (entry (md-live--snapshot-buffer buf)))
       (unwind-protect
           (progn
             (should-not (md-live--resolve-linked-document entry "target.el"))
             (should-not (md-live--resolve-linked-document entry "target.html"))
             (should-not (md-live--resolve-linked-document entry "https://example.com/target.md"))
             (should-not (md-live--resolve-linked-document entry "file:target.md"))
             (should-not (md-live--resolve-linked-document entry "/tmp/target.md"))
             (should (md-live--resolve-linked-document entry "target.org?x=y#heading")))
         (when (buffer-live-p buf)
           (kill-buffer buf)))))))

;; Preview HTML runtime hooks

(ert-deftest md-live-test-preview-html-includes-core-hooks ()
  "Preview HTML should contain core runtime hooks."
  (let ((html (md-live--preview-html)))
    (should (string-match-p "EventSource" html))
    (should (string-match-p "function pushNav" html))
    (should (string-match-p "mermaid" html))
    (should (string-match-p "katex" (downcase html)))))

(ert-deftest md-live-test-preview-html-includes-content-kind-branch ()
  "Preview HTML should branch by contentKind for Markdown and Org HTML."
  (let ((html (md-live--preview-html)))
    (should (string-match-p "contentKind" html))
    (should (string-match-p "org-html" html))
    (should (string-match-p "j.html" html))
    (should (string-match-p "marked.parse" html))))

(ert-deftest md-live-test-preview-html-post-process-base-after-render ()
  "Preview HTML should store highlight base after post-processing."
  (let ((html (md-live--preview-html)))
    (should (string-match-p "pre.src-mermaid" html))
    (should (string-match-p "data-base-html" html))
    (should (string-match-p "setAttribute('data-base-html',mdEl.innerHTML)" html))
    (should (string-match-p "wireDocumentLinkNavigation" html))))

(ert-deftest md-live-test-preview-html-includes-sanitizer-guards ()
  "Preview HTML should include browser-side sanitization guards."
  (let ((html (md-live--preview-html)))
    (should (string-match-p "function sanitizeHtml" html))
    (should (string-match-p "function escapeHtml" html))
    (should (string-match-p (regexp-quote "querySelectorAll('script,iframe')") html))
    (should (string-match-p (regexp-quote "/^on/i") html))
    (should (string-match-p "javascript:" html))
    (should (string-match-p "xlink:href" html))
    (should (string-match-p (regexp-quote "return '&#39;'") html))
    (should-not (string-match-p (regexp-quote ",:'&#39;'") html))))

(ert-deftest md-live-test-preview-html-escapes-frontmatter-cells ()
  "Frontmatter rows should escape keys and values before HTML insertion."
  (let ((html (md-live--preview-html)))
    (should (string-match-p (regexp-quote "${escapeHtml(k)}") html))
    (should (string-match-p (regexp-quote "${escapeHtml(v)}") html))
    (should-not (string-match-p (regexp-quote "<tr><th>${k}</th><td>${v}</td></tr>") html))))

(ert-deftest md-live-test-preview-html-sanitizes-before-innerhtml-post-processing ()
  "Preview HTML should sanitize generated HTML before DOM insertion and render hooks."
  (let ((html (md-live--preview-html)))
    (should
     (string-match-p
      (regexp-quote
       "html=sanitizeHtml(html); mdEl.setAttribute('data-content-kind',kind); mdEl.innerHTML=html; wireCopy(); renderMath(); await renderMermaid(); buildToc();")
      html))))

(ert-deftest md-live-test-preview-html-renders-pinned-chips-with-dom-apis ()
  "Pinned chips should render term labels with DOM APIs only."
  (let ((html (md-live--preview-html)))
    (should
     (string-match-p
      (regexp-quote
       "const label=document.createElement('b'); label.textContent=term; el.appendChild(label);")
      html))
    (should-not
     (string-match-p
      (regexp-quote "el.innerHTML=`<b>${term}</b>`")
      html))))

(ert-deftest md-live-test-preview-html-sanitizes-mermaid-svg-before-insertion ()
  "Mermaid output should use strict security and sanitize SVG before insertion."
  (let ((html (md-live--preview-html)))
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

(ert-deftest md-live-test-preview-html-applycontent-reuses-highlight-link-wiring ()
  "applyContent should rely on applyHighlights for document-link rewiring."
  (let ((html (md-live--preview-html))
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

(ert-deftest md-live-test-example-links ()
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

(ert-deftest md-live-test-parse-request-path ()
  "HTTP request line parser should extract path."
  (should (equal (md-live--parse-request-path "GET /content?id=abc HTTP/1.1")
                 "/content?id=abc"))
  (should (equal (md-live--parse-request-path "GET / HTTP/1.1") "/"))
  (should-not (md-live--parse-request-path "POST /x HTTP/1.1")))

(ert-deftest md-live-test-query-param ()
  "Query parameter parser should decode values."
  (should (equal (md-live--query-param "/content?id=abc" "id") "abc"))
  (should (equal (md-live--query-param "/open?id=a&path=qa-b.md" "path") "qa-b.md"))
  (should-not (md-live--query-param "/content?id=abc" "x")))

(provide 'md-live-test)

;;; md-live-test.el ends here
