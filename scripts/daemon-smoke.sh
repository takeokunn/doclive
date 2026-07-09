#!/usr/bin/env zsh
set -euo pipefail

root=${0:A:h:h}
server="doclive-smoke-$$"
port=$((49152 + RANDOM % 10000))
emacs_bin=${EMACS:-emacs}
emacsclient_bin=${EMACSCLIENT:-emacsclient}
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/doclive-daemon-smoke.XXXXXX")
open_url_file="$tmpdir/open-url.txt"
cookie_file="$tmpdir/cookies.txt"
html_file="$tmpdir/preview.html"
content_file="$tmpdir/content.json"
open_file="$tmpdir/open.json"
events_file="$tmpdir/events.txt"

cleanup() {
  if "$emacsclient_bin" -s "$server" --eval t >/dev/null 2>&1; then
    "$emacsclient_bin" -s "$server" --eval "(progn (ignore-errors (doclive-stop-server)) (kill-emacs 0))" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmpdir"
}
trap cleanup EXIT

die() {
  print -u2 -- "$1"
  exit 1
}

require_contains() {
  local file=$1
  local pattern=$2
  PATTERN="$pattern" perl -0ne 'BEGIN { $pattern = $ENV{"PATTERN"} } END { exit($matched ? 0 : 1) } $matched ||= /$pattern/s' "$file" \
    || die "missing pattern in $file: $pattern"
}

require_not_contains() {
  local file=$1
  local pattern=$2
  PATTERN="$pattern" perl -0ne 'BEGIN { $pattern = $ENV{"PATTERN"} } END { exit($matched ? 1 : 0) } $matched ||= /$pattern/s' "$file" \
    || die "unexpected pattern in $file: $pattern"
}

emacs_eval() {
  "$emacsclient_bin" -s "$server" --eval "$1"
}

extract_id_from_url() {
  print -r -- "$1" | perl -0ne 'if (/[?&]id=([^&]+)/) { print $1; $found = 1 } END { exit($found ? 0 : 1) }'
}

open_preview() {
  local label=$1
  local code=$2
  : > "$open_url_file"
  emacs_eval "$code" >/dev/null
  [[ -s "$open_url_file" ]] || die "$label did not open a preview URL"
  perl -0pe 's/\n+\z//' "$open_url_file"
}

fetch_preview() {
  local url=$1
  local http_status
  http_status=$(curl -sS -c "$cookie_file" -b "$cookie_file" -L -o "$html_file" -w "%{http_code}" "$url")
  [[ "$http_status" == "200" ]] || die "preview returned HTTP $http_status"
  require_contains "$html_file" "doclive workspace"
  require_contains "$html_file" "role='toolbar'"
  require_contains "$html_file" "--surface-glass"
  require_contains "$html_file" "class='hero'"
  require_contains "$html_file" "@media \\(prefers-reduced-motion:reduce\\)"
  require_contains "$html_file" "\\.toc\\{position:relative"
  require_not_contains "$html_file" "\\.toc\\{display:none"
}

fetch_content() {
  local id=$1
  local http_status
  http_status=$(curl -sS -b "$cookie_file" -o "$content_file" -w "%{http_code}" "http://127.0.0.1:$port/content?id=$id")
  [[ "$http_status" == "200" ]] || die "content returned HTTP $http_status"
  require_contains "$content_file" '"ok"[[:space:]]*:[[:space:]]*true'
  require_contains "$content_file" '"contentKind"'
}

"$emacs_bin" -Q --daemon="$server" >/dev/null

emacs_eval "(progn
  (add-to-list 'load-path \"$root\")
  (load-file \"$root/doclive.el\")
  (setq doclive-host \"127.0.0.1\")
  (setq doclive-port $port)
  (setq doclive-open-browser-function
        (lambda (url)
          (with-temp-file \"$open_url_file\"
            (insert url))))
  t)" >/dev/null

emacs_eval "(progn
  (doclive-start-server)
  (unless (doclive-server-running-p)
    (error \"server did not start\")))" >/dev/null

md_url=$(open_preview "doclive-preview-buffer" "(progn
  (find-file \"$root/example/sample.md\")
  (doclive-preview-buffer))")
fetch_preview "$md_url"
md_id=$(extract_id_from_url "$md_url")
fetch_content "$md_id"

events_status=$(curl -sS --max-time 1 -b "$cookie_file" -o "$events_file" -w "%{http_code}" "http://127.0.0.1:$port/events?id=$md_id" || true)
[[ "$events_status" == "200" ]] || die "events returned HTTP $events_status"
require_contains "$events_file" "event: revision"

open_status=$(curl -sS -b "$cookie_file" -o "$open_file" -w "%{http_code}" "http://127.0.0.1:$port/open?id=$md_id&path=sample.org")
[[ "$open_status" == "200" ]] || die "open returned HTTP $open_status"
require_contains "$open_file" '"ok"[[:space:]]*:[[:space:]]*true'
org_id=$(perl -0ne 'if (/"buffer_id"\s*:\s*"([^"]+)"/) { print $1; $found = 1 } END { exit($found ? 0 : 1) }' "$open_file")
fetch_content "$org_id"

emacs_eval "(with-current-buffer (find-buffer-visiting \"$root/example/sample.md\")
  (doclive-reload-page))" >/dev/null

emacs_eval "(with-current-buffer (find-buffer-visiting \"$root/example/sample.md\")
  (let ((id doclive--buffer-id-value))
    (unless id
      (error \"missing buffer id before disabling preview mode\"))
    (doclive-preview-mode -1)
    (when (doclive--get-entry id)
      (error \"preview entry was not cleaned up\"))))" >/dev/null

force_url=$(open_preview "doclive-preview-buffer force restart" "(with-current-buffer (find-buffer-visiting \"$root/example/sample.md\")
  (doclive-preview-buffer t))")
fetch_preview "$force_url"
force_id=$(extract_id_from_url "$force_url")
fetch_content "$force_id"

file_url=$(open_preview "doclive-preview-file" "(doclive-preview-file \"$root/example/sample.org\")")
fetch_preview "$file_url"
file_id=$(extract_id_from_url "$file_url")
fetch_content "$file_id"

emacs_eval "(progn
  (doclive-stop-server)
  (when (doclive-server-running-p)
    (error \"server did not stop\")))" >/dev/null

print -- "daemon smoke passed"
