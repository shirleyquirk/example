# uio-memcpy-bench. One Makefile, no generators of generators.
#
#   make deps        install the off-board toolchain (needs root; Debian/Ubuntu)
#   make gen         generate and validate the variants
#   make check       gen + negative tests (the gates must be shown to fail)
#   make qemu-test   execute every generated body under qemu
#   make host-test   native tests under ASan+UBSan          [phase A]
#   make all         cross-compile mcbench with the Yocto SDK [phase E]
#
# Phases A-D need nothing but `make deps`. See SETUP.md.

BUILD     := build
GEN       := $(BUILD)/gen
PY        := python3
CROSS     := aarch64-linux-gnu-
QEMU      := qemu-aarch64-static
HOSTCC    ?= cc
TIER      ?= caller

GEN_SRCS  := $(wildcard gen/*.py)
GEN_OUT   := $(GEN)/variants.S $(GEN)/variants_table.c $(GEN)/bodies_table.c

WARN      := -O2 -Wall -Wextra -Werror
SAN       := -fsanitize=address,undefined -fno-sanitize-recover=all

.PHONY: all gen check qemu-test host-test deps clean explain
.DEFAULT_GOAL := check

# ---------------------------------------------------------------- toolchain --
# Everything phases A-D need, from distro packages. Listed here rather than in
# a wiki page because this repo gets developed in throwaway containers.
DEB_PKGS := python3 build-essential \
            binutils-aarch64-linux-gnu gcc-aarch64-linux-gnu \
            libc6-dev-arm64-cross qemu-user-static

deps:
	@echo "installing: $(DEB_PKGS)"
	apt-get update -qq
	apt-get install -y --no-install-recommends $(DEB_PKGS)
	@$(MAKE) --no-print-directory check-tools

check-tools:
	@ok=1; for t in $(PY) $(CROSS)as $(CROSS)objdump $(CROSS)gcc $(QEMU); do \
	   command -v $$t >/dev/null || { echo "MISSING: $$t"; ok=0; }; done; \
	 [ $$ok = 1 ] && echo "toolchain complete" || \
	   { echo "run 'make deps' (needs root)"; exit 1; }

# ------------------------------------------------------------------ generate --
gen: $(GEN_OUT)

$(GEN_OUT): $(GEN_SRCS)
	@mkdir -p $(GEN)
	cd gen && $(PY) gen_variants.py --out ../$(GEN) --tier $(TIER)

# Print a human-readable trace of variants matching NAME=...
explain:
	@cd gen && $(PY) gen_variants.py --explain "$(NAME)"

# --------------------------------------------------------------------- gates --
# The negative tests run first: a validator nobody has watched fail proves
# nothing about the variants it passes.
check: check-tools
	$(PY) tests/test_validate.py
	@$(MAKE) --no-print-directory gen

qemu-test: gen
	$(CROSS)gcc $(WARN) -static -o $(BUILD)/test_bodies \
	    tests/test_bodies.c tests/poison.S \
	    $(GEN)/variants.S $(GEN)/bodies_table.c
	$(QEMU) $(BUILD)/test_bodies

# --------------------------------------------------------- phase A and later --
host-test:
	@test -f tests/test_headtail.c || { echo "phase A not built yet"; exit 1; }
	$(HOSTCC) $(WARN) $(SAN) -DHOST_MOCK_DEVIO -Isrc \
	    -o $(BUILD)/test_headtail tests/test_headtail.c src/headtail.c
	$(BUILD)/test_headtail

all: gen
	@test -f src/main.c || { echo "phase A not built yet"; exit 1; }
	@echo "source the Yocto SDK environment first; this uses \$$(CC)"
	$(CC) $(WARN) -Isrc -o $(BUILD)/mcbench src/*.c $(GEN)/variants.S \
	    $(GEN)/variants_table.c -DGIT_SHA=\"$$(git rev-parse --short HEAD)\"

clean:
	rm -rf $(BUILD)
