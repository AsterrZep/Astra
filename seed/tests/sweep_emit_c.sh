#!/usr/bin/env bash
# Emit-C differential sweep (PRE_LLVM_AUDIT §1): every non-UI conformance
# case through the VM and through --emit-c + gcc; stdout, stderr and the
# exit code must match byte-for-byte.
#
#   ./seed/tests/sweep_emit_c.sh            # report (exit 1 on divergence)
#
# The suite itself (run_tests.sh) compares conformance against EXPECT via
# the VM and only 19 fixtures through the C backend — divergences outside
# tests/codegen/ were invisible (the nested `?` frame bug of Fase 2.5 was
# found by reasoning, not by the suite). This sweep closes that gap.
set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
SEED="$root/seed/astra-seed"

if [ ! -x "$SEED" ]; then
    echo "sweep_emit_c: missing $SEED (build with 'make -C seed debug')" >&2
    exit 2
fi
if ! command -v gcc >/dev/null 2>&1; then
    echo "sweep_emit_c: gcc not found" >&2
    exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -r "$root/seed/tests/conformance" "$work/conf"

total=0
skip=0
fail=0

while IFS= read -r f; do
    rel=${f#"$work/conf/"}
    case "$rel" in ui/*) continue ;; esac
    total=$((total + 1))

    # The C backend is single-file: fixtures that import sibling modules
    # need the loader the codegen does not drive. WHY these 3 skip
    # (module/import_from.astra, module/use_paths.astra, module/root_import.astra):
    # the seed *discards* `import`/`from`/`use` (types them void, emits
    # nothing — single-file driver, no loader), while zig actually resolves
    # the module graph, so only zig can run their bodies to completion.
    if grep -qE '^(import|from|use) ' "$f"; then
        echo "skip $rel (module import)"
        skip=$((skip + 1))
        continue
    fi

    # stdin is pinned to empty (/dev/null): a case that reads stdin
    # (read_line at EOF, DEC-020) must fail deterministically instead of
    # blocking on the caller's terminal. CI already runs without a TTY.
    "$SEED" "$f" </dev/null >"$work/vm.out" 2>"$work/vm.err"
    vm_rc=$?

    if ! "$SEED" --emit-c "$f" >"$work/emit.err" 2>&1; then
        echo "FAIL $rel: --emit-c failed"
        sed 's/^/    /' "$work/emit.err"
        fail=$((fail + 1))
        continue
    fi

    cf="${f%.astra}.c"
    # -Wall -Wextra, not -w (audit §5.8): a warning in generated C is a
    # codegen defect (discarded qualifiers, unused things, …) and must fail
    # the sweep like any other divergence source.
    if ! gcc -Wall -Wextra -I"$root/seed/src" -o "$work/bin" "$cf" -lm 2>"$work/gcc.err"; then
        echo "FAIL $rel: gcc rejected the generated C"
        sed 's/^/    /' "$work/gcc.err"
        fail=$((fail + 1))
        continue
    fi
    # gcc exits 0 on warnings and still links a binary, so check its stderr
    # explicitly — otherwise the -Wall -Wextra above would stay silent.
    # If a warning class ever proves pervasive and unfixable, suppress it HERE
    # with a narrowly scoped -Wno-<class> and a comment naming it; do not
    # bring blanket -w back.
    if [ -s "$work/gcc.err" ]; then
        echo "FAIL $rel: gcc warned about the generated C"
        sed 's/^/    /' "$work/gcc.err"
        fail=$((fail + 1))
        continue
    fi

    "$work/bin" </dev/null >"$work/c.out" 2>"$work/c.err"
    c_rc=$?

    bad=0
    [ "$vm_rc" != "$c_rc" ] && bad=1
    cmp -s "$work/vm.out" "$work/c.out" || bad=1
    cmp -s "$work/vm.err" "$work/c.err" || bad=1

    if [ "$bad" = 1 ]; then
        echo "FAIL $rel (rc vm=$vm_rc c=$c_rc)"
        diff "$work/vm.out" "$work/c.out" | sed 's/^/    out: /'
        diff "$work/vm.err" "$work/c.err" | sed 's/^/    err: /'
        fail=$((fail + 1))
    else
        echo "ok   $rel"
    fi
done < <(find "$work/conf" -name '*.astra' | sort)

echo "----"
echo "sweep_emit_c: total=$total skip=$skip fail=$fail"
[ "$fail" -eq 0 ]
