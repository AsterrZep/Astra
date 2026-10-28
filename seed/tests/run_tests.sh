#!/usr/bin/env bash
# ============================================================
# Astra seed compiler — conformance test runner
# ------------------------------------------------------------
# Each test is an .astra file annotated with expectations:
#
#   // EXPECT: <line>              one expected stdout line (repeatable)
#   // EXPECT-ERROR: <text>        the program must fail to compile and the
#                                 error message must contain <text>
#   // EXPECT-ERROR-FIRST: <text>  audit §7.8, optional: in addition to the
#                                 EXPECT-ERROR above, <text> must appear in
#                                 the FIRST diagnostic line only. Use it with
#                                 the `file:line:col: error: …` prefix to pin
#                                 the position the user sees first, not just
#                                 the wording somewhere in the output.
#   // EXPECT-RUNTIME-ERROR: <text> the program must compile, then fail while
#                                 running. On the VM the message must contain
#                                 <text>; for --emit-c a clean exit 1 with a
#                                 "runtime error" line is required, and when
#                                 <text> is non-empty it must match there too.
#                                 Both backends word their runtime limits
#                                 alike since audit §1.1 (PRE_LLVM_AUDIT.md);
#                                 the exit-1 check stays because a crash also
#                                 exits non-zero.
#
# Only ONE EXPECT-ERROR: (and one EXPECT-RUNTIME-ERROR:) is honoured per file
# — each is read with `head -1`, so a second directive used to be silently
# ignored. That latent trap now fails the file: split it into one case per
# directive (audit §7.8).
#
# Usage: ./tests/run_tests.sh   (or: make test)
# ============================================================

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ASTRA="$ROOT/astra-seed"
DIR="$ROOT/tests/conformance"

if [ ! -x "$ASTRA" ]; then
    echo "error: $ASTRA not found. Run 'make' first." >&2
    exit 1
fi

pass=0
fail=0

# Fixed-string search over captured output. NEVER `printf | grep -q` here:
# with `pipefail`, grep -q exits at the first match, the writer then dies of
# EPIPE, and the pipeline reports failure even though the string WAS found —
# a false FAIL that fired in CI on block_nesting_too_deep. A here-string
# gives grep a file, so there is no writer to race against.
contains() {
    grep -qF "$1" <<<"$2"
}

# ------------------------------------------------------------
# Construct registry invariants
# ------------------------------------------------------------
# The registry is the single source of truth for what a construct is.
# This gate fails the whole suite if the registry, the lexer's keyword
# table, the parser's operator precedence table and the per-construct
# phase bits have drifted apart.
if registry_out="$("$ASTRA" --check-constructs 2>&1)"; then
    summary="$(printf '%s\n' "$registry_out" | grep -E 'constructs:|migrated' | tr '\n' ' ')"
    echo "ok   construct registry ($summary)"
    pass=$((pass + 1))
else
    echo "FAIL construct registry:"
    printf '%s\n' "$registry_out" | sed 's/^/      /'
    fail=$((fail + 1))
fi

# ------------------------------------------------------------
# --dump-ast exit codes (audit §2.7)
# ------------------------------------------------------------
# Error recovery returns a partial module even when the parse failed, so
# the flag used to exit 0 on broken files while zig exits 1. Pin both
# directions: a valid file still dumps and exits 0, a broken one fails.
if "$ASTRA" --dump-ast "$DIR/expressions/not_op.astra" >/dev/null 2>&1; then
    echo "ok   --dump-ast exit 0 on a valid file"
    pass=$((pass + 1))
else
    echo "FAIL --dump-ast exited non-zero on a valid file"
    fail=$((fail + 1))
fi
bad_ast="$(mktemp)"
printf 'fn main() {\n    let x = ;\n}\n' > "$bad_ast"
if "$ASTRA" --dump-ast "$bad_ast" >/dev/null 2>&1; then
    echo "FAIL --dump-ast exited 0 on a parse error (audit §2.7)"
    fail=$((fail + 1))
else
    echo "ok   --dump-ast exit 1 on a parse error"
    pass=$((pass + 1))
fi
rm -f "$bad_ast"

