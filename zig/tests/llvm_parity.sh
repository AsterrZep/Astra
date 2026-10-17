#!/usr/bin/env bash
# LLVM-route differential parity (LLVM_BACKEND_PLAN.md §6 M0.4, §4.4): every
# case through the zig VM (reference) and through the LLVM route
# (--emit-llvm -> llc -> link runtime -> run); stdout, stderr and the exit code
# must match byte-for-byte.
#
#   ./zig/tests/llvm_parity.sh            # report (exit 1 on divergence)
#
# Requires the compiler built with -Dllvm (zig build -Dllvm) and the LLVM 19..23
# tools discoverable the same way build.zig finds llvm-config: $LLC, llc,
# llc-19..-23, or /usr/lib/llvm-*/bin/llc.
#
# The zig VM is the reference here. The seed jobs separately guarantee the zig
# VM matches the seed VM (dump parity + conformance + ui parity), so
# LLVM == zig VM transitively implies LLVM == seed semantics for the subset the
# backend covers.
#
# The emitter accepts a growing scalar subset (ints, bools, floats, control
# flow, functions as of M1); a case using anything outside it is *skipped* (the
# emitter rejects it with "not supported by the LLVM backend") rather than
# failed — the sweep_emit_c.sh pattern. As each milestone widens the subset,
# cases flip from skip to ok automatically. A case that emits successfully but
# diverges from the VM is a hard FAIL.
set -u

here=$(cd "$(dirname "$0")" && pwd)
zigdir=$(cd "$here/.." && pwd)
root=$(cd "$zigdir/.." && pwd)
ASTRA_ZIG="$zigdir/zig-out/bin/astra-zig"
RUNTIME_SRC="$zigdir/src/llvm/runtime/astra_runtime_llvm.c"

die() { echo "llvm_parity: $*" >&2; exit 2; }

[ -x "$ASTRA_ZIG" ] || die "missing $ASTRA_ZIG (build with 'zig build -Dllvm')"
command -v "${CC:-cc}" >/dev/null 2>&1 || die "${CC:-cc} not found"

# llc: $LLC override -> llc on PATH -> versioned llc-19..-23 -> /usr/lib/llvm-*.
LLC="${LLC:-}"
if [ -z "$LLC" ]; then
    for c in llc llc-19 llc-20 llc-21 llc-22 llc-23; do
        command -v "$c" >/dev/null 2>&1 && { LLC=$c; break; }
    done
fi
if [ -z "$LLC" ]; then
    for d in /usr/lib/llvm-19 /usr/lib/llvm-20 /usr/lib/llvm-21 /usr/lib/llvm-22 /usr/lib/llvm-23; do
        [ -x "$d/bin/llc" ] && { LLC="$d/bin/llc"; break; }
    done
fi
[ -n "$LLC" ] || die "llc not found (set LLC=/path/to/llc or install LLVM 19..23)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Fail fast if the binary lacks the LLVM backend: without -Dllvm every case
# would exit 2 with an actionable message and look like a wall of divergences.
"$ASTRA_ZIG" --emit-llvm-stdout "$zigdir/tests/llvm/fib.astra" >/dev/null 2>"$work/probe.err"
probe_rc=$?
if [ "$probe_rc" = 2 ] && grep -q "requires the compiler to be built with" "$work/probe.err"; then
    cat "$work/probe.err" >&2
    die "build the compiler with 'zig build -Dllvm' first"
fi

# Snapshot the inputs into the temp dir: emitting writes a .ll next to each
# .astra, so working in-tree would leave artifacts behind.
mkdir -p "$work/conf" "$work/llvm"
cp -r "$root/seed/tests/conformance/." "$work/conf/"
cp -r "$zigdir/tests/llvm/." "$work/llvm/"

# Runtime object, compiled once (the thin TU over seed/src/codegen_runtime.h;
# exactly one includer because the header defines its globals).
if ! "${CC:-cc}" -c -O2 -std=c11 -I"$root/seed/src" "$RUNTIME_SRC" -o "$work/runtime.o" 2>"$work/rt.err"; then
    echo "llvm_parity: cannot compile the LLVM runtime TU"
    sed 's/^/    /' "$work/rt.err"
    exit 2
