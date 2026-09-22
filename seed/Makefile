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
BUILDDIR = build
TARGET  = astra-seed

# Sources are every .c under src/, including the one-file-per-construct
# modules in src/constructs/.
SRCS    = $(wildcard $(SRCDIR)/*.c) $(wildcard $(SRCDIR)/constructs/*.c)
OBJS    = $(patsubst $(SRCDIR)/%.c, $(BUILDDIR)/%.o, $(SRCS))
DEPS    = $(OBJS:.o=.d)

.PHONY: all clean debug release test format

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
