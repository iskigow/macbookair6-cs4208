# SPDX-License-Identifier: GPL-2.0-only
#
# Out-of-tree build of snd-hda-codec-cs420x from ../src.
#
# A staging tree build/<KVER>/ is assembled with the src/ layout and the
# header set selected for KVER copied over src/sound/hda/common/*.h. Every
# quoted include therefore resolves to the selected headers, whatever
# directory it is included from. Unknown kernels are refused.
#
#   make [KVER=<kernel release>]
#   Developers only: HEADER_SET=<set> forces a header set, SRCROOT=<dir>
#   builds another copy of src/ (used by tests/test-stock-equivalence.sh).

KVER ?= $(shell uname -r)
KDIR ?= /lib/modules/$(KVER)/build
TOP := $(abspath $(CURDIR)/..)
SRCROOT ?= $(TOP)/src
SRC := $(SRCROOT)/sound/hda
ifeq ($(origin HEADER_SET),undefined)
HEADER_SET := $(shell sh $(CURDIR)/select-headers.sh $(KVER))
endif
OUT := $(CURDIR)/build/$(KVER)

all:
	@test -n "$(HEADER_SET)" || { echo "Refusing to build for $(KVER)." >&2; exit 1; }
	@test -d headers/$(HEADER_SET) || { echo "Unknown header set $(HEADER_SET)." >&2; exit 1; }
	rm -rf $(OUT) && mkdir -p $(OUT)/common $(OUT)/codecs/cirrus
	cp $(SRC)/codecs/cirrus/cs420x.c $(OUT)/codecs/cirrus/
	cp $(SRC)/codecs/generic.h $(OUT)/codecs/
	cp $(SRC)/common/*.h $(OUT)/common/
	for h in headers/$(HEADER_SET)/*.h; do \
		case "$$h" in \
		*/generic.h) cp "$$h" $(OUT)/codecs/ ;; \
		*) if [ -e "$$h" ]; then cp "$$h" $(OUT)/common/; fi ;; \
		esac; \
	done
	printf '%s\n' 'ccflags-y += -I$$(src)/../../common' \
		'obj-m += snd-hda-codec-cs420x.o' \
		'snd-hda-codec-cs420x-y := cs420x.o' > $(OUT)/codecs/cirrus/Kbuild
	$(MAKE) -C $(KDIR) M=$(OUT)/codecs/cirrus modules
	cp $(OUT)/codecs/cirrus/snd-hda-codec-cs420x.ko $(OUT)/

clean:
	rm -rf $(CURDIR)/build

.PHONY: all clean
