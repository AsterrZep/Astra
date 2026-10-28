#!/usr/bin/env bash
# LLVM-route differential parity (LLVM_BACKEND_PLAN.md §6 M0.4, §4.4): every
# case through the zig VM (reference) and through the LLVM route
# (--emit-obj -> link runtime -> run); stdout, stderr and the exit code must
# match byte-for-byte.
#
#   ./zig/tests/llvm_parity.sh            # report (exit 1 on divergence)
#   ASTRA_LLVM_SAN=address ./zig/tests/llvm_parity.sh   # same gate under ASan (M4.d)
#
# ASTRA_LLVM_SAN=<type> passes `--sanitize=<type>` to the emitter and links the
# object and the runtime TU with `-fsanitize=<type>` (the emitted object
# references `__asan_*`, so a plain link fails by design).
#
# Requires the compiler built with -Dllvm (zig build -Dllvm) — since M2.e the
# object comes from TargetMachineEmitToFile inside astra-zig, so no external
# llc is needed; only ${CC:-cc} for linking the runtime.
#
# The zig VM is the reference here. The seed jobs separately guarantee the zig
# VM matches the seed VM (dump parity + conformance + ui parity), so
# LLVM == zig VM transitively implies LLVM == seed semantics for the subset the
# backend covers.
#
# The emitter accepts a growing subset (scalars, control flow, closures,
# strings, arrays, structs, enums, for..in); a case using anything outside it
# is *skipped* (the emitter rejects it with "not supported by the LLVM backend")
# rather than failed — the sweep_emit_c.sh pattern. As each milestone widens
# the subset, cases flip from skip to ok automatically. A case that emits
# successfully but diverges from the VM is a hard FAIL.
set -u

here=$(cd "$(dirname "$0")" && pwd)
zigdir=$(cd "$here/.." && pwd)
root=$(cd "$zigdir/.." && pwd)
ASTRA_ZIG="$zigdir/zig-out/bin/astra-zig"
RUNTIME_SRC="$zigdir/src/llvm/runtime/astra_runtime_llvm.c"
# M4.d: instrumentación de sanitizer para toda la ruta (emisor + runtime +
# enlace). Vacío = gate normal, sin tocar flags ni objetos.
SAN="${ASTRA_LLVM_SAN:-}"
SAN_EMIT=""
SAN_CFLAGS=""
SAN_LDFLAGS=""
if [ -n "$SAN" ]; then
    SAN_EMIT="--sanitize=$SAN"
    SAN_CFLAGS="-fsanitize=$SAN"
    SAN_LDFLAGS="-fsanitize=$SAN"
fi

die() { echo "llvm_parity: $*" >&2; exit 2; }

[ -x "$ASTRA_ZIG" ] || die "missing $ASTRA_ZIG (build with 'zig build -Dllvm')"
command -v "${CC:-cc}" >/dev/null 2>&1 || die "${CC:-cc} not found"

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

