#!/usr/bin/env bash
# classify.sh — triage de artefactos de fuzzing.
#
# Separa hallazgos reproducibles de flakes de entorno ANTES de dar la
# alarma. Clases de artefacto de libFuzzer:
#   crash-*    ASan/UBSan/segfault durante un input
#   leak-*     LSan al salir del proceso
#   timeout-*  un input superó -timeout (reloj de pared, ¡también se dispara
#              por carga, memoria llena o inundación de stderr!)
#   oom-*      RSS total superó -rss_limit_mb (acumulador de estados, no
#              necesariamente un input hambriento)
#   slow-unit-* informativo: el input más lento del batch
#
# Un proceso de campaña matado por el OOM killer no deja artefacto (rc 137,
# sin salida): eso es la máquina, no el compilador.
#
# Uso:  fuzz/classify.sh <artefacto> [binario]     (binario: build/fuzz/astra-fuzz)
# Salida: evidencia + VEREDICTO. rc=1 ⇒ candidato a hallazgo real (guardar
# el input en seed/fuzz/regressions/ con el fix); rc=0 ⇒ flake / no reproduce.

set -u
art=${1:?uso: classify.sh <artefacto> [binario]}
bin=${2:-build/fuzz/astra-fuzz}

if [ ! -f "$art" ]; then
    echo "no existe el artefacto: $art" >&2
    exit 2
fi
if [ ! -x "$bin" ]; then
    echo "binario no encontrado: $bin (corre 'make fuzz' en seed/)" >&2
    exit 2
fi

name=$(basename "$art")
echo "== artefacto: $name ($(wc -c < "$art") bytes)"

# Diagnosticos completos en este proceso: el triage quiere verlos.
unset ASTRA_FUZZ_QUIET

# 1) Reproduccion standalone por el mismo binario, fuera del bucle y sin
#    mutacion. 20 vueltas: un camino genuinamente lento se repite lento;
#    un stall del sistema no. ~80 ms de eso es el arranque de ASan.
max=0
fail=0
tmp=$(mktemp)
for _ in $(seq 1 20); do
    s=$(date +%s%N)
    timeout 30 "$bin" "$art" -runs=1 >"$tmp" 2>&1
    rc=$?
    e=$(date +%s%N)
    t=$(( (e - s) / 1000000 ))
    [ "$t" -gt "$max" ] && max=$t
    [ "$rc" -ne 0 ] && fail=$((fail + 1))
done
echo "standalone x20: rc!=0 en $fail/20, max ${max} ms (incluye arranque ASan)"
grep -m3 -E "ERROR: (AddressSanitizer|LeakSanitizer|libFuzzer)|SUMMARY:" "$tmp" || true

# 2) Si no reproduce standalone, bucle en proceso con stderr cerrado: si
#    aqui esta limpio y el artefacto salio de una campaña, el problema fue
#    de I/O o carga, no del compilador.
loop_rc=""
if [ "$fail" -eq 0 ]; then
    timeout 180 "$bin" "$art" -runs=3000 -timeout=10 -close_fd_mask=3 >/dev/null 2>&1
    loop_rc=$?
    echo "bucle en proceso x3000 (stderr cerrado): rc=$loop_rc (0=sin hallazgo)"
else
    echo "bucle en proceso: omitido (ya reproduce standalone)"
fi

# 3) Veredicto.
case "$name" in
    crash-* | leak-* | oom-*)
        if [ "$fail" -gt 0 ]; then
            echo "VEREDICTO: HALLAZGO REAL — reproduce standalone ($fail/20)."
            echo "  -> guarda el input en seed/fuzz/regressions/ con el fix y"
            echo "     añade su replay a .github/workflows/ci.yml."
            exit 1
        fi
        echo "VEREDICTO: NO REPRODUCE standalone — probable flake"
        echo "  (estado del allocator / ASLR / carga). Si insistes, sube a"
        echo "  x50 vueltas antes de concluir; no avises todavía."
        exit 0
        ;;
    timeout-* | slow-unit-*)
        if [ "$max" -gt 10000 ]; then
            echo "VEREDICTO: CAMINO LENTO GENUINO (max ${max} ms standalone)."
            exit 1
        elif [ "$loop_rc" = "0" ]; then
            echo "VEREDICTO: FLAKE DE ENTORNO — standalone ${max} ms y x3000 limpio."
            echo "  -> el timeout vino de carga/memoria/I/O, no del compilador."
            exit 0
        else
            echo "VEREDICTO: INDECIDIDO (bucle rc=$loop_rc). Repite y mira el log."
            exit 1
        fi
        ;;
    *)
        echo "VEREDICTO: clase de artefacto desconocida — inspecciona a mano."
        exit 1
        ;;
esac
