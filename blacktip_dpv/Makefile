VESC_TOOL ?= vesc_tool
PYTHON ?= python3

GENERATED_DIR := generated
DISPLAY_STAMP := $(GENERATED_DIR)/display_tables.stamp

ASSET_FILES := assets/display_lut.csv assets/brightness_levels.csv
GENERATOR := tools/update_display_tables.py

all: blacktip_dpv.vescpkg

$(DISPLAY_STAMP): $(ASSET_FILES) $(GENERATOR)
	@mkdir -p $(GENERATED_DIR)
	$(PYTHON) $(GENERATOR)
	@touch $@

blacktip_dpv.vescpkg: pkgdesc.qml README.md ui.qml blacktip_dpv.lisp $(DISPLAY_STAMP)
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
