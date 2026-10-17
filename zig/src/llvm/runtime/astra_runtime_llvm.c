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

/* ---- Option/Result (boxed) --------------------------------------------- */

/* Option/Result values are boxed: `{ int32 tag; int32 ptype; int64 payload }`
 * on the heap (process lifetime, like the VM's arena and the C backend's
 * wrapped pointer). `tag` uses the VM's TAG_IS numbering — 0=ok 1=err
 * 2=some — and `none` is the NULL pointer, because the VM types `none` as
 * nil (print(none) prints "nil"). `ptype` tells print/eq how to read the
 * payload when the static type has been lost to Tier-2 aliasing: 1=bool
 * 2=i64 3=f64 4=str 5=boxed (nested). The emitter reads tag/payload inline
 * through this fixed layout; only construction, print and equality route
 * through the runtime. */
typedef struct { int32_t tag; int32_t ptype; int64_t payload; } AstraLLVMBox;

void *astra_llvm_wrap(unsigned line, int32_t tag, int32_t ptype, int64_t payload) {
    AstraLLVMBox *b = (AstraLLVMBox *)malloc(sizeof *b);
    if (!b) astra_llvm_fail(line, "out of memory");
    b->tag = tag;
    b->ptype = ptype;
    b->payload = payload;
    return b;
}

static void astra_llvm_boxed_body(const void *p) {
    if (!p) { fputs("nil", stdout); return; }
    const AstraLLVMBox *b = (const AstraLLVMBox *)p;
    fputs(b->tag == 0 ? "ok(" : b->tag == 1 ? "err(" : "some(", stdout);
    switch (b->ptype) {
        case 1: fputs(b->payload ? "true" : "false", stdout); break;
        case 2: printf("%ld", (long)b->payload); break;
        case 3: { double d; memcpy(&d, &b->payload, sizeof d); printf("%g", d); break; }
        case 4: { const AstraLLVMStr *s = (const AstraLLVMStr *)b->payload;
                  fwrite(s->data, 1, (size_t)s->len, stdout); break; }
        case 5: astra_llvm_boxed_body((const void *)b->payload); break;
        default: fputc('?', stdout); break;
    }
    fputc(')', stdout);
}

void astra_llvm_print_boxed(const void *p) {
    if (astra_llvm_printed_any++) putchar(' ');
    astra_llvm_boxed_body(p);
}

/* Structural equality — VM value_eq's ok/err/some arms (inner compared with
 * value_eq) and NIL==NIL. Floats compare by value (NaN != NaN, like the VM's
 * `==`), strings by content, nested boxes recursively. */
int32_t astra_llvm_boxed_eq(const void *pa, const void *pb) {
    if (pa == pb) return 1;
    if (!pa || !pb) return 0;
    const AstraLLVMBox *a = (const AstraLLVMBox *)pa;
    const AstraLLVMBox *b = (const AstraLLVMBox *)pb;
    if (a->tag != b->tag || a->ptype != b->ptype) return 0;
    switch (a->ptype) {
        case 3: { double x, y;
                  memcpy(&x, &a->payload, sizeof x);
                  memcpy(&y, &b->payload, sizeof y);
                  return x == y; }
        case 4: return astra_llvm_str_eq((const void *)a->payload, (const void *)b->payload) ? 1 : 0;
        case 5: return astra_llvm_boxed_eq((const void *)a->payload, (const void *)b->payload);
        default: return a->payload == b->payload;
    }
}

/* Ordering is numeric-only in the VM: OPCODE_LT & co. on ok/err/some/nil
 * abort with "cannot compare <type> and <type>", and the type names come from
 * the runtime tags ("cannot compare some and some"). This always fails; the
 * emitter calls it unconditionally and yields a dead dummy bool. */
static const char *astra_llvm_boxed_name(const void *p) {
    static const char *names[] = { "ok", "err", "some" };
    if (!p) return "nil";
    const AstraLLVMBox *b = (const AstraLLVMBox *)p;
    return b->tag < 3 ? names[b->tag] : "nil";
}

void astra_llvm_boxed_order_fail(unsigned line, const void *pa, const void *pb) {
    char buf[96];
    snprintf(buf, sizeof buf, "cannot compare %s and %s",
             astra_llvm_boxed_name(pa), astra_llvm_boxed_name(pb));
    astra_llvm_fail(line, buf);
}