fi

# Cases in M0 emitter scope that still cannot be compared to the VM: they pin a
# VM-only runtime guard (the VM_CALL_DEPTH limit) that native code does not
# reproduce — the VM errors where the native binary legitimately completes.
# Paths are relative to conformance/. Revisit when the LLVM route grows its own
# call-depth guard (M1+).
EXCLUDE="expressions/recursion_depth_limit.astra"

total=0
skip=0
excl=0
fail=0

while IFS= read -r f; do
    case "$f" in
        "$work/conf"/*) rel=${f#"$work/conf/"} ;;
        *) rel="llvm/${f#"$work/llvm/"}" ;;
    esac
    total=$((total + 1))

    case " $EXCLUDE " in *" $rel "*)
        echo "excl $rel (VM-only guard)"
        excl=$((excl + 1))
        continue
    ;; esac

    # The LLVM emitter is single-file (multi-module exits 2 clean). Fixtures that
    # import sibling modules are out of M0 scope for the same reason sweep_emit_c
    # skips them, and for a second: the seed discards imports, zig resolves them.
    if grep -qE '^(import|from|use) ' "$f"; then
        echo "skip $rel (module import)"
        skip=$((skip + 1))
        continue
    fi

    # Reference: zig VM.
    "$ASTRA_ZIG" "$f" >"$work/vm.out" 2>"$work/vm.err"
    vm_rc=$?

    # LLVM route, step 1: emit .ll. Constructs outside M0 are a clean skip.
    base=${f%.astra}
    if ! "$ASTRA_ZIG" --emit-llvm "$f" >"$work/emit.out" 2>"$work/emit.err"; then
        if grep -q "not supported by the LLVM backend" "$work/emit.err"; then
            echo "skip $rel (not M0 scope)"
            skip=$((skip + 1))
            continue
        fi
        echo "FAIL $rel: --emit-llvm failed"
        sed 's/^/    /' "$work/emit.err"
        fail=$((fail + 1))
        continue
    fi

    # Step 2: llc -> object (-relocation-model=pic so the default-PIE cc links it).
    if ! "$LLC" -relocation-model=pic -filetype=obj "$base.ll" -o "$work/case.o" 2>"$work/llc.err"; then
        echo "FAIL $rel: llc rejected the IR"
        sed 's/^/    /' "$work/llc.err"
        fail=$((fail + 1))
        continue
    fi

    # Step 3: link against the runtime.
    if ! "${CC:-cc}" "$work/case.o" "$work/runtime.o" -o "$work/bin" -lm 2>"$work/link.err"; then
        echo "FAIL $rel: link failed"
        sed 's/^/    /' "$work/link.err"
        fail=$((fail + 1))
        continue
    fi

    # Step 4: run and compare stdout, stderr and exit code against the VM.
    "$work/bin" >"$work/llvm.out" 2>"$work/llvm.err"
    llvm_rc=$?

    bad=0
    [ "$vm_rc" != "$llvm_rc" ] && bad=1
    cmp -s "$work/vm.out" "$work/llvm.out" || bad=1
    cmp -s "$work/vm.err" "$work/llvm.err" || bad=1

    if [ "$bad" = 1 ]; then
        echo "FAIL $rel (rc vm=$vm_rc llvm=$llvm_rc)"
        diff "$work/vm.out" "$work/llvm.out" | sed 's/^/    out: /'
        diff "$work/vm.err" "$work/llvm.err" | sed 's/^/    err: /'
        fail=$((fail + 1))
    else
        echo "ok   $rel"
    fi
done < <(
    find "$work/conf" -name '*.astra' ! -path '*/ui/*' | sort
    find "$work/llvm" -name '*.astra' | sort
)

echo "----"
echo "llvm_parity: total=$total ok=$((total - skip - excl - fail)) skip=$skip excl=$excl fail=$fail"
[ "$fail" -eq 0 ]
