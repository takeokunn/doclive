EMACS ?= emacs
EMACS_BATCH = $(EMACS) -Q --batch -L . -L test

SRC = doclive.el
TEST = test/doclive-test-helpers.el test/doclive-test.el
AUTOLOAD_SYMBOLS = doclive-start-server doclive-stop-server doclive-preview-mode doclive-preview-buffer doclive-preview-file doclive-reload-page

.PHONY: check compile test lint package-lint autoloads security clean

check: compile test lint package-lint autoloads security
	git diff --check

compile:
	$(EMACS_BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(SRC) $(TEST)

test:
	$(EMACS_BATCH) -l test/doclive-test.el -f ert-run-tests-batch-and-exit

lint:
	$(EMACS_BATCH) --eval '(require (quote checkdoc))' --eval '(checkdoc-file "doclive.el")'

package-lint:
	$(EMACS_BATCH) \
	  --eval '(require (quote package))' \
	  --eval '(add-to-list (quote package-archives) (cons "gnu" "https://elpa.gnu.org/packages/") t)' \
	  --eval '(add-to-list (quote package-archives) (cons "melpa" "https://melpa.org/packages/") t)' \
	  --eval '(package-initialize)' \
	  --eval '(unless (require (quote package-lint) nil t) (unless package-archive-contents (package-refresh-contents)) (unless (package-installed-p (quote package-lint)) (package-install (quote package-lint))) (require (quote package-lint)))' \
	  --eval '(require (quote package-lint))' \
	  --eval '(find-file "doclive.el")' \
	  --eval '(let ((issues (package-lint-buffer))) (if issues (progn (dolist (i issues) (princ (format "%s\n" i))) (kill-emacs 1)) (kill-emacs 0)))'

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

clean:
	rm -f *.elc test/*.elc doclive-autoloads.el
