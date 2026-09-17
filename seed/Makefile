# Astra Seed Compiler — Makefile
# ============================================================
# Build system for the C seed compiler (astra-seed)
# Uses Clang for development, GCC for production
# ============================================================

CC      ?= clang
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

# Default: debug build
all: $(TARGET)

# Debug build
debug: CFLAGS += -fsanitize=address,undefined -fno-omit-frame-pointer
debug: $(TARGET)

# Release build
release: CC = gcc
release: CFLAGS = $(CFLAGS_RELEASE)
release: $(TARGET)

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

# Clean
clean:
	rm -rf $(BUILDDIR) $(TARGET)

# Format
format:
	clang-format -i $(SRCDIR)/*.c $(SRCDIR)/*.h $(SRCDIR)/constructs/*.c $(SRCDIR)/constructs/*.h $(INCDIR)/astra/*.h

# Test
test: $(TARGET)
	@echo "Running tests..."
	@./tests/run_tests.sh

# Include dependency files
-include $(DEPS)
