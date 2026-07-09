EMACS ?= emacs
EMACS_BATCH = $(EMACS) -Q --batch -L . -L test

SRC = doclive.el
TEST = test/doclive-test-helpers.el test/doclive-test.el
AUTOLOAD_SYMBOLS = doclive-start-server doclive-stop-server doclive-preview-mode doclive-preview-buffer doclive-preview-file doclive-reload-page

.PHONY: check compile test lint package-lint autoloads security smoke clean

check: compile test lint package-lint autoloads security smoke
	git diff --check

compile:
	@tmpdir=$$(mktemp -d "$${TMPDIR:-/tmp}/doclive-compile.XXXXXX"); \
	trap 'rm -rf "$$tmpdir"' EXIT; \
	mkdir -p "$$tmpdir/test"; \
	cp $(SRC) "$$tmpdir/"; \
	cp $(TEST) "$$tmpdir/test/"; \
	(cd "$$tmpdir" && $(EMACS_BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(SRC) $(TEST))

test:
	$(EMACS_BATCH) -l test/doclive-test.el -f ert-run-tests-batch-and-exit

lint:
	$(EMACS_BATCH) --eval '(require (quote checkdoc))' --eval '(checkdoc-file "doclive.el")'

package-lint:
	@if $(EMACS_BATCH) --eval '(kill-emacs (if (require (quote package-lint) nil t) 0 1))' >/dev/null 2>&1; then \
	  $(EMACS_BATCH) \
	    --eval '(require (quote package-lint))' \
	    --eval '(find-file "doclive.el")' \
	    --eval '(let ((issues (package-lint-buffer))) (if issues (progn (dolist (i issues) (princ (format "%s\n" i))) (kill-emacs 1)) (kill-emacs 0)))'; \
	elif [ -z "$$DOCLIVE_PACKAGE_LINT_NIX" ] && command -v nix >/dev/null 2>&1; then \
	  DOCLIVE_PACKAGE_LINT_NIX=1 nix run .#package-lint; \
	else \
	  printf '%s\n' "package-lint is required; run nix run .#package-lint or set EMACS to an Emacs with package-lint."; \
	  exit 127; \
	fi

autoloads:
	@tmpdir=$$(mktemp -d "$${TMPDIR:-/tmp}/doclive-autoloads.XXXXXX"); \
	trap 'rm -rf "$$tmpdir"' EXIT; \
	cp $(SRC) "$$tmpdir/"; \
	tmp="$$tmpdir/doclive-autoloads.el"; \
	DOCLIVE_AUTOLOADS_DIR="$$tmpdir" DOCLIVE_AUTOLOADS_OUTPUT="$$tmp" $(EMACS_BATCH) --eval '(let ((dir (getenv "DOCLIVE_AUTOLOADS_DIR")) (output (getenv "DOCLIVE_AUTOLOADS_OUTPUT"))) (require (quote loaddefs-gen)) (loaddefs-generate dir output nil nil nil t))'; \
	for symbol in $(AUTOLOAD_SYMBOLS); do \
	  DOCLIVE_AUTOLOAD_SYMBOL="$$symbol" perl -0ne 'BEGIN { $$needle = "(autoload " . chr(39) . $$ENV{"DOCLIVE_AUTOLOAD_SYMBOL"} } { $$contents .= $$_ } END { exit(index($$contents, $$needle) >= 0 ? 0 : 1) }' "$$tmp" \
	    || { echo "missing autoload for $$symbol" >&2; exit 1; }; \
	done

security:
	gitleaks detect --no-git --source .
	actionlint .github/workflows/*.yml
	zizmor --offline .github/workflows

smoke:
	./scripts/daemon-smoke.sh

clean:
	rm -f *.elc test/*.elc doclive-autoloads.el