while IFS= read -r file; do
    rel="${file#"$ROOT"/}"

    # Directive-count guard (audit §7.8): each EXPECT-ERROR: /
    # EXPECT-RUNTIME-ERROR: is read with `head -1`, so a second one in the
    # same file used to be silently ignored — a latent trap that hides half
    # of what the file claims to check. One file, one directive of each kind.
    n_err="$(grep -cE '^// *EXPECT-ERROR:' "$file")"
    n_rt="$(grep -cE '^// *EXPECT-RUNTIME-ERROR:' "$file")"
    if [ "$n_err" -gt 1 ] || [ "$n_rt" -gt 1 ]; then
        echo "FAIL $rel: $n_err EXPECT-ERROR: / $n_rt EXPECT-RUNTIME-ERROR: directive(s);"
        echo "      only the first of each is read (head -1), the rest would be silently ignored."
        echo "      Split it into one file per directive (audit §7.8)."
        fail=$((fail + 1))
        continue
    fi
    # EXPECT-ERROR-FIRST: is only ever checked inside the EXPECT-ERROR branch
    # below, so carrying it without one would quietly check nothing.
    if [ "$n_err" -eq 0 ] && grep -qE '^// *EXPECT-ERROR-FIRST:' "$file"; then
        echo "FAIL $rel: EXPECT-ERROR-FIRST: without an EXPECT-ERROR: directive — nothing would check it"
        fail=$((fail + 1))
        continue
    fi

    # Runtime failure: the compiler succeeds, the *program* does not. Checked
    # before EXPECT-ERROR because a runtime-error test also exits non-zero.
    if grep -qE '^// *EXPECT-RUNTIME-ERROR:' "$file"; then
        expected="$(grep -E '^// *EXPECT-RUNTIME-ERROR:' "$file" \
            | sed -E 's|^// *EXPECT-RUNTIME-ERROR: *||' | head -1)"
        # stdin is pinned to empty (/dev/null): a case that reads stdin
        # (read_line at EOF, DEC-020) must fail deterministically instead of
        # blocking on the caller's terminal. CI already runs without a TTY.
        if actual="$("$ASTRA" "$file" </dev/null 2>&1)"; then
            echo "FAIL $rel: expected a runtime error containing '$expected'"
            echo "      but the program ran to completion"
            fail=$((fail + 1))
            continue
        fi
        if [ -n "$expected" ] && ! contains "$expected" "$actual"; then
            echo "FAIL $rel: runtime error did not contain '$expected'"
            printf '      got: %s\n' "$actual"
            fail=$((fail + 1))
            continue
        fi
        echo "ok   $rel (runtime error as expected)"
        pass=$((pass + 1))
        continue
    fi

    if grep -qE '^// *EXPECT-ERROR:' "$file"; then
        expected="$(grep -E '^// *EXPECT-ERROR:' "$file" \
            | sed -E 's|^// *EXPECT-ERROR: *||' | head -1)"
        if actual="$("$ASTRA" "$file" 2>&1)"; then
            echo "FAIL $rel: expected an error containing '$expected'"
            echo "      but the program compiled and ran successfully"
            fail=$((fail + 1))
            continue
        fi
        if [ -n "$expected" ] && ! contains "$expected" "$actual"; then
            echo "FAIL $rel: error message did not contain '$expected'"
            printf '      got: %s\n' "$actual"
            fail=$((fail + 1))
            continue
        fi
        # Optional position pin (audit §7.8): EXPECT-ERROR-FIRST must appear
        # in the FIRST diagnostic line only, so `file:line:col:` and the
        # leading wording are asserted where the user actually reads them
        # (anywhere else in the output would not do). EXPECT-ERROR above keeps
        # its old semantics: substring of the whole output.
        first_directive="$(grep -E '^// *EXPECT-ERROR-FIRST:' "$file" \
            | sed -E 's|^// *EXPECT-ERROR-FIRST: *||' | head -1)"
        if [ -n "$first_directive" ]; then
            first_line="${actual%%$'\n'*}"
            if ! contains "$first_directive" "$first_line"; then
                echo "FAIL $rel: first diagnostic line does not contain '$first_directive'"
                printf '      got: %s\n' "$first_line"
                fail=$((fail + 1))
                continue
            fi
        fi
        echo "ok   $rel (error as expected)"
        pass=$((pass + 1))
        continue
    fi

    expected="$(grep -E '^// *EXPECT:' "$file" | sed -E 's|^// *EXPECT: *||')"
    if ! actual="$("$ASTRA" "$file" 2>&1)"; then
        echo "FAIL $rel: program exited with an error"
        printf '      %s\n' "$actual"
        fail=$((fail + 1))
        continue
    fi
    if [ "$actual" != "$expected" ]; then
        echo "FAIL $rel: output mismatch"
        diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/      /'
        fail=$((fail + 1))
        continue
    fi
    echo "ok   $rel"
    pass=$((pass + 1))
done < <(find "$DIR" -name '*.astra' | sort)

