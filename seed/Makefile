# Astra Seed Compiler — Makefile
# ============================================================
# Build system for the C seed compiler (astra-seed)
# Uses Clang for development, GCC for production
# ============================================================

# `CC ?= clang` never took effect: GNU make predefines CC=cc, and ?= only
# assigns to an undefined variable, so the documented "Clang for development"
# silently compiled with cc (gcc). Prefer clang when it is actually installed.
CC      := $(or $(shell command -v clang 2>/dev/null),cc)
CFLAGS  ?= -Wall -Wextra -Wpedantic -std=c11 -g -O0
CFLAGS_RELEASE ?= -Wall -Wextra -Wpedantic -std=c11 -O2 -DNDEBUG

SRCDIR  = src
INCDIR  = include
FUZZDIR = fuzz
BUILDDIR = build
TARGET  = astra-seed

# Sources are every .c under src/, including the one-file-per-construct
# modules in src/constructs/.
SRCS    = $(wildcard $(SRCDIR)/*.c) $(wildcard $(SRCDIR)/constructs/*.c)
OBJS    = $(patsubst $(SRCDIR)/%.c, $(BUILDDIR)/%.o, $(SRCS))
DEPS    = $(OBJS:.o=.d)

# Fuzz variant: every source except src/main.c — libFuzzer provides main().
FUZZ_SRCS = $(filter-out $(SRCDIR)/main.c,$(SRCS))

.PHONY: all clean debug release test format fuzz fuzz-run

# Default: development build (-g -O0, no sanitizers). `make debug` is the one to
# use while developing; `make release` is the optimized GCC build.
all: $(TARGET)

# Debug build
#
# Each variant compiles into its own object directory through an explicit
# recursive call. Sharing build/ between variants used to be broken in two ways,
# because a compiler flag is not part of an object file's timestamp:
#   - `make && make debug` answered "Nothing to be done for 'debug'" and left the
#     unsanitized binary in place, so the "green under ASan/UBSan" claim could not
#     be reproduced from the documented commands;
#   - relinking after a mixed build failed outright with
#     "ld: warning: creating DT_TEXTREL in a PIE".
# Passing BUILDDIR/CFLAGS on the command line makes the flags part of the objects'
# identity, so switching variants always recompiles from scratch; dropping the
# binary first makes the relink unconditional, so `make debug` cannot leave a
# release binary behind just because the file is newer than the objects.
debug:
	@rm -f $(TARGET)
	@$(MAKE) --no-print-directory BUILDDIR=build/debug \
	    CFLAGS="$(CFLAGS) -fsanitize=address,undefined -fno-omit-frame-pointer" \
	    $(TARGET)

# Release build
release:
	@rm -f $(TARGET)
	@$(MAKE) --no-print-directory BUILDDIR=build/release \
	    CC=gcc CFLAGS="$(CFLAGS_RELEASE)" $(TARGET)

# Fuzz build — clang + libFuzzer (PHASE1 §4bis#23)
#
# -fsanitize=fuzzer links libFuzzer's main(), which is why src/main.c is
# dropped from SRCS and the harness (fuzz/fuzz_compile.c) provides
# LLVMFuzzerTestOneInput instead. Like debug/release, the variant owns its
# object tree: fuzzer instrumentation is not part of an object's timestamp.
# -O1 overrides the default -O0 (last flag wins) because in-process fuzzing
# at -O0 loses most of its exec/s for no debugging benefit — traces still
# carry -g and frame pointers.
#
# libFuzzer ships with clang, and CI images often expose it only under a
# versioned name, so accept clang, clang-18, clang-17 or clang-16.
FUZZ_CC := $(or $(shell command -v clang 2>/dev/null), \
                 $(shell command -v clang-18 2>/dev/null), \
                 $(shell command -v clang-17 2>/dev/null), \
                 $(shell command -v clang-16 2>/dev/null))
fuzz:
	@[ -n "$(FUZZ_CC)" ] || { \
	    echo "make fuzz: clang not found — libFuzzer requires it"; exit 1; }
	@$(MAKE) --no-print-directory BUILDDIR=$(BUILDDIR)/fuzz CC="$(FUZZ_CC)" \
	    CFLAGS="$(CFLAGS) -O1 -fsanitize=fuzzer,address,undefined -fno-omit-frame-pointer" \
	    SRCS="$(FUZZ_SRCS)" fuzz-link

fuzz-link: $(OBJS) $(BUILDDIR)/fuzz_compile.o
	$(CC) $(CFLAGS) -o $(BUILDDIR)/astra-fuzz $^ -lm
	@echo "Built: $(BUILDDIR)/astra-fuzz"

$(BUILDDIR)/fuzz_compile.o: $(FUZZDIR)/fuzz_compile.c | $(BUILDDIR)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -I$(INCDIR) -I$(SRCDIR) -MMD -MP -c $< -o $@

# Fuzz campaign helper: seed the corpus with every test program (mutations of
# valid programs reach far deeper than raw bytes), then run with the token
# dictionary. Single worker by default — the ASan build costs ~250 MB RSS and
# parallel workers have no headroom on a small box. Time-boxed; make fuzz-run
# FUZZ_TIME=3600 for a long session. Crash artifacts land in
# $(BUILDDIR)/fuzz/artifacts/. Campaigns should redirect stderr to a file:
# every rejected input prints diagnostics, and a runaway write stalls can show
# up as libFuzzer "timeout" artifacts that are not real slow inputs.
FUZZ_TIME ?= 60
fuzz-run: fuzz
	@mkdir -p $(BUILDDIR)/fuzz/corpus $(BUILDDIR)/fuzz/work $(BUILDDIR)/fuzz/artifacts
	@find tests -name '*.astra' -exec cp -f {} $(BUILDDIR)/fuzz/corpus/ \;
	./$(BUILDDIR)/fuzz/astra-fuzz $(BUILDDIR)/fuzz/work $(BUILDDIR)/fuzz/corpus \
	    -artifact_prefix=$(BUILDDIR)/fuzz/artifacts/ \
	    -dict=$(FUZZDIR)/astra.dict -max_len=16384 -timeout=5 \
	    -rss_limit_mb=512 -malloc_limit_mb=64 \
	    -max_total_time=$(FUZZ_TIME) 2>$(BUILDDIR)/fuzz/campaign.log

# Link
$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^ -lm
	@echo "Built: $(TARGET)"

# Compile
# -I$(SRCDIR) lets construct modules include "constructs/construct.h"
# and "priv.h" without relative-path gymnastics.
$(BUILDDIR)/%.o: $(SRCDIR)/%.c | $(BUILDDIR)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -I$(INCDIR) -I$(SRCDIR) -MMD -MP -c $< -o $@

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

# Clean: remove every variant's objects, not just the active one.
clean:
	rm -rf build $(TARGET)

# Format
format:
	clang-format -i $(SRCDIR)/*.c $(SRCDIR)/*.h $(SRCDIR)/constructs/*.c $(SRCDIR)/constructs/*.h $(INCDIR)/astra/*.h

# Test
test: $(TARGET)
	@echo "Running tests..."
	@./tests/run_tests.sh

# Include dependency files
-include $(DEPS)
-include $(BUILDDIR)/fuzz_compile.d
