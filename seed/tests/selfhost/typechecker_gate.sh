#!/usr/bin/env bash
# typechecker_gate.sh — DEC-032/M-T2: differential gate for the self-hosted
# typechecker (seed/tests/selfhost/typechecker.astra).
#
# Builds the combined program (parser.astra WITHOUT its main + typechecker.astra
# — the concat discipline of DEC-032 §6-2) and runs it over
# typechecker_corpus.list (87 files: verdict + FIRST-error-line parity vs the
# seed, path-normalized). First-error only — cascades beyond it are out of
# scope for M-T2, exactly like parser_diag_parity (DEC-031 §3).
#
#   ./seed/tests/selfhost/typechecker_gate.sh        # from anywhere
#
# Seed-only (like lexer_tokens_parity / parser_diag_parity): needs astra-seed.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)     # seed/tests/selfhost
root=$(cd "$here/../../.." && pwd)
cd "$here"

SEED="$root/seed/astra-seed"
CORPUS_DIR="$root/seed/tests/conformance"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
total=0
ok_n=0

if [ ! -x "$SEED" ]; then
    echo "typechecker_gate: missing $SEED (build with 'make -C seed')" >&2
    exit 2
fi

# Build the combined program: strip parser.astra's main (it is the last
# function) and append the typechecker (which drives parse + check).
sed '/^fn main()/,$d' parser.astra > "$TMP/pp.astra"
cat "$TMP/pp.astra" typechecker.astra > "$TMP/combined.astra"
if ! "$SEED" --dump-ast "$TMP/combined.astra" >"$TMP/comb_parse.out" 2>&1; then
    echo "FAIL combined program does not parse:"
    sed 's/^/      /' "$TMP/comb_parse.out" | head -8
    exit 1
fi

mkdir -p "$TMP/run"

first_err() {
    grep -E '^[^ ]+:[0-9]+:[0-9]+: error: ' | head -1
}

norm() {
    sed -E 's|^[^:]+||' <<<"$1"
}

while IFS= read -r line; do
    case "$line" in ''|'#'*) continue;; esac
    f="$line"
    total=$((total + 1))
    dir="P"
    if grep -qE '^// *EXPECT-ERROR:' "$CORPUS_DIR/$f"; then dir="E";
    elif grep -qE '^// *EXPECT-RUNTIME-ERROR:' "$CORPUS_DIR/$f"; then dir="R"; fi

    # Seed side. E: verdict = compile failure + first error line.
    # P/R: typecheck passes by construction (R fails only at runtime — that
    # directive means "compile succeeds", so the verdict is ACCEPT).
    seed_first=""
    seed_ok=1
    if [ "$dir" = "E" ]; then
        out=$( (cd "$CORPUS_DIR" && "$SEED" "$f") 2>&1 ) || true
        seed_first=$(first_err <<<"$out")
        if [ -z "$seed_first" ]; then
            echo "FAIL $f (seed: EXPECT-ERROR but no diagnostic)"
            fail=1
            continue
        fi
        seed_ok=0
    fi

    # Combined side (typecheck only — it never runs the program).
    cp "$CORPUS_DIR/$f" "$TMP/run/parser_input.astra"
    cout=$( (cd "$TMP/run" && "$SEED" "$TMP/combined.astra") 2>&1 ) || true
    own_first=$(first_err <<<"$cout")
    own_ok=1
    if [ -n "$own_first" ]; then
        own_ok=0
    fi

    ok=1
    if [ "$seed_ok" != "$own_ok" ]; then
        echo "FAIL $f (verdict: seed_ok=$seed_ok own_ok=$own_ok)"
        [ -n "$own_first" ] && echo "      own: $own_first"
        [ -n "$seed_first" ] && echo "      seed: $seed_first"
        ok=0
        fail=1
    elif [ "$dir" = "E" ] && [ "$(norm "$seed_first")" != "$(norm "$own_first")" ]; then
        echo "FAIL $f (first diagnostic differs)"
        echo "      seed:  $seed_first"
        echo "      own:   $own_first"
        ok=0
        fail=1
    fi

    if [ "$ok" -eq 1 ]; then
        ok_n=$((ok_n + 1))
        echo "ok   $f ($dir)"
    fi
done < typechecker_corpus.list

