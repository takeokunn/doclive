;;; doclive.el --- Fast Markdown and Org preview for AI docs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 takeokunn
;;
;; Author: takeokunn
;; Maintainer: takeokunn
;; URL: https://github.com/takeokunn/doclive
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: markdown, tools, convenience
;;
;; This file is not part of GNU Emacs.
;;
;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; doclive provides live preview of Markdown and Org documents directly
;; inside Emacs.  It renders documents in an xwidget WebKit buffer (or an
;; external browser when xwidget is unavailable) and pushes edits in
;; real time via Server-Sent Events, keeping the preview in sync without
;; manual refresh.
;;
;; To start previewing the current buffer, use:
;;
;;     M-x doclive-preview-buffer
;;
;; To preview a specific file, use:
;;
;;     M-x doclive-preview-file
;;
;; Key features:
;;
;; - xwidget WebKit preview by default, with external browser fallback
;; - SSE-based live update with debounced change tracking (150 ms)
;; - Mermaid diagrams (backtick and tilde fences, mmd alias)
;; - KaTeX math with comprehensive LaTeX environments
;;   (equation, align, gather, cases, etc.)
;; - Syntax highlighting via highlight.js
;; - TOC sidebar and code-copy buttons
;; - Search with pin-system highlighting and dark/light theme toggle
;; - In-page navigation for linked .md / .org documents
;; - Session management: buffer-kill cleanup, Emacs shutdown hook
;; - C-u prefix arg on `doclive-preview-buffer' restarts the server
;;
;; Customization options:
;;
;; - doclive-host :: bind host (default \"127.0.0.1\")
;; - doclive-port :: bind port (default 39123)
;; - doclive-open-browser-function :: URL opening function (default
;;   xwidget-first, falls back to `browse-url')
;; - doclive-change-debounce-ms :: debounce delay in ms (default 150)
;; - doclive-preview-asset-urls :: browser asset URLs used by the preview
;; - doclive-allow-linked-document-parent-directory :: allow linked document
;;   navigation outside the source file directory

;;; Code:

