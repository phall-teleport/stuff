PACKAGE := Teleport Beams.bbpackage
SCRIPTS := $(wildcard $(PACKAGE)/Contents/Scripts/*/*.sh) $(wildcard $(PACKAGE)/Contents/Text\ Filters/*/*.sh)
LIB     := $(PACKAGE)/Contents/Resources/lib

.PHONY: install install-link uninstall check lint test

install:
	./install.sh

install-link:
	./install.sh --link

uninstall:
	./install.sh --uninstall

## Syntax-check every shell script and byte-compile the Python helpers.
check:
	@for f in "$(PACKAGE)"/Contents/Scripts/*/*.sh "$(PACKAGE)"/Contents/Text\ Filters/*/*.sh "$(LIB)"/beams-lib.sh; do bash -n "$$f" || exit 1; done
	@python3 -m py_compile "$(LIB)"/*.py
	@echo "syntax OK"

## shellcheck, if installed.
lint: check
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -x -s bash "$(LIB)/beams-lib.sh" "$(PACKAGE)"/Contents/Scripts/*/*.sh "$(PACKAGE)"/Contents/Text\ Filters/*/*.sh; \
	else echo "shellcheck not installed; skipping"; fi

## Unit tests for the Python helpers (no network, no tsh).
test: check
	@python3 tests/test_helpers.py