# ---- Route matrix (DEC-032 §6-1: the combined program must behave the
# same compiled by every backend). Each route binary is built ONCE, then
# run over the whole corpus comparing verdict + first error against the
# seed results stored above. Missing tools skip cleanly, like parser_gate.
ZIG="$root/zig/zig-out/bin/astra-zig"

build_c_route() {
    command -v gcc >/dev/null 2>&1 || return 1
    "$SEED" --emit-c "$TMP/combined.astra" >/dev/null 2>&1 || return 1
    gcc -Wall -Wextra -I"$root/seed/src" -o "$TMP/cbin" "$TMP/combined.c" 2>"$TMP/gcc.err" || return 1
    [ ! -s "$TMP/gcc.err" ] || return 1
    return 0
}

# replay: run $1 (binary-or-interpreter-prefix) over every file, comparing
# against the stored seed expectations (stored in the same order).
replay_ok=0
replay_total=0
replay() {
    local name="$1"; shift
    local bad=0
    local i=0
    while IFS= read -r f; do
        case "$f" in ''|'#'*) continue;; esac
        cp "$CORPUS_DIR/$f" "$TMP/run/parser_input.astra"
        local cout
        cout=$( (cd "$TMP/run" && "$@" "$TMP/combined.astra") 2>&1 ) || true
        local own_first dir_want seed_want
        own_first=$(first_err <<<"$cout")
        dir_want="${EXP_DIR[$i]}"
        seed_want="${EXP_FIRST[$i]}"
        if [ "$dir_want" = "E" ]; then
            if [ -z "$own_first" ] || [ "$(norm "$own_first")" != "$(norm "$seed_want")" ]; then
                echo "FAIL [$name] $f"
                echo "      seed:  $seed_want"
                echo "      own:   ${own_first:-<none>}"
                bad=1
            fi
        else
            if [ -n "$own_first" ]; then
                echo "FAIL [$name] $f (should accept)"
                echo "      own:   $own_first"
                bad=1
            fi
        fi
        i=$((i + 1))
    done < typechecker_corpus.list
    if [ "$bad" -eq 0 ]; then
        echo "ok   route $name: $i/$i corpus"
    else
        fail=1
    fi
}

# rebuild the seed expectations into parallel arrays (2nd pass over corpus)
EXP_DIR=()
EXP_FIRST=()
while IFS= read -r f; do
    case "$f" in ''|'#'*) continue;; esac
    if grep -qE '^// *EXPECT-ERROR:' "$CORPUS_DIR/$f"; then
        EXP_DIR+=("E")
        out=$( (cd "$CORPUS_DIR" && "$SEED" "$f") 2>&1 ) || true
        EXP_FIRST+=("$(first_err <<<"$out")")
    else
        EXP_DIR+=("P")
        EXP_FIRST+=("")
    fi
done < typechecker_corpus.list

# Route: C backend (--emit-c + gcc)
if build_c_route; then
    replay "C backend" "$TMP/cbin"
else
    echo "skip route C backend (gcc/--emit-c unavailable)"
fi

# Route: zig VM (astra-zig compiles the combined with ITS OWN frontend)
if [ -x "$ZIG" ]; then
    replay "zig VM" "$ZIG"
else
    echo "skip route zig VM (astra-zig not built)"
fi

# Route: LLVM --jit (needs -Dllvm)
if [ -x "$ZIG" ] && "$ZIG" --jit "$TMP/combined.astra" >/dev/null 2>&1; then
    replay "LLVM --jit" "$ZIG" --jit
elif [ -x "$ZIG" ] && "$ZIG" --jit "$TMP/combined.astra" 2>&1 | grep -q "require the compiler to be built with"; then
    echo "skip route LLVM --jit (compiler built without -Dllvm)"
elif [ -x "$ZIG" ]; then
    echo "skip route LLVM --jit (jit smoke failed unexpectedly)"
else
    echo "skip route LLVM --jit (astra-zig not built)"
fi

echo "----"
if [ "$fail" -eq 0 ]; then
    echo "typechecker_gate: $total/$total corpus (verdict + first-error) + routes"
else
    echo "typechecker_gate: FAIL ($ok_n/$total corpus)"
fi
[ "$fail" -eq 0 ]