# Snapshot the inputs into the temp dir: emitting writes a .o next to each
# .astra, so working in-tree would leave artifacts behind.
mkdir -p "$work/conf" "$work/llvm" "$work/cg"
cp -r "$root/seed/tests/conformance/." "$work/conf/"
cp -r "$zigdir/tests/llvm/." "$work/llvm/"
# M2 gate (LLVM_BACKEND_PLAN.md §6): the seed's C-codegen suite through the
# LLVM route too — both backends must agree with the VM on the same cases.
cp "$root"/seed/tests/codegen/*.astra "$work/cg/" 2>/dev/null || true

# Runtime object, compiled once (the thin TU over seed/src/codegen_runtime.h;
# exactly one includer because the header defines its globals).
if ! "${CC:-cc}" -c -O2 -std=c11 $SAN_CFLAGS -I"$root/seed/src" "$RUNTIME_SRC" -o "$work/runtime.o" 2>"$work/rt.err"; then
    echo "llvm_parity: cannot compile the LLVM runtime TU"
    sed 's/^/    /' "$work/rt.err"
    exit 2
fi

# Nivel de optimización del módulo antes de emitir el objeto (M4): 0 (default,
# el IR que fijan los FileCheck) o 1..3 para el pipeline del new PM. CI corre
# el gate dos veces, sin y con ASTRA_LLVM_OPT=2.
OPT="${ASTRA_LLVM_OPT:-0}"
OPT_ARGS=""
if [ "$OPT" != 0 ]; then OPT_ARGS="--opt-level=$OPT"; fi

# M3: the LLVM route reproduces the VM's VM_CALL_DEPTH bound with its own
# `call depth exceeded` trap at the same call site (recursion_depth_limit and
# frame_overflow now run through both routes), so no case is excluded.
EXCLUDE=""

total=0
skip=0
excl=0
fail=0

while IFS= read -r f; do
    case "$f" in
        "$work/conf"/*) rel=${f#"$work/conf/"} ;;
        "$work/cg"/*) rel="codegen/${f#"$work/cg/"}" ;;
        *) rel="llvm/${f#"$work/llvm/"}" ;;
    esac
    total=$((total + 1))

    case " $EXCLUDE " in *" $rel "*)
        echo "excl $rel (VM-only guard)"
        excl=$((excl + 1))
        continue
    ;; esac

    # The LLVM emitter is single-file, and the seed discards module
    # declarations. The module conformance fixtures assert exactly that
    # (their imports name files that must NOT be resolved), so both routes run
    # them with --single-file: the seed's semantics, and the same pipeline the
    # zig conformance runner uses for every case.
    extra=""
    if grep -qE '^(import|from|use) ' "$f"; then
        extra="--single-file"
    fi

    # Reference: zig VM.
    # stdin pinned empty (/dev/null): read_line-at-EOF (DEC-020) must fail
    # deterministically, not block on the caller's terminal (CI has no TTY).
    "$ASTRA_ZIG" $extra "$f" </dev/null >"$work/vm.out" 2>"$work/vm.err"
    vm_rc=$?

    # LLVM route, step 1: compile straight to a native object
    # (TargetMachineEmitToFile, M2.e — the .o lands next to the snapshot).
    # Constructs outside the backend's scope are a clean skip.
    base=${f%.astra}
    if ! "$ASTRA_ZIG" --emit-obj $extra $OPT_ARGS $SAN_EMIT "$f" >"$work/emit.out" 2>"$work/emit.err"; then
        if grep -q "not supported by the LLVM backend" "$work/emit.err"; then
            echo "skip $rel (not M0 scope)"
            skip=$((skip + 1))
            continue
        fi
        echo "FAIL $rel: --emit-obj failed"
        sed 's/^/    /' "$work/emit.err"
        fail=$((fail + 1))
        continue
    fi

    # Step 2: link against the runtime.
    if ! "${CC:-cc}" $SAN_LDFLAGS "$base.o" "$work/runtime.o" -o "$work/bin" -lm 2>"$work/link.err"; then
        echo "FAIL $rel: link failed"
        sed 's/^/    /' "$work/link.err"
        fail=$((fail + 1))
        continue
    fi

    # Step 3: run and compare stdout, stderr and exit code against the VM.
    "$work/bin" </dev/null >"$work/llvm.out" 2>"$work/llvm.err"
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
    find "$work/cg" -name '*.astra' | sort
)

echo "----"
echo "llvm_parity: total=$total ok=$((total - skip - excl - fail)) skip=$skip excl=$excl fail=$fail opt=$OPT san=${SAN:-none}"
# No silent coverage loss (lección de research/031/PR#15): a regression can
# turn an `ok` into a `skip` (emit rejects the file) while `fail` stays 0 —
# that is exactly how the DEC-008 top-level regression hid for one merge. A
# case genuinely outside the backend's subset belongs in EXCLUDE, with a
# comment; anything else skipping is a failure.
if [ "$skip" -gt 0 ]; then
    echo "llvm_parity: FAIL — $skip case(s) skipped: coverage shrank vs the last run." >&2
    echo "  Fix the emitter, or (only for a case deliberately outside the LLVM" >&2
    echo "  subset) add it to EXCLUDE at the top of this script with a comment." >&2
    exit 1
fi
[ "$fail" -eq 0 ]
