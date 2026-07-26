#!/usr/bin/env zsh

set -euo pipefail

readonly root=${0:A:h:h}
readonly tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/doclive-js.XXXXXX")
readonly script="$tmpdir/preview.js"

trap 'rm -rf "$tmpdir"' EXIT

"${EMACS:-emacs}" -Q --batch -L "$root" -l "$root/doclive.el" \
  --eval '(princ doclive--preview-js)' > "$script"

if [[ ! -s "$script" ]]; then
  print -u2 'generated preview JavaScript is empty'
  exit 1
fi

if command -v "${NODE:-node}" >/dev/null 2>&1; then
  "${NODE:-node}" --check "$script"
elif command -v nix >/dev/null 2>&1; then
  nix run nixpkgs#nodejs -- --check "$script"
else
  print -u2 'Node.js is required to validate the generated preview JavaScript'
  exit 127
fi
