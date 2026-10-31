#!/usr/bin/env bash
# DEC-021 gate: la CLI `astraea` (init/run/build) y el marcador de raíz
# `astraea.toml` (el rename desde astra.toml llegó con la CLI — DEC-021).
#
#   ./cli/cli_gate.sh                     # desde cualquier sitio
#
# Fases: version/help · init (rechazado la segunda vez) · run · root-marker (@/
# resuelto con astraea.toml vía la CLI, y el negativo noroot) · build
# (skip limpio si astra-zig no tiene -Dllvm).
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
BIN="$root/zig/zig-out/bin"
ASTRAEA="$BIN/astraea"
ZIG="$BIN/astra-zig"

fail=0
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ ! -x "$ASTRAEA" ]; then
    echo "cli_gate: falta $ASTRAEA (construye con 'zig build -C zig')" >&2
    exit 2
fi

ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }

# 1. version y help
out=$("$ASTRAEA" version 2>&1) || { bad "version (exit)"; }
case "$out" in *DEC-021*) ok "version";; *) bad "version: $out";; esac
if "$ASTRAEA" help >/dev/null 2>&1; then ok "help"; else bad "help (exit)"; fi

# 2. init — crea astraea.toml con [package]; repetir no pisa
cp "$root/zig/tests/link/rootproj/lib/util.astra" "$work/" 2>/dev/null || true
printf 'fn main() {\n    print("hola desde astraea")\n}\n' > "$work/hello.astra"
(cd "$work" && "$ASTRAEA" init . >/dev/null 2>&1) || bad "init (exit)"
grep -q '\[package\]' "$work/astraea.toml" 2>/dev/null || bad "init: sin [package]"
if (cd "$work" && "$ASTRAEA" init . >/dev/null 2>&1); then
    bad "init: pisa un astraea.toml existente"
else
    ok "init (2ª vez rechazada)"
fi

# 3. run — el driver invoca a astra-zig
out=$(cd "$work" && "$ASTRAEA" run hello.astra 2>&1) || { bad "run (exit)"; }
case "$out" in *"hola desde astraea"*) ok "run";; *) bad "run: $out";; esac

# 4. root-marker: @/ se ancla con astraea.toml (fixture rootproj) y el
#    negativo noroot sigue sin raíz con el mensaje nuevo.
if [ -x "$ZIG" ]; then
    out=$("$ASTRAEA" run "$root/zig/tests/link/rootproj/main.astra" 2>&1) || true
    case "$out" in
        *"42"*) ok "root-marker: @/ resuelto con astraea.toml";;
        *) bad "root-marker: $out";;
    esac
    out=$("$ASTRAEA" run "$root/zig/tests/modules/noroot/main.astra" 2>&1) || true
    case "$out" in
        *"no astraea.toml found (project root)"*) ok "noroot: mensaje con astraea.toml";;
        *) bad "noroot: $out";;
    esac
else
    echo "skip root-marker (falta astra-zig)"
fi

# 5. build — --emit-obj + link con cc (necesita -Dllvm). Captura en vez de
#    pipeline: --help sale con exit 1 (unknown flag) y pipefail lo haría
#    fallar aunque el uso contenga --emit-obj.
has_emit_obj=0
if [ -x "$ZIG" ]; then
    help_out=$("$ZIG" --help 2>&1 || true)
    case "$help_out" in *--emit-obj*) has_emit_obj=1;; esac
fi
if [ "$has_emit_obj" -eq 1 ]; then
    if (cd "$work" && "$ASTRAEA" build hello.astra >/dev/null 2>&1) && out=$("$work/a.out" 2>&1); then
        case "$out" in
            *"hola desde astraea"*) ok "build (emit-obj + cc)";;
            *) bad "build: salida '$out'";;
        esac
    else
        bad "build (exit)"
    fi
else
    echo "skip build (astra-zig sin -Dllvm)"
fi

if [ "$fail" -eq 0 ]; then
    echo "cli_gate: init/run/build + root-marker astraea.toml ok"
else
    echo "cli_gate: FAIL"
fi
exit "$fail"
