/* Runtime for the LLVM backend's generated .ll modules (M0.3).
 *
 * This is the "thin TU" from LLVM_BACKEND_PLAN.md §3.1: it includes the seed's
 * shared C runtime (codegen_runtime.h) exactly once and exports the handful of
 * extern entry points the emitted IR calls. Reusing the header guarantees the
 * LLVM path prints runtime errors and values byte-for-byte like the VM and the
 * --emit-c backend, instead of drifting into a third formatting.
 *
 * codegen_runtime.h *defines* the globals (astra_file, astra_line, astra_frame,
 * …) rather than declaring them extern, so this header may be included by
 * exactly one translation unit per linked program — this one. The generated .ll
 * only references the astra_llvm_* functions below.
 *
 * Compile (resolved via -I so the include is path-independent):
 *   cc -c -O2 -std=c11 -I<repo>/seed/src astra_runtime_llvm.c -o astra_runtime_llvm.o
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "codegen_runtime.h"

/* ---- program start ---------------------------------------------------- */

/* The emitted @main passes its own source-file name so runtime errors print
 * `file:line: …` exactly like the VM driver (which reads astra_file). */
void astra_llvm_set_file(const char *file) {
    astra_file = file;
}

/* Mirrors codegen.c's use of the shared init/cleanup hooks: currently no-ops,
 * exported so the emitted entry point stays in lockstep with the C backend. */
void astra_llvm_runtime_init(void) {
    astra_runtime_init();
}

void astra_llvm_runtime_cleanup(void) {
    astra_runtime_cleanup();
}

/* ---- hard runtime errors ---------------------------------------------- */

/* A hard runtime error (div-by-zero, INT64_MIN/-1, bad shift) is fatal: print
 * `file:line: runtime error: msg` and exit(1), exactly like the VM driver. The
 * emitter passes the source line of the failing operation directly, so the
 * guard's error path carries its own position with no global bookkeeping on the
 * happy path. Marked noreturn so the IR after the call can be `unreachable`. */
void astra_llvm_fail(unsigned line, const char *msg) {
    astra_line = line;
    astra_runtime_error(msg);
}

/* ---- print boundary ---------------------------------------------------- */

/* print's VM semantics (builtin_print): arguments space-separated, one trailing
 * newline. Formatting goes through the same primitives the VM and --emit-c use,
 * so stdout bytes match for every supported M0 value (i64, bool). The separator
 * state mirrors the VM's loop-index check. */
static int astra_llvm_printed_any = 0;

void astra_llvm_print_begin(void) {
    astra_llvm_printed_any = 0;
}

void astra_llvm_print_i64(int64_t v) {
    if (astra_llvm_printed_any++) putchar(' ');
    printf("%ld", (long)v);
}

/* Floats print with C's %g, the exact formatting builtin_print (VM) and the
 * --emit-c backend use, so stdout bytes match (audit: dump.zig replicates the
 * same %g without libc). */
void astra_llvm_print_f64(double v) {
    if (astra_llvm_printed_any++) putchar(' ');
    printf("%g", v);
}

void astra_llvm_print_bool(int v) {
    if (astra_llvm_printed_any++) putchar(' ');
    printf("%s", v ? "true" : "false");
}

void astra_llvm_print_end(void) {
    putchar('\n');
}

/* ---- strings ----------------------------------------------------------- */

/* String values are the one boxed shape M1 introduces: the emitter lays a
 * string out as `{ i64 len; [len+1 x i8] data }` (a NUL-terminated literal
 * global, or a malloc'd block from concat) and passes a pointer to it around
 * as `ptr`. The C view below mirrors that layout exactly — `len` at offset 0,
 * bytes at offset 8 — so the runtime reads the header directly through the
 * opaque pointer with no bitcasts in the IR. Length-bounded, like the VM's
 * (str, len) pair: a NUL byte inside the string must not truncate print,
 * concat or equality (audit §2.14, tests/conformance/types/string_nul). */
typedef struct { int64_t len; char data[]; } AstraLLVMStr;

void astra_llvm_print_str(const void *p) {
    const AstraLLVMStr *s = (const AstraLLVMStr *)p;
    if (astra_llvm_printed_any++) putchar(' ');
    fwrite(s->data, 1, (size_t)s->len, stdout);
}

/* `a + b` for strings (VM OPCODE_ADD string arm): length-bounded copy into a
 * fresh block, NUL-terminated for C convenience. The line rides along so the
 * only failure mode (OOM) reports `file:line:` like the VM's arena_alloc. */
void *astra_llvm_str_concat(unsigned line, const void *pa, const void *pb) {
    const AstraLLVMStr *a = (const AstraLLVMStr *)pa;
    const AstraLLVMStr *b = (const AstraLLVMStr *)pb;
    int64_t n = a->len + b->len;
    AstraLLVMStr *out = (AstraLLVMStr *)malloc(sizeof(int64_t) + (size_t)n + 1);
    if (!out) astra_llvm_fail(line, "out of memory");
    out->len = n;
    memcpy(out->data, a->data, (size_t)a->len);
    memcpy(out->data + a->len, b->data, (size_t)b->len);
    out->data[n] = '\0';
    return out;
}

/* `==`/`!=` for strings: content equality — VM value_eq's string arm (pointer
 * fast path, then length + memcmp). Ordering is deliberately absent: the VM
 * rejects `"a" < "b"` at runtime ("cannot compare string and string") and the
 * emitter reproduces that, so no compare function lives here. */
int32_t astra_llvm_str_eq(const void *pa, const void *pb) {
    const AstraLLVMStr *a = (const AstraLLVMStr *)pa;
    const AstraLLVMStr *b = (const AstraLLVMStr *)pb;
    if (a == b) return 1;
    if (a->len != b->len) return 0;
    return memcmp(a->data, b->data, (size_t)a->len) == 0;
}
