VESC_TOOL ?= vesc_tool
PYTHON ?= python3

GENERATED_DIR := generated
BINARY_STAMP := $(GENERATED_DIR)/binary_luts.stamp
LUT_BINARY := $(GENERATED_DIR)/display_lut.bin
BRIGHTNESS_BINARY := $(GENERATED_DIR)/brightness_lut.bin

ASSET_FILES := assets/display_lut.csv assets/brightness_levels.csv
BINARY_GENERATOR := tools/generate_lut_binary.py

all: blacktip_dpv.vescpkg

$(BINARY_STAMP): $(ASSET_FILES) $(BINARY_GENERATOR)
	@mkdir -p $(GENERATED_DIR)
	$(PYTHON) $(BINARY_GENERATOR)
	@touch $@

$(LUT_BINARY): $(BINARY_STAMP)
$(BRIGHTNESS_BINARY): $(BINARY_STAMP)

blacktip_dpv.vescpkg: pkgdesc.qml README.md ui.qml blacktip_dpv.lisp $(LUT_BINARY) $(BRIGHTNESS_BINARY)
	$(VESC_TOOL) --buildPkgFromDesc pkgdesc.qml --testPkgDesc 'vesc:test'

check-whitespace:
	@echo "Checking for trailing whitespace..."
	@if grep -nE '[[:space:]]+$$' blacktip_dpv.lisp; then \
		echo "Error: Trailing whitespace found (shown above)"; \
		exit 1; \
	else \
		echo "✓ No trailing whitespace found"; \
	fi

smoke-tests:
	@echo "Running smoke tests..."
	@$(PYTHON) tests/run_tests.py

binary: $(LUT_BINARY) $(BRIGHTNESS_BINARY)

test: check-whitespace smoke-tests
	@echo "All checks passed"

clean:
	rm -f blacktip_dpv.vescpkg
	rm -rf $(GENERATED_DIR)

.PHONY: all test clean check-whitespace smoke-tests binary
