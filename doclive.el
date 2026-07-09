;;; doclive.el --- Fast Markdown and Org preview for AI docs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 takeokunn <bararararatty@gmail.com>
;;
;; Author: takeokunn <bararararatty@gmail.com>
;; Maintainer: takeokunn <bararararatty@gmail.com>
;; URL: https://github.com/takeokunn/doclive
;; Version: 1.1.0
;; Keywords: markdown org tools convenience
;; Package-Requires: ((emacs "29.1"))
;; SPDX-License-Identifier: GPL-3.0-or-later
;;
;; This file is NOT part of GNU Emacs.
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
;; - doclive-allow-non-loopback-host :: allow non-loopback bind hosts
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

(defcustom doclive-allow-non-loopback-host nil
  "Whether doclive may bind the preview server to non-loopback hosts.
Keep this nil unless you understand that the preview server grants
cookie-authenticated access to local document contents."
  :type 'boolean
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

(defconst doclive--preview-asset-keys
  '(highlight-css
    katex-css
    marked-script
    highlight-script
    katex-script
    katex-auto-render-script
    mermaid-script)
  "Asset keys required by the doclive browser preview page.")

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

(defvar doclive--bootstrap-codes (make-hash-table :test #'equal)
  "Single-use preview bootstrap codes keyed by code string.")

(defvar doclive--buffers (make-hash-table :test #'equal)
  "Hash table of tracked buffer entries keyed by buffer-id.")

(defvar doclive--sse-clients (make-hash-table :test #'equal)
  "Hash table of SSE client lists keyed by buffer-id.")

(defvar doclive--change-timers (make-hash-table :test #'equal)
  "Hash table of debounced change timers keyed by buffer-id.")

(defvar-local doclive--buffer-id-value nil
  "Opaque preview ID for the current buffer.")

(defvar doclive--buffer-id-token-function #'doclive--random-token
  "Function used to create opaque preview IDs for buffers.")

(defvar doclive--max-request-bytes 16384
  "Maximum size of a buffered HTTP request header block.")

(defconst doclive--bootstrap-code-ttl-seconds 30
  "Lifetime in seconds for single-use preview bootstrap codes.")

(defconst doclive--request-line-regexp
  "\\`GET \\(/[^[:space:][:cntrl:]#]*\\) HTTP/1\\.[01]\\(?:\r\\)?\\'"
  "Regexp matching the supported HTTP/1.0 or HTTP/1.1 request line format.")

(defconst doclive--browser-security-base-headers
  '(("Referrer-Policy" . "no-referrer")
    ("X-Content-Type-Options" . "nosniff")
    ("X-Frame-Options" . "DENY")
    ("Permissions-Policy" . "camera=(), microphone=(), geolocation=(), payment=(), usb=()"))
  "Static browser hardening headers sent by doclive HTTP responses.")

(defun doclive--buffer-id (buffer)
  "Return stable opaque preview ID for BUFFER."
  (with-current-buffer buffer
    (or doclive--buffer-id-value
        (setq doclive--buffer-id-value
              (funcall doclive--buffer-id-token-function)))))

(defun doclive--escape-html (str)
  "Escape STR for safe HTML embedding."
  (let ((s (or str "")))
    (dolist (pair '(("&" . "&amp;") ("<" . "&lt;") (">" . "&gt;") ("\"" . "&quot;")))
      (setq s (replace-regexp-in-string (car pair) (cdr pair) s t t)))
    s))

(defun doclive--escape-html-attribute (str)
  "Escape STR for safe quoted HTML attribute embedding."
  (replace-regexp-in-string "'" "&#39;" (doclive--escape-html str) t t))

(defun doclive--browser-script-nonce (nonce)
  "Return NONCE when safe to use as a CSP nonce."
  (when (and (stringp nonce)
             (string-match-p "\\`[[:alnum:]+/_-]+\\'" nonce))
    nonce))

(defun doclive--safe-asset-port-p (port)
  "Return non-nil when PORT is nil or a valid TCP port string."
  (or (null port)
      (and (string-match-p "\\`[0-9]+\\'" port)
           (let ((number (string-to-number port)))
             (and (<= 1 number)
                  (<= number 65535))))))

(defun doclive--safe-asset-authority-p (authority)
  "Return non-nil when AUTHORITY is safe as an HTTP asset authority."
  (and (stringp authority)
       (not (string-empty-p authority))
       (or (and (string-match "\\`\\[[0-9a-fA-F:.]+\\]\\(?::\\([0-9]+\\)\\)?\\'" authority)
                (doclive--safe-asset-port-p (match-string 1 authority)))
           (and (string-match "\\`\\([[:alnum:].-]+\\)\\(?::\\([0-9]+\\)\\)?\\'" authority)
                (doclive--safe-asset-port-p (match-string 2 authority))
                (cl-every
                 (lambda (label)
                   (string-match-p "\\`[[:alnum:]]\\(?:[[:alnum:]-]*[[:alnum:]]\\)?\\'" label))
                 (split-string (match-string 1 authority) "\\."))))))

(defun doclive--absolute-asset-url-origin (url)
  "Return the normalized origin for absolute HTTP(S) asset URL, or nil."
  (when (and (stringp url)
             (string-match "\\`\\(https?\\)://\\([^/?#]+\\)\\(?:[/?#]\\|\\'\\)" url))
    (let ((scheme (downcase (match-string 1 url)))
          (authority (match-string 2 url)))
      (when (doclive--safe-asset-authority-p authority)
        (concat scheme "://" (downcase authority))))))

(defun doclive--safe-asset-url-p (url)
  "Return non-nil when URL is safe to embed as a browser asset URL."
  (let ((lower-url (and (stringp url) (downcase url))))
    (and (stringp url)
         (not (string-empty-p url))
         (not (string-match-p "[[:cntrl:][:space:]]" url))
         (not (string-match-p "\\\\" url))
         (not (string-prefix-p "//" url))
         (or (and (string-match-p "\\`https?://" lower-url)
                  (doclive--absolute-asset-url-origin url))
             (not (string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*:" url))))))

(defun doclive--asset-csp-source (url)
  "Return a CSP source expression for asset URL."
  (cond
   ((not (doclive--safe-asset-url-p url)) nil)
   ((doclive--absolute-asset-url-origin url))
   (t "'self'")))

(defun doclive--validate-preview-asset-urls ()
  "Signal an error when `doclive-preview-asset-urls' is malformed."
  (unless (and (listp doclive-preview-asset-urls)
               (cl-every (lambda (entry)
                           (and (consp entry)
                                (symbolp (car entry))
                                (stringp (cdr entry))))
                         doclive-preview-asset-urls))
    (error "Invalid doclive-preview-asset-urls; expected an alist of symbol keys and string URLs"))
  (dolist (key doclive--preview-asset-keys)
    (unless (alist-get key doclive-preview-asset-urls)
      (error "Missing doclive preview asset URL for %S" key))))

(defun doclive--preview-asset-csp-sources ()
  "Return CSP sources required by `doclive-preview-asset-urls'."
  (doclive--validate-preview-asset-urls)
  (let (sources)
    (dolist (source (cons "'self'"
                          (delq nil
                                (mapcar (lambda (pair)
                                          (doclive--asset-csp-source (cdr pair)))
                                        doclive-preview-asset-urls))))
      (unless (member source sources)
        (push source sources)))
    (nreverse sources)))

(defun doclive--browser-content-security-policy (&optional script-nonce)
  "Return the Content-Security-Policy for the preview page.
When SCRIPT-NONCE is safe for a CSP nonce, allow matching inline assets."
  (let ((asset-sources (mapconcat #'identity
                                  (doclive--preview-asset-csp-sources)
                                  " "))
        (nonce (doclive--browser-script-nonce script-nonce)))
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
      (concat "style-src " asset-sources
              (if nonce (format " 'nonce-%s'" nonce) ""))
      (concat "script-src " asset-sources
              (if nonce (format " 'nonce-%s'" nonce) ""))
      "connect-src 'self'")
     "; ")))

(defun doclive--browser-security-headers (&optional script-nonce)
  "Return browser hardening headers sent by doclive HTTP responses.
SCRIPT-NONCE is forwarded to the Content-Security-Policy builder."
  (append doclive--browser-security-base-headers
          `(("Content-Security-Policy" . ,(doclive--browser-content-security-policy script-nonce)))))

(defun doclive--preview-asset-url (key)
  "Return the escaped preview asset URL for KEY."
  (doclive--validate-preview-asset-urls)
  (let ((url (alist-get key doclive-preview-asset-urls)))
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
      (user-error "Doclive requires openssl rand or /dev/urandom for secure tokens")))

(defun doclive--ensure-server-token ()
  "Return the session token for the local preview server."
  (or doclive--server-token
      (setq doclive--server-token (doclive--random-token))))

(defun doclive--cleanup-expired-bootstrap-codes ()
  "Remove expired preview bootstrap codes from the pending table."
  (let ((expired nil)
        (now (float-time)))
    (maphash
     (lambda (code entry)
       (unless (and (listp entry)
                    (numberp (plist-get entry :expires))
                    (<= now (plist-get entry :expires)))
         (push code expired)))
     doclive--bootstrap-codes)
    (dolist (code expired)
      (remhash code doclive--bootstrap-codes))))

(defun doclive--create-bootstrap-code (id)
  "Create and return a single-use preview bootstrap code for ID."
  (doclive--cleanup-expired-bootstrap-codes)
  (let ((code (doclive--random-token)))
    (puthash code
             (list :id id
                   :expires (+ (float-time) doclive--bootstrap-code-ttl-seconds))
             doclive--bootstrap-codes)
    code))

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
       (not (string-match-p "[[:cntrl:][:space:]/?#]" host))
       (or (not (string-match-p ":" host))
           (string-match-p "\\`\\[[0-9A-Fa-f:.]+\\]\\'" host)
           (string-match-p "\\`[0-9A-Fa-f:.]+\\'" host))))

(defun doclive--url-host (host)
  "Return HOST formatted for use as a URL host component."
  (if (and (stringp host)
           (string-match-p ":" host)
           (not (string-prefix-p "[" host)))
      (concat "[" host "]")
    host))

(defun doclive--loopback-host-p (host)
  "Return non-nil when HOST names a loopback interface."
  (and (stringp host)
       (let ((host (downcase host)))
         (or (member host '("localhost" "::1" "[::1]"))
             (and (string-match
                   "\\`127\\.\\([0-9]+\\)\\.\\([0-9]+\\)\\.\\([0-9]+\\)\\'"
                   host)
                  (cl-every (lambda (octet)
                              (let ((value (string-to-number octet)))
                                (<= 0 value 255)))
                            (list (match-string 1 host)
                                  (match-string 2 host)
                                  (match-string 3 host))))))))

(defun doclive--valid-port-p (port)
  "Return non-nil when PORT is a valid TCP port."
  (and (integerp port)
       (<= 1 port)
       (<= port 65535)))

(defun doclive--validated-debounce-seconds ()
  "Return `doclive-change-debounce-ms' as seconds after validation."
  (unless (and (integerp doclive-change-debounce-ms)
               (> doclive-change-debounce-ms 0))
    (user-error "Doclive-change-debounce-ms must be a positive integer"))
  (/ (float doclive-change-debounce-ms) 1000.0))

(defun doclive--validate-server-options ()
  "Signal a user error if server customizations are invalid."
  (unless (doclive--valid-host-p doclive-host)
    (user-error "Doclive-host must be a hostname or IPv4 literal without URL syntax"))
  (unless (or doclive-allow-non-loopback-host
              (doclive--loopback-host-p doclive-host))
    (user-error "Doclive-host must be loopback unless doclive-allow-non-loopback-host is non-nil"))
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
  (let ((live-clients (seq-filter #'process-live-p clients)))
    (if live-clients
        (puthash id live-clients doclive--sse-clients)
      (remhash id doclive--sse-clients))))

(defun doclive--broadcast-revision (id revision)
  "Push REVISION event to all SSE clients of ID."
  (let ((clients (doclive--sse-clients-for id))
        (msg (format "event: revision\ndata: {\"revision\":%d}\n\n" revision))
        alive)
    (dolist (client clients)
      (when (process-live-p client)
        (condition-case _
            (progn
              (process-send-string client msg)
              (push client alive))
          (error
           (ignore-errors
             (delete-process client))))))
    (doclive--set-sse-clients-for id (nreverse alive))))

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
  "Decode query component VALUE.
Return nil when VALUE is not valid percent-encoded data."
  (let ((raw (or value "")))
    (unless (string-match-p "%\\(?:\\'\\|[^[:xdigit:]]\\|[[:xdigit:]]\\'\\|[[:xdigit:]][^[:xdigit:]]\\)" raw)
      (condition-case _
          (url-unhex-string
           (replace-regexp-in-string "\\+" " " raw t t))
        (error nil)))))

(defun doclive--local-document-link-p (rel)
  "Return non-nil when REL is a local relative document link."
  (and (stringp rel)
       (not (string-empty-p rel))
       (not (string-match-p "\\\\" rel))
       (not (string-match-p "[[:cntrl:]]" rel))
       (not (string-prefix-p "//" rel))
       (not (file-name-absolute-p rel))
       (not (string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*:" rel))))

(defun doclive--supported-document-file-p (file)
  "Return non-nil when FILE has a previewable document extension."
  (member (downcase (or (file-name-extension file) "")) '("md" "org")))

(defun doclive--previewable-document-file-p (file)
  "Return non-nil when FILE is a readable regular Markdown or Org file."
  (and (doclive--supported-document-file-p file)
       (file-regular-p file)
       (file-readable-p file)))

(defun doclive--file-in-directory-p (file directory)
  "Return non-nil when FILE resolves under DIRECTORY."
  (condition-case nil
      (let ((resolved-file (file-truename file))
            (resolved-dir (file-name-as-directory (file-truename directory))))
        (string-prefix-p resolved-dir resolved-file))
    (file-error nil)))

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
     ((and (doclive--previewable-document-file-p full)
           (doclive--linked-document-allowed-p full dir))
      full)
     ((string= (downcase (or (file-name-extension full) "")) "html")
      (cl-loop for ext in '("org" "md")
               for candidate = (concat (file-name-sans-extension full) "." ext)
               when (and (doclive--previewable-document-file-p candidate)
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

(defconst doclive--http-header-name-regexp
  "\\`[!#$%&'*+.^_`|~0-9A-Za-z-]+\\'"
  "Regexp matching supported HTTP header field names.")

(defun doclive--http-response (status content-type body &optional script-nonce extra-headers)
  "Build HTTP response from STATUS CONTENT-TYPE BODY.
SCRIPT-NONCE is included in the CSP when it is safe for nonce use.
EXTRA-HEADERS is a list of raw header lines ending in CRLF."
  (let* ((safe-extra-headers
          (delq nil
                (mapcar (lambda (line)
                          (and (doclive--safe-extra-header-line-p line)
                               line))
                        extra-headers)))
         (encoded-body (encode-coding-string body 'utf-8-unix t)))
    (concat
     (format "HTTP/1.1 %s\r\n" status)
     "Connection: close\r\n"
     (format "Content-Type: %s; charset=utf-8\r\n" content-type)
     (format "Content-Length: %d\r\n" (string-bytes encoded-body))
     "Cache-Control: no-store\r\n"
     (doclive--browser-security-header-lines script-nonce)
     (mapconcat #'identity safe-extra-headers "")
     "\r\n"
     encoded-body)))

(defun doclive--safe-extra-header-line-p (line)
  "Return non-nil when LINE is safe as one generated HTTP header line."
  (and (stringp line)
       (string-match "\\`\\([^:\r\n]+\\):[ \t]*\\([^\r\n]*\\)\r\n\\'" line)
       (string-match-p doclive--http-header-name-regexp (match-string 1 line))
       (not (string-match-p "[[:cntrl:]]" (match-string 2 line)))))

(defun doclive--browser-security-header-lines (&optional script-nonce)
  "Return HTTP header lines for browser-side response hardening.
SCRIPT-NONCE is included in the CSP when it is safe for nonce use."
  (concat
   (mapconcat
    (lambda (header)
      (format "%s: %s" (car header) (cdr header)))
    (doclive--browser-security-headers script-nonce)
    "\r\n")
   "\r\n"))

(defun doclive--preview-html (&optional script-nonce)
  "Return the complete self-contained preview HTML page.
The page embeds marked.js for Markdown rendering, highlight.js for
syntax highlighting, KaTeX for math typesetting with comprehensive
LaTeX environment support, Mermaid.js for diagram rendering, and an
SSE client for live-update support.  SCRIPT-NONCE is applied to inline
runtime script and style when it is safe for CSP nonce use."
  (concat
   "<!doctype html><html><head><meta charset='utf-8'>"
   "<meta name='viewport' content='width=device-width,initial-scale=1'>"
   "<meta name='referrer' content='no-referrer'>"
   "<title>doclive</title><link rel='icon' href='data:,'>"
   "<link rel='stylesheet' href='" (doclive--preview-asset-url 'highlight-css) "'>"
   "<link rel='stylesheet' href='" (doclive--preview-asset-url 'katex-css) "'>"
   "<style"
   (let ((nonce (doclive--browser-script-nonce script-nonce)))
     (if nonce (concat " nonce='" (doclive--escape-html-attribute nonce) "'") ""))
   ">"
   ":root{--bg:#09111f;--bg-2:#132235;--panel:#101827;--panel-strong:#172235;--surface-glass:rgba(16,24,39,.74);--text:#eef5ff;--muted:#9fb0c7;--border:rgba(175,194,220,.18);--accent:#5eead4;--accent-2:#f8b84e;--accent-ink:#062621;--danger:#ff6b6b;--shadow:0 24px 80px rgba(0,0,0,.34);--mark:#f8e16c;}"
   "body[data-theme='light']{--bg:#f4efe6;--bg-2:#dbeafe;--panel:#fffaf0;--panel-strong:#ffffff;--surface-glass:rgba(255,250,240,.82);--text:#172033;--muted:#667085;--border:rgba(37,54,79,.16);--accent:#0f766e;--accent-2:#b45309;--accent-ink:#f5fffc;--danger:#b42318;--shadow:0 24px 70px rgba(80,64,38,.18);--mark:#ffe08a;}"
   "*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;min-height:100vh;background:radial-gradient(circle at top left,rgba(94,234,212,.2),transparent 34rem),radial-gradient(circle at 85% 12%,rgba(248,184,78,.16),transparent 28rem),linear-gradient(135deg,var(--bg),var(--bg-2));color:var(--text);font-family:'Avenir Next','SF Pro Rounded','Segoe UI',sans-serif;}"
   "button,input,select{font:inherit}button:focus-visible,input:focus-visible,select:focus-visible,a:focus-visible{outline:2px solid var(--accent);outline-offset:2px}"
   ".layout{display:grid;grid-template-columns:minmax(230px,300px) minmax(0,1fr);gap:clamp(18px,3vw,36px);min-height:100vh;padding:clamp(14px,2.4vw,32px);}"
   ".toc{padding:18px;border:1px solid var(--border);border-radius:26px;background:linear-gradient(180deg,var(--surface-glass),rgba(16,24,39,.48));box-shadow:var(--shadow);backdrop-filter:blur(18px);overflow:auto;position:sticky;top:24px;height:calc(100vh - 48px);}"
   ".toc h2{margin:0 0 14px;font-size:11px;text-transform:uppercase;letter-spacing:.18em;color:var(--muted);}"
   ".toc a{display:block;color:var(--text);text-decoration:none;padding:8px 10px;border-radius:12px;font-size:13px;line-height:1.35;opacity:.78;transition:background .18s ease,opacity .18s ease,transform .18s ease;}"
   ".toc a:hover{background:rgba(94,234,212,.14);color:var(--text);opacity:1;transform:translateX(2px);}"
   ".main{min-width:0;padding:4px 0 42px;}"
   ".hero{display:flex;align-items:flex-end;justify-content:space-between;gap:18px;margin:2px auto 18px;max-width:1100px;animation:doclive-rise .42s ease-out both;}"
   ".eyebrow{margin:0 0 6px;color:var(--accent);font-size:11px;font-weight:800;letter-spacing:.18em;text-transform:uppercase;}"
   ".hero h1{margin:0;font-family:'Iowan Old Style','Charter','Source Serif 4',serif;font-size:clamp(30px,5vw,58px);line-height:.95;letter-spacing:-.04em;}"
   ".status{font-size:12px;color:var(--muted);display:flex;gap:8px;align-items:center;border:1px solid var(--border);border-radius:999px;background:var(--surface-glass);padding:8px 12px;box-shadow:0 10px 30px rgba(0,0,0,.14);white-space:nowrap;}"
   ".toolbar{position:sticky;top:16px;z-index:4;display:flex;flex-wrap:wrap;gap:10px;margin:0 auto 18px;align-items:center;max-width:1100px;padding:10px;border:1px solid var(--border);border-radius:22px;background:var(--surface-glass);box-shadow:var(--shadow);backdrop-filter:blur(20px);animation:doclive-rise .5s ease-out .05s both;}"
   ".toolbar input,.toolbar button,.toolbar select{background:var(--panel-strong);color:var(--text);border:1px solid var(--border);border-radius:14px;padding:9px 12px;font-size:12px;min-height:36px;}"
   ".toolbar input{min-width:min(280px,100%);flex:1 1 220px;background:linear-gradient(180deg,var(--panel-strong),var(--panel));}"
   ".toolbar button{cursor:pointer;font-weight:700;letter-spacing:.01em;transition:transform .16s ease,background .16s ease,border-color .16s ease;}"
   ".toolbar button:hover:not(:disabled){transform:translateY(-1px);border-color:color-mix(in oklab,var(--accent) 55%,var(--border));background:color-mix(in oklab,var(--accent) 16%,var(--panel-strong));}"
   ".toolbar button:disabled{opacity:.42;cursor:not-allowed}.toolbar select{cursor:pointer}.toolbar .primary{background:linear-gradient(135deg,var(--accent),color-mix(in oklab,var(--accent) 64%,var(--accent-2)));color:var(--accent-ink);border-color:transparent;}"
   ".chips{display:flex;gap:6px;flex-wrap:wrap;min-width:0;}"
   ".chip{border:1px solid var(--border);border-radius:999px;padding:5px 9px;font-size:11px;display:flex;gap:7px;align-items:center;background:color-mix(in oklab,var(--panel-strong) 76%,transparent);}"
   ".chip b{font-weight:700;max-width:160px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}"
   ".chip-close{border:none;background:transparent;color:var(--muted);cursor:pointer;padding:0;font-size:13px;line-height:1;min-height:0;}"
   ".dot{width:9px;height:9px;border-radius:999px;background:#35d07f;display:inline-block;box-shadow:0 0 0 6px rgba(53,208,127,.14);animation:doclive-pulse 1.8s ease-in-out infinite;}"
   ".dot-disconnected{background:var(--danger);box-shadow:0 0 0 6px color-mix(in oklab,var(--danger) 18%,transparent);}"
   ".md{max-width:1100px;margin:0 auto;padding:clamp(24px,4.4vw,54px);border:1px solid var(--border);border-radius:30px;background:linear-gradient(180deg,color-mix(in oklab,var(--panel-strong) 88%,transparent),color-mix(in oklab,var(--panel) 78%,transparent));box-shadow:var(--shadow);animation:doclive-rise .56s ease-out .1s both;}"
   ".md{font-family:'Iowan Old Style','Charter','Source Serif 4',serif;font-size:17px;line-height:1.72}.md h1,.md h2,.md h3{font-family:'Avenir Next','SF Pro Rounded','Segoe UI',sans-serif;letter-spacing:-.035em;line-height:1.12}.md a{color:var(--accent);text-decoration-thickness:2px;text-underline-offset:3px}.md img{max-width:100%;border-radius:18px}"
   ".md pre{position:relative;background:#06111f;padding:18px;border:1px solid rgba(94,234,212,.2);border-radius:18px;overflow:auto;box-shadow:inset 0 1px 0 rgba(255,255,255,.04);}"
   "body[data-theme='light'] .md pre{background:#172033;color:#f8fafc;border-color:rgba(15,118,110,.24);}"
   ".frontmatter{margin:0 0 18px;border:1px solid var(--border);border-radius:18px;overflow:hidden;background:color-mix(in oklab,var(--panel-strong) 84%,transparent);}"
   ".frontmatter summary{cursor:pointer;padding:12px 14px;font-weight:800;color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.12em;}"
   ".frontmatter table{margin:0;border-collapse:collapse;width:100%;}"
   ".frontmatter th,.frontmatter td{border-top:1px solid var(--border);padding:9px 12px;text-align:left;font-size:12px;}"
   ".copy-btn{position:absolute;top:10px;right:10px;background:var(--accent);color:var(--accent-ink);border:none;border-radius:999px;padding:6px 11px;font-size:12px;font-weight:800;cursor:pointer;box-shadow:0 8px 20px rgba(0,0,0,.2);}"
   ".copy-btn:hover{filter:brightness(1.06);}"
   ".mark-pin-0{background:var(--mark);color:#111}.mark-pin-1{background:#ffd180;color:#111}.mark-pin-2{background:#b9f6ca;color:#111}.mark-pin-3{background:#80d8ff;color:#111}"
   ".render-error{background:color-mix(in oklab,var(--danger) 12%,var(--panel));border:1px solid var(--danger);border-radius:18px;padding:14px;margin:8px 0;font-family:'SF Mono','Cascadia Code',monospace;font-size:12px;color:var(--danger);overflow:auto;white-space:pre-wrap;}"
   ".render-error::before{content:'⚠ Render error';display:block;font-weight:800;margin-bottom:8px;color:var(--danger);}"
   "body[data-theme='light'] .render-error{background:#fff5f5;border-color:var(--danger);color:var(--danger);}"
   "body[data-theme='light'] .render-error::before{color:var(--danger);}"
   ".md table{border-collapse:collapse;width:100%;}.md th,.md td{border:1px solid var(--border);padding:8px 10px;}"
   "@keyframes doclive-rise{from{opacity:0;transform:translateY(12px)}to{opacity:1;transform:none}}@keyframes doclive-pulse{0%,100%{transform:scale(1);opacity:1}50%{transform:scale(.82);opacity:.72}}"
   "@media (prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important;scroll-behavior:auto!important}}"
   "@media (max-width:980px){.layout{grid-template-columns:1fr;padding:12px}.toc{position:relative;top:auto;height:auto;max-height:240px;border-radius:22px}.hero{align-items:flex-start;flex-direction:column}.toolbar{top:8px}.main{padding:0}.md{border-radius:22px}}"
   "</style></head><body>"
   "<div class='layout'><aside class='toc'><h2>Outline</h2><nav id='toc'></nav></aside>"
   "<main class='main'><header class='hero'><div><p class='eyebrow'>Live document preview</p><h1>doclive workspace</h1></div><div class='status'><span class='dot' id='dot'></span><span id='status'>connecting…</span></div></header>"
   "<div class='toolbar' role='toolbar' aria-label='Preview controls'>"
   "<button id='back'>←</button><button id='forward'>→</button>"
   "<input id='search' placeholder='Find in page'>"
   "<button id='pin' class='primary'>Pin</button>"
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
   "<script"
   (let ((nonce (doclive--browser-script-nonce script-nonce)))
     (if nonce (concat " nonce='" (doclive--escape-html-attribute nonce) "'") ""))
   ">"
   "const qs=new URLSearchParams(location.search); let currentId=qs.get('id');"
   "function scrubSensitiveQueryFromLocation(){let dirty=false; const clean=new URLSearchParams(); qs.forEach((value,key)=>{const lower=(key||'').toLowerCase(); if(lower==='bootstrap'||lower==='token'){dirty=true; return;} clean.append(key,value);}); if(!dirty) return; const q=clean.toString(); history.replaceState({id:currentId},'',q?'?'+q:location.pathname);}"
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
   "function sanitizeUrlValue(value,allowMailto=false){const raw=String(value==null?'':value); const trimmed=raw.trim(); const folded=trimmed.replace(/[\\u0000-\\u001F\\u007F\\s]+/g,'').toLowerCase(); if(!folded||folded.startsWith('//')||trimmed.indexOf(String.fromCharCode(92))!==-1) return ''; if(/[\\u0000-\\u001F\\u007F\\s]/.test(trimmed)) return ''; if(/^[a-z][a-z0-9+.-]*:/.test(folded)&&!(/^https?:/.test(folded)||(allowMailto&&folded.startsWith('mailto:')))) return ''; return trimmed;}"
  "function sanitizeHtml(html){const tpl=document.createElement('template'); tpl.innerHTML=html||''; tpl.content.querySelectorAll('script,iframe,object,embed,link,meta,base').forEach((el)=>el.remove()); const walker=document.createTreeWalker(tpl.content,NodeFilter.SHOW_ELEMENT); const nodes=[]; while(walker.nextNode()) nodes.push(walker.currentNode); nodes.forEach((el)=>{Array.from(el.attributes).forEach((attr)=>{const name=attr.name||''; const lower=name.toLowerCase(); if(/^on/i.test(name)||lower==='style'||lower==='srcset'||lower==='ping'){el.removeAttribute(attr.name); return;} if(/^(href|src|xlink:href|formaction|action|poster)$/i.test(name)){const allowMailto=/^(href|xlink:href)$/i.test(name); const safe=sanitizeUrlValue(attr.value||'',allowMailto); if(safe){el.setAttribute(attr.name,safe);}else{el.removeAttribute(attr.name);}}}); if(el.tagName&&el.tagName.toLowerCase()==='a'&&(el.getAttribute('target')||'').toLowerCase()==='_blank'){el.setAttribute('rel','noopener noreferrer');}}); return tpl.innerHTML;}"
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
   "function getStoredTheme(){try{return localStorage.getItem('doclive-theme');}catch(e){return null;}}"
   "function storeTheme(theme){try{localStorage.setItem('doclive-theme',theme);}catch(e){}}"
   "function applyTheme(theme){theme=normalizeTheme(theme); document.body.setAttribute('data-theme',theme); storeTheme(theme); themeEl.value=theme;}"
   "function applyZoom(){mdEl.style.fontSize=(zoom*100)+'%';}"
   "function pushNav(id,name){if(navIndex>=0&&navStack[navIndex]&&navStack[navIndex].id===id) return; navStack=navStack.slice(0,navIndex+1); navStack.push({id:id,name:name||''}); navIndex=navStack.length-1; updateNavButtons();}"
   "function updateNavButtons(){document.getElementById('back').disabled=navIndex<=0; document.getElementById('forward').disabled=navIndex<0||navIndex>=navStack.length-1;}"
   "let es=null;"
   "async function fetchContent(){const r=await fetch('/content?id='+encodeURIComponent(currentId),{cache:'no-store'}); return r.json();}"
   "async function applyContent(j){if(!j.ok){statusEl.textContent=j.error||'not found'; dotEl.className='dot dot-disconnected'; return;} statusEl.textContent='live • rev '+j.revision+' • '+(j.name||''); dotEl.className='dot'; if(j.revision===lastRev) return; lastRev=j.revision; const kind=j.contentKind||'markdown'; let html=''; if(kind==='org-html'){html=j.html||'';}else{const parsed=parseFrontmatter(j.markdown||''); html=renderFrontmatter(parsed.front)+marked.parse(parsed.body||'');} html=sanitizeHtml(html); mdEl.setAttribute('data-content-kind',kind); mdEl.innerHTML=html; wireCopy(); renderMath(); await renderMermaid(); buildToc(); mdEl.setAttribute('data-base-html',mdEl.innerHTML); applyHighlights(); applyZoom(); pushNav(currentId,j.name||''); history.replaceState({id:currentId},'',`?id=${encodeURIComponent(currentId)}`);}"
   "async function openLinkedDocument(href){try{const r=await fetch('/open?id='+encodeURIComponent(currentId)+'&path='+encodeURIComponent(href),{cache:'no-store'}); const j=await r.json(); if(!j.ok){statusEl.textContent=j.error||'open failed'; return;} currentId=j.buffer_id; lastRev=-1; connectSSE(); const c=await fetchContent(); await applyContent(c);}catch(e){statusEl.textContent='open failed';}}"
   "function wireDocumentLinkNavigation(){mdEl.querySelectorAll('a[href]').forEach(a=>{const href=a.getAttribute('href')||''; if(/^[a-zA-Z][a-zA-Z0-9+.-]*:/i.test(href)||href.startsWith('#')||href.startsWith('//')||href.indexOf(String.fromCharCode(92))!==-1) return; if(!/\\.(md|org|html)($|#|\\?)/i.test(href)) return; a.addEventListener('click',ev=>{ev.preventDefault(); openLinkedDocument(href);});});}"
   "function connectSSE(){if(!currentId){statusEl.textContent='missing id'; dotEl.className='dot dot-disconnected'; return;} if(es){es.close(); es=null;} es=new EventSource('/events?id='+encodeURIComponent(currentId)); es.addEventListener('open',()=>{statusEl.textContent='connected'; dotEl.className='dot';}); es.addEventListener('revision',async()=>{try{const j=await fetchContent(); await applyContent(j);}catch(e){statusEl.textContent='sync error';}}); es.onerror=()=>{statusEl.textContent='reconnecting…'; dotEl.className='dot dot-disconnected';};}"
   "searchEl.addEventListener('input',()=>applyHighlights());"
   "pinEl.addEventListener('click',()=>{const q=(searchEl.value||'').trim(); if(!q) return; if(!pinned.includes(q)) pinned.push(q); renderChips(); applyHighlights();});"
   "themeEl.addEventListener('change',()=>applyTheme(themeEl.value));"
   "document.getElementById('zoom-in').addEventListener('click',()=>{zoom=Math.min(2,zoom+0.1);applyZoom();});"
   "document.getElementById('zoom-out').addEventListener('click',()=>{zoom=Math.max(0.7,zoom-0.1);applyZoom();});"
   "document.getElementById('zoom-reset').addEventListener('click',()=>{zoom=1;applyZoom();});"
   "document.getElementById('back').addEventListener('click',async()=>{if(navIndex<=0) return; navIndex--; currentId=navStack[navIndex].id; updateNavButtons(); lastRev=-1; connectSSE(); const j=await fetchContent(); await applyContent(j);});"
   "document.getElementById('forward').addEventListener('click',async()=>{if(navIndex>=navStack.length-1) return; navIndex++; currentId=navStack[navIndex].id; updateNavButtons(); lastRev=-1; connectSSE(); const j=await fetchContent(); await applyContent(j);});"
   "applyTheme(getStoredTheme());"
   "scrubSensitiveQueryFromLocation();"
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
          (wanted (downcase key))
          found
          seen
          duplicate
          invalid)
      (dolist (p pairs (and (not invalid) (not duplicate) found))
        (if (not (string-match "=" p))
            (let ((decoded-segment (and (not (doclive--unsafe-raw-query-component-p p))
                                        (doclive--decode-query-component p))))
              (when (or (null decoded-segment)
                        (doclive--unsafe-query-component-p decoded-segment))
                (setq invalid t)))
          (let* ((eq (match-beginning 0))
                 (raw-key (substring p 0 eq))
                 (raw-value (substring p (1+ eq)))
                 (decoded-key (and (not (doclive--unsafe-raw-query-component-p raw-key))
                                   (doclive--decode-query-component raw-key)))
                 (decoded-value (and (not (doclive--unsafe-raw-query-component-p raw-value))
                                     (doclive--decode-query-component raw-value))))
            (if (or (null decoded-key) (null decoded-value))
                (setq invalid t)
              (when (or (doclive--unsafe-query-component-p decoded-key)
                        (doclive--unsafe-query-component-p decoded-value))
                (setq invalid t))
              (when (string= (downcase decoded-key) wanted)
                (if seen
                    (setq duplicate t)
                  (setq seen t
                        found decoded-value))))))))))

(defun doclive--query-key-present-p (path key)
  "Return non-nil if query KEY appears in PATH after URL decoding."
  (when (and path (string-match "\\?" path))
    (let ((pairs (split-string (substring path (1+ (match-beginning 0))) "&"))
          (wanted (downcase key)))
      (catch 'found
        (dolist (p pairs)
          (when (string-match "=" p)
            (let* ((eq (match-beginning 0))
                   (raw-key (substring p 0 eq))
                   (decoded-key (and (not (doclive--unsafe-raw-query-component-p raw-key))
                                     (doclive--decode-query-component raw-key))))
              (when (and decoded-key
                         (string= (downcase decoded-key) wanted))
                (throw 'found t)))))
        nil))))

(defun doclive--valid-query-p (path)
  "Return non-nil when PATH has safe, unambiguous query syntax."
  (or (not (and path (string-match "\\?" path)))
      (let ((pairs (split-string (substring path (1+ (match-beginning 0))) "&"))
            (seen-keys (make-hash-table :test #'equal))
            invalid
            duplicate
            token-parameter)
        (dolist (p pairs (and (not invalid) (not duplicate) (not token-parameter)))
          (if (or (string= p "")
                  (not (string-match "=" p)))
              (setq invalid t)
            (let* ((eq (match-beginning 0))
                   (raw-key (substring p 0 eq))
                   (raw-value (substring p (1+ eq)))
                   (decoded-key (and (not (doclive--unsafe-raw-query-component-p raw-key))
                                     (doclive--decode-query-component raw-key)))
                   (decoded-value (and (not (doclive--unsafe-raw-query-component-p raw-value))
                                       (doclive--decode-query-component raw-value)))
                   (normalized-key (and decoded-key (downcase decoded-key))))
              (cond
               ((or (null decoded-key)
                    (null decoded-value)
                    (doclive--unsafe-query-component-p decoded-key)
                    (doclive--unsafe-query-component-p decoded-value))
                (setq invalid t))
               ((gethash normalized-key seen-keys)
                (setq duplicate t))
               ((string= normalized-key "token")
                (setq token-parameter t))
               (t
                (puthash normalized-key t seen-keys)))))))))

(defun doclive--unsafe-query-component-p (component)
  "Return non-nil when decoded query COMPONENT is unsafe for routing."
  (and (stringp component)
       (string-match-p "[[:cntrl:]]" component)))

(defun doclive--unsafe-raw-query-component-p (component)
  "Return non-nil when raw query COMPONENT encodes control characters."
  (and (stringp component)
       (string-match-p "%\\(?:0[0-9A-Fa-f]\\|1[0-9A-Fa-f]\\|7[Ff]\\)" component)))

(defun doclive--request-http-version (request-line)
  "Return the HTTP version from REQUEST-LINE, or nil."
  (when (and (stringp request-line)
             (string-match " HTTP/\\([0-9]+\\.[0-9]+\\)\\(?:\r\\)?\\'" request-line))
    (match-string 1 request-line)))

(defun doclive--parse-request-headers (request)
  "Parse HTTP REQUEST headers into a case-folded alist.
Return :invalid when REQUEST contains malformed or folded headers."
  (catch 'invalid
    (let (headers)
      (dolist (line (cdr (split-string request "\r\n" t)) (nreverse headers))
        (if (not (string-match "\\`\\([^:]+\\):[ \t]*\\(.*\\)\\'" line))
            (throw 'invalid :invalid)
          (let ((name (match-string 1 line))
                (value (match-string 2 line)))
            (if (or (not (string-match-p doclive--http-header-name-regexp name))
                    (string-match-p "[[:cntrl:]]" value))
                (throw 'invalid :invalid)
              (push (cons (downcase name) value) headers))))))))

(defun doclive--request-header-values (headers name)
  "Return all values for HTTP header NAME in HEADERS."
  (let ((name (downcase name))
        values)
    (when (listp headers)
      (dolist (header headers (nreverse values))
        (when (string= (car header) name)
          (push (cdr header) values))))))

(defun doclive--parse-host-header-value (value)
  "Return (HOST PORT) from Host header VALUE, or nil when malformed."
  (let ((value (or value "")))
    (cond
     ((or (string-empty-p value)
          (string-match-p "[[:cntrl:][:space:]/?#]" value))
      nil)
     ((string-match "\\`\\(\\[[0-9A-Fa-f:.]+\\]\\)\\(?::\\([0-9]+\\)\\)?\\'" value)
      (let ((port (and (match-string 2 value)
                       (string-to-number (match-string 2 value)))))
        (and (or (null port) (doclive--valid-port-p port))
             (list (downcase (match-string 1 value)) port))))
     ((string-match "\\`\\([^:]+\\):\\([0-9]+\\)\\'" value)
      (let ((port (string-to-number (match-string 2 value))))
        (and (doclive--valid-port-p port)
             (list (downcase (match-string 1 value)) port))))
     ((string-match-p ":" value)
      nil)
     (t
      (list (downcase value) nil)))))

(defun doclive--host-header-host-matches-p (host)
  "Return non-nil when parsed Host header HOST matches `doclive-host'."
  (let ((configured (downcase doclive-host)))
    (or (string= host configured)
        (and (string= configured "::1")
             (string= host "[::1]")))))

(defun doclive--accepted-host-header-value-p (value)
  "Return non-nil when Host header VALUE is acceptable for this server."
  (let ((parsed (doclive--parse-host-header-value value)))
    (and parsed
         (or (null (cadr parsed))
             (= (cadr parsed) doclive-port))
         (or (not (doclive--loopback-host-p doclive-host))
             (doclive--host-header-host-matches-p (car parsed))))))

(defun doclive--valid-host-header-p (request-line headers)
  "Return non-nil when HEADERS are valid for REQUEST-LINE Host handling."
  (and (listp headers)
       (let ((values (doclive--request-header-values headers "host")))
         (and (<= (length values) 1)
              (if (string= (doclive--request-http-version request-line) "1.1")
                  (and (= (length values) 1)
                       (doclive--accepted-host-header-value-p (car values)))
                (cl-every #'doclive--accepted-host-header-value-p values))))))

(defun doclive--cookie-token (headers)
  "Return the doclive session token from HEADERS, or nil on ambiguity."
  (let (found invalid-or-duplicate)
    (dolist (header (doclive--request-header-values headers "cookie")
                    (and (not invalid-or-duplicate) found))
      (dolist (cookie (split-string header ";" t))
        (let ((cookie (string-trim cookie)))
          (when (string-match "\\`doclive-token=\\([^;]*\\)\\'" cookie)
            (let ((token (match-string 1 cookie)))
              (if (or found
                      (not (doclive--safe-cookie-token-p token)))
                  (setq invalid-or-duplicate t)
                (setq found token)))))))))

(defun doclive--safe-cookie-token-p (token)
  "Return non-nil when TOKEN is safe to use as a doclive cookie value."
  (and (stringp token)
       (string-match-p "\\`[A-Za-z0-9._~-]+\\'" token)))

(defun doclive--session-cookie-header ()
  "Return a Set-Cookie header for the current server token."
  (when (doclive--safe-cookie-token-p doclive--server-token)
    (format "Set-Cookie: doclive-token=%s; Path=/; SameSite=Strict; HttpOnly\r\n"
            doclive--server-token)))

(defun doclive--sse-handshake ()
  "Return SSE headers."
  (concat
   "HTTP/1.1 200 OK\r\n"
   "Content-Type: text/event-stream\r\n"
   "Cache-Control: no-cache, no-store\r\n"
   (doclive--browser-security-header-lines)
   "Connection: keep-alive\r\n\r\n"
   "retry: 1200\n\n"))

(defun doclive--authorized-request-p (path &optional headers)
  "Return non-nil if PATH is valid and HEADERS has the current token cookie."
  (and (doclive--valid-query-p path)
       (not (doclive--query-key-present-p path "bootstrap"))
       (doclive--authorized-cookie-p headers)))

(defun doclive--authorized-cookie-p (headers)
  "Return non-nil if HEADERS includes the current session cookie."
  (and (stringp doclive--server-token)
       (let ((cookie-token (doclive--cookie-token headers)))
         (and (stringp cookie-token)
              (doclive--secure-string-equal-p cookie-token doclive--server-token)))))

(defun doclive--consume-bootstrap-code-p (path)
  "Return non-nil if PATH has a valid single-use preview bootstrap code."
  (and (doclive--valid-query-p path)
       (let* ((id (doclive--query-param path "id"))
              (code (doclive--query-param path "bootstrap"))
              (entry (and code (gethash code doclive--bootstrap-codes)))
              (entry-id (and (listp entry) (plist-get entry :id)))
              (expires (and (listp entry) (plist-get entry :expires))))
         (and (stringp id)
              (doclive--safe-cookie-token-p code)
              (stringp entry-id)
              (numberp expires)
              (string= id entry-id)
              (<= (float-time) expires)
              (progn
                (remhash code doclive--bootstrap-codes)
                t)))))

(defun doclive--preview-redirect-location (path)
  "Return a token-free preview redirect location derived from PATH."
  (format "/preview?id=%s"
          (url-hexify-string (or (doclive--query-param path "id") ""))))

(defun doclive--send-preview (proc)
  "Send the preview page on PROC and close it."
  (let ((script-nonce (doclive--random-token))
        (cookie-header (doclive--session-cookie-header)))
    (process-send-string
     proc
     (doclive--http-response "200 OK" "text/html"
                              (doclive--preview-html script-nonce)
                              script-nonce
                              (and cookie-header (list cookie-header))))
    (delete-process proc)))

(defun doclive--send-bootstrap-redirect (proc path)
  "Set the preview session cookie and redirect PROC to token-free PATH."
  (let ((cookie-header (doclive--session-cookie-header)))
    (process-send-string
     proc
     (doclive--http-response "303 See Other" "text/plain" ""
                              nil
                              (append
                               (list (format "Location: %s\r\n"
                                             (doclive--preview-redirect-location path)))
                               (and cookie-header (list cookie-header)))))
    (delete-process proc)))

(defun doclive--send-forbidden (proc)
  "Send a forbidden response on PROC and close it."
  (process-send-string proc (doclive--http-response "403 Forbidden" "text/plain" "Forbidden"))
  (delete-process proc))

(defun doclive--route-request (proc path &optional headers)
  "Route request on PROC for PATH and optional HEADERS."
  (cond
   ((doclive--route-matches-p path "/")
    (if (doclive--authorized-request-p path headers)
        (doclive--send-preview proc)
      (doclive--send-forbidden proc)))
   ((doclive--route-matches-p path "/preview")
    (cond
     ((doclive--authorized-request-p path headers)
      (doclive--send-preview proc))
     ((doclive--query-key-present-p path "bootstrap")
      (if (doclive--consume-bootstrap-code-p path)
          (doclive--send-bootstrap-redirect proc path)
        (doclive--send-forbidden proc)))
     (t
      (doclive--send-forbidden proc))))
   ((doclive--route-matches-p path "/content")
    (if (doclive--authorized-request-p path headers)
        (let ((id (doclive--query-param path "id")))
          (process-send-string proc (doclive--http-response "200 OK" "application/json" (doclive--json-for-id id)))
          (delete-process proc))
      (doclive--send-forbidden proc)))
   ((doclive--route-matches-p path "/open")
    (if (doclive--authorized-request-p path headers)
        (let ((id (doclive--query-param path "id"))
              (rel (doclive--query-param path "path")))
          (process-send-string
           proc
           (doclive--http-response "200 OK" "application/json"
                                    (doclive--open-linked-document id rel)))
          (delete-process proc))
      (doclive--send-forbidden proc)))
   ((doclive--route-matches-p path "/events")
    (if (doclive--authorized-request-p path headers)
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
        (let* ((head (substring buffer 0 (string-match "\r\n\r\n" buffer)))
               (line (car (split-string head "\r\n" t)))
               (path (doclive--parse-request-path line))
               (headers (doclive--parse-request-headers head)))
          (if (not (doclive--valid-request-line-p line))
              (progn
                (process-send-string proc (doclive--http-response "400 Bad Request" "text/plain" "Bad Request"))
                (delete-process proc))
            (if (or (eq headers :invalid)
                    (not (doclive--valid-host-header-p line headers)))
                (progn
                  (process-send-string proc (doclive--http-response "400 Bad Request" "text/plain" "Bad Request"))
                  (delete-process proc))
              (doclive--route-request proc path headers))))))))

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
    (message "doclive server started: http://%s:%d"
             (doclive--url-host doclive-host)
             doclive-port)))

;;;###autoload
(defun doclive-stop-server ()
  "Stop doclive local server."
  (interactive)
  (when (processp doclive--server)
    (delete-process doclive--server))
  (setq doclive--server nil)
  (setq doclive--server-token nil)
  (clrhash doclive--bootstrap-codes)
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
  (let ((id (doclive--buffer-id buffer)))
    (doclive--ensure-server-token)
    (format "http://%s:%d/preview?id=%s&bootstrap=%s"
            (doclive--url-host doclive-host)
            doclive-port
            (url-hexify-string id)
            (url-hexify-string (doclive--create-bootstrap-code id)))))

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