(require 'browse-url)
(require 'cl-lib)
(require 'json)
(require 'org)
(require 'ox-html)
(require 'seq)
(require 'subr-x)
(require 'url-util)

(declare-function xwidget-webkit-new-session "xwidget" (url))

(defgroup doclive nil
  "Fast Markdown and Org preview for AI-generated documents."
  :group 'tools
  :prefix "doclive-")

(defcustom doclive-host "127.0.0.1"
  "Host address for doclive local server."
  :type 'string
  :group 'doclive)

(defcustom doclive-port 39123
  "Port for doclive local server."
  :type 'integer
  :group 'doclive)

(defun doclive-xwidget-available-p ()
  "Return non-nil when xwidget WebKit can open doclive previews."
  (and (require 'xwidget nil t)
       (fboundp 'xwidget-webkit-new-session)
       (fboundp 'xwidget-live-p)))

(defun doclive-open-url-in-xwidget (url)
  "Open URL in a new xwidget WebKit session."
  (interactive "sPreview URL: ")
  (unless (doclive-xwidget-available-p)
    (user-error "This Emacs was not built with xwidget WebKit support"))
  (funcall #'xwidget-webkit-new-session url))

(defun doclive-open-url (url)
  "Open URL with xwidget WebKit, falling back to `browse-url'."
  (interactive "sPreview URL: ")
  (if (doclive-xwidget-available-p)
      (doclive-open-url-in-xwidget url)
    (browse-url url)))

(defcustom doclive-open-browser-function #'doclive-open-url
  "Function used to open preview URL.
The default uses xwidget WebKit when available and falls back to
`browse-url' otherwise."
  :type 'function
  :group 'doclive)

(defcustom doclive-change-debounce-ms 150
  "Debounce delay in milliseconds for after-change snapshots.
Lower values give faster preview but more CPU usage."
  :type 'integer
  :group 'doclive)

(defcustom doclive-preview-asset-urls
  '((highlight-css . "https://cdn.jsdelivr.net/npm/highlight.js@11.11.1/styles/github-dark.min.css")
    (katex-css . "https://cdn.jsdelivr.net/npm/katex@0.17.0/dist/katex.min.css")
    (marked-script . "https://cdn.jsdelivr.net/npm/marked@18.0.5/lib/marked.umd.js")
    (highlight-script . "https://cdn.jsdelivr.net/npm/highlight.js@11.11.1/lib/common.min.js")
    (katex-script . "https://cdn.jsdelivr.net/npm/katex@0.17.0/dist/katex.min.js")
    (katex-auto-render-script . "https://cdn.jsdelivr.net/npm/katex@0.17.0/dist/contrib/auto-render.min.js")
    (mermaid-script . "https://cdn.jsdelivr.net/npm/mermaid@11.16.0/dist/mermaid.min.js"))
  "Alist of browser asset URLs used by the preview page.
The default values point to pinned CDN releases.  Customize this
variable if you want to mirror the assets locally or swap CDNs.
Each URL must be an absolute http(s) URL or a same-origin relative
URL."
  :type '(alist :key-type symbol :value-type string)
  :group 'doclive)

(defcustom doclive-allow-linked-document-parent-directory nil
  "Whether local link navigation may open files outside the source directory.
When nil, doclive opens linked Markdown and Org documents only when
they resolve under the current document's directory."
  :type 'boolean
  :group 'doclive)

(defvar doclive--server nil
  "The doclive HTTP server process.")

(defvar doclive--server-token nil
  "Session token required by doclive HTTP endpoints.")

(defvar doclive--buffers (make-hash-table :test #'equal)
  "Hash table of tracked buffer entries keyed by buffer-id.")

(defvar doclive--sse-clients (make-hash-table :test #'equal)
  "Hash table of SSE client lists keyed by buffer-id.")

(defvar doclive--change-timers (make-hash-table :test #'equal)
  "Hash table of debounced change timers keyed by buffer-id.")

(defvar doclive--max-request-bytes 16384
  "Maximum size of a buffered HTTP request header block.")

(defconst doclive--request-line-regexp
  "\\`GET \\([^[:space:]]+\\) HTTP/[0-9]+\\.[0-9]+\\(?:\r\\)?\\'"
  "Regexp matching the supported HTTP request line format.")

(defconst doclive--browser-security-base-headers
  '(("Referrer-Policy" . "no-referrer")
    ("X-Content-Type-Options" . "nosniff")
    ("X-Frame-Options" . "DENY")
    ("Permissions-Policy" . "camera=(), microphone=(), geolocation=(), payment=(), usb=()"))
  "Static browser hardening headers sent by doclive HTTP responses.")

(defun doclive--buffer-id (buffer)
  "Return stable ID for BUFFER."
  (let ((name (with-current-buffer buffer (or buffer-file-name (buffer-name)))))
    (secure-hash 'sha1 name)))

(defun doclive--escape-html (str)
  "Escape STR for safe HTML embedding."
  (let ((s (or str "")))
    (dolist (pair '(("&" . "&amp;") ("<" . "&lt;") (">" . "&gt;") ("\"" . "&quot;")))
      (setq s (replace-regexp-in-string (car pair) (cdr pair) s t t)))
    s))

(defun doclive--escape-html-attribute (str)
  "Escape STR for safe quoted HTML attribute embedding."
  (replace-regexp-in-string "'" "&#39;" (doclive--escape-html str) t t))

(defun doclive--safe-asset-url-p (url)
  "Return non-nil when URL is safe to embed as a browser asset URL."
  (let ((lower-url (and (stringp url) (downcase url))))
    (and (stringp url)
         (not (string-empty-p url))
         (not (string-match-p "[[:cntrl:][:space:]]" url))
         (not (string-prefix-p "//" url))
         (or (string-match-p "\\`https?://" lower-url)
             (not (string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*:" url))))))

(defun doclive--asset-csp-source (url)
  "Return a CSP source expression for asset URL."
  (cond
   ((not (doclive--safe-asset-url-p url)) nil)
   ((string-match "\\`\\(https?://[^/?#]+\\)" url)
    (downcase (match-string 1 url)))
   (t "'self'")))

(defun doclive--preview-asset-csp-sources ()
  "Return CSP sources required by `doclive-preview-asset-urls'."
  (let (sources)
    (dolist (source (cons "'self'"
                          (delq nil
                                (mapcar (lambda (pair)
                                          (doclive--asset-csp-source (cdr pair)))
                                        doclive-preview-asset-urls))))
      (unless (member source sources)
        (push source sources)))
    (nreverse sources)))

(defun doclive--browser-content-security-policy ()
  "Return the Content-Security-Policy for the preview page."
  (let ((asset-sources (mapconcat #'identity
                                  (doclive--preview-asset-csp-sources)
                                  " ")))
    (mapconcat
     #'identity
     (list
      "default-src 'none'"
      "base-uri 'none'"
      "form-action 'none'"
      "frame-ancestors 'none'"
      "object-src 'none'"
      "img-src 'self' data: blob:"
      (concat "font-src " asset-sources " data:")
      (concat "style-src " asset-sources " 'unsafe-inline'")
      (concat "script-src " asset-sources " 'unsafe-inline'")
      "connect-src 'self'")
     "; ")))

(defun doclive--browser-security-headers ()
  "Return browser hardening headers sent by doclive HTTP responses."
  (append doclive--browser-security-base-headers
          `(("Content-Security-Policy" . ,(doclive--browser-content-security-policy)))))

(defun doclive--preview-asset-url (key)
  "Return the escaped preview asset URL for KEY."
  (let ((url (alist-get key doclive-preview-asset-urls)))
    (unless url
      (error "Missing doclive preview asset URL for %S" key))
    (unless (doclive--safe-asset-url-p url)
      (error "Unsafe doclive preview asset URL for %S" key))
    (doclive--escape-html-attribute url)))

(defun doclive--hex-encode-string (string)
  "Return lowercase hexadecimal encoding of unibyte STRING."
  (mapconcat (lambda (byte) (format "%02x" byte)) string ""))

(defun doclive--random-token-from-urandom ()
  "Return a 32-byte hex token from /dev/urandom when available."
  (when (file-readable-p "/dev/urandom")
    (condition-case nil
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (let ((coding-system-for-read 'binary))
            (insert-file-contents-literally "/dev/urandom" nil 0 32))
          (let ((bytes (buffer-string)))
            (when (= (length bytes) 32)
              (doclive--hex-encode-string bytes))))
      (error nil))))

(defun doclive--random-token ()
  "Return a high-entropy token string for local bearer authentication."
  (or (let ((openssl (executable-find "openssl")))
        (when openssl
          (condition-case nil
              (with-temp-buffer
                (when (zerop (process-file openssl nil t nil "rand" "-hex" "32"))
                  (let ((token (replace-regexp-in-string
                                "\\`[[:space:]\n\r]+\\|[[:space:]\n\r]+\\'"
                                ""
                                (buffer-string))))
                    (when (string-match-p "\\`[0-9a-f]\\{64\\}\\'" token)
                      token))))
            (error nil))))
      (doclive--random-token-from-urandom)
      (secure-hash
       'sha256
       (format "%S:%S:%S:%S"
               (random t)
               (current-time)
               (emacs-pid)
               (user-uid)))))

(defun doclive--ensure-server-token ()
  "Return the session token for the local preview server."
  (or doclive--server-token
      (setq doclive--server-token (doclive--random-token))))

(defun doclive--secure-string-equal-p (left right)
  "Return non-nil when LEFT and RIGHT are equal without early exit."
  (and (stringp left)
       (stringp right)
       (let* ((left-bytes (encode-coding-string left 'utf-8-unix t))
              (right-bytes (encode-coding-string right 'utf-8-unix t))
              (left-len (string-bytes left-bytes))
              (right-len (string-bytes right-bytes))
              (max-len (max left-len right-len))
              (diff (logxor left-len right-len)))
         (dotimes (index max-len)
           (setq diff
                 (logior diff
                         (logxor (if (< index left-len)
                                     (aref left-bytes index)
                                   0)
                                 (if (< index right-len)
                                     (aref right-bytes index)
                                   0)))))
         (zerop diff))))

(defun doclive--valid-host-p (host)
  "Return non-nil when HOST is usable in the local preview URL."
  (and (stringp host)
       (not (string-empty-p host))
       (not (string-match-p "[[:cntrl:][:space:]/?#:]" host))))

(defun doclive--valid-port-p (port)
  "Return non-nil when PORT is a valid TCP port."
  (and (integerp port)
       (<= 1 port)
       (<= port 65535)))

(defun doclive--validated-debounce-seconds ()
  "Return `doclive-change-debounce-ms' as seconds after validation."
  (unless (and (numberp doclive-change-debounce-ms)
               (> doclive-change-debounce-ms 0))
    (user-error "Doclive-change-debounce-ms must be a positive number"))
  (/ (float doclive-change-debounce-ms) 1000.0))

(defun doclive--validate-server-options ()
  "Signal a user error if server customizations are invalid."
  (unless (doclive--valid-host-p doclive-host)
    (user-error "Doclive-host must be a hostname or IPv4 literal without URL syntax"))
  (unless (doclive--valid-port-p doclive-port)
    (user-error "Doclive-port must be an integer between 1 and 65535")))

(defun doclive--get-entry (id)
  "Get entry for buffer ID."
  (gethash id doclive--buffers))

(defun doclive--put-entry (id entry)
  "Store ENTRY for buffer ID."
  (puthash id entry doclive--buffers))

(defun doclive--remove-entry (id)
  "Remove entry for buffer ID."
  (remhash id doclive--buffers))

(defun doclive--ensure-entry (buffer)
  "Ensure state entry exists for BUFFER."
  (let* ((id (doclive--buffer-id buffer))
         (entry (or (doclive--get-entry id)
                    (list :id id
                          :buffer buffer
                          :name (buffer-name buffer)
                          :file nil
                          :revision 0
                          :content-kind "markdown"
                          :markdown ""
                          :html ""))))
    (setf (plist-get entry :buffer) buffer)
    (setf (plist-get entry :name) (buffer-name buffer))
    (setf (plist-get entry :file) (buffer-local-value 'buffer-file-name buffer))
    (doclive--put-entry id entry)
    entry))

(defun doclive--sse-clients-for (id)
  "Return live SSE clients list for ID."
  (seq-filter #'process-live-p (copy-sequence (gethash id doclive--sse-clients))))

(defun doclive--set-sse-clients-for (id clients)
  "Set SSE CLIENTS list for ID."
  (puthash id (seq-filter #'process-live-p clients) doclive--sse-clients))

(defun doclive--broadcast-revision (id revision)
  "Push REVISION event to all SSE clients of ID."
  (let ((clients (doclive--sse-clients-for id))
        (msg (format "event: revision\ndata: {\"revision\":%d}\n\n" revision)))
    (dolist (client clients)
      (condition-case _
          (process-send-string client msg)
        (error nil)))
    (doclive--set-sse-clients-for id clients)))

(defun doclive--org-buffer-p (buffer)
  "Return non-nil when BUFFER should be exported as Org."
  (with-current-buffer buffer
    (or (derived-mode-p 'org-mode)
        (and buffer-file-name
             (string-equal (downcase (or (file-name-extension buffer-file-name) ""))
                           "org")))))

(defun doclive--org-to-html (text)
  "Export Org TEXT to a safe HTML body fragment without Babel execution."
  (let ((org-export-use-babel nil)
        (org-confirm-babel-evaluate nil)
        (org-export-allow-bind-keywords nil)
        (org-export-with-broken-links 'mark)
        (org-html-doctype "html5")
        (org-html-html5-fancy t)
        (org-html-validation-link nil)
        (org-html-head-include-default-style nil)
        (org-html-head-include-scripts nil))
    (condition-case err
        (org-export-string-as text 'html t '(:with-toc nil))
      (error
       (format "<pre class=\"doclive-export-error\">%s</pre>"
               (doclive--escape-html (error-message-string err)))))))

(defun doclive--snapshot-buffer (buffer)
  "Capture BUFFER contents and notify clients."
  (doclive--cleanup-stale-entries)
  (let* ((entry (doclive--ensure-entry buffer))
         (id (plist-get entry :id))
         (text (with-current-buffer buffer
                  (buffer-substring-no-properties (point-min) (point-max))))
         (org-buffer-p (doclive--org-buffer-p buffer))
         (rev (1+ (or (plist-get entry :revision) 0))))
    (setf (plist-get entry :revision) rev)
    (setf (plist-get entry :content-kind) (if org-buffer-p "org-html" "markdown"))
    (setf (plist-get entry :markdown) (if org-buffer-p "" text))
    (setf (plist-get entry :html) (if org-buffer-p (doclive--org-to-html text) ""))
    (doclive--put-entry id entry)
    (doclive--broadcast-revision id rev)
    entry))

(defun doclive--json-for-id (id)
  "Return JSON payload for tracked buffer ID."
  (let ((entry (doclive--get-entry id)))
    (if (not entry)
        (json-encode `((ok . :json-false)
                       (error . "unknown buffer id")))
      (let* ((content-kind (or (plist-get entry :content-kind) "markdown"))
             (base `((ok . t)
                     (buffer_id . ,id)
                     (name . ,(or (plist-get entry :name) ""))
                     (file . ,(or (plist-get entry :file) ""))
                     (revision . ,(or (plist-get entry :revision) 0))
                     (contentKind . ,content-kind))))
        (json-encode
         (append base
                 (if (string= content-kind "org-html")
                     `((html . ,(or (plist-get entry :html) "")))
                   `((markdown . ,(or (plist-get entry :markdown) ""))))))))))

(defun doclive--strip-link-target (rel)
  "Return REL without fragment or query parts."
  (let ((target (or rel "")))
    (if (string-match "[?#]" target)
        (substring target 0 (match-beginning 0))
      target)))

(defun doclive--decode-query-component (value)
  "Decode query component VALUE."
  (condition-case _
      (url-unhex-string
       (replace-regexp-in-string "\\+" " " (or value "") t t))
    (error (or value ""))))

(defun doclive--local-document-link-p (rel)
  "Return non-nil when REL is a local relative document link."
  (and (stringp rel)
       (not (string-empty-p rel))
       (not (file-name-absolute-p rel))
       (not (string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*:" rel))))

(defun doclive--supported-document-file-p (file)
  "Return non-nil when FILE has a previewable document extension."
  (member (downcase (or (file-name-extension file) "")) '("md" "org")))

(defun doclive--file-in-directory-p (file directory)
  "Return non-nil when FILE resolves under DIRECTORY."
  (let ((resolved-file (file-truename file))
        (resolved-dir (file-name-as-directory (file-truename directory))))
    (string-prefix-p resolved-dir resolved-file)))

(defun doclive--linked-document-allowed-p (file directory)
  "Return non-nil when FILE may be opened from DIRECTORY."
  (or doclive-allow-linked-document-parent-directory
      (doclive--file-in-directory-p file directory)))

(defun doclive--route-matches-p (path route)
  "Return non-nil when PATH matches ROUTE exactly or with a query string."
  (or (equal path route)
      (string-prefix-p (concat route "?") path)))

(defun doclive--resolve-linked-document (entry rel)
  "Resolve REL Markdown or Org document path from ENTRY file context."
  (let* ((target (and (doclive--local-document-link-p rel)
                      (doclive--strip-link-target rel)))
         (base (plist-get entry :file))
         (dir (and base (file-name-directory base)))
         (full (and target dir (expand-file-name target dir))))
    (cond
     ((not full) nil)
     ((and (file-exists-p full)
           (doclive--supported-document-file-p full)
           (doclive--linked-document-allowed-p full dir))
      full)
     ((string= (downcase (or (file-name-extension full) "")) "html")
      (cl-loop for ext in '("org" "md")
               for candidate = (concat (file-name-sans-extension full) "." ext)
               when (and (file-exists-p candidate)
                         (doclive--linked-document-allowed-p candidate dir))
               return candidate))
     (t nil))))

(defun doclive--open-linked-document (current-id rel)
  "Open REL Markdown or Org document linked from CURRENT-ID entry."
  (let* ((entry (doclive--get-entry current-id))
         (full (and entry (doclive--resolve-linked-document entry rel))))
    (if (not full)
        (json-encode `((ok . :json-false)
                       (error . "linked document not found")))
      (let ((enable-local-variables nil)
            (enable-local-eval nil))
        (let* ((buf (find-file-noselect full))
               (new-entry (doclive--snapshot-buffer buf))
               (new-id (plist-get new-entry :id)))
          (json-encode `((ok . t)
                         (buffer_id . ,new-id)
                         (name . ,(plist-get new-entry :name)))))))))

(defun doclive--http-response (status content-type body)
  "Build HTTP response from STATUS CONTENT-TYPE BODY."
  (concat
   (format "HTTP/1.1 %s\r\n" status)
   "Connection: close\r\n"
   (format "Content-Type: %s; charset=utf-8\r\n" content-type)
   (format "Content-Length: %d\r\n" (string-bytes body))
   "Cache-Control: no-store\r\n"
   (doclive--browser-security-header-lines)
   "\r\n"
   body))

(defun doclive--browser-security-header-lines ()
  "Return HTTP header lines for browser-side response hardening."
  (concat
   (mapconcat
    (lambda (header)
      (format "%s: %s" (car header) (cdr header)))
    (doclive--browser-security-headers)
    "\r\n")
   "\r\n"))

(defun doclive--preview-html ()
  "Return the complete self-contained preview HTML page.
The page embeds marked.js for Markdown rendering, highlight.js for
syntax highlighting, KaTeX for math typesetting with comprehensive
LaTeX environment support, Mermaid.js for diagram rendering, and an
SSE client for live-update support."
  (concat
   "<!doctype html><html><head><meta charset='utf-8'>"
   "<meta name='viewport' content='width=device-width,initial-scale=1'>"
   "<meta name='referrer' content='no-referrer'>"
   "<title>doclive</title><link rel='icon' href='data:,'>"
   "<link rel='stylesheet' href='" (doclive--preview-asset-url 'highlight-css) "'>"
   "<link rel='stylesheet' href='" (doclive--preview-asset-url 'katex-css) "'>"
   "<style>"
   ":root{--bg:#0d1117;--panel:#111827;--text:#e6edf3;--muted:#8b949e;--border:#30363d;--accent:#58a6ff;}"
   "body[data-theme='light']{--bg:#f6f8fa;--panel:#ffffff;--text:#24292f;--muted:#57606a;--border:#d0d7de;--accent:#0969da;}"
   "*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font-family:ui-sans-serif,system-ui,-apple-system,'Segoe UI',sans-serif;}"
   ".layout{display:grid;grid-template-columns:280px 1fr;min-height:100vh;}"
   ".toc{padding:16px;border-right:1px solid var(--border);background:linear-gradient(180deg,#0f1724 0,#0d1117 100%);overflow:auto;position:sticky;top:0;height:100vh;}"
   ".toc h2{margin:0 0 12px;font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);}"
   ".toc a{display:block;color:#c9d1d9;text-decoration:none;padding:6px 8px;border-radius:8px;font-size:13px;}"
   ".toc a:hover{background:#1f2937;color:#fff;}"
   ".main{padding:20px 4vw 40px;}"
   ".status{font-size:12px;color:var(--muted);margin-bottom:16px;display:flex;gap:8px;align-items:center;}"
   ".toolbar{display:flex;flex-wrap:wrap;gap:8px;margin-bottom:14px;align-items:center;}"
   ".toolbar input,.toolbar button,.toolbar select{background:var(--panel);color:var(--text);border:1px solid var(--border);border-radius:8px;padding:6px 10px;font-size:12px;}"
   ".toolbar button{cursor:pointer;}"
   ".chips{display:flex;gap:6px;flex-wrap:wrap;}"
   ".chip{border:1px solid var(--border);border-radius:999px;padding:3px 8px;font-size:11px;display:flex;gap:6px;align-items:center;background:var(--panel);}"
   ".chip b{font-weight:600;}"
   ".chip-close{border:none;background:transparent;color:var(--muted);cursor:pointer;padding:0;font-size:12px;line-height:1;}"
   ".dot{width:8px;height:8px;border-radius:999px;background:#3fb950;display:inline-block;}"
   ".dot-disconnected{background:#f85149;}"
   ".md{max-width:980px;margin:0 auto;padding:28px;border:1px solid var(--border);border-radius:14px;background:color-mix(in oklab,var(--panel) 70%, transparent);box-shadow:0 8px 30px rgba(0,0,0,.15);}"
   ".md pre{position:relative;background:#0b1220;padding:14px;border:1px solid #243041;border-radius:10px;overflow:auto;}"
   "body[data-theme='light'] .md pre{background:#f6f8fa;border-color:#d8dee4;}"
   ".frontmatter{margin:0 0 16px;border:1px solid var(--border);border-radius:10px;overflow:hidden;background:var(--panel);}"
   ".frontmatter summary{cursor:pointer;padding:10px 12px;font-weight:600;color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.06em;}"
   ".frontmatter table{margin:0;border-collapse:collapse;width:100%;}"
   ".frontmatter th,.frontmatter td{border-top:1px solid var(--border);padding:8px 10px;text-align:left;font-size:12px;}"
   ".copy-btn{position:absolute;top:8px;right:8px;background:#1f6feb;color:#fff;border:none;border-radius:8px;padding:5px 10px;font-size:12px;cursor:pointer;}"
   ".copy-btn:hover{background:#388bfd;}"
   ".mark-pin-0{background:#fff59d;color:#111}.mark-pin-1{background:#ffd180;color:#111}.mark-pin-2{background:#b9f6ca;color:#111}.mark-pin-3{background:#80d8ff;color:#111}"
   ".render-error{background:#1a0a0a;border:1px solid #f85149;border-radius:10px;padding:14px;margin:8px 0;font-family:monospace;font-size:12px;color:#f85149;overflow:auto;white-space:pre-wrap;}"
   ".render-error::before{content:'⚠ Render error';display:block;font-weight:600;margin-bottom:8px;color:#ff7b72;}"
   "body[data-theme='light'] .render-error{background:#fff5f5;border-color:#cf222e;color:#cf222e;}"
   "body[data-theme='light'] .render-error::before{color:#cf222e;}"
   ".md table{border-collapse:collapse;width:100%;}.md th,.md td{border:1px solid var(--border);padding:6px 8px;}"
   "@media (max-width:980px){.layout{grid-template-columns:1fr}.toc{display:none}.main{padding:14px}}"
   "</style></head><body>"
   "<div class='layout'><aside class='toc'><h2>Outline</h2><nav id='toc'></nav></aside>"
   "<main class='main'><div class='status'><span class='dot' id='dot'></span><span id='status'>connecting…</span></div>"
   "<div class='toolbar'>"
   "<button id='back'>←</button><button id='forward'>→</button>"
   "<input id='search' placeholder='Find in page'>"
   "<button id='pin'>Pin</button>"
   "<span class='chips' id='chips'></span>"
   "<select id='theme'><option value='dark'>Dark</option><option value='light'>Light</option></select>"
   "<button id='zoom-out'>A-</button><button id='zoom-reset'>A</button><button id='zoom-in'>A+</button>"
   "</div>"
   "<article id='md' class='md'></article></main></div>"
   "<script src='" (doclive--preview-asset-url 'marked-script) "'></script>"
   "<script src='" (doclive--preview-asset-url 'highlight-script) "'></script>"
   "<script src='" (doclive--preview-asset-url 'katex-script) "'></script>"
   "<script src='" (doclive--preview-asset-url 'katex-auto-render-script) "'></script>"
   "<script src='" (doclive--preview-asset-url 'mermaid-script) "'></script>"
   "<script>"
   "const qs=new URLSearchParams(location.search); let currentId=qs.get('id'); const currentToken=qs.get('token')||'';"
   "const statusEl=document.getElementById('status'); const mdEl=document.getElementById('md'); const tocEl=document.getElementById('toc');"
   "const searchEl=document.getElementById('search'); const pinEl=document.getElementById('pin'); const chipsEl=document.getElementById('chips');"
   "const themeEl=document.getElementById('theme'); const dotEl=document.getElementById('dot');"
   "let lastRev=-1;"
   "let navStack=[]; let navIndex=-1;"
   "let pinned=[]; let zoom=1;"
   "marked.setOptions({gfm:true,breaks:true});"
   "mermaid.initialize({startOnLoad:false,securityLevel:'strict',theme:'dark'});"
   "function parseFrontmatter(md){if(!md.startsWith('---\\n')) return {front:null,body:md}; const end=md.indexOf('\\n---\\n',4); if(end===-1) return {front:null,body:md}; const raw=md.slice(4,end).trim(); const body=md.slice(end+5); const map={}; raw.split('\\n').forEach(line=>{const i=line.indexOf(':'); if(i>0){const k=line.slice(0,i).trim(); const v=line.slice(i+1).trim(); map[k]=v;}}); return {front:map,body};}"
   "function escapeHtml(s){return String(s==null?'':s).replace(/[&<>\"']/g,(ch)=>{if(ch==='&') return '&amp;'; if(ch==='<') return '&lt;'; if(ch==='>') return '&gt;'; if(ch==='\"') return '&quot;'; return '&#39;';});}"
   "function sanitizeUrlValue(value){const raw=String(value==null?'':value); const folded=raw.replace(/[\\u0000-\\u001F\\u007F\\s]+/g,'').toLowerCase(); return /^(javascript:|vbscript:|data:)/.test(folded)?'':raw;}"
   "function sanitizeHtml(html){const tpl=document.createElement('template'); tpl.innerHTML=html||''; tpl.content.querySelectorAll('script,iframe,object,embed,link,meta,base').forEach((el)=>el.remove()); const walker=document.createTreeWalker(tpl.content,NodeFilter.SHOW_ELEMENT); const nodes=[]; while(walker.nextNode()) nodes.push(walker.currentNode); nodes.forEach((el)=>{Array.from(el.attributes).forEach((attr)=>{const name=attr.name||''; if(/^on/i.test(name)||name.toLowerCase()==='style'){el.removeAttribute(attr.name); return;} if(/^(href|src|xlink:href|formaction)$/i.test(name)){const safe=sanitizeUrlValue(attr.value||''); if(safe){el.setAttribute(attr.name,safe);}else{el.removeAttribute(attr.name);}}});}); return tpl.innerHTML;}"
   "function setSanitizedSvg(container,svg){const tpl=document.createElement('template'); tpl.innerHTML=sanitizeHtml(svg||''); const root=tpl.content.firstElementChild; if(!root||root.tagName.toLowerCase()!=='svg'||tpl.content.childElementCount!==1) throw new Error('invalid mermaid svg'); container.replaceChildren(root.cloneNode(true));}"
   "function renderFrontmatter(front){if(!front) return ''; const rows=Object.entries(front).map(([k,v])=>`<tr><th>${escapeHtml(k)}</th><td>${escapeHtml(v)}</td></tr>`).join(''); return `<details class=\"frontmatter\" open><summary>Frontmatter</summary><table>${rows}</table></details>`;}"
   "function buildToc(){tocEl.innerHTML=''; const hs=mdEl.querySelectorAll('h1,h2,h3,h4,h5,h6'); hs.forEach((h,i)=>{if(!h.id)h.id='h-'+i; const a=document.createElement('a'); a.href='#'+h.id; a.textContent=h.textContent; a.style.paddingLeft=((parseInt(h.tagName.slice(1))-1)*10+8)+'px'; tocEl.appendChild(a);});}"
   "function highlightCodeBlocks(){mdEl.querySelectorAll('pre code').forEach((code)=>{try{hljs.highlightElement(code);}catch(e){}});}"
   "function wireCopy(){mdEl.querySelectorAll('pre').forEach((pre)=>{const old=pre.querySelector('.copy-btn'); if(old) old.remove(); const code=pre.querySelector('code'); const src=code||pre; const b=document.createElement('button'); b.className='copy-btn'; b.textContent='Copy'; b.onclick=async()=>{try{await navigator.clipboard.writeText(src.innerText); b.textContent='Copied'; setTimeout(()=>b.textContent='Copy',900);}catch(e){b.textContent='Failed'; setTimeout(()=>b.textContent='Copy',900);}}; pre.appendChild(b);});}"
   "async function renderMermaid(){"
   "const blocks=Array.from(mdEl.querySelectorAll('pre code.language-mermaid, pre code.language-mmd, pre.src-mermaid, pre.src.src-mermaid'));"
   "for(const el of blocks){"
   "const pre=el.tagName==='PRE'?el:el.closest('pre');"
   "let graph='';"
   "if(el.tagName==='PRE'){const clone=el.cloneNode(true); clone.querySelectorAll('.copy-btn').forEach((b)=>b.remove()); graph=clone.textContent||'';}"
   "else{graph=el.textContent||'';}"
   "if(!graph.trim()) continue;"
   "const holder=document.createElement('div'); holder.style.background='#fff'; holder.style.padding='10px'; holder.style.borderRadius='10px'; holder.style.overflow='auto';"
   "try{const out=await mermaid.render('m'+Math.random().toString(36).slice(2),graph); setSanitizedSvg(holder,out.svg);}"
   "catch(e){holder.className='render-error'; holder.textContent=graph;}"
   "if(pre&&pre.parentNode) pre.parentNode.replaceChild(holder,pre);"
   "}}"
   "function renderMath(){"
   "if(!window.renderMathInElement) return;"
   "try{renderMathInElement(mdEl,{delimiters:["
   "{left:'\\\\\\\\[',right:'\\\\\\\\]',display:true},"
   "{left:'\\\\\\\\(',right:'\\\\\\\\)',display:false},"
   "{left:'$$',right:'$$',display:true},"
   "{left:'$',right:'$',display:false},"
   "{left:'\\\\begin{equation}',right:'\\\\end{equation}',display:true},"
   "{left:'\\\\begin{equation*}',right:'\\\\end{equation*}',display:true},"
   "{left:'\\\\begin{align}',right:'\\\\end{align}',display:true},"
   "{left:'\\\\begin{align*}',right:'\\\\end{align*}',display:true},"
   "{left:'\\\\begin{aligned}',right:'\\\\end{aligned}',display:true},"
   "{left:'\\\\begin{alignat}',right:'\\\\end{alignat}',display:true},"
   "{left:'\\\\begin{alignat*}',right:'\\\\end{alignat*}',display:true},"
   "{left:'\\\\begin{gather}',right:'\\\\end{gather}',display:true},"
   "{left:'\\\\begin{gather*}',right:'\\\\end{gather*}',display:true},"
   "{left:'\\\\begin{multline}',right:'\\\\end{multline}',display:true},"
   "{left:'\\\\begin{multline*}',right:'\\\\end{multline*}',display:true},"
   "{left:'\\\\begin{cases}',right:'\\\\end{cases}',display:true},"
   "{left:'\\\\begin{Bmatrix}',right:'\\\\end{Bmatrix}',display:true},"
   "{left:'\\\\begin{pmatrix}',right:'\\\\end{pmatrix}',display:true},"
   "{left:'\\\\begin{bmatrix}',right:'\\\\end{bmatrix}',display:true},"
   "{left:'\\\\begin{vmatrix}',right:'\\\\end{vmatrix}',display:true}"
   "],ignoredTags:['script','noscript','style','textarea','pre','code','.render-error'],"
   "throwOnError:false,errorColor:'#f85149'});"
   "}catch(e){console.warn('KaTeX render error:',e);}"
   "}"
   "function escReg(s){return s.replace(/[.*+?^${}()|[\\]\\\\]/g,'\\\\$&');}"
   "function replaceTextNode(node,re,cls){const text=node.nodeValue; let m,last=0; const frag=document.createDocumentFragment(); while((m=re.exec(text))!==null){if(m.index>last) frag.appendChild(document.createTextNode(text.slice(last,m.index))); const mark=document.createElement('mark'); mark.className=cls; mark.textContent=m[0]; frag.appendChild(mark); last=re.lastIndex; if(re.lastIndex===m.index) re.lastIndex++;} if(last<text.length) frag.appendChild(document.createTextNode(text.slice(last))); node.parentNode.replaceChild(frag,node);}"
   "function walkAndHighlight(root,re,cls){const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,{acceptNode(n){if(!n.nodeValue.trim()) return NodeFilter.FILTER_REJECT; const p=n.parentNode; if(!p) return NodeFilter.FILTER_REJECT; if(p.closest&&p.closest('script,style,code,pre,.katex,svg')) return NodeFilter.FILTER_REJECT; return NodeFilter.FILTER_ACCEPT;}}); const nodes=[]; while(walker.nextNode()) nodes.push(walker.currentNode); nodes.forEach(n=>replaceTextNode(n,re,cls));}"
   "function applyHighlights(){const html=mdEl.getAttribute('data-base-html')||mdEl.innerHTML; mdEl.innerHTML=html; highlightCodeBlocks(); const q=(searchEl.value||'').trim(); if(q){walkAndHighlight(mdEl,new RegExp(escReg(q),'gi'),'mark-pin-0');} pinned.forEach((term,idx)=>{if(term){walkAndHighlight(mdEl,new RegExp(escReg(term),'gi'),'mark-pin-'+(idx%4));}}); wireCopy(); wireDocumentLinkNavigation();}"
   "function renderChips(){chipsEl.innerHTML=''; pinned.forEach((term,idx)=>{const el=document.createElement('span'); el.className='chip'; const label=document.createElement('b'); label.textContent=term; el.appendChild(label); const c=document.createElement('button'); c.className='chip-close'; c.textContent='×'; c.onclick=()=>{pinned=pinned.filter((_,i)=>i!==idx); applyHighlights(); renderChips();}; el.appendChild(c); chipsEl.appendChild(el);});}"
   "function normalizeTheme(theme){return theme==='light'?'light':'dark';}"
   "function applyTheme(theme){theme=normalizeTheme(theme); document.body.setAttribute('data-theme',theme); localStorage.setItem('doclive-theme',theme); themeEl.value=theme;}"
   "function applyZoom(){mdEl.style.fontSize=(zoom*100)+'%';}"
   "function authedPath(path){const sep=path.includes('?')?'&':'?'; return path+sep+'token='+encodeURIComponent(currentToken);}"
   "function pushNav(id,name){if(navIndex>=0&&navStack[navIndex]&&navStack[navIndex].id===id) return; navStack=navStack.slice(0,navIndex+1); navStack.push({id:id,name:name||''}); navIndex=navStack.length-1; updateNavButtons();}"
   "function updateNavButtons(){document.getElementById('back').disabled=navIndex<=0; document.getElementById('forward').disabled=navIndex<0||navIndex>=navStack.length-1;}"
   "let es=null;"
   "async function fetchContent(){const r=await fetch(authedPath('/content?id='+encodeURIComponent(currentId)),{cache:'no-store'}); return r.json();}"
   "async function applyContent(j){if(!j.ok){statusEl.textContent=j.error||'not found'; dotEl.className='dot dot-disconnected'; return;} statusEl.textContent='live • rev '+j.revision+' • '+(j.name||''); dotEl.className='dot'; if(j.revision===lastRev) return; lastRev=j.revision; const kind=j.contentKind||'markdown'; let html=''; if(kind==='org-html'){html=j.html||'';}else{const parsed=parseFrontmatter(j.markdown||''); html=renderFrontmatter(parsed.front)+marked.parse(parsed.body||'');} html=sanitizeHtml(html); mdEl.setAttribute('data-content-kind',kind); mdEl.innerHTML=html; wireCopy(); renderMath(); await renderMermaid(); buildToc(); mdEl.setAttribute('data-base-html',mdEl.innerHTML); applyHighlights(); applyZoom(); pushNav(currentId,j.name||''); history.replaceState({id:currentId},'',`?id=${encodeURIComponent(currentId)}&token=${encodeURIComponent(currentToken)}`);}"
   "async function openLinkedDocument(href){try{const r=await fetch(authedPath('/open?id='+encodeURIComponent(currentId)+'&path='+encodeURIComponent(href)),{cache:'no-store'}); const j=await r.json(); if(!j.ok){statusEl.textContent=j.error||'open failed'; return;} currentId=j.buffer_id; lastRev=-1; connectSSE(); const c=await fetchContent(); await applyContent(c);}catch(e){statusEl.textContent='open failed';}}"
   "function wireDocumentLinkNavigation(){mdEl.querySelectorAll('a[href]').forEach(a=>{const href=a.getAttribute('href')||''; if(/^[a-zA-Z][a-zA-Z0-9+.-]*:/i.test(href)||href.startsWith('#')) return; if(!/\\.(md|org|html)($|#|\\?)/i.test(href)) return; a.addEventListener('click',ev=>{ev.preventDefault(); openLinkedDocument(href);});});}"
   "function connectSSE(){if(!currentId){statusEl.textContent='missing id'; dotEl.className='dot dot-disconnected'; return;} if(es){es.close(); es=null;} es=new EventSource(authedPath('/events?id='+encodeURIComponent(currentId))); es.addEventListener('open',()=>{statusEl.textContent='connected'; dotEl.className='dot';}); es.addEventListener('revision',async()=>{try{const j=await fetchContent(); await applyContent(j);}catch(e){statusEl.textContent='sync error';}}); es.onerror=()=>{statusEl.textContent='reconnecting…'; dotEl.className='dot dot-disconnected';};}"
   "searchEl.addEventListener('input',()=>applyHighlights());"
   "pinEl.addEventListener('click',()=>{const q=(searchEl.value||'').trim(); if(!q) return; if(!pinned.includes(q)) pinned.push(q); renderChips(); applyHighlights();});"
   "themeEl.addEventListener('change',()=>applyTheme(themeEl.value));"
   "document.getElementById('zoom-in').addEventListener('click',()=>{zoom=Math.min(2,zoom+0.1);applyZoom();});"
   "document.getElementById('zoom-out').addEventListener('click',()=>{zoom=Math.max(0.7,zoom-0.1);applyZoom();});"
   "document.getElementById('zoom-reset').addEventListener('click',()=>{zoom=1;applyZoom();});"
   "document.getElementById('back').addEventListener('click',async()=>{if(navIndex<=0) return; navIndex--; currentId=navStack[navIndex].id; updateNavButtons(); lastRev=-1; connectSSE(); const j=await fetchContent(); await applyContent(j);});"
   "document.getElementById('forward').addEventListener('click',async()=>{if(navIndex>=navStack.length-1) return; navIndex++; currentId=navStack[navIndex].id; updateNavButtons(); lastRev=-1; connectSSE(); const j=await fetchContent(); await applyContent(j);});"
   "applyTheme(localStorage.getItem('doclive-theme'));"
   "(async()=>{try{const j=await fetchContent(); await applyContent(j);}catch(e){statusEl.textContent='initial load failed'; dotEl.className='dot dot-disconnected';} connectSSE();})();"
   "</script></body></html>"))

(defun doclive--parse-request-path (request-line)
  "Extract request path from REQUEST-LINE."
  (when (and request-line (string-match doclive--request-line-regexp request-line))
    (match-string 1 request-line)))

(defun doclive--valid-request-line-p (request-line)
  "Return non-nil when REQUEST-LINE is a supported HTTP request line."
  (and request-line
       (string-match-p doclive--request-line-regexp request-line)))

(defun doclive--query-param (path key)
  "Extract KEY from query in PATH."
  (when (and path (string-match "\\?" path))
    (let ((pairs (split-string (substring path (1+ (match-beginning 0))) "&" t))
          found)
      (dolist (p pairs found)
        (when (and (not found) (string-match "=" p))
          (let* ((eq (match-beginning 0))
                 (raw-key (substring p 0 eq))
                 (raw-value (substring p (1+ eq))))
            (when (string= (doclive--decode-query-component raw-key) key)
              (setq found (doclive--decode-query-component raw-value)))))))))

(defun doclive--sse-handshake ()
  "Return SSE headers."
  (concat
   "HTTP/1.1 200 OK\r\n"
   "Content-Type: text/event-stream\r\n"
   "Cache-Control: no-cache, no-store\r\n"
   (doclive--browser-security-header-lines)
   "Connection: keep-alive\r\n\r\n"
   "retry: 1200\n\n"))

(defun doclive--authorized-request-p (path)
  "Return non-nil when PATH contains the current server token."
  (let ((token (doclive--query-param path "token")))
    (and (stringp doclive--server-token)
         (stringp token)
         (doclive--secure-string-equal-p token doclive--server-token))))

(defun doclive--send-forbidden (proc)
  "Send a forbidden response on PROC and close it."
  (process-send-string proc (doclive--http-response "403 Forbidden" "text/plain" "Forbidden"))
  (delete-process proc))

(defun doclive--route-request (proc path)
  "Route request on PROC for PATH."
  (cond
   ((or (doclive--route-matches-p path "/") (doclive--route-matches-p path "/preview"))
    (if (doclive--authorized-request-p path)
        (progn
          (process-send-string proc (doclive--http-response "200 OK" "text/html" (doclive--preview-html)))
          (delete-process proc))
      (doclive--send-forbidden proc)))
   ((doclive--route-matches-p path "/content")
    (if (doclive--authorized-request-p path)
        (let ((id (doclive--query-param path "id")))
          (process-send-string proc (doclive--http-response "200 OK" "application/json" (doclive--json-for-id id)))
          (delete-process proc))
      (doclive--send-forbidden proc)))
   ((doclive--route-matches-p path "/open")
    (if (doclive--authorized-request-p path)
        (let ((id (doclive--query-param path "id"))
              (rel (doclive--query-param path "path")))
          (process-send-string
           proc
           (doclive--http-response "200 OK" "application/json"
                                    (doclive--open-linked-document id rel)))
          (delete-process proc))
      (doclive--send-forbidden proc)))
   ((doclive--route-matches-p path "/events")
    (if (doclive--authorized-request-p path)
        (let* ((id (doclive--query-param path "id"))
               (entry (and id (doclive--get-entry id))))
          (if (not entry)
              (progn
                (process-send-string proc (doclive--http-response "400 Bad Request" "text/plain" "Missing or unknown buffer id"))
                (delete-process proc))
            (let ((clients (doclive--sse-clients-for id)))
              (process-send-string proc (doclive--sse-handshake))
              (set-process-query-on-exit-flag proc nil)
              (set-process-sentinel proc #'doclive--sse-sentinel)
              (process-put proc 'doclive-buffer-id id)
              (doclive--set-sse-clients-for id (cons proc clients))
              (process-send-string proc
                                   (format "event: revision\ndata: {\"revision\":%d}\n\n"
                                           (or (plist-get entry :revision) 0))))))
      (doclive--send-forbidden proc)))
   (t
    (process-send-string proc (doclive--http-response "404 Not Found" "text/plain" "Not Found"))
    (delete-process proc))))

(defun doclive--sse-sentinel (proc _event)
  "Cleanup SSE PROC from client table."
  (let* ((id (process-get proc 'doclive-buffer-id))
         (clients (doclive--sse-clients-for id)))
    (doclive--set-sse-clients-for id (delq proc clients))))

(defun doclive--cancel-change-timer-by-id (id)
  "Cancel and forget the debounce timer for buffer ID."
  (let ((timer (gethash id doclive--change-timers)))
    (when timer
      (cancel-timer timer)
      (remhash id doclive--change-timers))))

(defun doclive--cancel-change-timer (buffer)
  "Cancel and forget the debounce timer for BUFFER."
  (doclive--cancel-change-timer-by-id (doclive--buffer-id buffer)))

(defun doclive--cancel-all-change-timers ()
  "Cancel all pending debounce timers."
  (maphash (lambda (_id timer)
             (when timer
               (cancel-timer timer)))
           doclive--change-timers)
  (clrhash doclive--change-timers))

(defun doclive--connection-filter (proc chunk)
  "Handle incoming HTTP CHUNK on PROC."
  (let* ((buffer (concat (or (process-get proc 'doclive-request-buffer) "") chunk)))
    (if (> (string-bytes buffer) doclive--max-request-bytes)
        (progn
          (process-put proc 'doclive-request-buffer nil)
          (process-send-string proc (doclive--http-response "413 Payload Too Large" "text/plain" "Request header too large"))
          (delete-process proc))
      (if (not (string-match-p "\r\n\r\n" buffer))
          (process-put proc 'doclive-request-buffer buffer)
        (process-put proc 'doclive-request-buffer nil)
        (let* ((line (car (split-string buffer "\r\n" t)))
               (path (doclive--parse-request-path line)))
          (if (not (doclive--valid-request-line-p line))
              (progn
                (process-send-string proc (doclive--http-response "400 Bad Request" "text/plain" "Bad Request"))
                (delete-process proc))
            (doclive--route-request proc path)))))))

(defun doclive-server-running-p ()
  "Return non-nil when doclive server is running."
  (process-live-p doclive--server))

(defun doclive--cleanup-entry (entry)
  "Clean up SSE clients for ENTRY and release its buffer tracking."
  (let* ((id (plist-get entry :id))
         (clients (doclive--sse-clients-for id)))
    (doclive--cancel-change-timer-by-id id)
    (dolist (proc clients)
      (when (process-live-p proc)
        (delete-process proc)))
    (doclive--set-sse-clients-for id nil)
    (doclive--remove-entry id)))

(defun doclive--cleanup-stale-entries ()
  "Remove entries for buffers that are no longer live."
  (let (stale-entries)
    (maphash
     (lambda (_id entry)
       (let ((buf (plist-get entry :buffer)))
         (unless (and buf (buffer-live-p buf))
           (push entry stale-entries))))
     doclive--buffers)
    (dolist (entry stale-entries)
      (doclive--cleanup-entry entry))))

(defun doclive--kill-emacs-cleanup ()
  "Clean up doclive server and clients before Emacs exits."
  (when (doclive-server-running-p)
    (delete-process doclive--server)
    (setq doclive--server nil))
  (setq doclive--server-token nil)
  (maphash (lambda (_id clients)
             (dolist (proc clients)
               (when (process-live-p proc)
                 (delete-process proc))))
           doclive--sse-clients)
  (clrhash doclive--sse-clients)
  (doclive--cancel-all-change-timers)
  (clrhash doclive--buffers))

;;;###autoload
(defun doclive-start-server ()
  "Start doclive local server."
  (interactive)
  (doclive--validate-server-options)
  (doclive--ensure-server-token)
  (unless (doclive-server-running-p)
    (setq doclive--server
          (make-network-process
           :name "doclive-server"
           :server t
           :service doclive-port
           :host doclive-host
           :filter #'doclive--connection-filter
           :coding 'utf-8-unix
           :noquery t))
    (add-hook 'kill-emacs-hook #'doclive--kill-emacs-cleanup)
    (message "doclive server started: http://%s:%d" doclive-host doclive-port)))

;;;###autoload
(defun doclive-stop-server ()
  "Stop doclive local server."
  (interactive)
  (when (processp doclive--server)
    (delete-process doclive--server))
  (setq doclive--server nil)
  (setq doclive--server-token nil)
  (maphash (lambda (_id clients)
             (dolist (proc clients)
               (when (process-live-p proc)
                 (delete-process proc))))
           doclive--sse-clients)
  (clrhash doclive--sse-clients)
  (doclive--cancel-all-change-timers)
  (remove-hook 'kill-emacs-hook #'doclive--kill-emacs-cleanup)
  (message "doclive server stopped"))

(defun doclive--preview-url (buffer)
  "Return preview URL for BUFFER."
  (format "http://%s:%d/preview?id=%s&token=%s"
          doclive-host
          doclive-port
          (url-hexify-string (doclive--buffer-id buffer))
          (url-hexify-string (doclive--ensure-server-token))))

(defvar doclive-preview-mode)

(defun doclive--on-change (&rest _)
  "Debounced after-change handler.
Schedules a snapshot after `doclive-change-debounce-ms' ms of
inactivity, preventing excessive processing during rapid typing."
  (let* ((buffer (current-buffer))
         (id (doclive--buffer-id buffer)))
    (when (and doclive-preview-mode
               (buffer-live-p buffer))
      (doclive--cancel-change-timer-by-id id)
      (let ((timer nil))
        (setq timer
              (run-with-timer
               (doclive--validated-debounce-seconds) nil
               (lambda (buffer id)
                 (when (and (buffer-live-p buffer)
                            (buffer-local-value 'doclive-preview-mode buffer))
                   (with-current-buffer buffer
                     (doclive--snapshot-buffer buffer)))
                 (when (eq (gethash id doclive--change-timers) timer)
                   (remhash id doclive--change-timers)))
               buffer id))
        (puthash id timer doclive--change-timers)))))

(defun doclive--on-kill ()
  "Clean up doclive tracking when previewed buffer is killed."
  (when doclive-preview-mode
    (let ((id (doclive--buffer-id (current-buffer))))
      (doclive--cancel-change-timer-by-id id)
      (let ((clients (doclive--sse-clients-for id)))
        (dolist (proc clients)
          (when (process-live-p proc)
            (delete-process proc))))
      (doclive--set-sse-clients-for id nil)
      (doclive--remove-entry id))))

;;;###autoload
(define-minor-mode doclive-preview-mode
  "Track this buffer and push changes to the doclive preview in real time.
When enabled, every edit and save triggers a debounced snapshot that
is broadcast via Server-Sent Events to the connected preview page.
Disable this mode when you are done previewing."
  :lighter " doclive"
  (if doclive-preview-mode
      (progn
        (add-hook 'after-change-functions #'doclive--on-change nil t)
        (add-hook 'after-save-hook #'doclive--on-change nil t)
        (add-hook 'kill-buffer-hook #'doclive--on-kill nil t)
        (doclive--snapshot-buffer (current-buffer)))
    (remove-hook 'after-change-functions #'doclive--on-change t)
    (remove-hook 'after-save-hook #'doclive--on-change t)
    (remove-hook 'kill-buffer-hook #'doclive--on-kill t)
    (let ((entry (doclive--get-entry (doclive--buffer-id (current-buffer)))))
      (if entry
          (doclive--cleanup-entry entry)
        (doclive--cancel-change-timer (current-buffer))))))

;;;###autoload
(defun doclive-preview-buffer (&optional force-restart)
  "Preview current buffer in xwidget WebKit and keep it live.
When optional prefix argument FORCE-RESTART is non-nil (via
\\[universal-argument]), the server is restarted before opening
the preview."
  (interactive "P")
  (when force-restart
    (doclive-stop-server))
  (doclive-start-server)
  (doclive-preview-mode 1)
  (funcall doclive-open-browser-function (doclive--preview-url (current-buffer)))
  (message "doclive preview opened"))

;;;###autoload
(defun doclive-preview-file (file)
  "Open Markdown or Org FILE and start doclive preview."
  (interactive "fMarkdown or Org file: ")
  (unless (doclive--supported-document-file-p file)
    (user-error "Doclive can preview only Markdown or Org files"))
  (unless (and (file-regular-p file)
               (file-readable-p file))
    (user-error "Doclive can preview only readable regular files"))
  (let ((enable-local-variables nil)
        (enable-local-eval nil))
    (find-file file))
  (doclive-preview-buffer))

;;;###autoload
(defun doclive-reload-page ()
  "Force reload the preview page by pushing the latest snapshot.
Useful when you want to manually refresh the preview without
restarting the server."
  (interactive)
  (if (not doclive-preview-mode)
      (user-error "Doclive-preview-mode is not active in this buffer")
    (doclive--snapshot-buffer (current-buffer))
    (message "doclive snapshot pushed to preview")))

(provide 'doclive)

;;; doclive.el ends here
