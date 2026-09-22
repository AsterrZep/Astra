#!/usr/bin/env bash
# ============================================================
# Astra seed compiler — conformance test runner
# ------------------------------------------------------------
# Each test is an .astra file annotated with expectations:
#
#   // EXPECT: <line>              one expected stdout line (repeatable)
#   // EXPECT-ERROR: <text>        the program must fail to compile and the
#                                 error message must contain <text>
#   // EXPECT-RUNTIME-ERROR: <text> the program must compile, then fail while
#                                 running. On the VM the message must contain
#                                 <text>; for --emit-c only a clean exit 1 with
#                                 a "runtime error" line is required, because
#                                 the two backends word their limits
#                                 differently on purpose (see the S8/S9 notes
#                                 in PHASE1_PROGRESS.md §6).
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

while IFS= read -r file; do
    rel="${file#"$ROOT"/}"

    # Runtime failure: the compiler succeeds, the *program* does not. Checked
    # before EXPECT-ERROR because a runtime-error test also exits non-zero.
    if grep -qE '^// *EXPECT-RUNTIME-ERROR:' "$file"; then
        expected="$(grep -E '^// *EXPECT-RUNTIME-ERROR:' "$file" \
            | sed -E 's|^// *EXPECT-RUNTIME-ERROR: *||' | head -1)"
        if actual="$("$ASTRA" "$file" 2>&1)"; then
            echo "FAIL $rel: expected a runtime error containing '$expected'"
            echo "      but the program ran to completion"
            fail=$((fail + 1))
            continue
        fi
        if [ -n "$expected" ] && ! printf '%s' "$actual" | grep -qF "$expected"; then
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
        if [ -n "$expected" ] && ! printf '%s' "$actual" | grep -qF "$expected"; then
            echo "FAIL $rel: error message did not contain '$expected'"
            printf '      got: %s\n' "$actual"
            fail=$((fail + 1))
            continue
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
        cg_compile() {
            gcc -w -I"$ROOT/src" -o "$ROOT/build/codegen_test" "$1" -lm 2>/dev/null
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
                if [ -n "$expected" ] && ! printf '%s' "$actual" | grep -qF "$expected"; then
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
                rm -f "$cfile" "$ROOT/build/codegen_test"
                fail=$((fail + 1))
                continue
            fi
            actual="$("$ROOT/build/codegen_test" 2>&1)"
            rc=$?
            rm -f "$cfile" "$ROOT/build/codegen_test"

            # The generated program is expected to die at run time, not to be
            # rejected by --emit-c or gcc. Exit 1 with a "runtime error" line is
            # required rather than "any failure": a segfault also exits non-zero,
            # and a crash is precisely what these tests exist to rule out.
            if grep -qE '^// *EXPECT-RUNTIME-ERROR:' "$file"; then
                if [ "$rc" -ne 1 ] || ! printf '%s' "$actual" | grep -qF "runtime error"; then
                    echo "FAIL $rel: expected a clean runtime error from the generated program"
                    printf '      exit=%s got: %s\n' "$rc" "$actual"
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
