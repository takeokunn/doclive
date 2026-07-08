EMACS ?= emacs
EMACS_BATCH = $(EMACS) -Q --batch -L . -L test

SRC = doclive.el
TEST = test/doclive-test-helpers.el test/doclive-test.el

.PHONY: check compile test lint package-lint autoloads clean

check: compile test lint package-lint autoloads
	git diff --check
	git diff --exit-code -- doclive-autoloads.el

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
	$(EMACS_BATCH) --eval '(let ((output (expand-file-name "doclive-autoloads.el" default-directory))) (if (require (quote loaddefs-gen) nil t) (loaddefs-generate default-directory output) (require (quote autoload)) (let ((generated-autoload-file output)) (update-directory-autoloads default-directory))))'

clean:
	rm -f *.elc test/*.elc doclive-autoloads.el
