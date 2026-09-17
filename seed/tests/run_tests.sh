#!/usr/bin/env bash
# ============================================================
# Astra seed compiler — conformance test runner
# ------------------------------------------------------------
# Each test is an .astra file annotated with expectations:
#
#   // EXPECT: <line>         one expected stdout line (repeatable)
#   // EXPECT-ERROR: <text>   the program must fail and the error
#                            message must contain <text>
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

while IFS= read -r file; do
    rel="${file#"$ROOT"/}"

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

echo
echo "----"
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
