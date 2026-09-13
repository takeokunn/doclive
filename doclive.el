;;; doclive.el --- Fast Markdown and Org preview for AI docs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 takeokunn <bararararatty@gmail.com>
;;
;; Author: takeokunn <bararararatty@gmail.com>
;; Maintainer: takeokunn <bararararatty@gmail.com>
;; URL: https://github.com/takeokunn/doclive
;; Version: 1.4.0
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
;; - Mermaid diagrams (backtick and tilde fences, mmd alias), with
;;   Fit / 100% / Expand controls and a zoom/pan overlay
;; - KaTeX math, including LaTeX environments
;;   (equation, align, gather, cases, etc.)
;; - Syntax highlighting via highlight.js
;; - TOC sidebar and code-copy buttons
;; - Search with pin-system highlighting and dark/light theme toggle
;; - In-page navigation for linked .md / .org documents
;; - Session management: buffer-kill cleanup, Emacs shutdown hook
;; - C-u prefix arg on `doclive-preview-buffer' restarts the server
;; - Preview buffer remaps copy/yank to the xwidget page's selection
;;   and search box via `doclive-xwidget-preview-mode'
;;
;; Customization options:
;;
;; - doclive-host :: bind host (default \"127.0.0.1\")
;; - doclive-allow-non-loopback-host :: allow non-loopback bind hosts
;; - doclive-port :: bind port (default 39123)
;; - doclive-open-browser-function :: URL opening function (default
;;   xwidget-first, falls back to `browse-url')
;; - doclive-xwidget-display-buffer-action :: display-buffer ACTION for
;;   the xwidget preview window (default: split right)
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
(declare-function xwidget-webkit-pass-command-event "xwidget" ())
(declare-function xwidget-webkit-execute-script "xwidget.c" (xwidget script &optional callback))
(declare-function xwidget-webkit-goto-uri "xwidget.c" (xwidget uri))
(declare-function xwidget-webkit-uri "xwidget.c" (xwidget))
(declare-function xwidget-webkit-current-session "xwidget" ())
(declare-function xwidget-webkit-adjust-size-to-window "xwidget" (xwidget &optional window))
(declare-function get-buffer-xwidgets "xwidget.c" (buffer))
(declare-function set-xwidget-query-on-exit-flag "xwidget.c" (xwidget flag))
(declare-function xwidget-at "xwidget" (pos))

(defgroup doclive nil
  "Fast Markdown and Org preview for AI-generated documents."
  :group 'tools
  :prefix "doclive-")

(defcustom doclive-host "127.0.0.1"
  "Host address for doclive local server."
  :type 'string
  :package-version '(doclive . "1.2.0")
  :group 'doclive)

(defcustom doclive-allow-non-loopback-host nil
  "Whether doclive may bind the preview server to non-loopback hosts.
Keep this nil unless you understand that the preview server grants
cookie-authenticated access to local document contents."
  :type 'boolean
  :package-version '(doclive . "1.2.0")
  :group 'doclive)

(defcustom doclive-port 39123
  "Port for doclive local server."
  :type 'natnum
  :package-version '(doclive . "1.2.0")
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

(defvar doclive-preview-mode)

(defun doclive-open-url (url)
  "Open URL with xwidget WebKit, falling back to `browse-url'."
  (interactive "sPreview URL: ")
  (cond
   ((not (doclive-xwidget-available-p)) (browse-url url))
   ((bound-and-true-p doclive-preview-mode)
    (doclive--xwidget-open-preview url (current-buffer)))
   (t (doclive-open-url-in-xwidget url))))

(defcustom doclive-open-browser-function #'doclive-open-url
  "Function used to open preview URL.
The default uses xwidget WebKit when available and falls back to
`browse-url' otherwise."
  :type 'function
  :package-version '(doclive . "1.2.0")
  :group 'doclive)

(defcustom doclive-xwidget-display-buffer-action
  '(display-buffer-in-direction (direction . right))
  "Display-buffer ACTION used for the xwidget preview."
  :type 'sexp
  :package-version '(doclive . "1.3.0")
  :group 'doclive)

(defvar doclive--buffers)
(defvar doclive--server-token)

(defun doclive--xwidget-bridge-origin (widget buffer)
  "Validate WIDGET ownership and preview location in BUFFER, returning its origin."
  (let ((origin (format "http://%s:%d" (doclive--url-host doclive-host) doclive-port))
        owned)
    (when (and widget (buffer-live-p buffer) doclive--server-token
               (memq widget (get-buffer-xwidgets buffer)))
      (maphash (lambda (_id entry)
                 (when (and (eq (plist-get entry :xwidget-buffer) buffer)
                            (equal (plist-get entry :xwidget-token) doclive--server-token))
                   (setq owned t)))
               doclive--buffers))
    (unless (and owned
                 (string-match-p
                  (concat "\\`" (regexp-quote origin) "/preview\\(?:[?#]\\|\\'\\)")
                  (or (xwidget-webkit-uri widget) "")))
      (user-error "Not an owned doclive preview; reopen the document preview"))
    origin))

(defun doclive--xwidget-execute (widget buffer script &optional callback)
  "Run SCRIPT only in BUFFER's owned preview WIDGET, with CALLBACK."
  (let ((origin (doclive--xwidget-bridge-origin widget buffer)))
    (xwidget-webkit-execute-script
     widget
     (format "(()=>{if(window.location.origin!==%s||window.location.pathname!=='/preview')return null;return %s})()"
             (json-encode-string origin) script)
     callback)))

(defun doclive-xwidget-copy-selection ()
  "Copy the active xwidget preview's text selection to the kill ring."
  (interactive)
  (let ((xwidget (xwidget-webkit-current-session)))
    (unless xwidget
      (user-error "No active doclive xwidget preview"))
    (doclive--xwidget-execute
     xwidget (current-buffer)
     "window.docliveGetSelection?window.docliveGetSelection():window.getSelection().toString();"
     (lambda (result)
       (if (and (stringp result) (not (string-empty-p result)))
           (progn
             (kill-new result)
             (message "Copied %d characters from preview" (length result)))
         (message "No selection in preview"))))))

(defun doclive--json-escape-line-separators (encoded)
  "Escape raw U+2028/U+2029 line separators `json-encode-string' leaves in ENCODED.
Both are valid unescaped JSON string content but invalid unescaped
JavaScript string content, so a value containing either breaks the
script it is embedded in."
  (let ((s (replace-regexp-in-string " " "\\u2028" encoded t t)))
    (replace-regexp-in-string " " "\\u2029" s t t)))

(defun doclive-xwidget-yank-to-search ()
  "Paste the latest kill into the focused input, or start a page search."
  (interactive)
  (let ((xwidget (xwidget-webkit-current-session)))
    (unless xwidget
      (user-error "No active doclive xwidget preview"))
    (unless kill-ring
      (user-error "Kill ring is empty"))
    (doclive--xwidget-execute
     xwidget (current-buffer)
     (format "window.doclivePaste(%s)?'pasted':'rejected';"
             (doclive--json-escape-line-separators (json-encode-string (current-kill 0))))
     (lambda (result)
       (message
        (cond ((equal result "pasted") "Pasted into doclive preview")
              ((equal result "rejected") "Cannot paste into this preview input")
              (t "Paste unavailable: preview changed or is not ready")))))))

(defvar doclive--xwidget-search-history nil)
(defvar-local doclive--xwidget-search-text "")
(defvar-local doclive--xwidget-wiki-search-text "")
(defvar-local doclive--xwidget-search-request nil)

(defun doclive--xwidget-search (wiki backward)
  "Read a native search for WIKI or the current page, optionally BACKWARD."
  (let* ((widget (xwidget-webkit-current-session))
         (origin (current-buffer))
         (window (selected-window))
         (displayed (window-buffer window))
         (request (make-symbol "doclive-search")))
    (setq doclive--xwidget-search-request request)
    (doclive--xwidget-execute
     widget origin (format "window.docliveGetSearch(%s);" (if wiki "true" "false"))
     (lambda (initial)
       (when (buffer-live-p origin)
         (with-current-buffer origin
           (when (eq request doclive--xwidget-search-request)
             (setq doclive--xwidget-search-request nil)
             (when (and (eq window (selected-window))
                        (eq displayed (window-buffer window))
                        (not (active-minibuffer-window)))
               (if (stringp initial)
                   (doclive--xwidget-read-search widget origin wiki backward initial)
                 (message "Search unavailable: preview changed or is not ready"))))))))))

