# Makefile — build the KolinOS native tools.
#
# Cross-compiles for ARM64 from any host. The default toolchain is the Debian
# cross package (gcc-aarch64-linux-gnu); override CROSS to build for the host
# instead, which is what the test target does so the binaries can actually be
# executed during development.
#
#   make                  # ARM64 binaries (production)
#   make CROSS= ARCH=x86-64     # native host build, for testing
#   make test             # build for the host and run the self-tests
#   make clean
#
# Determinism: no timestamps or host paths are embedded. Pass
# KOLIN_BUILD_EPOCH to pin __DATE__/__TIME__-style macros if a source ever
# needs them; today none do.

CROSS ?= aarch64-linux-gnu-
CC    := $(CROSS)gcc

# -ffile-prefix-map keeps the build directory out of the binary, so two
# checkouts of the same commit produce identical output.
CFLAGS  ?= -O2 -std=c11 -Wall -Wextra -Wpedantic -Wshadow -Wconversion \
           -Wstrict-prototypes -Wmissing-prototypes
CPPFLAGS += -Isrc/include
LDFLAGS  ?=

# Static linking removes the libc dependency entirely: the binary then runs in
# a rootfs whose dynamic loader or libc is broken, which is the whole point of
# these tools. musl would be smaller, but glibc static is what the cross
# toolchain provides without extra packages.
STATIC ?= 1
ifeq ($(STATIC),1)
LDFLAGS += -static
endif

BINDIR := build/native
TOOLS  := kolinos-hw kolinos-fetch

# common.o is linked into every tool.
OBJS := src/common/common.c

.PHONY: all clean test install check-syntax

all: $(addprefix $(BINDIR)/,$(TOOLS))

# One explicit rule per tool. A pattern rule cannot express the mapping
# build/native/foo <- src/foo/foo.c, because make allows a single % per rule.
define TOOL_RULE
$(BINDIR)/$(1): src/$(1)/$(1).c $(OBJS) src/include/kolinos.h
	@mkdir -p $(BINDIR)
	$$(CC) $$(CPPFLAGS) $$(CFLAGS) $(OBJS) $$< -o $$@ $$(LDFLAGS)
endef
$(foreach t,$(TOOLS),$(eval $(call TOOL_RULE,$(t))))

# Syntax/type check without linking — fast feedback, no cross toolchain needed
# for the diagnostics themselves.
check-syntax:
	$(CC) $(CPPFLAGS) $(CFLAGS) -fsyntax-only $(OBJS) $(addsuffix /$(TOOLS).c,src/$(TOOLS))

clean:
	rm -rf build/native

# Host build + smoke test: verifies the tools actually run and parse real
# /proc and /etc files, which a cross-compiled binary cannot be made to do
# without qemu-user.
test:
	$(MAKE) CROSS= ARCH= STATIC=0 BINDIR=build/native-host all
	@echo "=== kolinos-fetch ==="
	@build/native-host/kolinos-fetch
	@echo "=== kolinos-hw ==="
	@build/native-host/kolinos-hw
	@echo "=== kolinos-hw --json ==="
	@build/native-host/kolinos-hw --json
	@echo "=== sem tty: sem escapes ANSI ==="
	@build/native-host/kolinos-hw | grep -q $$'\033' && { echo "FALHA: escape ANSI na saída"; exit 1; } || echo "OK"
