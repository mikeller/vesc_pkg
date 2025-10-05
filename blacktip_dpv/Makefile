VESC_TOOL ?= vesc_tool

all: blacktip_dpv.vescpkg

blacktip_dpv.vescpkg: pkgdesc.qml README.md ui.qml blacktip_dpv.lisp
	$(VESC_TOOL) --buildPkgFromDesc pkgdesc.qml --testPkgDesc 'vesc:test'

check-whitespace:
	@echo "Checking for trailing whitespace..."
	@if grep -nE '[[:space:]]+$$' blacktip_dpv.lisp; then \
		echo "Error: Trailing whitespace found (shown above)"; \
		exit 1; \
	else \
		echo "✓ No trailing whitespace found"; \
	fi

test: check-whitespace
	@echo "No tests defined"

clean:
	rm -f blacktip_dpv.vescpkg

.PHONY: all test clean check-whitespace
