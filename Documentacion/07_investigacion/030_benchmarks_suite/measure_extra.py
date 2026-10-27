#!/usr/bin/env python3
"""Mide tiempo (min de N) y pico real de RSS (muestreando VmHWM en /proc).

A diferencia de ru_maxrss (hereda el piso del proceso padre en el fork),
VmHWM tras exec refleja el pico real del binario.
"""
import json
import os
import subprocess
import time

BENCH = os.path.dirname(os.path.abspath(__file__))

# (label, cmd, runs)
CELLS = [
    # -- timing de las celdas corregidas --
    ("time/str25k_c_O2", ["./str25k_c"], 3),
    ("time/alloc2m_rust_O0", ["./alloc2m_rust_O0"], 3),
    ("time/str25k_rust_O0", ["./str25k_rust_O0"], 3),
    # -- RSS real: alloc2m (2M arreglos) --
    ("rss/alloc2m_astra_O0", ["./alloc2m_astra_O0"], 3),
    ("rss/alloc2m_astra_O2", ["./alloc2m_astra_O2"], 3),
    ("rss/alloc2m_rust", ["./alloc2m_rust"], 3),
    ("rss/alloc2m_rust_O0", ["./alloc2m_rust_O0"], 3),
    ("rss/alloc2m_go", ["./alloc2m_go"], 3),
    ("rss/alloc2m_c", ["./alloc2m_c"], 3),
    ("rss/alloc2m_zig", ["./alloc2m_zig"], 3),
    ("rss/alloc2m_seed_vm", ["/home/aster/Astra/seed/astra-seed", "alloc2m.astra"], 2),
    ("rss/alloc2m_zig_vm", ["/home/aster/Astra/zig/zig-out/bin/astra-zig", "alloc2m.astra"], 2),
    # -- RSS real: str25k (concatenación acumulativa) --
    ("rss/str25k_astra_O0", ["./str25k_astra_O0"], 3),
    ("rss/str25k_rust_O0", ["./str25k_rust_O0"], 3),
    ("rss/str25k_go", ["./str25k_go"], 3),
    ("rss/str25k_c", ["./str25k_c"], 3),
    ("rss/str25k_zig", ["./str25k_zig"], 3),
    ("rss/str25k_seed_vm", ["/home/aster/Astra/seed/astra-seed", "str25k.astra"], 2),
    ("rss/str25k_zig_vm", ["/home/aster/Astra/zig/zig-out/bin/astra-zig", "str25k.astra"], 2),
]


def run_polled(cmd):
    """Ejecuta y devuelve (tiempo_s, pico_VmHWM_KB)."""
    t0 = time.perf_counter()
    p = subprocess.Popen(cmd, cwd=BENCH, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
    peak = 0
    while p.poll() is None:
        try:
            with open(f"/proc/{p.pid}/status") as f:
                for line in f:
                    if line.startswith("VmHWM:"):
                        v = int(line.split()[1])
                        if v > peak:
                            peak = v
                        break
        except (FileNotFoundError, ProcessLookupError):
            break
        time.sleep(0.002)
    dt = time.perf_counter() - t0
    return dt, peak


def main():
    out = []
    for label, cmd, runs in CELLS:
        times, peaks = [], []
        for _ in range(runs):
            dt, peak = run_polled(cmd)
            times.append(dt)
            peaks.append(peak)
        out.append({"label": label, "runs": runs,
                    "min_s": round(min(times), 4),
                    "max_rss_kb": max(peaks)})
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