# ------------------------------------------------------------
# C codegen round-trip (--emit-c -> gcc -> run)
# ------------------------------------------------------------
# The conformance loop above only exercises the VM. Anything that breaks
# only on the bytecode->C path (string escaping, registry limits) stays
# invisible without this step, so those cases live in tests/codegen/.
CGDIR="$ROOT/tests/codegen"
if [ -d "$CGDIR" ]; then
    if command -v gcc >/dev/null 2>&1; then
        # Compile a generated .c into the throwaway test binary.
        # -I"$ROOT/src" is required: the generated file includes codegen_runtime.h,
        # which lives in seed/src and not next to the emitted file.
        # -Wall -Wextra, never -w (audit §7.10; same policy as sweep_emit_c.sh
        # §5.8): a warning in generated C is a codegen defect — discarded
        # qualifiers, unused things, incompatible pointers — and must fail this
        # gate like any other divergence source. gcc exits 0 on warnings and
        # still links the binary, so stderr is captured here and the caller
        # checks it explicitly.
        CG_GCC_ERR="$ROOT/build/codegen_gcc.err"
        cg_compile() {
            gcc -Wall -Wextra -I"$ROOT/src" -o "$ROOT/build/codegen_test" "$1" -lm 2>"$CG_GCC_ERR"
        }

        for file in "$CGDIR"/*.astra; do
            [ -f "$file" ] || continue
            rel="${file#"$ROOT"/}"
            cfile="${file%.astra}.c"

            if grep -qE '^// *EXPECT-ERROR:' "$file"; then
                expected="$(grep -E '^// *EXPECT-ERROR:' "$file" \
                    | sed -E 's|^// *EXPECT-ERROR: *||' | head -1)"
                if actual="$("$ASTRA" --emit-c "$file" 2>&1)"; then
                    echo "FAIL $rel: expected --emit-c to fail"
                    rm -f "$cfile"
                    fail=$((fail + 1))
                    continue
                fi
                if [ -n "$expected" ] && ! contains "$expected" "$actual"; then
                    echo "FAIL $rel: --emit-c error did not contain '$expected'"
                    printf '      got: %s\n' "$actual"
                    rm -f "$cfile"
                    fail=$((fail + 1))
                    continue
                fi
                rm -f "$cfile"
                echo "ok   $rel (--emit-c rejected as expected)"
                pass=$((pass + 1))
                continue
            fi

            if ! "$ASTRA" --emit-c "$file" >/dev/null 2>&1; then
                echo "FAIL $rel: --emit-c failed"
                rm -f "$cfile"
                fail=$((fail + 1))
                continue
            fi
            if ! cg_compile "$cfile"; then
                echo "FAIL $rel: generated C did not compile"
                sed 's/^/      /' "$CG_GCC_ERR" 2>/dev/null
                rm -f "$cfile" "$ROOT/build/codegen_test" "$CG_GCC_ERR"
                fail=$((fail + 1))
                continue
            fi
            # gcc exits 0 on warnings, so a non-empty stderr is a FAIL of its
            # own (the -Wall -Wextra above would otherwise stay silent).
            if [ -s "$CG_GCC_ERR" ]; then
                echo "FAIL $rel: gcc warned about the generated C"
                sed 's/^/      /' "$CG_GCC_ERR"
                rm -f "$cfile" "$ROOT/build/codegen_test" "$CG_GCC_ERR"
                fail=$((fail + 1))
                continue
            fi
            actual="$("$ROOT/build/codegen_test" </dev/null 2>&1)"
            rc=$?
            rm -f "$cfile" "$ROOT/build/codegen_test" "$CG_GCC_ERR"

            # The generated program is expected to die at run time, not to be
            # rejected by --emit-c or gcc. Exit 1 with a "runtime error" line is
            # required rather than "any failure": a segfault also exits non-zero,
            # and a crash is precisely what these tests exist to rule out.
            if grep -qE '^// *EXPECT-RUNTIME-ERROR:' "$file"; then
                if [ "$rc" -ne 1 ] || ! contains "runtime error" "$actual"; then
                    echo "FAIL $rel: expected a clean runtime error from the generated program"
                    printf '      exit=%s got: %s\n' "$rc" "$actual"
                    fail=$((fail + 1))
                    continue
                fi
                # Mirror the VM loop: when the header carries expected text
                # (file:line: message), the C backend's error must match it.
                expected="$(grep -E '^// *EXPECT-RUNTIME-ERROR:' "$file" \
                    | sed -E 's|^// *EXPECT-RUNTIME-ERROR: *||' | head -1)"
                if [ -n "$expected" ] && ! contains "$expected" "$actual"; then
                    echo "FAIL $rel: runtime error did not contain '$expected'"
                    printf '      got: %s\n' "$actual"
                    fail=$((fail + 1))
                    continue
                fi
                echo "ok   $rel (--emit-c runtime error as expected)"
                pass=$((pass + 1))
                continue
            fi

            expected="$(grep -E '^// *EXPECT:' "$file" | sed -E 's|^// *EXPECT: *||')"
            if [ "$actual" != "$expected" ]; then
                echo "FAIL $rel: --emit-c output mismatch"
                diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/      /'
                fail=$((fail + 1))
                continue
            fi
            echo "ok   $rel (--emit-c round-trip)"
            pass=$((pass + 1))
        done
    else
        echo "skip tests/codegen (gcc not found)"
    fi
fi

echo
echo "----"
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