(defun doclive--xwidget-read-search (widget origin wiki backward initial)
  "Search WIDGET in ORIGIN from INITIAL, using WIKI and BACKWARD options."
  (let* ((last-text nil)
         (map (copy-keymap minibuffer-local-map)))
    (doclive--xwidget-bridge-origin widget origin)
    (cl-labels
        ((send (text)
           (doclive--xwidget-execute
            widget origin (format "window.%s(%s);"
                           (if wiki "docliveSetWikiSearch" "docliveSetSearch")
                           (doclive--json-escape-line-separators
                            (json-encode-string text)))))
         (update ()
           (let ((text (minibuffer-contents-no-properties)))
             (unless (equal text last-text)
               (setq last-text text)
               (send text))))
         (step (reverse)
           (doclive--xwidget-execute
            widget origin (format "window.docliveSearchNext(%s);"
                           (if reverse "true" "false")))))
      (unless wiki
        (define-key map (kbd "C-s") (lambda () (interactive) (step nil)))
        (define-key map (kbd "C-r") (lambda () (interactive) (step t))))
      (condition-case nil
          (let ((text
                 (minibuffer-with-setup-hook
                     (lambda ()
                       (add-hook 'post-command-hook #'update nil t)
                       (update)
                       (when backward (step t)))
                   (read-from-minibuffer
                    (if wiki "Wiki search: " "Preview search: ")
                    initial map nil 'doclive--xwidget-search-history))))
            (when (buffer-live-p origin)
              (with-current-buffer origin
                (if wiki (setq doclive--xwidget-wiki-search-text text)
                  (setq doclive--xwidget-search-text text)))))
        (quit (send initial))))))

(defun doclive-xwidget-search ()
  "Search the preview incrementally from the Emacs minibuffer."
  (interactive)
  (doclive--xwidget-search nil nil))

(defun doclive-xwidget-search-backward ()
  "Search backward in the preview from the Emacs minibuffer."
  (interactive)
  (doclive--xwidget-search nil t))

(defun doclive-xwidget-wiki-search ()
  "Search the Wiki workspace from the Emacs minibuffer."
  (interactive)
  (doclive--xwidget-search t nil))

(defun doclive--xwidget-command (script)
  "Run SCRIPT in the active preview."
  (let ((widget (xwidget-webkit-current-session)))
    (unless widget (user-error "No active doclive xwidget preview"))
    (doclive--xwidget-execute widget (current-buffer) script)))

(defun doclive-xwidget-dismiss ()
  "Dismiss preview search and open panels."
  (interactive)
  (setq doclive--xwidget-search-request nil
        doclive--xwidget-search-text "" doclive--xwidget-wiki-search-text "")
  (doclive--xwidget-command "window.docliveDismiss();"))

(defun doclive-xwidget-back ()
  "Go back in preview navigation history."
  (interactive)
  (doclive--xwidget-command "history.back();"))

(defun doclive-xwidget-forward ()
  "Go forward in preview navigation history."
  (interactive)
  (doclive--xwidget-command "history.forward();"))

(define-minor-mode doclive-xwidget-preview-mode
  "Minor mode active in a doclive xwidget preview buffer.
Remaps copy and yank commands to operate on the previewed page's
selection and search box instead of ordinary buffer text.
Typing and editing keys go directly to WebKit's focused element."
  :lighter " doclive"
  :keymap (let ((map (make-sparse-keymap)))
            (substitute-key-definition 'self-insert-command
                                       'xwidget-webkit-pass-command-event map global-map)
            (define-key map [remap self-insert-command] #'xwidget-webkit-pass-command-event)
            (dolist (key '("RET" "TAB" "DEL" "<backspace>" "<tab>" "<return>"
                           "<left>" "<right>" "<up>" "<down>"
                           "C-<left>" "C-<right>" "C-<up>" "C-<down>" "C-<return>"
                           "S-<left>" "S-<right>" "S-<up>" "S-<down>" "S-<return>"
                           "M-<left>" "M-<right>" "M-<up>" "M-<down>" "M-<return>"
                           "C-<backspace>" "<delete>" "<backtab>"))
              (define-key map (kbd key) #'xwidget-webkit-pass-command-event))
            (define-key map [remap kill-ring-save] #'doclive-xwidget-copy-selection)
            (define-key map [remap ns-copy-including-secondary] #'doclive-xwidget-copy-selection)
            (define-key map [remap yank] #'doclive-xwidget-yank-to-search)
            (dolist (key '("C-s" "s-f"))
              (define-key map (kbd key) #'doclive-xwidget-search))
            (define-key map (kbd "C-r") #'doclive-xwidget-search-backward)
            (define-key map (kbd "s-k") #'doclive-xwidget-wiki-search)
            (dolist (key '("s-c" "M-w"))
              (define-key map (kbd key) #'doclive-xwidget-copy-selection))
            (define-key map (kbd "C-y") #'doclive-xwidget-yank-to-search)
            (define-key map (kbd "<escape>") #'doclive-xwidget-dismiss)
            (define-key map (kbd "M-<left>") #'doclive-xwidget-back)
            (define-key map (kbd "M-<right>") #'doclive-xwidget-forward)
            map))

(defcustom doclive-change-debounce-ms 150
  "Debounce delay in milliseconds for after-change snapshots.
Lower values give faster preview but more CPU usage."
  :type 'natnum
  :package-version '(doclive . "1.2.0")
  :group 'doclive)

(defcustom doclive-preview-asset-urls
  '((highlight-css . "https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11.11.1/styles/github-dark.min.css")
    (katex-css . "https://cdn.jsdelivr.net/npm/katex@0.17.0/dist/katex.min.css")
    (marked-script . "https://cdn.jsdelivr.net/npm/marked@18.0.5/lib/marked.umd.js")
    (highlight-script . "https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11.11.1/highlight.min.js")
    (katex-script . "https://cdn.jsdelivr.net/npm/katex@0.17.0/dist/katex.min.js")
    (katex-auto-render-script . "https://cdn.jsdelivr.net/npm/katex@0.17.0/dist/contrib/auto-render.min.js")
    (mermaid-script . "https://cdn.jsdelivr.net/npm/mermaid@11.16.0/dist/mermaid.min.js"))
  "Alist of browser asset URLs used by the preview page.
The default values point to pinned CDN releases.  Customize this
variable if you want to mirror the assets locally or swap CDNs.
Each URL must be an absolute http(s) URL or a same-origin relative
URL."
  :type '(alist :key-type symbol :value-type string)
  :package-version '(doclive . "1.2.0")
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
  :package-version '(doclive . "1.2.0")
  :group 'doclive)

(defcustom doclive-wiki-state-file
  (locate-user-emacs-file "doclive-wiki.json")
  "File for recent Wiki roots, bookmarks and reading preferences.
Set to nil to keep this state only for the current Emacs session."
  :type '(choice (const :tag "Do not save" nil) file)
  :group 'doclive)

(defvar doclive--wiki-state nil
  "Persisted Wiki state as an alist.")

(defvar doclive--wiki-state-loaded nil
  "Whether Wiki state has been loaded in this session.")

(defvar-local doclive--wiki-root nil
  "Canonical Wiki root associated with this preview buffer.")

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

(defvar-local doclive--xwidget-buffer nil
  "This document buffer's dedicated xwidget preview buffer, if any.
Kept buffer-local on the owning document buffer so it survives
`doclive-stop-server' clearing `doclive--buffers'.")

(defvar-local doclive--xwidget-token nil
  "Server token the current `doclive--xwidget-buffer' was last opened with.")

(defvar doclive--buffer-id-token-function #'doclive--random-token
  "Function used to create opaque preview IDs for buffers.")

(defvar doclive--max-request-bytes 16384
  "Maximum size of a buffered HTTP request header block.")

(defconst doclive--request-header-timeout-seconds 10
  "Seconds a connection may take to send its complete HTTP header block.
Connections that do not finish their headers in time are closed to
bound slow-request resource exhaustion.")

(defconst doclive--max-sse-clients-per-buffer 32
  "Maximum concurrent Server-Sent Events clients tracked per buffer.
Requests beyond this bound are refused to cap descriptor exhaustion.")

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
When SCRIPT-NONCE is safe for a CSP nonce, allow matching inline scripts.
Inline styles are allowed because KaTeX and Mermaid position rendered
output through generated style attributes and SVG style elements, which
CSP nonces cannot authorize; the preview sanitizer strips style elements
and style attributes from document-derived HTML before DOM insertion, so
this applies only to trusted runtime-generated styles."
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
      (concat "style-src " asset-sources " 'unsafe-inline'")
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

(defconst doclive--preview-asset-integrity
  '(("https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11.11.1/styles/github-dark.min.css"
     . "sha384-wH75j6z1lH97ZOpMOInqhgKzFkAInZPPSPlZpYKYTOqsaizPvhQZmAtLcPKXpLyH")
    ("https://cdn.jsdelivr.net/npm/katex@0.17.0/dist/katex.min.css"
     . "sha384-vlBdW0r3AcZO/HboRPznQNowvexd3fY8qHOWkBi5q7KGgqJ+F48+DceybYmrVbmB")
    ("https://cdn.jsdelivr.net/npm/marked@18.0.5/lib/marked.umd.js"
     . "sha384-ZD0fTOwPMHi7zM6WTVIWJR21I07lq0ccnqz3J6WMvQKG9thh4y7TA1QE6PJu0Af8")
    ("https://cdn.jsdelivr.net/npm/@highlightjs/cdn-assets@11.11.1/highlight.min.js"
     . "sha384-RH2xi4eIQ/gjtbs9fUXM68sLSi99C7ZWBRX1vDrVv6GQXRibxXLbwO2NGZB74MbU")
    ("https://cdn.jsdelivr.net/npm/katex@0.17.0/dist/katex.min.js"
     . "sha384-AtrdNsnxl/75rvBneBVH7DtOvCxSVahR2zWqle1coBKd8DEmLoviqNeJSx64gNAs")
    ("https://cdn.jsdelivr.net/npm/katex@0.17.0/dist/contrib/auto-render.min.js"
     . "sha384-bjyGPfbij8/NDKJhSGZNP/khQVgtHUE5exjm4Ydllo42FwIgYsdLO2lXGmRBf5Mz")
    ("https://cdn.jsdelivr.net/npm/mermaid@11.16.0/dist/mermaid.min.js"
     . "sha384-T/0lMUdJpd2S1ZHtRiofG3htU3xPCrFVeAQ1UUE2TJwlEJSV5NUwn30kP28n238E"))
  "Subresource Integrity hashes for the pinned default browser assets.
Keyed by the exact default URL so that customized mirrors, which cannot
share these hashes, simply load without an integrity attribute.")

(defun doclive--preview-asset-integrity-attrs (key)
  "Return SRI/crossorigin attributes for asset KEY, or an empty string.
The attributes are emitted only when the configured URL matches the
pinned default, so custom mirrors keep working."
  (let ((hash (assoc-default (alist-get key doclive-preview-asset-urls)
                             doclive--preview-asset-integrity)))
    (if hash
        (format " integrity='%s' crossorigin='anonymous'"
                (doclive--escape-html-attribute hash))
      "")))

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
  "Return a high-entropy token string for local bearer authentication.
Prefer /dev/urandom, which avoids spawning a subprocess per token, and
fall back to openssl rand where /dev/urandom is unavailable."
  (or (doclive--random-token-from-urandom)
      (let ((openssl (executable-find "openssl")))
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
      (user-error "Doclive requires /dev/urandom or openssl rand for secure tokens")))

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
                          :html ""
                          :xwidget-buffer nil
                          :xwidget-token nil))))
    (setf (plist-get entry :buffer) buffer)
    (setf (plist-get entry :name) (buffer-name buffer))
    (setf (plist-get entry :file) (buffer-local-value 'buffer-file-name buffer))
    (setf (plist-get entry :wiki-root) (buffer-local-value 'doclive--wiki-root buffer))
    (setf (plist-get entry :xwidget-buffer) (buffer-local-value 'doclive--xwidget-buffer buffer))
    (setf (plist-get entry :xwidget-token) (buffer-local-value 'doclive--xwidget-token buffer))
    (doclive--put-entry id entry)
    entry))

(defun doclive--xwidget-remember (owner entry buffer token)
  "Record BUFFER and TOKEN as the xwidget preview state for OWNER and ENTRY.
Mirrors the state into both the entry plist and OWNER's buffer-local
variables so it survives `doclive--buffers' being cleared."
  (setf (plist-get entry :xwidget-buffer) buffer)
  (setf (plist-get entry :xwidget-token) token)
  (doclive--put-entry (plist-get entry :id) entry)
  (with-current-buffer owner
    (setq doclive--xwidget-buffer buffer)
    (setq doclive--xwidget-token token)))

(defun doclive--xwidget-open-preview (url owner)
  "Open URL in OWNER's dedicated xwidget preview buffer, creating it if needed."
  (let* ((entry (doclive--ensure-entry owner))
         (xwidget-buffer (plist-get entry :xwidget-buffer)))
    (if (and (buffer-live-p xwidget-buffer) (get-buffer-xwidgets xwidget-buffer))
        (unless (equal (plist-get entry :xwidget-token) doclive--server-token)
          (xwidget-webkit-goto-uri
           (with-current-buffer xwidget-buffer (xwidget-at (point-min)))
           url)
          (doclive--xwidget-remember owner entry xwidget-buffer doclive--server-token))
      (when (buffer-live-p xwidget-buffer)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer xwidget-buffer)))
      (let (buf)
        (save-window-excursion
          (xwidget-webkit-new-session url)
          (setq buf (current-buffer)))
        (with-current-buffer buf
          (dolist (xw (get-buffer-xwidgets buf))
            (set-xwidget-query-on-exit-flag xw nil))
          (doclive-xwidget-preview-mode 1))
        (doclive--xwidget-remember owner entry buf doclive--server-token)
        (setq xwidget-buffer buf)))
    (let ((window (display-buffer xwidget-buffer doclive-xwidget-display-buffer-action)))
      (when (and window (get-buffer-xwidgets xwidget-buffer))
        (xwidget-webkit-adjust-size-to-window
         (car (get-buffer-xwidgets xwidget-buffer)) window)))
    xwidget-buffer))

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

(defconst doclive--org-unsafe-directive-regexps
  '(("eval macro" . "^[ \t]*#\\+MACRO:[ \t]*[^ \t\n]+[ \t]+(eval\\b")
    ("INCLUDE directive" . "^[ \t]*#\\+INCLUDE:")
    ("SETUPFILE directive" . "^[ \t]*#\\+SETUPFILE:"))
  "Org directives that execute code or read files during export.
These are rejected before export because Babel-disabling options do not
gate the macro evaluator, file inclusion, or setup-file loading.")

(defun doclive--org-unsafe-directive (text)
  "Return a description of the first unsafe Org directive in TEXT, or nil."
  (let ((case-fold-search t))
    (cl-loop for (label . regexp) in doclive--org-unsafe-directive-regexps
             when (string-match-p regexp text)
             return label)))

(defun doclive--org-to-html (text)
  "Export Org TEXT to a safe HTML body fragment without Babel execution.
Reject documents containing directives that would execute Emacs Lisp or
read local files during export, since Org's macro evaluator, `#+INCLUDE:',
and `#+SETUPFILE:' run independently of Babel."
  (let ((unsafe (doclive--org-unsafe-directive text)))
    (if unsafe
        (format "<pre class=\"doclive-export-error\">%s</pre>"
                (doclive--escape-html
                 (format "doclive refused to render an Org %s for security reasons"
                         unsafe)))
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
                   (doclive--escape-html (error-message-string err)))))))))

(defun doclive--snapshot-buffer (buffer)
  "Capture BUFFER contents and notify clients."
  (doclive--cleanup-stale-entries)
  (let* ((entry (doclive--ensure-entry buffer))
         (id (plist-get entry :id))
         (org-buffer-p (doclive--org-buffer-p buffer))
         (source-tick (with-current-buffer buffer
                        (buffer-chars-modified-tick)))
         (reuse-org-html-p
          (and org-buffer-p
               (equal source-tick (plist-get entry :source-tick))
               (string= (plist-get entry :content-kind) "org-html")))
         (text (unless reuse-org-html-p
                 (with-current-buffer buffer
                   (buffer-substring-no-properties (point-min) (point-max)))))
         (rev (1+ (or (plist-get entry :revision) 0))))
    (setf (plist-get entry :revision) rev)
    (setf (plist-get entry :source-tick) source-tick)
    (setf (plist-get entry :content-kind) (if org-buffer-p "org-html" "markdown"))
    (setf (plist-get entry :markdown) (if org-buffer-p "" text))
    (unless reuse-org-html-p
      (setf (plist-get entry :html) (if org-buffer-p (doclive--org-to-html text) "")))
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
  "Decode query component VALUE as UTF-8 text.
Return nil when VALUE is not valid percent-encoded data."
  (let ((raw (or value "")))
    (unless (string-match-p "%\\(?:\\'\\|[^[:xdigit:]]\\|[[:xdigit:]]\\'\\|[[:xdigit:]][^[:xdigit:]]\\)" raw)
      (condition-case _
          (decode-coding-string
           (url-unhex-string
            (replace-regexp-in-string "\\+" " " raw t t))
           'utf-8 t)
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

(defconst doclive--wiki-excluded-directories
  '(".git" ".svn" "node_modules" ".cache"))

(defun doclive--wiki-path-allowed-p (file root)
  "Return non-nil when FILE resolves inside ROOT outside excluded directories."
  (condition-case nil
      (let* ((root (file-name-as-directory (file-truename root)))
             (file (file-truename file))
             (ignore-case (file-name-case-insensitive-p file)))
        (and (string-prefix-p root file ignore-case)
             (not (cl-intersection
                   (split-string (if ignore-case
                                     (downcase (file-relative-name file root))
                                   (file-relative-name file root)) "/" t)
                   doclive--wiki-excluded-directories :test #'equal))))
    (file-error nil)))

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
         (root (plist-get entry :wiki-root))
         (full (and target dir (expand-file-name target dir))))
    (cond
     ((not full) nil)
     ((and (doclive--previewable-document-file-p full)
           (if root (doclive--wiki-path-allowed-p full root)
             (doclive--linked-document-allowed-p full dir)))
      full)
     ((string= (downcase (or (file-name-extension full) "")) "html")
      (cl-loop for ext in '("org" "md")
               for candidate = (concat (file-name-sans-extension full) "." ext)
               when (and (doclive--previewable-document-file-p candidate)
                         (if root (doclive--wiki-path-allowed-p candidate root)
                           (doclive--linked-document-allowed-p candidate dir)))
               return candidate))
     (t nil))))

(defvar doclive-preview-mode)

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
               (new-entry
                (with-current-buffer buf
                  (setq doclive--wiki-root (plist-get entry :wiki-root))
                  (if doclive-preview-mode
                      (doclive--snapshot-buffer buf)
                    (doclive-preview-mode 1)
                    (doclive--get-entry (doclive--buffer-id buf)))))
               (new-id (plist-get new-entry :id)))
          (when (plist-get entry :wiki-root)
            (doclive--wiki-remember-page (plist-get entry :wiki-root) full))
          (json-encode `((ok . t)
                         (buffer_id . ,new-id)
                         (name . ,(plist-get new-entry :name)))))))))

(defun doclive--wiki-load-state ()
  "Load reading state without evaluating Lisp or changing document buffers."
  (unless doclive--wiki-state-loaded
    (setq doclive--wiki-state-loaded t)
    (when (and doclive-wiki-state-file
               (file-readable-p doclive-wiki-state-file))
      (condition-case nil
          (with-temp-buffer
            (insert-file-contents doclive-wiki-state-file)
            (setq doclive--wiki-state
                  (json-parse-buffer :object-type 'alist :array-type 'list
                                     :null-object nil :false-object nil)))
        (error (message "Doclive: unreadable Wiki state; starting fresh"))))))

(defun doclive--wiki-save-state ()
  "Atomically persist reading state when storage is enabled."
  (when doclive-wiki-state-file
    (let* ((file (expand-file-name doclive-wiki-state-file))
           (directory (file-name-directory file))
           temporary)
      (condition-case err
          (unwind-protect
              (progn
                (make-directory directory t)
                (setq temporary (make-temp-file
                                 (expand-file-name ".doclive-" directory)))
                (with-temp-file temporary
                  (insert (json-encode doclive--wiki-state)))
                (set-file-modes temporary #o600)
                (rename-file temporary file t))
            (when (and temporary (file-exists-p temporary))
              (delete-file temporary)))
        (file-error (message "Doclive: cannot save reading state: %s"
                             (error-message-string err)))))))

(defun doclive--wiki-files (root)
  "Return sorted canonical readable Markdown and Org files under ROOT.
Do not visit document buffers or follow directory symlinks."
  (let ((root (file-name-as-directory (file-truename root)))
        files)
    (cl-labels
        ((walk (directory)
           (dolist (file (condition-case nil
                            (directory-files directory t
                                             directory-files-no-dot-files-regexp)
                          (file-error nil)))
             (cond
              ((file-directory-p file)
               (unless (or (file-symlink-p file)
                           (not (doclive--wiki-path-allowed-p file root)))
                 (walk file)))
              ((and (doclive--previewable-document-file-p file)
                    (doclive--wiki-path-allowed-p file root))
               (push (file-truename file) files))))))
      (walk root))
    (sort (delete-dups files) #'string-lessp)))

(defun doclive--wiki-read (file)
  "Read FILE without visiting it, preferring an existing edited buffer."
  (let ((buffer (find-buffer-visiting file)))
    (if (and buffer (buffer-modified-p buffer))
        (with-current-buffer buffer
          (save-restriction
            (widen)
            (buffer-substring-no-properties (point-min) (point-max))))
      (with-temp-buffer
        (insert-file-contents file)
        (buffer-string)))))

(defun doclive--wiki-title (file text)
  "Return the first heading in TEXT, or FILE's base name."
  (let ((case-fold-search t))
    (if (string-match "^\\(?:#+ +\\|\\*+ +\\|#\\+title: *\\)\\(.+\\)$" text)
        (string-trim (match-string 1 text))
      (file-name-base file))))

(defun doclive--wiki-search (root query)
  "Search QUERY in Wiki ROOT, returning at most 100 ranked result plists.
Prefer literal title or path matches, then whitespace-separated literal
tokens across title and path in any order, then literal body matches.
Each result has relative :path, display :name and body :snippet fields.
An empty or whitespace-only query returns nil.  No files are visited."
  (let* ((root (file-name-as-directory (file-truename root)))
         (query (string-trim (or query "")))
         (pattern (regexp-quote query))
         (tokens (mapcar #'regexp-quote (split-string query nil t)))
         (case-fold-search t)
         (buckets (vector nil nil nil)))
    (unless (string-empty-p query)
      (dolist (file (doclive--wiki-files root))
        (condition-case nil
            (let* ((text (doclive--wiki-read file))
                   (path (file-relative-name file root))
                   (name (doclive--wiki-title file text))
                   (metadata (concat name "\n" path))
                   (hit (string-match pattern text))
                   (rank (cond
                          ((or (string-match-p pattern name)
                               (string-match-p pattern path)) 0)
                          ((seq-every-p
                            (lambda (token) (string-match-p token metadata))
                            tokens) 1)
                          (hit 2))))
              (when (and rank (< (length (aref buckets rank)) 100))
                (push (list :path path :name name
                            :snippet (replace-regexp-in-string
                                      "[\n\r\t ]+" " "
                                      (substring text (max 0 (- (or hit 0) 60))
                                                 (min (length text)
                                                      (+ (or hit 0) 180)))))
                      (aref buckets rank))))
          (file-error nil))))
    (seq-take (append (nreverse (aref buckets 0))
                      (nreverse (aref buckets 1))
                      (nreverse (aref buckets 2)))
              100)))

(defun doclive--wiki-remember-page (root file)
  "Remember FILE as a recently read page in ROOT."
  (doclive--wiki-load-state)
  (let* ((key (intern root))
         (pages (alist-get 'recent doclive--wiki-state))
         (relative (file-relative-name file root))
         (recent (cons relative (delete relative (alist-get key pages)))))
    (setf (alist-get key pages) (seq-take recent 20)
          (alist-get 'recent doclive--wiki-state) pages))
  (doclive--wiki-save-state))

(defun doclive--wiki-workspace (id path)
  "Return Wiki metadata for ID, applying validated preferences from PATH."
  (doclive--wiki-load-state)
  (let* ((entry (doclive--get-entry id))
         (root (plist-get entry :wiki-root)))
    (if (not root)
        '((ok . t) (workspace . :json-false))
      (let* ((key (intern root))
             (bookmarks (alist-get 'bookmarks doclive--wiki-state))
             (marked (alist-get key bookmarks))
             (bookmark (doclive--query-param path "bookmark"))
             (theme (doclive--query-param path "theme"))
             (zoom (doclive--query-param path "zoom"))
             (pins (doclive--query-param path "pins"))
             (files (doclive--wiki-files root))
             changed)
        (when (and bookmark
                   (member (expand-file-name bookmark root) files))
          (setq marked (delete bookmark marked))
          (when (equal (doclive--query-param path "value") "1")
            (push bookmark marked))
          (setf (alist-get key bookmarks) marked
                (alist-get 'bookmarks doclive--wiki-state) bookmarks)
          (setq changed t))
        (when (member theme '("dark" "light"))
          (setf (alist-get 'theme doclive--wiki-state) theme)
          (setq changed t))
        (when (and zoom (string-match-p "\\`[0-9.]+\\'" zoom)
                   (<= 0.7 (string-to-number zoom) 2))
          (setf (alist-get 'zoom doclive--wiki-state) (string-to-number zoom))
          (setq changed t))
        (when (and pins (< (length pins) 2000))
          (let ((values (condition-case nil
                            (json-parse-string pins :array-type 'list)
                          (error :invalid))))
            (when (and (listp values) (seq-every-p #'stringp values))
              (setf (alist-get 'pins doclive--wiki-state) (seq-take values 12))
              (setq changed t))))
        (when changed (doclive--wiki-save-state))
        `((ok . t) (workspace . t)
          (name . ,(file-name-nondirectory (directory-file-name root)))
          (current . ,(file-relative-name (plist-get entry :file) root))
          (bookmarks . ,(vconcat marked))
          (recent . ,(vconcat (alist-get key (alist-get 'recent doclive--wiki-state))))
          (theme . ,(or (alist-get 'theme doclive--wiki-state) "dark"))
          (zoom . ,(or (alist-get 'zoom doclive--wiki-state) 1))
          (pins . ,(vconcat (alist-get 'pins doclive--wiki-state)))
          (files . ,(vconcat
                     (mapcar
                      (lambda (file)
                        `((path . ,(file-relative-name file root))
                          (name . ,(condition-case nil
                                       (doclive--wiki-title file (doclive--wiki-read file))
                                     (file-error (file-name-base file))))))
                      files))))))))

(defun doclive--wiki-open (id relative)
  "Open root-relative RELATIVE in the Wiki associated with ID."
  (let* ((entry (doclive--get-entry id))
         (root (plist-get entry :wiki-root))
         (file (and root (doclive--local-document-link-p relative)
                    (expand-file-name relative root))))
    (if (and file (doclive--previewable-document-file-p file)
             (doclive--wiki-path-allowed-p file root))
        (doclive--open-linked-document
         id (file-relative-name file (file-name-directory (plist-get entry :file))))
      (json-encode '((ok . :json-false) (error . "Page is outside this Wiki or unavailable"))))))

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

(defconst doclive--preview-css
  (concat
   ":root{--mono:ui-monospace,'SF Mono','JetBrains Mono','Cascadia Code',Menlo,Consolas,monospace;--serif:'Iowan Old Style',Charter,'Source Serif 4',Georgia,serif;--bg:#0c0f14;--bg-raise:#11151d;--panel:#10141c;--surface-glass:rgba(12,15,20,.82);--text:#e9edf5;--muted:#8e98ac;--border:rgba(148,163,184,.16);--accent:#a78bfa;--accent-strong:#c4b0ff;--accent-ink:#160e33;--pin:#e0b458;--danger:#f87171;--mark:#f5d76e;--code-bg:#0d1117;--code-text:#e6edf3;--ok:#4ade80;}"
   "body[data-theme='light']{--bg:#f7f6f2;--bg-raise:#fffefb;--panel:#fbfaf6;--surface-glass:rgba(247,246,242,.88);--text:#232733;--muted:#69707f;--border:rgba(35,39,51,.14);--accent:#6d3fc4;--accent-strong:#5b21b6;--accent-ink:#f4f0ff;--pin:#9a6a00;--danger:#b91c1c;--mark:#ffe08a;--code-bg:#14181f;--code-text:#e6edf3;--ok:#15803d;}"
   "*{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;min-height:100vh;background:var(--bg);color:var(--text);font-family:var(--serif);padding-bottom:48px;}"
   "button,input,select{font:inherit}button:focus-visible,input:focus-visible,select:focus-visible,a:focus-visible{outline:2px solid var(--accent);outline-offset:2px}"
   ".layout{display:grid;grid-template-columns:248px minmax(0,1fr);min-height:calc(100vh - 48px);}"
   ".toc{border-right:1px solid var(--border);padding:22px 14px 22px 20px;position:sticky;top:0;height:calc(100vh - 32px);overflow:auto;font-family:var(--mono);}"
   ".toc h2{margin:0 0 12px;font-size:10px;font-weight:600;letter-spacing:.22em;text-transform:uppercase;color:var(--muted);}"
   ".toc a{display:block;color:var(--muted);text-decoration:none;padding:5px 8px 5px 10px;border-left:2px solid transparent;font-size:12px;line-height:1.5;transition:color .15s ease,border-color .15s ease;}"
   ".toc a:hover{color:var(--text);}"
   ".toc a.active{color:var(--accent);border-left-color:var(--accent);}"
   ".main{min-width:0;}"
   ".toolbar{position:sticky;top:0;z-index:4;display:flex;flex-wrap:wrap;gap:8px;align-items:center;padding:10px 18px;border-bottom:1px solid var(--border);background:var(--surface-glass);backdrop-filter:blur(14px);font-family:var(--mono);}"
   ".hero{display:flex;align-items:center;margin-right:10px;}"
   ".wordmark{margin:0;font-size:12.5px;font-weight:600;letter-spacing:.04em;color:var(--text);font-family:var(--mono);white-space:nowrap;}"
   ".caret{display:inline-block;width:.55em;height:1.05em;margin-left:3px;vertical-align:text-bottom;background:var(--accent);animation:doclive-blink 1.2s steps(2,start) infinite;}"
   ".toolbar input,.toolbar button,.toolbar select{background:var(--bg-raise);color:var(--text);border:1px solid var(--border);border-radius:8px;padding:6px 10px;font-size:12px;min-height:32px;font-family:var(--mono);}"
   ".toolbar input{min-width:min(240px,100%);flex:1 1 200px;}"
   ".toolbar input::placeholder{color:var(--muted);}"
   ".toolbar button{cursor:pointer;transition:border-color .15s ease,color .15s ease,filter .15s ease;}"
   ".toolbar button:hover:not(:disabled){border-color:var(--accent);color:var(--accent);}"
   ".toolbar button:disabled{opacity:.38;cursor:not-allowed}.toolbar select{cursor:pointer}"
   ".toolbar .primary{background:var(--accent);border-color:transparent;color:var(--accent-ink);font-weight:700;}"
   ".toolbar .primary:hover:not(:disabled){color:var(--accent-ink);border-color:transparent;filter:brightness(1.08);}"
   ".chips{display:flex;gap:6px;flex-wrap:wrap;min-width:0;}"
   ".chip{border:1px solid var(--border);border-radius:6px;padding:4px 8px;font-size:11px;display:flex;gap:6px;align-items:center;background:var(--bg-raise);font-family:var(--mono);}"
   ".chip b{font-weight:600;max-width:160px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--pin);}"
   ".chip-close{border:none;background:transparent;color:var(--muted);cursor:pointer;padding:0;font-size:13px;line-height:1;min-height:0;}"
   ".chip-close:hover{color:var(--danger);}"
   ".md{max-width:1080px;margin:0 auto;padding:clamp(28px,5vw,56px) clamp(20px,4vw,40px) 72px;font-size:16.5px;line-height:1.75;animation:doclive-rise .4s ease-out both;}"
   ".md h1,.md h2,.md h3,.md h4{font-family:var(--serif);letter-spacing:-.015em;line-height:1.2;scroll-margin-top:64px;}"
   ".md h1{font-size:2.1rem;margin:0 0 .8em;}"
   ".md h2{font-size:1.45rem;margin:2em 0 .7em;padding-bottom:.35em;border-bottom:1px solid var(--border);}"
   ".md h3{font-size:1.15rem;margin:1.6em 0 .6em;}"
   ".md a{color:var(--accent);text-decoration-thickness:1.5px;text-underline-offset:3px;}"
   ".md a:hover{color:var(--accent-strong);}"
   ".md img{max-width:100%;border-radius:8px;}"
   ".md blockquote{margin:1.2em 0;padding:.2em 0 .2em 1.1em;border-left:3px solid var(--accent);color:var(--muted);}"
   ".md hr{border:none;border-top:1px solid var(--border);margin:2.4em 0;}"
   ".md pre{position:relative;background:var(--code-bg);color:var(--code-text);padding:16px 18px;border:1px solid var(--border);border-radius:10px;overflow:auto;font-size:13px;line-height:1.6;}"
   ".md pre,.md code,.md kbd{font-family:var(--mono);}"
   ".mermaid-holder{background:var(--code-bg);padding:14px;border:1px solid var(--border);border-radius:10px;overflow:auto;margin:1.2em 0;max-height:70vh;position:relative;}"
   ".mermaid-tools{position:absolute;top:8px;right:8px;display:flex;gap:6px;}"
   ".mermaid-tools button{background:var(--bg-raise);color:var(--muted);border:1px solid var(--border);border-radius:6px;padding:4px 9px;font-size:11px;font-family:var(--mono);cursor:pointer;}"
   ".mermaid-tools button:hover{color:var(--accent);border-color:var(--accent);}"
   ".mermaid-holder.is-fit svg{width:100%;height:auto;}"
   "#mermaid-overlay{position:fixed;inset:0;z-index:50;background:var(--bg);display:flex;align-items:center;justify-content:center;overflow:hidden;cursor:grab;}"
   ".mermaid-overlay-wrap{transform-origin:0 0;will-change:transform;}"
   ".mermaid-overlay-close{position:absolute;top:14px;right:14px;background:var(--bg-raise);color:var(--muted);border:1px solid var(--border);border-radius:6px;padding:6px 12px;font-size:12px;font-family:var(--mono);cursor:pointer;}"
   ".mermaid-overlay-close:hover{color:var(--accent);border-color:var(--accent);}"
   ".mermaid-overlay-hint{position:absolute;left:14px;bottom:14px;color:var(--muted);font-family:var(--mono);font-size:11px;}"
   ".md :not(pre)>code{background:color-mix(in oklab,var(--accent) 12%,transparent);border-radius:4px;padding:.12em .35em;font-size:.86em;}"
   ".md table{border-collapse:collapse;width:100%;margin:1.2em 0;font-size:.92em;}"
   ".md th{font-family:var(--mono);font-size:11px;color:var(--muted);text-align:left;}"
   ".md th,.md td{border:1px solid var(--border);padding:8px 10px;}"
   ".table-wrap{overflow-x:auto;margin:1.2em 0}"
   ".md .table-wrap table{margin:0}"
   ".md td code,.md th code{white-space:nowrap}"
   ".md li:has(>input[type=checkbox]){list-style:none;margin-left:-1.4em}"
   ".md li>input[type=checkbox]{margin-right:.5em;accent-color:var(--accent)}"
   ".frontmatter{margin:0 0 20px;border:1px solid var(--border);border-radius:10px;overflow:hidden;font-family:var(--mono);}"
   ".frontmatter summary{cursor:pointer;padding:10px 12px;font-weight:600;color:var(--muted);font-size:10.5px;text-transform:uppercase;letter-spacing:.18em;}"
   ".frontmatter table{margin:0;border-collapse:collapse;width:100%;}"
   ".frontmatter th,.frontmatter td{border-top:1px solid var(--border);padding:8px 12px;text-align:left;font-size:12px;}"
   ".copy-btn{position:absolute;top:8px;right:8px;background:var(--bg-raise);color:var(--muted);border:1px solid var(--border);border-radius:6px;padding:4px 9px;font-size:11px;font-family:var(--mono);cursor:pointer;}"
   ".copy-btn:hover{color:var(--accent);border-color:var(--accent);}"
   ".mark-pin-0{background:var(--mark);color:#111}.mark-pin-1{background:#ffd180;color:#111}.mark-pin-2{background:#b9f6ca;color:#111}.mark-pin-3{background:#80d8ff;color:#111}"
   ".render-error{background:color-mix(in oklab,var(--danger) 10%,transparent);border:1px solid var(--danger);border-radius:10px;padding:14px;margin:8px 0;font-family:var(--mono);font-size:12px;color:var(--danger);overflow:auto;white-space:pre-wrap;}"
   ".render-error::before{content:'⚠ Render error';display:block;font-weight:700;margin-bottom:8px;}"
   ".modeline{position:fixed;left:0;right:0;bottom:0;z-index:5;display:flex;gap:10px;align-items:center;height:32px;padding:0 14px;border-top:1px solid var(--border);background:var(--panel);font-family:var(--mono);font-size:11.5px;color:var(--muted);}"
   ".modeline .spacer{flex:1}"
   "#scrollpos{color:var(--text);min-width:3.5ch;text-align:right;}"
   ".dot{width:8px;height:8px;border-radius:999px;background:var(--ok);display:inline-block;flex:none;box-shadow:0 0 0 4px color-mix(in oklab,var(--ok) 20%,transparent);}"
   ".dot-disconnected{background:var(--danger);box-shadow:0 0 0 4px color-mix(in oklab,var(--danger) 20%,transparent);}"
   "@keyframes doclive-rise{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:none}}"
   "@keyframes doclive-blink{50%{opacity:0}}"
   "@media (prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important;scroll-behavior:auto!important}}"
   "@media (max-width:980px){.layout{grid-template-columns:1fr}.toc{position:relative;top:auto;height:auto;max-height:240px;border-right:none;border-bottom:1px solid var(--border)}.md{padding:24px 16px 64px}}")
  "CSS stylesheet for the doclive preview page.")

(defconst doclive--wiki-js
  "let workspace=null, workspaceId=null, preferencesReady=false, wikiFilter='all';
const explorer=document.createElement('aside'); explorer.id='explorer'; explorer.hidden=true; explorer.setAttribute('aria-label','Wiki explorer');
explorer.innerHTML='<div class=wiki-heading><span>LIBRARY</span><strong id=wiki-name></strong></div><label class=wiki-search-label for=wiki-search>Search all pages <kbd>⌘ K</kbd></label><input id=wiki-search type=search placeholder=\"Title or text…\" autocomplete=off><div class=wiki-tabs role=group aria-label=\"Page filter\"><button data-filter=all aria-pressed=true>All pages</button><button data-filter=bookmarks aria-pressed=false>Saved</button><button data-filter=recent aria-pressed=false>Recent</button></div><p id=wiki-search-status role=status></p><nav id=wiki-files aria-label=\"Wiki pages\"></nav><nav id=wiki-results aria-label=\"Search results\" hidden></nav>';
document.querySelector('.layout').prepend(explorer);
const wikiToggle=document.createElement('button'); wikiToggle.id='wiki-toggle'; wikiToggle.textContent='Library'; wikiToggle.hidden=true; wikiToggle.setAttribute('aria-controls','explorer'); wikiToggle.setAttribute('aria-expanded','true'); document.querySelector('.toolbar').prepend(wikiToggle);
const outlinePanel=document.querySelector('.toc'),outlineToggle=document.createElement('button'),compactOutline=matchMedia('(max-width:1200px)');outlinePanel.id='outline-panel';outlineToggle.id='outline-toggle';outlineToggle.textContent='Outline';outlineToggle.setAttribute('aria-controls','outline-panel');document.querySelector('.toolbar').appendChild(outlineToggle);
function setOutline(open){outlinePanel.hidden=compactOutline.matches&&!open;outlineToggle.setAttribute('aria-expanded',String(!outlinePanel.hidden));if(open&&compactOutline.matches){outlinePanel.style.top=document.querySelector('.toolbar').getBoundingClientRect().bottom+'px';document.body.classList.add('explorer-closed');wikiToggle.setAttribute('aria-expanded','false');}}
function resizeOutline(){outlineToggle.hidden=!compactOutline.matches;setOutline(false);if(!compactOutline.matches)outlinePanel.style.removeProperty('top');}window.addEventListener('resize',resizeOutline);resizeOutline();outlineToggle.onclick=()=>{setOutline(outlinePanel.hidden);if(!outlinePanel.hidden)outlinePanel.querySelector('a')?.focus();};outlinePanel.addEventListener('keydown',event=>{if(event.key==='Escape'&&compactOutline.matches){setOutline(false);outlineToggle.focus();}});outlinePanel.addEventListener('click',event=>{if(event.target.closest('a')&&compactOutline.matches){setOutline(false);outlineToggle.focus();}});
const pagebar=document.createElement('div'); pagebar.className='wiki-pagebar'; pagebar.hidden=true; pagebar.innerHTML='<span id=wiki-path></span><button id=wiki-bookmark aria-pressed=false>Save page</button>'; mdEl.before(pagebar);
const wikiSearch=document.getElementById('wiki-search'), wikiFiles=document.getElementById('wiki-files'), wikiResults=document.getElementById('wiki-results'), wikiStatus=document.getElementById('wiki-search-status'), bookmarkButton=document.getElementById('wiki-bookmark');
const wikiStyle=document.createElement('style'); wikiStyle.textContent=`
.layout{grid-template-columns:minmax(0,1fr)220px}.main{grid-column:1;grid-row:1;min-width:0}.toc{grid-column:2;grid-row:1;border-right:0;border-left:1px solid var(--border)}
.wiki-mode .layout{grid-template-columns:260px minmax(0,1fr)220px}.wiki-mode .main{grid-column:2}.wiki-mode .toc{grid-column:3}
#explorer{grid-column:1;grid-row:1;position:sticky;top:0;height:calc(100vh - 32px);overflow:auto;padding:24px 16px;box-sizing:border-box;background:var(--panel);border-right:1px solid var(--border);font-family:system-ui,sans-serif;font-size:13px}
[hidden]{display:none!important}.wiki-heading{display:grid;gap:10px;margin-bottom:24px}.wiki-heading span{font-size:10px;letter-spacing:.16em;color:var(--muted)}.wiki-heading strong{font-size:18px;overflow-wrap:anywhere}.wiki-search-label{display:flex;justify-content:space-between;color:var(--muted);font-size:12px;margin-bottom:8px}kbd{font:inherit}#wiki-search{box-sizing:border-box;width:100%;padding:10px;border:1px solid var(--border);border-radius:8px;color:var(--text);background:var(--bg)}
.wiki-tabs{display:flex;gap:4px;margin-top:14px}.wiki-tabs button{font:inherit;flex:1;padding:7px 2px;border:0;background:transparent;color:var(--muted);border-radius:6px;cursor:pointer}.wiki-tabs button[aria-pressed=true]{background:var(--bg);color:var(--text)}#wiki-search-status{color:var(--muted);font-size:12px;min-height:1em}
.wiki-page{display:flex;flex-direction:column;gap:4px;width:100%;text-align:left;border:0;border-radius:7px;background:transparent;color:var(--text);padding:9px 10px;font:inherit;cursor:pointer;overflow-wrap:anywhere}.wiki-page:hover,.wiki-page[aria-current=page]{background:color-mix(in srgb,var(--accent) 12%,transparent)}.wiki-page[aria-current=page]{box-shadow:inset 2px 0 var(--accent)}.wiki-page small{font-size:11px;color:var(--muted)}.wiki-page .snippet{font-size:12px;line-height:1.6;color:var(--muted)}#wiki-files details{margin:4px 0 4px 8px}#wiki-files summary{padding:8px 2px;color:var(--muted);cursor:pointer;overflow-wrap:anywhere}
.wiki-pagebar{display:flex;justify-content:space-between;align-items:center;gap:16px;padding:14px 28px;border-bottom:1px solid var(--border);font:12px system-ui;color:var(--muted)}#wiki-path{overflow-wrap:anywhere}.wiki-pagebar button{flex:none;background:transparent;color:var(--text);border:1px solid var(--border);border-radius:6px;padding:6px 10px;cursor:pointer}.wiki-pagebar button[aria-pressed=true]{color:var(--accent)}
.md{max-width:850px;line-height:1.85;letter-spacing:.005em;padding-top:40px}.md h1{font-size:2.1em;line-height:1.25}.md h2{font-size:1.5em;line-height:1.4}.md h3{font-size:1.2em}.md p,.md ul,.md ol{margin-block:1.15em}.md img{max-width:100%;height:auto;border-radius:6px}.md :is(h1,h2,h3,h4,h5,h6){scroll-margin-top:120px}.github-alert{border-left:3px solid var(--accent)!important;background:color-mix(in srgb,var(--accent) 5%,transparent)!important;border-radius:0 8px 8px 0}.alert-title{display:block;color:var(--accent);font-family:system-ui;font-size:.9em}.github-alert.warning,.github-alert.caution{border-left-color:#d9a441!important}.wordmark{font-size:14px!important}.caret{display:none}.hero{animation:none!important}button:focus-visible,input:focus-visible,summary:focus-visible,a:focus-visible{outline:2px solid var(--accent);outline-offset:3px}
.wiki-mode.explorer-closed .layout{grid-template-columns:minmax(0,1fr)220px}.wiki-mode.explorer-closed #explorer{display:none}.wiki-mode.explorer-closed .main{grid-column:1}.wiki-mode.explorer-closed .toc{grid-column:2}
@media(max-width:1200px){.layout{grid-template-columns:minmax(0,1fr)}.wiki-mode .layout{grid-template-columns:240px minmax(0,1fr)}.wiki-mode.explorer-closed .layout{grid-template-columns:1fr}.toc{position:fixed;z-index:9;right:0;top:60px;bottom:32px;height:auto;max-height:none;width:min(320px,88vw);box-sizing:border-box;background:var(--panel);box-shadow:-12px 0 30px #0003;overflow:auto}}
@media(max-width:800px){.layout,.wiki-mode .layout{display:block}#explorer{position:fixed;z-index:8;top:60px;bottom:32px;height:auto;width:min(320px,88vw);box-shadow:12px 0 30px #0003}.wiki-pagebar{padding:12px 16px}.toolbar{padding:10px!important}.hero{display:none}.md{padding:24px 20px 64px}.toolbar #search{min-width:90px;max-width:150px}}
`; document.head.appendChild(wikiStyle);
function pageButton(page){const button=document.createElement('button');button.className='wiki-page';button.dataset.path=page.path;button.setAttribute('aria-current',workspace&&workspace.current===page.path?'page':'false');const title=document.createElement('span');title.textContent=page.name;button.appendChild(title);const path=document.createElement('small');path.textContent=page.path;button.appendChild(path);if(page.snippet){const snippet=document.createElement('span');snippet.className='snippet';snippet.textContent=page.snippet;button.appendChild(snippet);}button.onclick=()=>openLinkedDocument(page.path,true);return button;}
function renderWorkspace(){if(!workspace)return;document.getElementById('wiki-name').textContent=workspace.name;document.getElementById('wiki-path').textContent=workspace.current;const saved=workspace.bookmarks.includes(workspace.current);bookmarkButton.setAttribute('aria-pressed',String(saved));bookmarkButton.textContent=saved?'Saved':'Save page';wikiFiles.replaceChildren();let pages=workspace.files;if(wikiFilter==='bookmarks')pages=pages.filter(p=>workspace.bookmarks.includes(p.path));if(wikiFilter==='recent')pages=workspace.recent.map(path=>pages.find(p=>p.path===path)).filter(Boolean);const folders=new Map();pages.forEach(page=>{let parent=wikiFiles;const parts=page.path.split('/');parts.pop();if(wikiFilter==='all'){let prefix='';parts.forEach(part=>{prefix+=part+'/';let folder=folders.get(prefix);if(!folder){folder=document.createElement('details');folder.open=true;const summary=document.createElement('summary');summary.textContent=part;folder.appendChild(summary);parent.appendChild(folder);folders.set(prefix,folder);}parent=folder;});}parent.appendChild(pageButton(page));});if(!wikiSearch.value)wikiStatus.textContent=pages.length?pages.length+' pages':wikiFilter==='bookmarks'?'Save a page to find it here.':'No pages yet.';}
async function refreshWorkspace(){const id=currentId,generation=navigationGeneration;const response=await fetch('/workspace?id='+encodeURIComponent(id),{cache:'no-store'});const data=await response.json();if(id!==currentId||generation!==navigationGeneration)return;if(!data.ok)throw Error(data.error||'Workspace unavailable');workspaceId=id;workspace=data.workspace?data:null;explorer.hidden=!workspace;wikiToggle.hidden=!workspace;pagebar.hidden=!workspace;document.body.classList.toggle('wiki-mode',!!workspace);if(!workspace)return;if(!preferencesReady){zoom=Number(data.zoom)||1;pinned=Array.isArray(data.pins)?data.pins:[];applyTheme(data.theme);applyZoom();renderChips();applyHighlights();preferencesReady=true;if(innerWidth<=800)document.body.classList.add('explorer-closed');}wikiToggle.setAttribute('aria-expanded',String(!document.body.classList.contains('explorer-closed')));renderWorkspace();}
let savePreferencesTimer;function savePreferences(){if(!workspace||!preferencesReady)return;clearTimeout(savePreferencesTimer);savePreferencesTimer=setTimeout(async()=>{try{const query=new URLSearchParams({id:currentId,theme:themeEl.value,zoom:String(zoom),pins:JSON.stringify(pinned)});const r=await fetch('/workspace?'+query,{cache:'no-store'});if(!r.ok)throw Error();}catch(e){wikiStatus.textContent='Could not save reading preferences.';}},250);}
document.querySelector('.toolbar').addEventListener('click',savePreferences);themeEl.addEventListener('change',savePreferences);
wikiToggle.onclick=()=>{const closed=document.body.classList.toggle('explorer-closed');wikiToggle.setAttribute('aria-expanded',String(!closed));if(!closed){setOutline(false);wikiSearch.focus();}};
document.querySelectorAll('[data-filter]').forEach(button=>button.onclick=()=>{wikiFilter=button.dataset.filter;document.querySelectorAll('[data-filter]').forEach(b=>b.setAttribute('aria-pressed',String(b===button)));wikiSearch.value='';wikiSearch.dispatchEvent(new Event('input'));renderWorkspace();});
bookmarkButton.onclick=async()=>{if(!workspace)return;const id=currentId,generation=navigationGeneration;bookmarkButton.disabled=true;try{const query=new URLSearchParams({id:currentId,bookmark:workspace.current,value:workspace.bookmarks.includes(workspace.current)?'0':'1'});const response=await fetch('/workspace?'+query,{cache:'no-store'});const data=await response.json();if(id!==currentId||generation!==navigationGeneration)return;if(!data.ok)throw Error();workspace=data;renderWorkspace();}catch(e){if(id===currentId&&generation===navigationGeneration)wikiStatus.textContent='Could not save bookmark. Try again.';}finally{bookmarkButton.disabled=false;}};
let searchTimer,searchGeneration=0;wikiSearch.addEventListener('input',()=>{clearTimeout(searchTimer);const id=currentId,navigation=navigationGeneration,generation=++searchGeneration,q=wikiSearch.value.trim();wikiFiles.hidden=!!q;wikiResults.hidden=!q;wikiResults.replaceChildren();if(!q){renderWorkspace();return;}wikiStatus.textContent='Searching…';searchTimer=setTimeout(async()=>{try{const response=await fetch('/search?'+new URLSearchParams({id,q}),{cache:'no-store'});const data=await response.json();if(generation!==searchGeneration||navigation!==navigationGeneration)return;if(!data.ok)throw Error();wikiResults.replaceChildren(...data.results.map(pageButton));wikiStatus.textContent=data.results.length?data.results.length+' results':'No matching pages. Try another word.';}catch(e){if(generation===searchGeneration&&navigation===navigationGeneration)wikiStatus.textContent='Search unavailable. Try again.';}},180);});
window.docliveSetWikiSearch=function(text){if(!workspace)return false;setOutline(false);document.body.classList.remove('explorer-closed');wikiToggle.setAttribute('aria-expanded','true');wikiSearch.value=String(text==null?'':text);wikiSearch.dispatchEvent(new Event('input'));return true;};
window.docliveDismiss=function(){closeMermaidOverlay();window.docliveSetSearch('');wikiSearch.value='';wikiSearch.dispatchEvent(new Event('input'));setOutline(false);document.body.classList.add('explorer-closed');wikiToggle.setAttribute('aria-expanded','false');document.activeElement?.blur();mdEl.focus({preventScroll:true});};
explorer.addEventListener('keydown',event=>{if(event.isComposing||event.keyCode===229)return;const buttons=Array.from((wikiResults.hidden?wikiFiles:wikiResults).querySelectorAll('.wiki-page')).filter(b=>!b.closest('details:not([open])'));if(event.key==='ArrowDown'||event.key==='ArrowUp'){event.preventDefault();const index=buttons.indexOf(document.activeElement);const next=event.key==='ArrowDown'?Math.min(index+1,buttons.length-1):Math.max(index-1,0);if(buttons[next])buttons[next].focus();}if(event.key==='Enter'&&event.target===wikiSearch&&buttons[0])buttons[0].click();if(event.key==='Escape'){if(wikiSearch.value){wikiSearch.value='';wikiSearch.dispatchEvent(new Event('input'));wikiSearch.focus();}else{document.body.classList.add('explorer-closed');wikiToggle.setAttribute('aria-expanded','false');wikiToggle.focus();}}});
document.addEventListener('keydown',event=>{if(workspace&&(event.metaKey||event.ctrlKey)&&event.key.toLowerCase()==='k'){event.preventDefault();document.body.classList.remove('explorer-closed');wikiToggle.setAttribute('aria-expanded','true');wikiSearch.focus();wikiSearch.select();}});
buildToc=function(){tocEl.replaceChildren();const headings=Array.from(mdEl.querySelectorAll('h1,h2,h3,h4,h5,h6')),used=new Set(headings.filter(h=>h.id).map(h=>h.id)),links=new Map();headings.forEach(h=>{if(!h.id){const base=h.textContent.trim().toLowerCase().replace(/[^\\p{L}\\p{N}_\\s-]/gu,'').replace(/\\s/g,'-')||'section';let slug=base,n=0;while(used.has(slug))slug=base+'-'+(++n);h.id=slug;used.add(slug);}const a=document.createElement('a');a.href='#'+encodeURIComponent(h.id);a.textContent=h.textContent;a.style.paddingLeft=((Number(h.tagName.slice(1))-1)*10+8)+'px';tocEl.appendChild(a);links.set(h.id,a);});tocLinks=links;tocHeadings=headings.map(h=>h.id);updateActiveToc();};
const originalApplyContent=applyContent;applyContent=async function(data){const changed=await originalApplyContent(data);if(data.sourceId!==currentId||data.navigationGeneration!==navigationGeneration)return;if(changed){mdEl.innerHTML=mdEl.getAttribute('data-base-html')||mdEl.innerHTML;mdEl.querySelectorAll('blockquote').forEach(block=>{const p=block.querySelector('p');if(!p||!p.firstChild||p.firstChild.nodeType!==Node.TEXT_NODE)return;const match=p.firstChild.textContent.match(/^\\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\\]\\s*/);if(!match)return;p.firstChild.textContent=p.firstChild.textContent.slice(match[0].length);block.classList.add('github-alert',match[1].toLowerCase());const label=document.createElement('strong');label.className='alert-title';label.textContent=match[1][0]+match[1].slice(1).toLowerCase();block.prepend(label);});mdEl.setAttribute('data-base-html',mdEl.innerHTML);applyHighlights();}if(workspaceId!==currentId){try{await refreshWorkspace();}catch(e){if(data.sourceId===currentId)wikiStatus.textContent='Library unavailable. Reload to retry.';}}};
function navigationUrl(id,hash=''){const url=new URL(location.href);url.search='?'+new URLSearchParams({id});url.hash=hash;return url.pathname+url.search+url.hash;}
function recordNavigation(id,hash=''){const url=navigationUrl(id,hash);if(url===location.pathname+location.search+location.hash)return;navStack=navStack.slice(0,navIndex+1);navStack.push({id});navIndex=navStack.length-1;history.pushState({id,docliveIndex:navIndex},'',url);updateNavButtons();}
function scrollToFragment(hash){let fragment=hash.replace(/^#/,'');try{fragment=decodeURIComponent(fragment);}catch(e){}const target=fragment&&document.getElementById(fragment);if(target)target.scrollIntoView();else window.scrollTo(0,0);}
async function navigatePage(id,hash,generation,record){if(generation!==navigationGeneration)return;if(id!==currentId||lastRev<0){const data=await fetchContent(id);if(generation!==navigationGeneration)return;if(!data.ok)throw Error(data.error||'Page unavailable');currentId=id;lastRev=-1;++renderGeneration;if(record)recordNavigation(id,hash);connectSSE();await applyContent(data);}else if(record){recordNavigation(id,hash);}if(generation!==navigationGeneration)return;scrollToFragment(hash);if(innerWidth<=800){document.body.classList.add('explorer-closed');wikiToggle.setAttribute('aria-expanded','false');}mdEl.tabIndex=-1;mdEl.focus({preventScroll:true});}
openLinkedDocument=async function(href,fromRoot=false){const generation=++navigationGeneration;mdEl.setAttribute('aria-busy','true');statusEl.textContent='Opening page…';try{const response=await fetch('/open?'+new URLSearchParams({id:currentId,path:href,...(fromRoot?{wiki:'1'}:{})}),{cache:'no-store'});const data=await response.json();if(generation!==navigationGeneration)return;if(!data.ok)throw Error(data.error||'Page unavailable');const hash=href.includes('#')?href.slice(href.indexOf('#')):'';await navigatePage(data.buffer_id,hash,generation,true);if(generation===navigationGeneration)showLiveStatus();}catch(e){if(generation===navigationGeneration)statusEl.textContent=e.message||'Could not open page.';}finally{if(generation===navigationGeneration)mdEl.removeAttribute('aria-busy');}};
window.addEventListener('popstate',async event=>{const id=new URLSearchParams(location.search).get('id');if(!id)return;const generation=++navigationGeneration,hash=location.hash;if(Number.isInteger(event.state?.docliveIndex)){navIndex=event.state.docliveIndex;updateNavButtons();}mdEl.setAttribute('aria-busy','true');try{await navigatePage(id,hash,generation,false);}catch(e){if(generation===navigationGeneration)statusEl.textContent=e.message||'Could not restore page.';}finally{if(generation===navigationGeneration)mdEl.removeAttribute('aria-busy');}});
document.addEventListener('click',event=>{if(event.defaultPrevented||event.button!==0||event.metaKey||event.ctrlKey||event.shiftKey||event.altKey)return;const link=event.target.closest('a[href]');if(!link||!link.closest('#md,#toc'))return;const href=link.getAttribute('href');if(!href.startsWith('#'))return;event.preventDefault();recordNavigation(currentId,href);scrollToFragment(href);});
function initializeNavigation(){navStack=[{id:currentId}];navIndex=0;history.replaceState({id:currentId,docliveIndex:0},'',navigationUrl(currentId,location.hash));updateNavButtons();}
"
  "Wiki explorer and reading enhancements for the preview client.")

(defconst doclive--preview-js
  (concat
   "const qs=new URLSearchParams(location.search); let currentId=qs.get('id');"
   "function scrubSensitiveQueryFromLocation(){let dirty=false; const clean=new URLSearchParams(); qs.forEach((value,key)=>{const lower=(key||'').toLowerCase(); if(lower==='bootstrap'||lower==='token'){dirty=true; return;} clean.append(key,value);}); if(!dirty) return; const q=clean.toString(); history.replaceState({id:currentId},'',q?'?'+q:location.pathname);}"
   "const statusEl=document.getElementById('status'); const mdEl=document.getElementById('md'); const tocEl=document.getElementById('toc');"
   "const searchEl=document.getElementById('search'); const pinEl=document.getElementById('pin'); const chipsEl=document.getElementById('chips');"
   "const themeEl=document.getElementById('theme'); const dotEl=document.getElementById('dot');"
   "const scrollPosEl=document.getElementById('scrollpos');"
   "let lastRev=-1,renderGeneration=0,navigationGeneration=0;let liveName='';function showLiveStatus(connection='live'){statusEl.textContent=lastRev>=0?connection+' • rev '+lastRev+' • '+liveName:connection;}"
   "let scrollTick=false;"
   "function updateScrollPos(){const doc=document.documentElement; const max=doc.scrollHeight-doc.clientHeight; let label; if(max<=4){label='All';}else{const y=window.scrollY||doc.scrollTop; if(y<=2){label='Top';}else if(y>=max-2){label='Bot';}else{label=Math.round((y/max)*100)+'%';}} scrollPosEl.textContent=label;}"
   "window.addEventListener('scroll',()=>{if(scrollTick) return; scrollTick=true; requestAnimationFrame(()=>{scrollTick=false; updateScrollPos(); updateActiveToc();});},{passive:true});"
   "window.addEventListener('resize',()=>updateScrollPos());"
   "let navStack=[]; let navIndex=-1;"
   "let pinned=[]; let zoom=1;"
   "marked.setOptions({gfm:true,breaks:false});"
   "function mermaidTheme(){return document.body.getAttribute('data-theme')==='light'?'default':'dark';}"
   "function initializeMermaid(){mermaid.initialize({startOnLoad:false,securityLevel:'strict',theme:mermaidTheme()});}"
   "initializeMermaid();"
   "function parseFrontmatter(md){if(!md.startsWith('---\\n')) return {front:null,body:md}; const end=md.indexOf('\\n---\\n',4); if(end===-1) return {front:null,body:md}; const raw=md.slice(4,end).trim(); const body=md.slice(end+5); const map={}; raw.split('\\n').forEach(line=>{const i=line.indexOf(':'); if(i>0){const k=line.slice(0,i).trim(); const v=line.slice(i+1).trim(); map[k]=v;}}); return {front:map,body};}"
   "function escapeHtml(s){return String(s==null?'':s).replace(/[&<>\"']/g,(ch)=>{if(ch==='&') return '&amp;'; if(ch==='<') return '&lt;'; if(ch==='>') return '&gt;'; if(ch==='\"') return '&quot;'; return '&#39;';});}"
   "function sanitizeUrlValue(value,allowMailto=false){const raw=String(value==null?'':value); const trimmed=raw.trim(); const folded=trimmed.replace(/[\\u0000-\\u001F\\u007F\\s]+/g,'').toLowerCase(); if(!folded||folded.startsWith('//')||trimmed.indexOf(String.fromCharCode(92))!==-1) return ''; if(/[\\u0000-\\u001F\\u007F\\s]/.test(trimmed)) return ''; if(/^[a-z][a-z0-9+.-]*:/.test(folded)&&!(/^https?:/.test(folded)||(allowMailto&&folded.startsWith('mailto:')))) return ''; return trimmed;}"
   "function sanitizeHtml(html,allowTrustedStyles=false){const tpl=document.createElement('template'); tpl.innerHTML=html||''; const removed=allowTrustedStyles?'script,iframe,object,embed,link,meta,base':'script,iframe,object,embed,link,meta,base,style'; tpl.content.querySelectorAll(removed).forEach((el)=>el.remove()); const walker=document.createTreeWalker(tpl.content,NodeFilter.SHOW_ELEMENT); const nodes=[]; while(walker.nextNode()) nodes.push(walker.currentNode); nodes.forEach((el)=>{Array.from(el.attributes).forEach((attr)=>{const name=attr.name||''; const lower=name.toLowerCase(); if(/^on/i.test(name)||(lower==='style'&&!allowTrustedStyles)||lower==='srcset'||lower==='ping'){el.removeAttribute(attr.name); return;} if(/^(href|src|xlink:href|formaction|action|poster)$/i.test(name)){const allowMailto=/^(href|xlink:href)$/i.test(name); const safe=sanitizeUrlValue(attr.value||'',allowMailto); if(safe){el.setAttribute(attr.name,safe);}else{el.removeAttribute(attr.name);}}}); if(el.tagName&&el.tagName.toLowerCase()==='a'&&(el.getAttribute('target')||'').toLowerCase()==='_blank'){el.setAttribute('rel','noopener noreferrer');}}); return tpl.innerHTML;}"
   "function setSanitizedSvg(container,svg){const tpl=document.createElement('template'); tpl.innerHTML=sanitizeHtml(svg||'',true); const root=tpl.content.firstElementChild; if(!root||root.tagName.toLowerCase()!=='svg'||tpl.content.childElementCount!==1) throw new Error('invalid mermaid svg'); container.replaceChildren(root.cloneNode(true));}"
   "function renderFrontmatter(front){if(!front) return ''; const rows=Object.entries(front).map(([k,v])=>`<tr><th>${escapeHtml(k)}</th><td>${escapeHtml(v)}</td></tr>`).join(''); return `<details class=\"frontmatter\" open><summary>Frontmatter</summary><table>${rows}</table></details>`;}"
   "let tocLinks=new Map(); let tocHeadings=[];"
   "function updateActiveToc(){if(!tocHeadings.length) return; const line=Math.min(120,window.innerHeight*0.25); let currentId=tocHeadings[0]; tocHeadings.forEach((id)=>{const h=document.getElementById(id); if(h&&h.getBoundingClientRect().top<=line) currentId=id;}); tocLinks.forEach((a)=>a.classList.remove('active')); const active=tocLinks.get(currentId); if(active) active.classList.add('active');}"
   "function buildToc(){tocEl.innerHTML=''; const hs=mdEl.querySelectorAll('h1,h2,h3,h4,h5,h6'); const links=new Map(); hs.forEach((h,i)=>{if(!h.id)h.id='h-'+i; const a=document.createElement('a'); a.href='#'+h.id; a.textContent=h.textContent; a.style.paddingLeft=((parseInt(h.tagName.slice(1))-1)*10+8)+'px'; tocEl.appendChild(a); links.set(h.id,a);}); tocLinks=links; tocHeadings=Array.from(hs).map((h)=>h.id); updateActiveToc();}"
   "function wrapTables(){mdEl.querySelectorAll('table').forEach((t)=>{if(t.closest('.table-wrap')) return; const wrap=document.createElement('div'); wrap.className='table-wrap'; t.parentNode.insertBefore(wrap,t); wrap.appendChild(t);});}"
   "function highlightCodeBlocks(){mdEl.querySelectorAll('pre code').forEach((code)=>{try{const language=(code.className+' '+code.parentElement.className).match(/\\blang(?:uage)?-([\\w-]+)\\b/i);if(language&&!hljs.getLanguage(language[1])){code.classList.add('hljs','nohighlight');return;}hljs.highlightElement(code);}catch(e){}});}"
   "function fallbackCopyText(text){let ok=false; const sel=document.getSelection(); const prevRange=sel&&sel.rangeCount?sel.getRangeAt(0):null; const ta=document.createElement('textarea'); ta.value=text; ta.setAttribute('readonly',''); ta.style.position='fixed'; ta.style.top='-1000px'; ta.style.left='-1000px'; document.body.appendChild(ta); ta.select(); ta.setSelectionRange(0,ta.value.length); try{ok=document.execCommand('copy');}catch(e){ok=false;} document.body.removeChild(ta); if(sel){sel.removeAllRanges(); if(prevRange) sel.addRange(prevRange);} return ok;}"
   "function wireCopy(){mdEl.querySelectorAll('pre').forEach((pre)=>{const old=pre.querySelector('.copy-btn'); if(old) old.remove(); const code=pre.querySelector('code'); const src=code||pre; const b=document.createElement('button'); b.className='copy-btn'; b.textContent='Copy'; b.onclick=async()=>{const text=src.innerText;let ok=false;const nativeCopy=window.docliveCopyText(text); if(navigator.clipboard&&navigator.clipboard.writeText){try{await navigator.clipboard.writeText(src.innerText); ok=true;}catch(e){ok=false;}} if(!ok){ok=fallbackCopyText(src.innerText);} ok=(await nativeCopy)||ok;b.textContent=ok?'Copied':'Failed'; setTimeout(()=>b.textContent='Copy',900);}; pre.appendChild(b);});}"
   "function normalizeMermaidSvgSize(svg){if(!svg) return; if(svg.getAttribute('width')==='100%') svg.removeAttribute('width'); const style=svg.getAttribute('style'); if(style){const stripped=style.replace(/max-width\\s*:[^;]+;?/i,'').trim(); if(stripped){svg.setAttribute('style',stripped);}else{svg.removeAttribute('style');}} const vb=(svg.getAttribute('viewBox')||'').trim().split(/\\s+/); if(vb.length===4){const w=parseFloat(vb[2]); const h=parseFloat(vb[3]); if(w>0&&!isNaN(w)) svg.setAttribute('width',String(w)); if(h>0&&!isNaN(h)) svg.setAttribute('height',String(h));}}"
   "async function renderMermaid(){const generation=renderGeneration,navigation=navigationGeneration;"
   "const blocks=Array.from(mdEl.querySelectorAll('pre code.language-mermaid, pre code.language-mmd, pre.src-mermaid, pre.src.src-mermaid'));"
   "for(const el of blocks){"
   "const pre=el.tagName==='PRE'?el:el.closest('pre');"
   "let graph='';"
   "if(el.tagName==='PRE'){const clone=el.cloneNode(true); clone.querySelectorAll('.copy-btn').forEach((b)=>b.remove()); graph=clone.textContent||'';}"
   "else{graph=el.textContent||'';}"
   "if(!graph.trim()) continue;"
   "const holder=document.createElement('div'); holder.className='mermaid-holder';"
   "try{const out=await mermaid.render('m'+Math.random().toString(36).slice(2),graph); setSanitizedSvg(holder,out.svg); normalizeMermaidSvgSize(holder.querySelector('svg'));}"
   "catch(e){holder.className='render-error'; holder.textContent=graph;}"
   "if(generation!==renderGeneration||navigation!==navigationGeneration)return;"
   "if(pre&&pre.parentNode) pre.parentNode.replaceChild(holder,pre);"
   "}"
   "wireMermaidTools();"
   "}"
   "function wireMermaidTools(){mdEl.querySelectorAll('.mermaid-holder').forEach((holder)=>{const old=holder.querySelector('.mermaid-tools'); if(old) old.remove(); const svg=holder.querySelector('svg'); if(!svg) return; const bar=document.createElement('div'); bar.className='mermaid-tools'; const fit=document.createElement('button'); fit.type='button'; fit.textContent='Fit'; fit.onclick=()=>{svg.style.width='100%'; svg.style.height='auto'; holder.classList.add('is-fit');}; const natural=document.createElement('button'); natural.type='button'; natural.textContent='100%'; natural.onclick=()=>{svg.style.width=''; svg.style.height=''; holder.classList.remove('is-fit');}; const expand=document.createElement('button'); expand.type='button'; expand.textContent='Expand'; expand.onclick=()=>openMermaidOverlay(svg); bar.appendChild(fit); bar.appendChild(natural); bar.appendChild(expand); holder.appendChild(bar);});}"
   "let mermaidScale=1,mermaidTx=0,mermaidTy=0,mermaidOverlayWrap=null,mermaidOverlayDragging=false,mermaidOverlayLastX=0,mermaidOverlayLastY=0,mermaidOverlayReturnFocus=null;"
   "function applyMermaidOverlayTransform(){if(!mermaidOverlayWrap) return; mermaidOverlayWrap.style.transform='translate('+mermaidTx+'px,'+mermaidTy+'px) scale('+mermaidScale+')';}"
   "function closeMermaidOverlay(){const overlay=document.getElementById('mermaid-overlay'); if(!overlay) return; overlay.remove(); mermaidOverlayWrap=null; mermaidScale=1; mermaidTx=0; mermaidTy=0; const returnTo=mermaidOverlayReturnFocus; mermaidOverlayReturnFocus=null; if(returnTo&&document.contains(returnTo)) returnTo.focus();}"
   "function openMermaidOverlay(svg){const invoker=document.activeElement; closeMermaidOverlay(); mermaidOverlayReturnFocus=invoker; const overlay=document.createElement('div'); overlay.id='mermaid-overlay'; overlay.setAttribute('role','dialog'); overlay.setAttribute('aria-modal','true'); overlay.setAttribute('aria-label','Expanded diagram'); const wrap=document.createElement('div'); wrap.className='mermaid-overlay-wrap'; const clone=svg.cloneNode(true); clone.style.width=''; clone.style.height=''; wrap.appendChild(clone); const closeBtn=document.createElement('button'); closeBtn.type='button'; closeBtn.className='mermaid-overlay-close'; closeBtn.textContent='Close'; closeBtn.setAttribute('aria-label','Close diagram'); closeBtn.onclick=closeMermaidOverlay; const hint=document.createElement('div'); hint.className='mermaid-overlay-hint'; hint.textContent='Scroll to zoom, drag to pan. Esc or Close to exit.'; mermaidOverlayWrap=wrap; mermaidScale=1; mermaidTx=0; mermaidTy=0; applyMermaidOverlayTransform(); overlay.appendChild(wrap); overlay.appendChild(closeBtn); overlay.appendChild(hint); overlay.addEventListener('wheel',(ev)=>{ev.preventDefault(); const px=ev.clientX; const py=ev.clientY; const prevScale=mermaidScale; const factor=Math.exp(-ev.deltaY*0.0015); mermaidScale=Math.min(8,Math.max(0.2,mermaidScale*factor)); const ratio=mermaidScale/prevScale; mermaidTx=px-(px-mermaidTx)*ratio; mermaidTy=py-(py-mermaidTy)*ratio; applyMermaidOverlayTransform();},{passive:false}); overlay.addEventListener('mousedown',(ev)=>{if(ev.target===closeBtn) return; mermaidOverlayDragging=true; mermaidOverlayLastX=ev.clientX; mermaidOverlayLastY=ev.clientY;}); overlay.addEventListener('mousemove',(ev)=>{if(!mermaidOverlayDragging) return; mermaidTx+=ev.clientX-mermaidOverlayLastX; mermaidTy+=ev.clientY-mermaidOverlayLastY; mermaidOverlayLastX=ev.clientX; mermaidOverlayLastY=ev.clientY; applyMermaidOverlayTransform();}); overlay.addEventListener('mouseup',()=>{mermaidOverlayDragging=false;}); overlay.addEventListener('mouseleave',()=>{mermaidOverlayDragging=false;}); overlay.addEventListener('click',(ev)=>{if(ev.target===overlay) closeMermaidOverlay();}); document.body.appendChild(overlay); closeBtn.focus();}"
   "function renderMath(){"
   "if(!window.renderMathInElement) return;"
   "try{renderMathInElement(mdEl,{delimiters:["
   "{left:'\\\\[',right:'\\\\]',display:true},"
   "{left:'\\\\(',right:'\\\\)',display:false},"
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
   "],ignoredTags:['script','noscript','style','textarea','pre','code'],ignoredClasses:['render-error'],"
   "throwOnError:false,errorColor:'#f85149'});"
   "}catch(e){console.warn('KaTeX render error:',e);}"
   "}"
   "function escReg(s){return s.replace(/[.*+?^${}()|[\\]\\\\]/g,'\\\\$&');}"
   "function replaceTextNode(node,re,cls){const text=node.nodeValue; let m,last=0; const frag=document.createDocumentFragment(); while((m=re.exec(text))!==null){if(m.index>last) frag.appendChild(document.createTextNode(text.slice(last,m.index))); const mark=document.createElement('mark'); mark.className=cls; mark.textContent=m[0]; frag.appendChild(mark); last=re.lastIndex; if(re.lastIndex===m.index) re.lastIndex++;} if(last<text.length) frag.appendChild(document.createTextNode(text.slice(last))); node.parentNode.replaceChild(frag,node);}"
   "function walkAndHighlight(root,re,cls){const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,{acceptNode(n){if(!n.nodeValue.trim()) return NodeFilter.FILTER_REJECT; const p=n.parentNode; if(!p) return NodeFilter.FILTER_REJECT; if(p.closest&&p.closest('script,style,code,pre,.katex,svg')) return NodeFilter.FILTER_REJECT; return NodeFilter.FILTER_ACCEPT;}}); const nodes=[]; while(walker.nextNode()) nodes.push(walker.currentNode); nodes.forEach(n=>replaceTextNode(n,re,cls));}"
   "function applyHighlights(){const html=mdEl.getAttribute('data-base-html')||mdEl.innerHTML; mdEl.innerHTML=html; highlightCodeBlocks(); const q=(searchEl.value||'').trim(); if(q){walkAndHighlight(mdEl,new RegExp(escReg(q),'gi'),'mark-pin-0 search-match');} pinned.forEach((term,idx)=>{if(term){walkAndHighlight(mdEl,new RegExp(escReg(term),'gi'),'mark-pin-'+(idx%4));}}); wireCopy(); wireMermaidTools(); wireDocumentLinkNavigation();}"
   "function renderChips(){chipsEl.innerHTML=''; pinned.forEach((term,idx)=>{const el=document.createElement('span'); el.className='chip'; const label=document.createElement('b'); label.textContent=term; el.appendChild(label); const c=document.createElement('button'); c.className='chip-close'; c.textContent='×'; c.setAttribute('aria-label','Remove pinned highlight: '+term); c.onclick=()=>{pinned=pinned.filter((_,i)=>i!==idx); applyHighlights(); renderChips();}; el.appendChild(c); chipsEl.appendChild(el);});}"
   "function normalizeTheme(theme){return theme==='light'?'light':'dark';}"
   "function getStoredTheme(){try{return localStorage.getItem('doclive-theme');}catch(e){return null;}}"
   "function storeTheme(theme){try{localStorage.setItem('doclive-theme',theme);}catch(e){}}"
   "function applyTheme(theme){theme=normalizeTheme(theme); document.body.setAttribute('data-theme',theme); storeTheme(theme); themeEl.value=theme; initializeMermaid();}"
   "function applyZoom(){mdEl.style.fontSize=(zoom*100)+'%';}"
   "function updateNavButtons(){document.getElementById('back').disabled=navIndex<=0; document.getElementById('forward').disabled=navIndex<0||navIndex>=navStack.length-1;}"
   "let es=null;"
   "async function fetchContent(id=currentId){const generation=navigationGeneration; const r=await fetch('/content?id='+encodeURIComponent(id),{cache:'no-store'}); const data=await r.json(); return {...data,sourceId:id,navigationGeneration:generation};}"
   "async function applyContent(j){if(j.sourceId!==currentId||j.navigationGeneration!==navigationGeneration)return false;if(!j.ok){statusEl.textContent=j.error||'not found'; dotEl.className='dot dot-disconnected'; return false;} if(j.revision<=lastRev)return false;statusEl.textContent='live • rev '+j.revision+' • '+(j.name||''); dotEl.className='dot'; document.title=j.name?j.name+' - doclive':'doclive'; const generation=++renderGeneration; const kind=j.contentKind||'markdown'; let html=''; if(kind==='org-html'){html=j.html||'';}else{const parsed=parseFrontmatter(j.markdown||''); html=renderFrontmatter(parsed.front)+marked.parse(parsed.body||'');} html=sanitizeHtml(html); mdEl.setAttribute('data-content-kind',kind); mdEl.innerHTML=html; wireCopy(); renderMath(); await renderMermaid(); if(generation!==renderGeneration||j.sourceId!==currentId||j.navigationGeneration!==navigationGeneration)return false;lastRev=j.revision;liveName=j.name||'';showLiveStatus(); buildToc(); wrapTables(); mdEl.setAttribute('data-base-html',mdEl.innerHTML); applyHighlights(); applyZoom(); updateScrollPos(); return true;}"
   "async function openLinkedDocument(href){try{const r=await fetch('/open?id='+encodeURIComponent(currentId)+'&path='+encodeURIComponent(href),{cache:'no-store'}); const j=await r.json(); if(!j.ok){statusEl.textContent=j.error||'open failed'; return;} currentId=j.buffer_id; lastRev=-1; connectSSE(); const c=await fetchContent(); await applyContent(c);}catch(e){statusEl.textContent='open failed';}}"
   "function wireDocumentLinkNavigation(){mdEl.querySelectorAll('a[href]').forEach(a=>{const href=a.getAttribute('href')||''; if(/^[a-zA-Z][a-zA-Z0-9+.-]*:/i.test(href)||href.startsWith('#')||href.startsWith('//')||href.indexOf(String.fromCharCode(92))!==-1) return; if(!/\\.(md|org|html)($|#|\\?)/i.test(href)) return; a.addEventListener('click',ev=>{ev.preventDefault(); openLinkedDocument(href);});});}"
   "function connectSSE(){if(!currentId){statusEl.textContent='missing id'; dotEl.className='dot dot-disconnected'; return;} if(es){es.close(); es=null;} const id=currentId,source=new EventSource('/events?id='+encodeURIComponent(id));es=source;source.addEventListener('open',()=>{if(es!==source)return;showLiveStatus(lastRev>=0?'live':'connected'); dotEl.className='dot';}); source.addEventListener('revision',async()=>{if(es!==source)return;try{const j=await fetchContent(id);if(es===source)await applyContent(j);}catch(e){if(es===source)statusEl.textContent='sync error';}}); source.onerror=()=>{if(es!==source)return;showLiveStatus('reconnecting…'); dotEl.className='dot dot-disconnected';};}"
   "window.docliveGetSearch=function(wiki){return (wiki?wikiSearch:searchEl).value;};"
   "window.docliveSetSearch=function(text){searchEl.value=String(text==null?'':text); applyHighlights();searchMatchIndex=-1;return window.docliveSearchNext(false);};"
   "let searchMatchIndex=-1;window.docliveSearchNext=function(backward=false){const matches=Array.from(mdEl.querySelectorAll('.search-match'));matches.forEach(m=>{m.style.outline='';m.removeAttribute('aria-current');});if(!matches.length)return {index:0,total:0};searchMatchIndex=(searchMatchIndex+(backward?-1:1)+matches.length)%matches.length;const match=matches[searchMatchIndex];match.style.outline='2px solid var(--accent)';match.setAttribute('aria-current','true');match.scrollIntoView({block:'center'});return {index:searchMatchIndex+1,total:matches.length};};"
   "window.docliveGetSelection=function(){const input=document.activeElement;if(input&&(input.tagName==='INPUT'||input.tagName==='TEXTAREA')&&typeof input.selectionStart==='number')return input.value.slice(input.selectionStart,input.selectionEnd);return window.getSelection().toString();};"
   "window.doclivePaste=function(text){const input=document.activeElement; text=String(text);if(input&&(input.tagName==='INPUT'||input.tagName==='TEXTAREA')&&typeof input.selectionStart==='number'){if(input.readOnly||input.disabled)return false;input.setRangeText(text,input.selectionStart,input.selectionEnd,'end');input.dispatchEvent(new Event('input',{bubbles:true}));return true;}searchEl.focus();window.docliveSetSearch(text);searchEl.setSelectionRange(text.length,text.length);return true;};"
   "window.docliveCopyText=async function(text){try{const query=new URLSearchParams({id:currentId,text:JSON.stringify(String(text))});if(query.toString().length>12000)return false;const response=await fetch('/copy?'+query,{cache:'no-store'});return response.ok&&(await response.json()).ok===true;}catch(e){return false;}};"
   "document.addEventListener('keydown',(ev)=>{if(ev.key==='Escape') closeMermaidOverlay();});"
   "searchEl.addEventListener('input',()=>applyHighlights());"
   "pinEl.addEventListener('click',()=>{const q=(searchEl.value||'').trim(); if(!q) return; if(!pinned.includes(q)) pinned.push(q); renderChips(); applyHighlights();});"
   "themeEl.addEventListener('change',()=>applyTheme(themeEl.value));"
   "document.getElementById('zoom-in').addEventListener('click',()=>{zoom=Math.min(2,zoom+0.1);applyZoom();});"
   "document.getElementById('zoom-out').addEventListener('click',()=>{zoom=Math.max(0.7,zoom-0.1);applyZoom();});"
   "document.getElementById('zoom-reset').addEventListener('click',()=>{zoom=1;applyZoom();});"
   "document.getElementById('back').addEventListener('click',()=>history.back());"
   "document.getElementById('forward').addEventListener('click',()=>history.forward());"
   doclive--wiki-js
   "applyTheme(getStoredTheme());"
   "scrubSensitiveQueryFromLocation();"
   "initializeNavigation();"
   "(async()=>{try{const j=await fetchContent(); await applyContent(j);}catch(e){statusEl.textContent='initial load failed'; dotEl.className='dot dot-disconnected';} connectSSE();})();")
  "Client-side JavaScript for the doclive preview page.")

(defun doclive--preview-html (&optional script-nonce title)
  "Return the complete self-contained preview HTML page.
The page embeds marked.js for Markdown rendering, highlight.js for
syntax highlighting, KaTeX for math typesetting including LaTeX
environments, Mermaid.js for diagram rendering, and an
SSE client for live-update support.  SCRIPT-NONCE is applied to inline
runtime script and style when it is safe for CSP nonce use.  TITLE,
when non-nil, names the previewed buffer in the page's <title>."
  (concat
   "<!doctype html><html><head><meta charset='utf-8'>"
   "<meta name='viewport' content='width=device-width,initial-scale=1'>"
   "<meta name='referrer' content='no-referrer'>"
   "<title>" (doclive--escape-html (if title (concat title " - doclive") "doclive")) "</title>"
   "<link rel='icon' href='data:,'>"
   "<link rel='stylesheet' href='" (doclive--preview-asset-url 'highlight-css) "'"
   (doclive--preview-asset-integrity-attrs 'highlight-css) ">"
   "<link rel='stylesheet' href='" (doclive--preview-asset-url 'katex-css) "'"
   (doclive--preview-asset-integrity-attrs 'katex-css) ">"
   "<style>"
   doclive--preview-css
   "</style></head><body>"
   "<div class='layout'><aside class='toc'><h2>Outline</h2><nav id='toc'></nav></aside>"
   "<main class='main'>"
   "<div class='toolbar' role='toolbar' aria-label='Preview controls'>"
   "<header class='hero'><h1 class='wordmark'>doclive workspace<span class='caret' aria-hidden='true'></span></h1></header>"
   "<button id='back' aria-label='Back'>←</button><button id='forward' aria-label='Forward'>→</button>"
   "<input id='search' placeholder='Find in page' aria-label='Find in page'>"
   "<button id='pin' class='primary'>Pin</button>"
   "<span class='chips' id='chips'></span>"
   "<select id='theme' aria-label='Theme'><option value='dark'>Dark</option><option value='light'>Light</option></select>"
   "<button id='zoom-out' aria-label='Zoom out'>A-</button><button id='zoom-reset' aria-label='Reset zoom'>A</button><button id='zoom-in' aria-label='Zoom in'>A+</button>"
   "</div>"
   "<article id='md' class='md'></article></main></div>"
   "<footer class='modeline'><span class='dot' id='dot' aria-hidden='true'></span><span id='status' role='status' aria-live='polite' aria-atomic='true'>connecting…</span><span class='spacer'></span><span id='scrollpos'>Top</span></footer>"
   "<script src='" (doclive--preview-asset-url 'marked-script) "'"
   (doclive--preview-asset-integrity-attrs 'marked-script) "></script>"
   "<script src='" (doclive--preview-asset-url 'highlight-script) "'"
   (doclive--preview-asset-integrity-attrs 'highlight-script) "></script>"
   "<script src='" (doclive--preview-asset-url 'katex-script) "'"
   (doclive--preview-asset-integrity-attrs 'katex-script) "></script>"
   "<script src='" (doclive--preview-asset-url 'katex-auto-render-script) "'"
   (doclive--preview-asset-integrity-attrs 'katex-auto-render-script) "></script>"
   "<script src='" (doclive--preview-asset-url 'mermaid-script) "'"
   (doclive--preview-asset-integrity-attrs 'mermaid-script) "></script>"
   "<script"
   (let ((nonce (doclive--browser-script-nonce script-nonce)))
     (if nonce (concat " nonce='" (doclive--escape-html-attribute nonce) "'") ""))
   ">"
   doclive--preview-js
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

(defun doclive--acceptable-fetch-site-p (headers)
  "Return non-nil when the Sec-Fetch-Site HEADERS value is acceptable.
Browsers cannot be relied upon for SameSite isolation across loopback
ports because port is not part of a site.  When a browser sends
Sec-Fetch-Site, require `same-origin' or `none' so that requests
initiated by another local origin (reported as `same-site' or
`cross-site') are rejected.  Non-browser clients that omit the header
are still allowed."
  (let ((values (doclive--request-header-values headers "sec-fetch-site")))
    (or (null values)
        (and (= (length values) 1)
             (member (downcase (car values)) '("same-origin" "none"))))))

(defun doclive--authorized-request-p (path &optional headers)
  "Return non-nil if PATH is valid and HEADERS has the current token cookie."
  (and (doclive--valid-query-p path)
       (not (doclive--query-key-present-p path "bootstrap"))
       (doclive--acceptable-fetch-site-p headers)
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

(defun doclive--send-preview (proc &optional path)
  "Send the preview page on PROC and close it.
PATH, when supplied, is used to look up the previewed buffer's name
for the page title."
  (let* ((script-nonce (doclive--random-token))
         (cookie-header (doclive--session-cookie-header))
         (id (and path (doclive--query-param path "id")))
         (name (and id (plist-get (doclive--get-entry id) :name))))
    (process-send-string
     proc
     (doclive--http-response "200 OK" "text/html"
                              (doclive--preview-html script-nonce name)
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
        (doclive--send-preview proc path)
      (doclive--send-forbidden proc)))
   ((doclive--route-matches-p path "/preview")
    (cond
     ((doclive--authorized-request-p path headers)
      (doclive--send-preview proc path))
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
   ((doclive--route-matches-p path "/copy")
    (if (doclive--authorized-request-p path headers)
        (let* ((id (doclive--query-param path "id"))
               (text (condition-case nil
                         (json-parse-string (or (doclive--query-param path "text") ""))
                       (error nil)))
               (valid (and (doclive--get-entry id)
                           (stringp text) (not (string-empty-p text))
                           (<= (string-bytes text) 12000))))
          (when valid (kill-new text))
          (process-send-string
           proc (doclive--http-response
                 (if valid "200 OK" "400 Bad Request") "application/json"
                 (json-encode (if valid '((ok . t))
                                '((ok . :json-false) (error . "Invalid copy request"))))))
          (delete-process proc))
      (doclive--send-forbidden proc)))
   ((or (doclive--route-matches-p path "/workspace")
        (doclive--route-matches-p path "/search"))
    (if (doclive--authorized-request-p path headers)
        (let* ((id (doclive--query-param path "id"))
               (root (plist-get (doclive--get-entry id) :wiki-root))
               (body (if (doclive--route-matches-p path "/workspace")
                         (doclive--wiki-workspace id path)
                       (if root
                           `((ok . t) (results . ,(vconcat (doclive--wiki-search root (doclive--query-param path "q")))))
                         '((ok . :json-false) (error . "No Wiki workspace"))))))
          (process-send-string proc (doclive--http-response "200 OK" "application/json" (json-encode body)))
          (delete-process proc))
      (doclive--send-forbidden proc)))
   ((doclive--route-matches-p path "/open")
    (if (doclive--authorized-request-p path headers)
        (let ((id (doclive--query-param path "id"))
              (rel (doclive--query-param path "path")))
          (process-send-string
           proc
           (doclive--http-response "200 OK" "application/json"
                                    (if (equal (doclive--query-param path "wiki") "1")
                                        (doclive--wiki-open id rel)
                                      (doclive--open-linked-document id rel))))
          (delete-process proc))
      (doclive--send-forbidden proc)))
   ((doclive--route-matches-p path "/events")
    (if (doclive--authorized-request-p path headers)
        (let* ((id (doclive--query-param path "id"))
               (entry (and id (doclive--get-entry id))))
          (cond
           ((not entry)
            (process-send-string proc (doclive--http-response "400 Bad Request" "text/plain" "Missing or unknown buffer id"))
            (delete-process proc))
           ((>= (length (doclive--sse-clients-for id))
                doclive--max-sse-clients-per-buffer)
            (process-send-string proc (doclive--http-response "429 Too Many Requests" "text/plain" "Too many preview streams"))
            (delete-process proc))
           (t
            (let ((clients (doclive--sse-clients-for id)))
              (process-send-string proc (doclive--sse-handshake))
              (set-process-query-on-exit-flag proc nil)
              (set-process-sentinel proc #'doclive--sse-sentinel)
              (process-put proc 'doclive-buffer-id id)
              (doclive--set-sse-clients-for id (cons proc clients))
              (process-send-string proc
                                   (format "event: revision\ndata: {\"revision\":%d}\n\n"
                                           (or (plist-get entry :revision) 0)))))))
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

(defun doclive--cancel-request-timeout (proc)
  "Cancel the header-read timeout timer stored on PROC, if any."
  (let ((timer (process-get proc 'doclive-request-timer)))
    (when timer
      (cancel-timer timer)
      (process-put proc 'doclive-request-timer nil))))

(defun doclive--arm-request-timeout (proc)
  "Close PROC if it does not finish its HTTP headers in time."
  (unless (process-get proc 'doclive-request-timer)
    (process-put
     proc 'doclive-request-timer
     (run-with-timer
      doclive--request-header-timeout-seconds nil
      (lambda ()
        (process-put proc 'doclive-request-timer nil)
        (when (and (process-live-p proc)
                   (not (process-get proc 'doclive-headers-complete)))
          (ignore-errors
            (process-send-string
             proc (doclive--http-response "408 Request Timeout" "text/plain" "Request timeout")))
          (ignore-errors (delete-process proc))))))))

(defun doclive--connection-filter (proc chunk)
  "Handle incoming HTTP CHUNK on PROC."
  (doclive--arm-request-timeout proc)
  (let* ((buffer (concat (or (process-get proc 'doclive-request-buffer) "") chunk)))
    (if (> (string-bytes buffer) doclive--max-request-bytes)
        (progn
          (process-put proc 'doclive-request-buffer nil)
          (doclive--cancel-request-timeout proc)
          (process-send-string proc (doclive--http-response "413 Payload Too Large" "text/plain" "Request header too large"))
          (delete-process proc))
      (if (not (string-match-p "\r\n\r\n" buffer))
          (process-put proc 'doclive-request-buffer buffer)
        (process-put proc 'doclive-request-buffer nil)
        (process-put proc 'doclive-headers-complete t)
        (doclive--cancel-request-timeout proc)
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
         (clients (doclive--sse-clients-for id))
         (owner (plist-get entry :buffer))
         (owner-xwidget-buffer (and (buffer-live-p owner)
                                     (buffer-local-value 'doclive--xwidget-buffer owner)))
         (xwidget-buffers (delete-dups
                            (delq nil (list (plist-get entry :xwidget-buffer)
                                             owner-xwidget-buffer)))))
    (doclive--cancel-change-timer-by-id id)
    (dolist (proc clients)
      (when (process-live-p proc)
        (delete-process proc)))
    (doclive--set-sse-clients-for id nil)
    (dolist (xwidget-buffer xwidget-buffers)
      (when (buffer-live-p xwidget-buffer)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer xwidget-buffer))))
    (when (buffer-live-p owner)
      (with-current-buffer owner
        (setq doclive--xwidget-buffer nil)
        (setq doclive--xwidget-token nil)))
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
          (condition-case err
              (make-network-process
               :name "doclive-server"
               :server t
               :service doclive-port
               :host doclive-host
               :filter #'doclive--connection-filter
               :coding 'utf-8-unix
               :noquery t)
            (file-error
             (setq doclive--server-token nil)
             (user-error "Doclive cannot listen on %s:%d (%s); customize `doclive-port' and retry"
                         doclive-host doclive-port
                         (error-message-string err)))))
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
  (clrhash doclive--buffers)
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
    (let* ((id (doclive--buffer-id (current-buffer)))
           (entry (doclive--get-entry id)))
      (if entry
          (doclive--cleanup-entry entry)
        (doclive--cancel-change-timer-by-id id)
        (let ((clients (doclive--sse-clients-for id)))
          (dolist (proc clients)
            (when (process-live-p proc)
              (delete-process proc))))
        (doclive--set-sse-clients-for id nil)
        (doclive--remove-entry id)))))

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
(defun doclive-open-wiki (root)
  "Open a Markdown and Org Wiki at ROOT without visiting its other pages.
Recent roots are offered as completion candidates.  Only the initial
README or first sorted document is visited."
  (interactive
   (progn
     (doclive--wiki-load-state)
     (list (completing-read "Wiki directory: "
                            (alist-get 'roots doclive--wiki-state)
                            nil nil nil nil default-directory))))
  (setq root (file-name-as-directory (file-truename root)))
  (unless (file-directory-p root) (user-error "Not a directory: %s" root))
  (let* ((files (doclive--wiki-files root))
         (initial (or (seq-find
                       (lambda (file)
                         (and (equal (file-name-directory file) root)
                              (equal (downcase (file-name-base file)) "readme")))
                       files)
                      (car files))))
    (unless initial (user-error "No readable Markdown or Org pages in this Wiki"))
    (doclive--wiki-load-state)
    (setf (alist-get 'roots doclive--wiki-state)
          (seq-take (cons root (delete root (alist-get 'roots doclive--wiki-state))) 12))
    (let ((enable-local-variables nil) (enable-local-eval nil))
      (with-current-buffer (find-file-noselect initial)
        (setq-local doclive--wiki-root root)
        (doclive--wiki-remember-page root initial)
        (doclive-preview-buffer)))))

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
