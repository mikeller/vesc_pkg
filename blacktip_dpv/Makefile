VESC_TOOL ?= vesc_tool
PYTHON ?= python3

GENERATED_DIR := generated
DISPLAY_STAMP := $(GENERATED_DIR)/display_tables.stamp
LUT_RESOURCE := $(GENERATED_DIR)/display_lut_data.lisp

ASSET_FILES := assets/display_lut.csv assets/brightness_levels.csv
GENERATOR := tools/update_display_tables.py
RESOURCE_GENERATOR := tools/generate_lut_resource.py

all: blacktip_dpv.vescpkg

$(DISPLAY_STAMP): $(ASSET_FILES) $(GENERATOR)
	@mkdir -p $(GENERATED_DIR)
	$(PYTHON) $(GENERATOR)
	@touch $@

$(LUT_RESOURCE): $(ASSET_FILES) $(RESOURCE_GENERATOR)
	@mkdir -p $(GENERATED_DIR)
	$(PYTHON) $(RESOURCE_GENERATOR)

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

check-display-tables: $(ASSET_FILES) $(GENERATOR)
	@echo "Verifying display tables are up to date..."
	@$(PYTHON) $(GENERATOR) --check

resource: $(LUT_RESOURCE)

test: check-whitespace check-display-tables
	@echo "All checks passed"

clean:
	rm -f blacktip_dpv.vescpkg
	rm -rf $(GENERATED_DIR)

.PHONY: all test clean check-whitespace check-display-tables resource
