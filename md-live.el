;;; md-live.el --- Fast Markdown and Org preview for AI docs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 takeokunn
;;
;; Author: md-live contributors
;; Maintainer: md-live contributors
;; URL: https://github.com/takeokunn/md-live
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

;; md-live is a fast Markdown and Org previewer focused on AI-generated
;; documents.
;;
;; - xwidget is NOT required (external browser by default)
;; - SSE-based live update (no websocket lifecycle complexity)
;; - Mermaid + KaTeX + code highlight in preview UI
;; - TOC sidebar and code-copy buttons

;;; Code:

(require 'browse-url)
(require 'json)
(require 'org)
(require 'ox-html)
(require 'subr-x)
(require 'url-util)

(defgroup md-live nil
  "Fast Markdown and Org preview for AI-generated documents."
  :group 'tools
  :prefix "md-live-")

(defcustom md-live-host "127.0.0.1"
  "Host address for md-live local server."
  :type 'string
  :group 'md-live)

(defcustom md-live-port 39123
  "Port for md-live local server."
  :type 'integer
  :group 'md-live)

(defcustom md-live-open-browser-function #'browse-url
  "Function used to open preview URL."
  :type 'function
  :group 'md-live)

(defvar md-live--server nil)
(defvar md-live--buffers (make-hash-table :test #'equal))
(defvar md-live--sse-clients (make-hash-table :test #'equal))

(defun md-live--buffer-id (buffer)
  "Return stable ID for BUFFER."
  (let ((name (with-current-buffer buffer (or buffer-file-name (buffer-name)))))
    (secure-hash 'sha1 name)))

(defun md-live--escape-html (str)
  "Escape STR for safe HTML embedding."
  (let ((s (replace-regexp-in-string "&" "&amp;" (or str "") t t)))
    (setq s (replace-regexp-in-string "<" "&lt;" s t t))
    (setq s (replace-regexp-in-string ">" "&gt;" s t t))
    (setq s (replace-regexp-in-string "\"" "&quot;" s t t))
    s))

(defun md-live--get-entry (id)
  "Get entry for buffer ID."
  (gethash id md-live--buffers))

(defun md-live--put-entry (id entry)
  "Store ENTRY for buffer ID."
  (puthash id entry md-live--buffers))

(defun md-live--ensure-entry (buffer)
  "Ensure state entry exists for BUFFER."
  (let* ((id (md-live--buffer-id buffer))
         (entry (or (md-live--get-entry id)
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
    (md-live--put-entry id entry)
    entry))

(defun md-live--sse-clients-for (id)
  "Return live SSE clients list for ID."
  (seq-filter #'process-live-p (copy-sequence (gethash id md-live--sse-clients))))

(defun md-live--set-sse-clients-for (id clients)
  "Set SSE CLIENTS list for ID."
  (puthash id (seq-filter #'process-live-p clients) md-live--sse-clients))

(defun md-live--broadcast-revision (id revision)
  "Push REVISION event to all SSE clients of ID."
  (let ((clients (md-live--sse-clients-for id))
        (msg (format "event: revision\ndata: {\"revision\":%d}\n\n" revision)))
    (dolist (client clients)
      (condition-case _
          (process-send-string client msg)
        (error nil)))
    (md-live--set-sse-clients-for id clients)))

(defun md-live--org-buffer-p (buffer)
  "Return non-nil when BUFFER should be exported as Org."
  (with-current-buffer buffer
    (or (derived-mode-p 'org-mode)
        (and buffer-file-name
             (string-equal (downcase (or (file-name-extension buffer-file-name) ""))
                           "org")))))

(defun md-live--org-to-html (text)
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
       (format "<pre class=\"md-live-export-error\">%s</pre>"
               (md-live--escape-html (error-message-string err)))))))

(defun md-live--snapshot-buffer (buffer)
  "Capture BUFFER contents and notify clients."
  (let* ((entry (md-live--ensure-entry buffer))
         (id (plist-get entry :id))
         (text (with-current-buffer buffer
                  (buffer-substring-no-properties (point-min) (point-max))))
         (org-buffer-p (md-live--org-buffer-p buffer))
         (rev (1+ (or (plist-get entry :revision) 0))))
    (setf (plist-get entry :revision) rev)
    (setf (plist-get entry :content-kind) (if org-buffer-p "org-html" "markdown"))
    (setf (plist-get entry :markdown) (if org-buffer-p "" text))
    (setf (plist-get entry :html) (if org-buffer-p (md-live--org-to-html text) ""))
    (md-live--put-entry id entry)
    (md-live--broadcast-revision id rev)
    entry))

(defun md-live--json-for-id (id)
  "Return JSON payload for tracked buffer ID."
  (let ((entry (md-live--get-entry id)))
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

(defun md-live--strip-link-target (rel)
  "Return REL without fragment or query parts."
  (let ((target (or rel "")))
    (if (string-match "[?#]" target)
        (substring target 0 (match-beginning 0))
      target)))

(defun md-live--local-document-link-p (rel)
  "Return non-nil when REL is a local relative document link."
  (and (stringp rel)
       (not (string-empty-p rel))
       (not (file-name-absolute-p rel))
       (not (string-match-p "\\`[[:alpha:]][[:alnum:]+.-]*:" rel))))

(defun md-live--resolve-linked-document (entry rel)
  "Resolve REL Markdown or Org document path from ENTRY file context."
  (let* ((target (and (md-live--local-document-link-p rel)
                      (md-live--strip-link-target rel)))
         (base (plist-get entry :file))
         (dir (and base (file-name-directory base)))
         (full (and target dir (expand-file-name target dir)))
         (ext (and full (downcase (or (file-name-extension full) "")))))
    (when (and full
               (file-exists-p full)
               (member ext '("md" "org")))
      full)))

(defun md-live--open-linked-document (current-id rel)
  "Open REL Markdown or Org document linked from CURRENT-ID entry."
  (let* ((entry (md-live--get-entry current-id))
         (full (and entry (md-live--resolve-linked-document entry rel))))
    (if (not full)
        (json-encode `((ok . :json-false)
                       (error . "linked document not found")))
      (let* ((buf (find-file-noselect full))
             (new-entry (md-live--snapshot-buffer buf))
             (new-id (plist-get new-entry :id)))
        (json-encode `((ok . t)
                       (buffer_id . ,new-id)
                       (name . ,(plist-get new-entry :name))))))))

(defun md-live--http-response (status content-type body)
  "Build HTTP response from STATUS CONTENT-TYPE BODY."
  (concat
   (format "HTTP/1.1 %s\r\n" status)
   "Connection: close\r\n"
   (format "Content-Type: %s; charset=utf-8\r\n" content-type)
   (format "Content-Length: %d\r\n" (string-bytes body))
   "Cache-Control: no-store\r\n"
   "\r\n"
   body))

(defun md-live--preview-html ()
  "Return complete preview HTML."
  (concat
   "<!doctype html><html><head><meta charset='utf-8'>"
   "<meta name='viewport' content='width=device-width,initial-scale=1'>"
   "<title>md-live</title><link rel='icon' href='data:,'>"
   "<link rel='stylesheet' href='https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.10.0/styles/github-dark.min.css'>"
   "<link rel='stylesheet' href='https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css'>"
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
   ".md table{border-collapse:collapse;width:100%;}.md th,.md td{border:1px solid var(--border);padding:6px 8px;}"
   "@media (max-width:980px){.layout{grid-template-columns:1fr}.toc{display:none}.main{padding:14px}}"
   "</style></head><body>"
   "<div class='layout'><aside class='toc'><h2>Outline</h2><nav id='toc'></nav></aside>"
   "<main class='main'><div class='status'><span class='dot'></span><span id='status'>connecting…</span></div>"
   "<div class='toolbar'>"
   "<button id='back'>←</button><button id='forward'>→</button>"
   "<input id='search' placeholder='Find in page'>"
   "<button id='pin'>Pin</button>"
   "<span class='chips' id='chips'></span>"
   "<select id='theme'><option value='dark'>Dark</option><option value='light'>Light</option></select>"
   "<button id='zoom-out'>A-</button><button id='zoom-reset'>A</button><button id='zoom-in'>A+</button>"
   "</div>"
   "<article id='md' class='md'></article></main></div>"
   "<script src='https://cdn.jsdelivr.net/npm/marked/marked.min.js'></script>"
   "<script src='https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.10.0/highlight.min.js'></script>"
   "<script defer src='https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js'></script>"
   "<script defer src='https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js'></script>"
   "<script src='https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js'></script>"
   "<script>"
   "const qs=new URLSearchParams(location.search); let currentId=qs.get('id');"
   "const statusEl=document.getElementById('status'); const mdEl=document.getElementById('md'); const tocEl=document.getElementById('toc');"
   "const searchEl=document.getElementById('search'); const pinEl=document.getElementById('pin'); const chipsEl=document.getElementById('chips');"
   "const themeEl=document.getElementById('theme');"
   "let lastRev=-1;"
   "let navStack=[]; let navIndex=-1;"
   "let pinned=[]; let zoom=1;"
   "marked.setOptions({gfm:true,breaks:true,headerIds:true,mangle:false,highlight:(code,lang)=>{try{return hljs.highlight(code,{language:lang||'plaintext'}).value}catch(e){return hljs.highlightAuto(code).value}}});"
   "mermaid.initialize({startOnLoad:false,securityLevel:'strict',theme:'dark'});"
    "function parseFrontmatter(md){if(!md.startsWith('---\\n')) return {front:null,body:md}; const end=md.indexOf('\\n---\\n',4); if(end===-1) return {front:null,body:md}; const raw=md.slice(4,end).trim(); const body=md.slice(end+5); const map={}; raw.split('\\n').forEach(line=>{const i=line.indexOf(':'); if(i>0){const k=line.slice(0,i).trim(); const v=line.slice(i+1).trim(); map[k]=v;}}); return {front:map,body};}"
    "function escapeHtml(s){return String(s==null?'':s).replace(/[&<>\"']/g,(ch)=>{if(ch==='&') return '&amp;'; if(ch==='<') return '&lt;'; if(ch==='>') return '&gt;'; if(ch==='\"') return '&quot;'; return '&#39;';});}"
    "function sanitizeUrlValue(value){const raw=String(value==null?'':value); const folded=raw.replace(/[\\u0000-\\u001F\\u007F\\s]+/g,'').toLowerCase(); return folded.startsWith('javascript:')?'':raw;}"
    "function sanitizeHtml(html){const tpl=document.createElement('template'); tpl.innerHTML=html||''; tpl.content.querySelectorAll('script,iframe').forEach((el)=>el.remove()); const walker=document.createTreeWalker(tpl.content,NodeFilter.SHOW_ELEMENT); const nodes=[]; while(walker.nextNode()) nodes.push(walker.currentNode); nodes.forEach((el)=>{Array.from(el.attributes).forEach((attr)=>{const name=attr.name||''; if(/^on/i.test(name)){el.removeAttribute(attr.name); return;} if(/^(href|src|xlink:href|formaction)$/i.test(name)){const safe=sanitizeUrlValue(attr.value||''); if(safe){el.setAttribute(attr.name,safe);}else{el.removeAttribute(attr.name);}}});}); return tpl.innerHTML;}"
     "function setSanitizedSvg(container,svg){const tpl=document.createElement('template'); tpl.innerHTML=sanitizeHtml(svg||''); const root=tpl.content.firstElementChild; if(!root||root.tagName.toLowerCase()!=='svg'||tpl.content.childElementCount!==1) throw new Error('invalid mermaid svg'); container.replaceChildren(root.cloneNode(true));}"
    "function renderFrontmatter(front){if(!front) return ''; const rows=Object.entries(front).map(([k,v])=>`<tr><th>${escapeHtml(k)}</th><td>${escapeHtml(v)}</td></tr>`).join(''); return `<details class=\"frontmatter\" open><summary>Frontmatter</summary><table>${rows}</table></details>`;}"
   "function buildToc(){tocEl.innerHTML=''; const hs=mdEl.querySelectorAll('h1,h2,h3,h4,h5,h6'); hs.forEach((h,i)=>{if(!h.id)h.id='h-'+i; const a=document.createElement('a'); a.href='#'+h.id; a.textContent=h.textContent; a.style.paddingLeft=((parseInt(h.tagName.slice(1))-1)*10+8)+'px'; tocEl.appendChild(a);});}"
    "function wireCopy(){mdEl.querySelectorAll('pre').forEach((pre)=>{const old=pre.querySelector('.copy-btn'); if(old) old.remove(); const code=pre.querySelector('code'); const src=code||pre; const b=document.createElement('button'); b.className='copy-btn'; b.textContent='Copy'; b.onclick=async()=>{try{await navigator.clipboard.writeText(src.innerText); b.textContent='Copied'; setTimeout(()=>b.textContent='Copy',900);}catch(e){b.textContent='Failed'; setTimeout(()=>b.textContent='Copy',900);}}; pre.appendChild(b);});}"
    "async function renderMermaid(){const blocks=Array.from(mdEl.querySelectorAll('pre code.language-mermaid, pre.src-mermaid, pre.src.src-mermaid')); for(const el of blocks){const pre=el.tagName==='PRE'?el:el.closest('pre'); let graph=''; if(el.tagName==='PRE'){const clone=el.cloneNode(true); clone.querySelectorAll('.copy-btn').forEach((b)=>b.remove()); graph=clone.textContent||'';}else{graph=el.textContent||'';} const holder=document.createElement('div'); holder.style.background='#fff'; holder.style.padding='10px'; holder.style.borderRadius='10px'; holder.style.overflow='auto'; try{const out=await mermaid.render('m'+Math.random().toString(36).slice(2),graph); setSanitizedSvg(holder,out.svg); if(pre&&pre.parentNode) pre.parentNode.replaceChild(holder,pre);}catch(e){holder.textContent=graph; if(pre&&pre.parentNode) pre.parentNode.replaceChild(holder,pre);}}}"
    "function renderMath(){if(window.renderMathInElement){renderMathInElement(mdEl,{delimiters:[{left:'\\\\[',right:'\\\\]',display:true},{left:'\\\\(',right:'\\\\)',display:false},{left:'$$',right:'$$',display:true},{left:'$',right:'$',display:false}]});}}"
   "function escReg(s){return s.replace(/[.*+?^${}()|[\\]\\\\]/g,'\\\\$&')}"
   "function replaceTextNode(node,re,cls){const text=node.nodeValue; let m,last=0; const frag=document.createDocumentFragment(); while((m=re.exec(text))!==null){if(m.index>last) frag.appendChild(document.createTextNode(text.slice(last,m.index))); const mark=document.createElement('mark'); mark.className=cls; mark.textContent=m[0]; frag.appendChild(mark); last=re.lastIndex; if(re.lastIndex===m.index) re.lastIndex++;} if(last<text.length) frag.appendChild(document.createTextNode(text.slice(last))); node.parentNode.replaceChild(frag,node);}"
    "function walkAndHighlight(root,re,cls){const walker=document.createTreeWalker(root,NodeFilter.SHOW_TEXT,{acceptNode(n){if(!n.nodeValue.trim()) return NodeFilter.FILTER_REJECT; const p=n.parentNode; if(!p) return NodeFilter.FILTER_REJECT; if(p.closest&&p.closest('script,style,code,pre,.katex,svg')) return NodeFilter.FILTER_REJECT; return NodeFilter.FILTER_ACCEPT;}}); const nodes=[]; while(walker.nextNode()) nodes.push(walker.currentNode); nodes.forEach(n=>replaceTextNode(n,re,cls));}"
    "function applyHighlights(){const html=mdEl.getAttribute('data-base-html')||mdEl.innerHTML; mdEl.innerHTML=html; const q=(searchEl.value||'').trim(); if(q){walkAndHighlight(mdEl,new RegExp(escReg(q),'gi'),'mark-pin-0');} pinned.forEach((term,idx)=>{if(term){walkAndHighlight(mdEl,new RegExp(escReg(term),'gi'),'mark-pin-'+(idx%4));}}); wireCopy(); wireDocumentLinkNavigation();}"
   "function renderChips(){chipsEl.innerHTML=''; pinned.forEach((term,idx)=>{const el=document.createElement('span'); el.className='chip'; const label=document.createElement('b'); label.textContent=term; el.appendChild(label); const c=document.createElement('button'); c.className='chip-close'; c.textContent='×'; c.onclick=()=>{pinned=pinned.filter((_,i)=>i!==idx); applyHighlights(); renderChips();}; el.appendChild(c); chipsEl.appendChild(el);});}"
   "function applyTheme(theme){document.body.setAttribute('data-theme',theme); localStorage.setItem('md-live-theme',theme); themeEl.value=theme;}"
   "function applyZoom(){mdEl.style.fontSize=(zoom*100)+'%';}"
   "function pushNav(id,name){if(navIndex>=0&&navStack[navIndex]&&navStack[navIndex].id===id) return; navStack=navStack.slice(0,navIndex+1); navStack.push({id:id,name:name||''}); navIndex=navStack.length-1; updateNavButtons();}"
   "function updateNavButtons(){document.getElementById('back').disabled=navIndex<=0; document.getElementById('forward').disabled=navIndex<0||navIndex>=navStack.length-1;}"
   "let es=null;"
   "async function fetchContent(){const r=await fetch('/content?id='+encodeURIComponent(currentId),{cache:'no-store'}); return r.json();}"
     "async function applyContent(j){if(!j.ok){statusEl.textContent=j.error||'not found'; return;} statusEl.textContent='live • rev '+j.revision+' • '+(j.name||''); if(j.revision===lastRev) return; lastRev=j.revision; const kind=j.contentKind||'markdown'; let html=''; if(kind==='org-html'){html=j.html||'';}else{const parsed=parseFrontmatter(j.markdown||''); html=renderFrontmatter(parsed.front)+marked.parse(parsed.body||'');} html=sanitizeHtml(html); mdEl.setAttribute('data-content-kind',kind); mdEl.innerHTML=html; wireCopy(); renderMath(); await renderMermaid(); buildToc(); mdEl.setAttribute('data-base-html',mdEl.innerHTML); applyHighlights(); applyZoom(); pushNav(currentId,j.name||''); history.replaceState({id:currentId},'',`?id=${encodeURIComponent(currentId)}`);}"
    "async function openLinkedDocument(href){try{const r=await fetch('/open?id='+encodeURIComponent(currentId)+'&path='+encodeURIComponent(href),{cache:'no-store'}); const j=await r.json(); if(!j.ok){statusEl.textContent=j.error||'open failed'; return;} currentId=j.buffer_id; lastRev=-1; connectSSE(); const c=await fetchContent(); await applyContent(c);}catch(e){statusEl.textContent='open failed';}}"
    "function wireDocumentLinkNavigation(){mdEl.querySelectorAll('a[href]').forEach(a=>{const href=a.getAttribute('href')||''; if(/^[a-zA-Z][a-zA-Z0-9+.-]*:/i.test(href)||href.startsWith('#')) return; if(!/\\.(md|org)($|#|\\?)/i.test(href)) return; a.addEventListener('click',ev=>{ev.preventDefault(); openLinkedDocument(href);});});}"
   "function connectSSE(){if(!currentId){statusEl.textContent='missing id'; return;} if(es){es.close(); es=null;} es=new EventSource('/events?id='+encodeURIComponent(currentId)); es.addEventListener('open',()=>{statusEl.textContent='connected';}); es.addEventListener('revision',async()=>{try{const j=await fetchContent(); await applyContent(j);}catch(e){statusEl.textContent='sync error';}}); es.onerror=()=>{statusEl.textContent='reconnecting…';};}"
   "searchEl.addEventListener('input',()=>applyHighlights());"
   "pinEl.addEventListener('click',()=>{const q=(searchEl.value||'').trim(); if(!q) return; if(!pinned.includes(q)) pinned.push(q); renderChips(); applyHighlights();});"
   "themeEl.addEventListener('change',()=>applyTheme(themeEl.value));"
   "document.getElementById('zoom-in').addEventListener('click',()=>{zoom=Math.min(2,zoom+0.1);applyZoom();});"
   "document.getElementById('zoom-out').addEventListener('click',()=>{zoom=Math.max(0.7,zoom-0.1);applyZoom();});"
   "document.getElementById('zoom-reset').addEventListener('click',()=>{zoom=1;applyZoom();});"
   "document.getElementById('back').addEventListener('click',async()=>{if(navIndex<=0) return; navIndex--; currentId=navStack[navIndex].id; updateNavButtons(); lastRev=-1; connectSSE(); const j=await fetchContent(); await applyContent(j);});"
   "document.getElementById('forward').addEventListener('click',async()=>{if(navIndex>=navStack.length-1) return; navIndex++; currentId=navStack[navIndex].id; updateNavButtons(); lastRev=-1; connectSSE(); const j=await fetchContent(); await applyContent(j);});"
   "applyTheme(localStorage.getItem('md-live-theme')||'dark');"
   "(async()=>{try{const j=await fetchContent(); await applyContent(j);}catch(e){statusEl.textContent='initial load failed';} connectSSE();})();"
   "</script></body></html>"))

(defun md-live--parse-request-path (request-line)
  "Extract request path from REQUEST-LINE."
  (when (and request-line (string-match "^GET \\([^ ]+\\) HTTP/" request-line))
    (match-string 1 request-line)))

(defun md-live--query-param (path key)
  "Extract KEY from query in PATH."
  (when (and path (string-match "?\\(.*\\)$" path))
    (let ((pairs (split-string (match-string 1 path) "&" t))
          (needle (concat key "="))
          found)
      (dolist (p pairs found)
        (when (and (not found) (string-prefix-p needle p))
          (setq found (url-unhex-string (substring p (length needle)))))))))

(defun md-live--sse-handshake ()
  "Return SSE headers."
  (concat
   "HTTP/1.1 200 OK\r\n"
   "Content-Type: text/event-stream\r\n"
   "Cache-Control: no-cache\r\n"
   "Connection: keep-alive\r\n\r\n"
   "retry: 1200\n\n"))

(defun md-live--route-request (proc path)
  "Route request on PROC for PATH."
  (cond
   ((or (equal path "/") (string-prefix-p "/preview" path))
    (process-send-string proc (md-live--http-response "200 OK" "text/html" (md-live--preview-html)))
    (delete-process proc))
   ((string-prefix-p "/content" path)
    (let ((id (md-live--query-param path "id")))
      (process-send-string proc (md-live--http-response "200 OK" "application/json" (md-live--json-for-id id)))
      (delete-process proc)))
   ((string-prefix-p "/open" path)
    (let ((id (md-live--query-param path "id"))
          (rel (md-live--query-param path "path")))
      (process-send-string
       proc
       (md-live--http-response "200 OK" "application/json"
                                (md-live--open-linked-document id rel)))
      (delete-process proc)))
   ((string-prefix-p "/events" path)
    (let* ((id (md-live--query-param path "id"))
           (clients (md-live--sse-clients-for id)))
      (process-send-string proc (md-live--sse-handshake))
      (set-process-query-on-exit-flag proc nil)
      (set-process-sentinel proc #'md-live--sse-sentinel)
      (process-put proc 'md-live-buffer-id id)
      (md-live--set-sse-clients-for id (cons proc clients))
      (let ((entry (md-live--get-entry id)))
        (when entry
          (process-send-string proc
                               (format "event: revision\ndata: {\"revision\":%d}\n\n"
                                       (or (plist-get entry :revision) 0)))))))
   (t
    (process-send-string proc (md-live--http-response "404 Not Found" "text/plain" "Not Found"))
    (delete-process proc))))

(defun md-live--sse-sentinel (proc _event)
  "Cleanup SSE PROC from client table."
  (let* ((id (process-get proc 'md-live-buffer-id))
         (clients (md-live--sse-clients-for id)))
    (md-live--set-sse-clients-for id (delq proc clients))))

(defun md-live--connection-filter (proc chunk)
  "Handle incoming HTTP CHUNK on PROC."
  (let* ((line (car (split-string chunk "\r\n" t)))
         (path (md-live--parse-request-path line)))
    (md-live--route-request proc (or path "/"))))

(defun md-live--server-log (_server client message)
  "Attach filter for accepted CLIENT and MESSAGE."
  (when (and (processp client) (stringp message) (string-match-p "open" message))
    (set-process-filter client #'md-live--connection-filter)
    (set-process-coding-system client 'utf-8-unix 'utf-8-unix)))

(defun md-live-server-running-p ()
  "Return non-nil when md-live server is running."
  (process-live-p md-live--server))

;;;###autoload
(defun md-live-start-server ()
  "Start md-live local server."
  (interactive)
  (unless (md-live-server-running-p)
    (setq md-live--server
          (make-network-process
           :name "md-live-server"
           :server t
           :service md-live-port
           :host md-live-host
           :filter #'md-live--connection-filter
           :coding 'utf-8-unix
           :noquery t))
    (message "md-live server started: http://%s:%d" md-live-host md-live-port)))

;;;###autoload
(defun md-live-stop-server ()
  "Stop md-live local server."
  (interactive)
  (when (md-live-server-running-p)
    (delete-process md-live--server)
    (setq md-live--server nil))
  (maphash (lambda (_id clients)
             (dolist (proc clients)
               (when (process-live-p proc)
                 (delete-process proc))))
           md-live--sse-clients)
  (clrhash md-live--sse-clients)
  (message "md-live server stopped"))

(defun md-live--preview-url (buffer)
  "Return preview URL for BUFFER."
  (format "http://%s:%d/preview?id=%s"
          md-live-host md-live-port (url-hexify-string (md-live--buffer-id buffer))))

(defun md-live--on-change (&rest _)
  "Update snapshot after local edits."
  (when (bound-and-true-p md-live-preview-mode)
    (md-live--snapshot-buffer (current-buffer))))

;;;###autoload
(define-minor-mode md-live-preview-mode
  "Track this buffer for md-live preview updates."
  :lighter " md-live"
  (if md-live-preview-mode
      (progn
        (add-hook 'after-change-functions #'md-live--on-change nil t)
        (add-hook 'after-save-hook #'md-live--on-change nil t)
        (md-live--snapshot-buffer (current-buffer)))
    (remove-hook 'after-change-functions #'md-live--on-change t)
    (remove-hook 'after-save-hook #'md-live--on-change t)))

;;;###autoload
(defun md-live-preview-buffer ()
  "Preview current buffer in browser and keep it live."
  (interactive)
  (md-live-start-server)
  (md-live-preview-mode 1)
  (funcall md-live-open-browser-function (md-live--preview-url (current-buffer)))
  (message "md-live preview opened"))

;;;###autoload
(defun md-live-preview-file (file)
  "Open Markdown or Org FILE and start md-live preview."
  (interactive "fMarkdown or Org file: ")
  (find-file file)
  (md-live-preview-buffer))

(provide 'md-live)

;;; md-live.el ends here
