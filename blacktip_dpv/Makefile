VESC_TOOL ?= vesc_tool

all: blacktip_dpv.vescpkg

blacktip_dpv.vescpkg: pkgdesc.qml README.md ui.qml blacktip_dpv.lisp
	$(VESC_TOOL) --buildPkgFromDesc pkgdesc.qml --testPkgDesc 'vesc:test'

test:
	@echo "No tests defined"

clean:
	rm -f blacktip_dpv.vescpkg

.PHONY: all test clean
