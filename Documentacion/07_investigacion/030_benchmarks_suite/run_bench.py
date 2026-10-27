#!/usr/bin/env python3
"""Benchmark harness: wall time (perf_counter) + maxRSS (wait4 ru_maxrss).

Uso: python3 run_bench.py > results.json
Cada binario corre N veces; se reporta min/med/max de tiempo y el pico de
RSS (VmHWM equivalente, en KB) de todas las corridas. Las salidas se
verifican contra el valor esperado en la primera corrida.
"""
import json
import os
import statistics
import subprocess
import time

BENCH = os.path.dirname(os.path.abspath(__file__))

TESTS = {
    "fib30":   {"runs": 5, "expect": "832040"},
    "alloc2m": {"runs": 3, "expect": "2000000"},
    "str25k":  {"runs": 3, "expect": "x" * 25000},
    "startup": {"runs": 20, "expect": ""},
}
BINARIES = ["astra_O0", "astra_O2", "rust", "go", "c", "zig"]
VMS = {
    "seed_vm": ["/home/aster/Astra/seed/astra-seed"],
    "zig_vm": ["/home/aster/Astra/zig/zig-out/bin/astra-zig"],
}


def run_one(cmd):
    t0 = time.perf_counter()
    p = subprocess.Popen(cmd, cwd=BENCH, stdout=subprocess.PIPE,
                         stderr=subprocess.STDOUT)
    pid, status, ru = os.wait4(p.pid, 0)
    dt = time.perf_counter() - t0
    out = p.stdout.read()
    p.returncode = 0  # ya esperado via wait4
    rc = os.waitstatus_to_exitcode(status)
    return dt, ru.ru_maxrss, rc, out


def bench(label, cmd, runs, expect):
    times, rsses = [], []
    for _ in range(runs):
        dt, rss, rc, out = run_one(cmd)
        if rc != 0:
            return {"label": label, "error": f"rc={rc}", "out": out[:200].decode(errors="replace")}
        if out.decode(errors="replace").rstrip("\n") != expect:
            return {"label": label, "error": "bad output",
                    "out": out[:80].decode(errors="replace")}
        times.append(dt)
        rsses.append(rss)
    return {
        "label": label,
        "runs": runs,
        "min_s": round(min(times), 4),
        "med_s": round(statistics.median(times), 4),
        "max_s": round(max(times), 4),
        "rss_kb": max(rsses),
    }


def main():
    results = {"loadavg_start": os.getloadavg(), "results": []}
    for test, cfg in TESTS.items():
        for lang in BINARIES:
            cmd = [os.path.join(BENCH, f"{test}_{lang}")]
            if not os.path.exists(cmd[0]):
                results["results"].append({"label": f"{test}/{lang}", "error": "missing"})
                continue
            results["results"].append(bench(f"{test}/{lang}", cmd, cfg["runs"], cfg["expect"]))
        for vm, base in VMS.items():
            # los VMs compilan+corren el .astra; corridas reducidas (son lentos)
            runs = 3 if test != "startup" else 5
            results["results"].append(
                bench(f"{test}/{vm}", base + [f"{test}.astra"], runs, cfg["expect"]))
    results["loadavg_end"] = os.getloadavg()
    print(json.dumps(results, indent=1))


if __name__ == "__main__":
    main()
