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

/* ---- reference counting (v1 ownership model) -------------------------- */

/* Every value with heap storage carries an 8-byte header immediately before
 * the pointer the emitted IR handles: `{ int32_t rc; int32_t kind; }`. The
 * header keeps the object layouts unchanged (array len still at +0, struct
 * def still at +0, …), so print/eq and every inline GEP in the IR keep
 * working. Static values (string literals, kind-0 enum constants) carry the
 * same header with rc = -1 (immortal): releasing them is a no-op, which lets
 * the emitter release any value pointer uniformly without tracking provenance.
 *
 * Ownership rules the emitter implements on top of this:
 *   - a fresh object starts at rc = 1 and is registered as a temporary;
 *   - storing a pointer into a local/global/field/element/box/env retains it;
 *   - a function return retains the value; parameters are retained on entry;
 *   - locals/globals are released by their owner, temporaries at statement
 *     boundaries (or before break/continue/return).
 * Cycles (a closure whose env reaches the closure itself) are the one leak
 * this model cannot collect; they are documented as a v1 limitation. */
typedef struct { int32_t rc; int32_t kind; } AstraLLVMHdr;

void astra_llvm_fail(unsigned line, const char *msg);

enum {
    ASTRA_LLVM_KIND_STR = 1,
    ASTRA_LLVM_KIND_BOX = 2,
    ASTRA_LLVM_KIND_ARR = 3,
    ASTRA_LLVM_KIND_STRUCT = 4,
    ASTRA_LLVM_KIND_ENUM = 5,
    ASTRA_LLVM_KIND_FN = 6,
    ASTRA_LLVM_KIND_ENV = 7,
};

static void astra_llvm_destroy(int32_t kind, void *p);

static AstraLLVMHdr *astra_llvm_hdr(const void *p) {
    return (AstraLLVMHdr *)((char *)p - sizeof(AstraLLVMHdr));
}

/* Zero-filled allocation: aggregate constructors store fields/elements with
 * the same "release the previous value" path used for assignments, and the
 * previous value of a fresh slot must be NULL rather than malloc garbage. */
void *astra_llvm_alloc(unsigned line, int64_t size, int32_t kind) {
    if (size < 0) astra_llvm_fail(line, "out of memory");
    AstraLLVMHdr *h = (AstraLLVMHdr *)calloc(1, sizeof *h + (size_t)size);
    if (!h) astra_llvm_fail(line, "out of memory");
    h->rc = 1;
    h->kind = kind;
    return (char *)h + sizeof *h;
}

void astra_llvm_retain(void *p) {
    if (!p) return;
    AstraLLVMHdr *h = astra_llvm_hdr(p);
    if (h->rc < 0) return; /* immortal (static literal / unit enum) */
    h->rc++;
}

void astra_llvm_release(void *p) {
    if (!p) return;
    AstraLLVMHdr *h = astra_llvm_hdr(p);
    if (h->rc < 0) return;
    if (--h->rc > 0) return;
    astra_llvm_destroy(h->kind, p);
    free(h);
}

/* Temporary roots: the emitter registers every fresh object here and clears
 * back to a statement/function mark, so values that are never stored are
 * released instead of living until process exit. The stack is per-process but
 * marks nest, which makes recursion and nested calls safe: a callee only
 * clears its own entries. */
static void **astra_llvm_temps = NULL;
static size_t astra_llvm_temp_count = 0;
static size_t astra_llvm_temp_cap = 0;

int64_t astra_llvm_tmp_mark(void) {
    return (int64_t)astra_llvm_temp_count;
}

void astra_llvm_tmp_push(void *p) {
    if (!p) return;
    if (astra_llvm_temp_count == astra_llvm_temp_cap) {
        size_t cap = astra_llvm_temp_cap ? astra_llvm_temp_cap * 2 : 256;
        void **grown = (void **)realloc(astra_llvm_temps, cap * sizeof *grown);
        /* Sin memoria para registrar el temporal: se deja sin raíz (peor caso,
         * una fuga) en vez de abortar un programa correcto. */
        if (!grown) return;
        astra_llvm_temps = grown;
        astra_llvm_temp_cap = cap;
    }
    astra_llvm_temps[astra_llvm_temp_count++] = p;
}

void astra_llvm_tmp_clear(int64_t mark) {
    if (mark < 0) mark = 0;
    while (astra_llvm_temp_count > (size_t)mark) {
        void *p = astra_llvm_temps[--astra_llvm_temp_count];
        astra_llvm_release(p);
    }
}

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
    /* El emisor vacía los temporales por sentencia; lo que quede aquí sólo
     * puede ser un ciclo o una salida por error. Se libera el buffer para que
     * LSan no lo cuente como fuga del runtime. */
    free(astra_llvm_temps);
    astra_llvm_temps = NULL;
    astra_llvm_temp_count = 0;
    astra_llvm_temp_cap = 0;
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
    /* %lld + long long:64 bits en LP64 (host), ILP32 (wasm32-wasi) y LLP64.
     * `%ld` con (long) sólo es 64-bit en LP64; en wasm32 long mide 32 y cada
     * entero grande se trunca (i64 max -> -1), roto el contrato byte a byte. */
    printf("%lld", (long long)v);
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
    if (astra_llvm_printed_any++) putchar(' ');
    /* `let s: string` sin inicializador es nil (NULL), igual que en el VM:
     * print lo escribe como `nil` en vez de desreferenciar el puntero. */
    if (!p) { fputs("nil", stdout); return; }
    const AstraLLVMStr *s = (const AstraLLVMStr *)p;
    fwrite(s->data, 1, (size_t)s->len, stdout);
}

/* `a + b` for strings (VM OPCODE_ADD string arm): length-bounded copy into a
 * fresh block, NUL-terminated for C convenience. The line rides along so the
 * only failure mode (OOM) reports `file:line:` like the VM's arena_alloc. */
void *astra_llvm_str_concat(unsigned line, const void *pa, const void *pb) {
    /* `+` con un string nil no es IEEE ni basura: el VM aborta nombrando los
     * dos operandos (`cannot add nil and string`). */
    if (!pa && !pb) astra_llvm_fail(line, "cannot add nil and nil");
    if (!pa) astra_llvm_fail(line, "cannot add nil and string");
    if (!pb) astra_llvm_fail(line, "cannot add string and nil");
    const AstraLLVMStr *a = (const AstraLLVMStr *)pa;
    const AstraLLVMStr *b = (const AstraLLVMStr *)pb;
    int64_t n = a->len + b->len;
    if (n < a->len) astra_llvm_fail(line, "out of memory");
    AstraLLVMStr *out = (AstraLLVMStr *)astra_llvm_alloc(
        line, (int64_t)sizeof(int64_t) + n + 1, ASTRA_LLVM_KIND_STR);
    out->len = n;
    memcpy(out->data, a->data, (size_t)a->len);
    memcpy(out->data + a->len, b->data, (size_t)b->len);
    out->data[n] = '\0';
    return out;
}

/* `==`/`!=` for strings: content equality — VM value_eq's string arm (pointer
 * fast path, then length + memcmp). nil is the NULL string: nil == nil and
 * nil != any string. Ordering is always rejected, but its message names the
 * real operands, so `astra_llvm_str_order_fail` below is the only entry. */
int32_t astra_llvm_str_eq(const void *pa, const void *pb) {
    if (pa == pb) return 1; /* incluye nil == nil */
    if (!pa || !pb) return 0; /* nil vs string: false, como value_eq */
    const AstraLLVMStr *a = (const AstraLLVMStr *)pa;
    const AstraLLVMStr *b = (const AstraLLVMStr *)pb;
    if (a->len != b->len) return 0;
    return memcmp(a->data, b->data, (size_t)a->len) == 0;
}

/* Ordenación de strings: el VM la rechaza siempre, pero nombra los tipos
 * reales de los operandos (`cannot compare nil and string` para un string
 * nil), así que el emisor pasa ambos valores en vez de un mensaje fijo. */
void astra_llvm_str_order_fail(unsigned line, const void *pa, const void *pb) {
    char buf[96];
    snprintf(buf, sizeof buf, "cannot compare %s and %s",
             pa ? "string" : "nil", pb ? "string" : "nil");
    astra_llvm_fail(line, buf);
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
    AstraLLVMBox *b = (AstraLLVMBox *)astra_llvm_alloc(line, sizeof *b, ASTRA_LLVM_KIND_BOX);
    b->tag = tag;
    b->ptype = ptype;
    b->payload = payload;
    /* La caja posee una referencia al payload cuando es un puntero (string,
     * array, struct, enum, caja anidada o closure): liberarla al destruir la
     * caja es lo que evita que `some([...])` deje el array vivo. */
    if (ptype >= 4 && ptype <= 9) astra_llvm_retain((void *)(intptr_t)payload);
    return b;
}

/* Defined with the arrays below (M2.a): `some([1, 2])` prints through it. */
static void astra_llvm_array_body(const void *p);
/* Defined with the structs (M2.b): `some(P { … })` prints/compares through them. */
static void astra_llvm_struct_body(const void *p);
int32_t astra_llvm_struct_eq(const void *pa, const void *pb);
/* Defined with the enums (M2.c): `some(Color.Rojo)` prints/compares through it. */
static void astra_llvm_enum_body(const void *p);
int32_t astra_llvm_enum_eq(const void *pa, const void *pb);
/* VM value_eq: arrays compare ELEMENT-WISE and recurse (vm.c value_eq's
 * early array case; the identity arm in the switch is dead for two arrays) —
 * so `some([1, 2]) == some([1, 2])` and struct fields with arrays are
 * structural too. */
int32_t astra_llvm_array_eq(const void *pa, const void *pb);
/* Payload recursion shared by structs/enums/arrays (defined below, with the
 * struct eq — array_eq calls it for elements, so it needs the decl here). */
static int32_t astra_llvm_value_eq_pty(int32_t pty, const char *a, const char *b);

static void astra_llvm_boxed_body(const void *p) {
    if (!p) { fputs("nil", stdout); return; }
    const AstraLLVMBox *b = (const AstraLLVMBox *)p;
    fputs(b->tag == 0 ? "ok(" : b->tag == 1 ? "err(" : "some(", stdout);
    switch (b->ptype) {
        case 1: fputs(b->payload ? "true" : "false", stdout); break;
        case 2: printf("%lld", (long long)b->payload); break;
        case 3: { double d; memcpy(&d, &b->payload, sizeof d); printf("%g", d); break; }
        case 4: { const AstraLLVMStr *s = (const AstraLLVMStr *)b->payload;
                  if (!s) { fputs("nil", stdout); break; }
                  fwrite(s->data, 1, (size_t)s->len, stdout); break; }
        case 5: astra_llvm_boxed_body((const void *)b->payload); break;
        case 6: astra_llvm_array_body((const void *)b->payload); break;
        case 7: astra_llvm_struct_body((const void *)b->payload); break;
        case 8: astra_llvm_enum_body((const void *)b->payload); break;
        case 9: fputs("<fn>", stdout); break;
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
        case 6: return astra_llvm_array_eq((const void *)a->payload, (const void *)b->payload);
        case 7: return astra_llvm_struct_eq((const void *)a->payload, (const void *)b->payload);
        case 8: return astra_llvm_enum_eq((const void *)a->payload, (const void *)b->payload);
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

/* `len(x)` sobre una caja/par (DEC-013): el VM nombra el valor con
 * type_name (`cannot take length of nil/ok/err/some`) — mismo texto en el
 * backend C (astra_tag_name) y en los VMs. Siempre falla: el emisor marca
 * la llamada noreturn y pone `unreachable` detrás. */
void astra_llvm_len_fail(unsigned line, const void *p) {
    char buf[64];
    snprintf(buf, sizeof buf, "cannot take length of %s", astra_llvm_boxed_name(p));
    astra_llvm_fail(line, buf);
}

void astra_llvm_boxed_order_fail(unsigned line, const void *pa, const void *pb) {
    char buf[96];
    snprintf(buf, sizeof buf, "cannot compare %s and %s",
             astra_llvm_boxed_name(pa), astra_llvm_boxed_name(pb));
    astra_llvm_fail(line, buf);
}

/* ---- arrays (M2.a) ------------------------------------------------------ */

/* Arrays are homogeneous heap objects with SHARED identity: `let mut b = a`
 * aliases, so a write through `b` is visible through `a` (conformance
 * arrays/alias_write) — the pointer *is* the seed's handle. Layout:
 *   { int64 len; int32 elem_pty; int32 pad; <inline elements> }
 * with elements at offset 16 in their static LLVM type (8 bytes for
 * i64/f64/pointers, 1 byte for bool). `elem_pty` lets print dispatch when the
 * static type is gone (an array inside an array, a boxed payload):
 * 1=bool 2=i64 3=f64 4=str 5=boxed 6=array 7=struct 8=enum 9=fn. `==` is
 * structural by element (VM value_eq's early array arm), so array_eq lives in
 * this file and walks elements with the same slot size `arr_slot` returns;
 * ordering is rejected by the emitter ("cannot compare array and array"). */
#define ASTRA_LLVM_ARR_HDR 16

static int astra_llvm_arr_slot(int32_t pty) { return pty == 1 ? 1 : 8; }

static void astra_llvm_elem_print(int32_t pty, const char *slot);

static void astra_llvm_array_body(const void *p) {
    /* El VM imprime `nil` para un array nil (`let a: [i32]`); `[]` sería
     * indistinguible de un array vacío, que en Astra-0 no existe (el literal
     * vacío se rechaza por falta de tipo de elemento). */
    if (!p) { fputs("nil", stdout); return; }
    const char *base = (const char *)p;
    int64_t len;
    int32_t pty;
    memcpy(&len, base, sizeof len);
    memcpy(&pty, base + 8, sizeof pty);
    fputc('[', stdout);
    int slot = astra_llvm_arr_slot(pty);
    for (int64_t i = 0; i < len; i++) {
        if (i > 0) fputs(", ", stdout);
        astra_llvm_elem_print(pty, base + ASTRA_LLVM_ARR_HDR + i * slot);
    }
    fputc(']', stdout);
}

static void astra_llvm_elem_print(int32_t pty, const char *slot) {
    switch (pty) {
        case 1: fputs(*(const int8_t *)slot ? "true" : "false", stdout); break;
        case 2: { int64_t v; memcpy(&v, slot, sizeof v); printf("%lld", (long long)v); break; }
        case 3: { double d; memcpy(&d, slot, sizeof d); printf("%g", d); break; }
        case 4: { const AstraLLVMStr *s; memcpy(&s, slot, sizeof s);
                  if (!s) { fputs("nil", stdout); break; }
                  fwrite(s->data, 1, (size_t)s->len, stdout); break; }
        case 5: { const void *b; memcpy(&b, slot, sizeof b); astra_llvm_boxed_body(b); break; }
        case 6: { const void *a; memcpy(&a, slot, sizeof a); astra_llvm_array_body(a); break; }
        case 7: { const void *s; memcpy(&s, slot, sizeof s); astra_llvm_struct_body(s); break; }
        case 8: { const void *e; memcpy(&e, slot, sizeof e); astra_llvm_enum_body(e); break; }
        case 9: fputs("<fn>", stdout); break;
        default: fputc('?', stdout); break;
    }
}

void astra_llvm_print_array(const void *p) {
    if (astra_llvm_printed_any++) putchar(' ');
    astra_llvm_array_body(p);
}

/* VM value_eq structural de arrays: identidad como atajo, luego longitud,
 * luego elemento a elemento con el ptype del propio objeto — recursivo a
 * través de arrays anidados, structs y enums (igual que value_eq del VM). */
int32_t astra_llvm_array_eq(const void *pa, const void *pb) {
    if (pa == pb) return 1;
    if (!pa || !pb) return 0;
    int64_t la, lb;
    int32_t ea, eb;
    memcpy(&la, pa, sizeof la);
    memcpy(&lb, pb, sizeof lb);
    memcpy(&ea, (const char *)pa + 8, sizeof ea);
    memcpy(&eb, (const char *)pb + 8, sizeof eb);
    if (la != lb || ea != eb) return 0;
    /* El stride depende del ptype: los bool viven en 1 byte (arr_slot), no en
     * el slot de 8 de los demás. Con `8 * i` fijo, comparar dos arrays de bool
     * leía fuera del objeto (ASan: heap-buffer-overflow) y podía devolver un
     * resultado arbitrario. */
    const int slot = astra_llvm_arr_slot(ea);
    for (int64_t i = 0; i < la; i++) {
        if (!astra_llvm_value_eq_pty(ea,
                (const char *)pa + 16 + (size_t)slot * (size_t)i,
                (const char *)pb + 16 + (size_t)slot * (size_t)i))
            return 0;
    }
    return 1;
}

/* Bounds check (VM OPCODE_INDEX & OPCODE_INDEX_SET): fatal
 * `index i out of bounds (len n)` with file:line. The happy path is an inline
 * icmp + load/store in the IR; only the failing arm calls here. */
void astra_llvm_index_fail(unsigned line, int64_t idx, int64_t len) {
    char buf[96];
    snprintf(buf, sizeof buf, "index %lld out of bounds (len %lld)",
             (long long)idx, (long long)len);
    astra_llvm_fail(line, buf);
}

/* Nil receiver (VM OPCODE_INDEX): `let a: [i32]` with no initializer is nil
 * (NULL in this model), and `a[i]` must report `cannot index nil` — the same
 * guard audit §5.3 added to the C backend — instead of GEPping NULL. */
void astra_llvm_index_nil_fail(unsigned line) {
    astra_llvm_fail(line, "cannot index nil");
}

/* `s[i]` (DEC-013, research/028 PR1): byte i of the string as a fresh
 * one-byte string. The whole receiver/int/bounds sequence lives here so the
 * emitter emits a single call and the messages are literally the VM's —
 * `cannot index nil` for a nil string, then `index i out of bounds (len n)`
 * (shared with the array path via astra_llvm_index_fail). The result goes
 * through the same alloc/kind as str_concat, so retain/release treat it like
 * any other heap string. */
void *astra_llvm_str_index(unsigned line, const void *ps, int64_t i) {
    if (!ps) {
        astra_llvm_index_nil_fail(line);
        return NULL; /* noreturn en el IR; en C, para el compilador */
    }
    const AstraLLVMStr *s = (const AstraLLVMStr *)ps;
    if (i < 0 || i >= s->len) {
        astra_llvm_index_fail(line, i, s->len);
        return NULL;
    }
    AstraLLVMStr *out = (AstraLLVMStr *)astra_llvm_alloc(
        line, (int64_t)sizeof(int64_t) + 1 + 1, ASTRA_LLVM_KIND_STR);
    out->len = 1;
    out->data[0] = s->data[i];
    out->data[1] = '\0';
    return out;
}

/* ---- to_string / read_file (DEC-014, research/028 PR2) ------------------- */

/* `to_string(i64) -> string`: %lld + long long, la MISMA conversión que
 * astra_llvm_print_i64, así `print(to_string(n))` es byte-idéntico a
 * `print(n)` en LP64, ILP32 (wasm32-wasi) y LLP64 — el `snprintf("%ld")` del
 * seed se truncaría a 32 bits en wasm. El bloque sale por astra_llvm_alloc
 * (rc/kind) como str_concat/str_index, y el emisor lo registra como temporal
 * igual que a esos. */
void *astra_llvm_to_string(unsigned line, int64_t v) {
    char buf[32]; /* int64 min: 20 chars + signo */
    int n = snprintf(buf, sizeof buf, "%lld", (long long)v);
    if (n < 0) astra_llvm_fail(line, "to_string conversion failed");
    AstraLLVMStr *s = (AstraLLVMStr *)astra_llvm_alloc(
        line, (int64_t)sizeof(int64_t) + n + 1, ASTRA_LLVM_KIND_STR);
    s->len = n;
    memcpy(s->data, buf, (size_t)n + 1);
    return s;
}

/* `to_string` sobre caja/par (espejo de astra_llvm_len_fail): en este modelo
 * una caja es nil/ok/err/some — nunca un entero plano, igual que el VM nunca
 * ve un VAL_INT envuelto — así que el intento SIEMPRE falla y nombra el valor
 * con type_name, el mismo texto de las otras tres rutas. El emisor marca la
 * llamada noreturn y pone `unreachable` detrás. */
void astra_llvm_to_string_fail(unsigned line, const void *p) {
    char buf[64];
    snprintf(buf, sizeof buf, "to_string expects an int, got %s", astra_llvm_boxed_name(p));
    astra_llvm_fail(line, buf);
}

/* `read_file(path) -> string`: abre en binario y lee por bloques (sin
 * fseek/ftell: el tamaño no es fiable en todos los destinos, y el VM lee igual).
 * TODOS los fallos caen en `cannot open file '<path>'` — la redacción
 * unificada de las cuatro rutas (DEC-014), la misma que la del driver del
 * seed para un fichero que no se puede abrir. El path se copia
 * NUL-terminado a mano: el bloque del string es length-bounded, como el par
 * (str, len) del VM. El resultado sale por astra_llvm_alloc con el rc del
 * resto de strings. */
void *astra_llvm_read_file(unsigned line, const void *ppath) {
    if (!ppath) {
        astra_llvm_fail(line, "expected string path, got nil");
        return NULL; /* noreturn en el IR; en C, para el compilador */
    }
    const AstraLLVMStr *ps = (const AstraLLVMStr *)ppath;
    char *path = (char *)malloc((size_t)ps->len + 1);
    if (!path) astra_llvm_fail(line, "out of memory");
    memcpy(path, ps->data, (size_t)ps->len);
    path[ps->len] = '\0';

    FILE *f = fopen(path, "rb");
    if (!f) {
        /* 192 bytes: el mismo recorte que astra_errorf del backend C. */
        char msg[192];
        snprintf(msg, sizeof msg, "cannot open file '%s'", path);
        free(path);
        astra_llvm_fail(line, msg);
        return NULL;
    }
    /* Buffer temporal con malloc (no astra_llvm_alloc): el objeto con
     * rc/kind sólo existe cuando ya se conoce el tamaño final. */
    size_t cap = 4096, len = 0;
    char *buf = (char *)malloc(cap);
    if (!buf) { fclose(f); free(path); astra_llvm_fail(line, "out of memory"); return NULL; }
    for (;;) {
        if (len == cap) {
            char *bigger = (char *)realloc(buf, cap * 2);
            if (!bigger) { free(buf); free(path); fclose(f); astra_llvm_fail(line, "out of memory"); return NULL; }
            buf = bigger;
            cap *= 2;
        }
        size_t got = fread(buf + len, 1, cap - len, f);
        len += got;
        if (got == 0) break; /* EOF o error de lectura */
    }
    int io_err = ferror(f) != 0;
    fclose(f);
    if (io_err) {
        char msg[192];
        snprintf(msg, sizeof msg, "cannot open file '%s'", path);
        free(buf);
        free(path);
        astra_llvm_fail(line, msg);
        return NULL;
    }
    free(path);
    AstraLLVMStr *out = (AstraLLVMStr *)astra_llvm_alloc(
        line, (int64_t)sizeof(int64_t) + (int64_t)len + 1, ASTRA_LLVM_KIND_STR);
    out->len = (int64_t)len;
    memcpy(out->data, buf, len);
    out->data[len] = '\0';
    free(buf);
    return out;
}

/* `read_file` sobre caja/par (espejo de astra_llvm_to_string_fail): la caja
 * es nil/ok/err/some, nunca un string plano, y type_name del VM lo dice. */
void astra_llvm_read_file_fail(unsigned line, const void *p) {
    char buf[96];
    snprintf(buf, sizeof buf, "expected string path, got %s", astra_llvm_boxed_name(p));
    astra_llvm_fail(line, buf);
}

/* ---- ord / substr (DEC-018, research/028 M2a) --------------------------- */

/* `ord(string) -> i64`: el valor del PRIMER byte (0..255) — byte y no
 * codepoint, porque `s[i]` ya devuelve un string de 1 byte (DEC-013) y el
 * lexer del seed recorre bytes. Un string vacío no tiene primer byte y lo
 * dice (`ord() of empty string`), la misma frase del seed y del backend C;
 * el nil del receptor lo trae el guard del emisor con type_name. */
int64_t astra_llvm_ord(unsigned line, const void *ps) {
    if (!ps) {
        astra_llvm_fail(line, "ord expects a string, got nil");
        return 0; /* noreturn en el IR; en C, para el compilador */
    }
    const AstraLLVMStr *s = (const AstraLLVMStr *)ps;
    if (s->len == 0) astra_llvm_fail(line, "ord() of empty string");
    return (int64_t)(unsigned char)s->data[0];
}

/* `ord` sobre caja/par (espejo de astra_llvm_to_string_fail): la caja es
 * nil/ok/err/some, nunca un string plano, y type_name del VM lo dice. */
void astra_llvm_ord_fail(unsigned line, const void *p) {
    char buf[64];
    snprintf(buf, sizeof buf, "ord expects a string, got %s", astra_llvm_boxed_name(p));
    astra_llvm_fail(line, buf);
}

/* `substr(string, start, len) -> string`: `len` bytes desde `start`, sin
 * recorte silencioso — fuera de rango es error, el mismo contrato que `s[i]`.
 * El emisor ya filtró los tipos de los tres argumentos; aquí se ven los
 * límites con la longitud real, con la redacción exacta del seed y del
 * backend C. El resultado sale por astra_llvm_alloc (rc/kind) como
 * str_concat/str_index, y el emisor lo registra como temporal igual que a
 * esos. */
void *astra_llvm_substr(unsigned line, const void *ps, int64_t start, int64_t n) {
    if (!ps) {
        astra_llvm_fail(line, "substr expects a string, got nil");
        return NULL; /* noreturn en el IR; en C, para el compilador */
    }
    const AstraLLVMStr *s = (const AstraLLVMStr *)ps;
    if (start < 0 || start > s->len) {
        char msg[96];
        snprintf(msg, sizeof msg, "substr start %lld out of bounds (len %lld)",
                 (long long)start, (long long)s->len);
        astra_llvm_fail(line, msg);
        return NULL;
    }
    /* `start <= s->len` queda establecido arriba, así que el hueco restante
     * es exacto y `start + n` no puede desbordar: un `n` enorme (p. ej.
     * 9223372036854775807) debe fallar, no envolverse. */
    if (n < 0 || n > s->len - start) {
        char msg[96];
        snprintf(msg, sizeof msg, "substr length %lld out of bounds (len %lld)",
                 (long long)n, (long long)s->len);
        astra_llvm_fail(line, msg);
        return NULL;
    }
    AstraLLVMStr *out = (AstraLLVMStr *)astra_llvm_alloc(
        line, (int64_t)sizeof(int64_t) + n + 1, ASTRA_LLVM_KIND_STR);
    out->len = n;
    if (n > 0) memcpy(out->data, s->data + start, (size_t)n);
    out->data[n] = '\0';
    return out;
}

/* `substr` sobre caja/par (espejo de astra_llvm_to_string_fail): dos helpers
 * porque la redacción depende del parámetro que falla (receptor vs start/len)
 * y el emisor elige uno u otro. */
void astra_llvm_substr_str_fail(unsigned line, const void *p) {
    char buf[96];
    snprintf(buf, sizeof buf, "substr expects a string, got %s", astra_llvm_boxed_name(p));
    astra_llvm_fail(line, buf);
}

void astra_llvm_substr_int_fail(unsigned line, const void *p) {
    char buf[96];
    snprintf(buf, sizeof buf, "substr expects an int, got %s", astra_llvm_boxed_name(p));
    astra_llvm_fail(line, buf);
}

/* ---- chr / read_line (DEC-020, research/028 M3) ------------------------- */

/* `chr(i64) -> string`: el string de 1 byte cuyo PRIMER byte es el valor — la
 * inversa de `ord` (DEC-018), byte y no codepoint, así `chr(ord(s))`
 * round-tripea un `s` de 1 byte. Fuera de [0, 255] es error de runtime, nunca
 * el byte bajo enmascarado. El nil / caja del argumento lo trae el guard del
 * emisor con type_name; aquí se ve el rango con el valor real. El bloque sale
 * por astra_llvm_alloc (rc/kind) como str_index/substr. */
void *astra_llvm_chr(unsigned line, int64_t v) {
    if (v < 0 || v > 255) {
        char msg[64];
        snprintf(msg, sizeof msg, "chr value %lld out of bounds (0..255)", (long long)v);
        astra_llvm_fail(line, msg);
        return NULL; /* noreturn en el IR; en C, para el compilador */
    }
    AstraLLVMStr *out = (AstraLLVMStr *)astra_llvm_alloc(
        line, (int64_t)sizeof(int64_t) + 1 + 1, ASTRA_LLVM_KIND_STR);
    out->len = 1;
    out->data[0] = (char)(unsigned char)v;
    out->data[1] = '\0';
    return out;
}

/* `chr` sobre caja/par (espejo de astra_llvm_substr_int_fail): la caja es
 * nil/ok/err/some, nunca un entero plano, y type_name del VM lo dice. */
void astra_llvm_chr_fail(unsigned line, const void *p) {
    char buf[64];
    snprintf(buf, sizeof buf, "chr expects an int, got %s", astra_llvm_boxed_name(p));
    astra_llvm_fail(line, buf);
}

/* `read_line() -> string`: una línea de STANDARD INPUT hasta (sin incluir) el
 * `\n` final, o error de runtime `end of input` en EOF sin datos. stdin se lee
 * byte a byte con fgetc para que el MISMO buffer estático sirva a cada llamada
 * consecutiva (un lexer lee el fuente línea a línea; fread por bloques se
 * comería los bytes de la SIGUIENTE línea en un buffer desechado). Una última
 * línea sin `\n` devuelve lo que hay, una línea vacía devuelve "". El fallo de
 * arity lo trae el emisor: `read_line` no toma argumentos. El bloque sale por
 * astra_llvm_alloc (rc/kind); el buffer es estático porque astra_string_new
 * copia los bytes hacia fuera. */
void *astra_llvm_read_line(unsigned line) {
    static char *buf = NULL;
    static size_t cap = 0;
    size_t len = 0;
    int c;
    while ((c = fgetc(stdin)) != EOF && c != '\n') {
        if (len == cap) {
            cap = cap ? cap * 2 : 4096;
            char *bigger = (char *)realloc(buf, cap);
            if (!bigger) {
                astra_llvm_fail(line, "out of memory reading stdin");
                return NULL;
            }
            buf = bigger;
        }
        buf[len++] = (char)c;
    }
    if (c == EOF && len == 0 && ferror(stdin) == 0) {
        astra_llvm_fail(line, "end of input");
        return NULL; /* noreturn en el IR; en C, para el compilador */
    }
    AstraLLVMStr *out = (AstraLLVMStr *)astra_llvm_alloc(
        line, (int64_t)sizeof(int64_t) + (int64_t)len + 1, ASTRA_LLVM_KIND_STR);
    out->len = (int64_t)len;
    if (len > 0) memcpy(out->data, buf, len);
    out->data[len] = '\0';
    return out;
}

/* ---- push / str_to_int (DEC-019, research/028 M2b) ---------------------- */

/* Espejo de astra_llvm_release_slot (definido abajo, con los destructores):
 * el puntero dentro de un slot según el ptype del runtime (4=str 5=boxed
 * 6=array 7=struct 8=enum 9=fn) retiene una referencia. Los escalares (1/2/3)
 * no poseen nada. */
static void astra_llvm_retain_slot(int32_t pty, const char *slot) {
    if (pty < 4 || pty > 9) return;
    void *child;
    memcpy(&child, slot, sizeof child);
    astra_llvm_retain(child);
}

/* Nombre de type_name del VM para un ptype del runtime; los escalares y
 * agregados estáticos son su nombre y la caja (5) se nombra por su tag real
 * leyendo el puntero del slot (some/ok/err), como el VM nombra sus valores. */
static const char *astra_llvm_pty_name(int32_t pty, const char *slot) {
    switch (pty) {
        case 1: return "bool";
        case 2: return "int";
        case 3: return "float";
        case 4: return "string";
        case 5: { void *b = NULL; if (slot) memcpy(&b, slot, sizeof b); return astra_llvm_boxed_name(b); }
        case 6: return "array";
        case 7: return "struct";
        case 8: return "enum";
        case 9: return "function";
        default: return "unknown";
    }
}

/* `push(array, value) -> array` (DEC-019, research/028 M2b): a NEW array with
 * the value appended — the caller rebinds (`a = push(a, x)`), so the array it
 * came from stays untouched for every binding that still holds it. The object
 * keeps its elements INLINE (M2.a), so growing in place would relocate the
 * object and leave every alias pointing at the old one: the copy is the only
 * model that matches the seed's handle on all four routes. The copy is O(n)
 * (O(n²) for n pushes), like the VM's arena bump — documented in DEC-019.
 *
 * The emitter already rejected a statically mismatched element (its pty is
 * the object's pty), so here the slot holds the value in the element's own
 * width (1 byte for bool, 8 otherwise). Every element of the new object is
 * retained — it owns one reference each; the old object keeps its own and
 * dies with its last binding. */
void *astra_llvm_array_push(unsigned line, const void *p, const void *ev) {
    if (!p) {
        astra_llvm_fail(line, "push expects an array, got nil");
        return NULL; /* noreturn en el IR; en C, para el compilador */
    }
    int64_t len;
    int32_t pty;
    memcpy(&len, p, sizeof len);
    memcpy(&pty, (const char *)p + 8, sizeof pty);
    const int slot = astra_llvm_arr_slot(pty);
    const int64_t nlen = len + 1;
    void *np = astra_llvm_alloc(line, ASTRA_LLVM_ARR_HDR + (int64_t)slot * nlen, ASTRA_LLVM_KIND_ARR);
    memcpy(np, &nlen, sizeof nlen);
    memcpy((char *)np + 8, &pty, sizeof pty);
    memcpy((char *)np + ASTRA_LLVM_ARR_HDR,
           (const char *)p + ASTRA_LLVM_ARR_HDR, (size_t)slot * (size_t)len);
    memcpy((char *)np + ASTRA_LLVM_ARR_HDR + (size_t)slot * (size_t)len, ev, (size_t)slot);
    for (int64_t i = 0; i < nlen; i++)
        astra_llvm_retain_slot(pty, (const char *)np + ASTRA_LLVM_ARR_HDR + (size_t)slot * (size_t)i);
    return np;
}

/* `push` sobre caja/par (espejo de astra_llvm_substr_str_fail): la caja es
 * nil/ok/err/some, nunca un array plano, y type_name del VM lo dice. */
void astra_llvm_push_fail(unsigned line, const void *p) {
    char buf[96];
    snprintf(buf, sizeof buf, "push expects an array, got %s", astra_llvm_boxed_name(p));
    astra_llvm_fail(line, buf);
}

/* Elemento de `push` con un tipo dinámico distinto del elemento del array —
 * el checker solo lo deja pasar por los parámetros `unknown` (DEC-019). La
 * frase abrevia la del checker de arrays (`array element N has type X,
 * expected Y`) porque el runtime no conoce N; el lado que es caja se nombra
 * dinámicamente (some/ok/err) y el otro por su ptype, como el VM. */
void astra_llvm_push_elem_fail(unsigned line, const void *arr, const void *ev, int32_t ev_pty) {
    int32_t ap;
    int64_t alen;
    memcpy(&ap, (const char *)arr + 8, sizeof ap);
    memcpy(&alen, arr, sizeof alen);
    /* Los arrays de Astra-0 no pueden estar vacíos (el literal exige
     * elementos y push solo añade), pero si el día de mañana lo estuvieran,
     * nombrar el lado esperado leería pasando del objeto: un array vacío no
     * tiene elemento que nombrar y dice `nil`. */
    const char *e0 = alen > 0 ? (const char *)arr + ASTRA_LLVM_ARR_HDR : NULL;
    char buf[128];
    snprintf(buf, sizeof buf, "push element has type %s, expected %s",
             astra_llvm_pty_name(ev_pty, ev),
             astra_llvm_pty_name(ap, e0));
    astra_llvm_fail(line, buf);
}

/* `str_to_int(string) -> i64` (DEC-019, research/028 M2b): el decimal que
 * to_string produce — `str_to_int(to_string(n))` redondea para todo entero
 * nombrable. Un `-` inicial forma parte de esa rendered y se acepta; `+`,
 * espacios, `_` y los prefijos `0x`/`0b`/`0o` no (son del lexer). Cualquier
 * otra entrada — incluido el string vacío — es UN error de runtime que nombra
 * la entrada, y la magnitud se capa en INT64_MAX exactamente como el
 * accumulate_digit del lexer, así que "-9223372036854775808" falla igual que
 * el literal en origen. El emisor ya filtró el tipo del receptor. */
int64_t astra_llvm_str_to_int(unsigned line, const void *ps) {
    if (!ps) {
        astra_llvm_fail(line, "str_to_int expects a string, got nil");
        return 0; /* noreturn en el IR; en C, para el compilador */
    }
    const AstraLLVMStr *s = (const AstraLLVMStr *)ps;
    const char *p = s->data;
    int64_t i = 0, len = s->len;
    int neg = 0;
    if (i < len && p[i] == '-') { neg = 1; i++; }
    uint64_t acc = 0;
    int any = 0;
    for (; i < len; i++) {
        char c = p[i];
        if (c < '0' || c > '9') {
            /* The literal is DISPLAYED truncated to 64 bytes (and, like
             * every %s, up to the first NUL): identical wording on all four
             * routes — the seed and the C backend cap their error buffers at
             * different sizes otherwise. */
            char msg[128];
            snprintf(msg, sizeof msg, "str_to_int: invalid integer literal '%.*s'",
                     (int)(len < 64 ? len : 64), p);
            astra_llvm_fail(line, msg);
            return 0;
        }
        any = 1;
        uint64_t d = (uint64_t)(c - '0');
        if (acc > ((uint64_t)INT64_MAX - d) / 10) {
            astra_llvm_fail(line, "str_to_int: integer literal is out of range for i64");
            return 0;
        }
        acc = acc * 10 + d;
    }
    if (!any) {
        char msg[128];
        snprintf(msg, sizeof msg, "str_to_int: invalid integer literal '%.*s'",
                 (int)(len < 64 ? len : 64), p);
        astra_llvm_fail(line, msg);
        return 0;
    }
    return neg ? -(int64_t)acc : (int64_t)acc;
}

/* `str_to_int` sobre caja/par (espejo de astra_llvm_ord_fail): la caja es
 * nil/ok/err/some, nunca un string plano, y type_name del VM lo dice. */
void astra_llvm_str_to_int_fail(unsigned line, const void *p) {
    char buf[96];
    snprintf(buf, sizeof buf, "str_to_int expects a string, got %s", astra_llvm_boxed_name(p));
    astra_llvm_fail(line, buf);
}

/* ---- structs (M2.b) ----------------------------------------------------- */

/* Structs are heap handles like arrays (aliasing, Hallazgo G) but printed and
 * compared STRUCTURALLY: the object starts with a pointer to a static layout
 * descriptor the emitter emits per declaration, so print and equality need no
 * static type at the call site (the VM reads s->def the same way):
 *   object: { const AstraLLVMStructDef *def; f0@8; f1@16; … }
 * Every field lives in an 8-byte slot (bool stored as i8 at the slot start),
 * in DECLARATION order — a literal's field order is irrelevant because the
 * emitter stores by declaration index. Descriptor ptypes use the elem codes
 * (1=bool 2=i64 3=f64 4=str 5=boxed 6=array 7=struct). */
typedef struct {
    const char *name;
    int32_t nfields;
    const int32_t *ptypes;
    const char *const *fields;
} AstraLLVMStructDef;

/* VM value_print's struct arm: `Name { f: v, f: v }` (def is always present
 * for objects the emitter builds; the NULL branch mirrors `<struct>`). */
static void astra_llvm_struct_body(const void *p) {
    /* `let p: P` sin inicializador es nil: el VM imprime `nil`. */
    if (!p) { fputs("nil", stdout); return; }
    const AstraLLVMStructDef *def;
    memcpy(&def, p, sizeof def);
    if (!def) { fputs("<struct>", stdout); return; }
    printf("%s { ", def->name);
    const char *base = (const char *)p;
    for (int32_t i = 0; i < def->nfields; i++) {
        if (i > 0) fputs(", ", stdout);
        printf("%s: ", def->fields[i]);
        astra_llvm_elem_print(def->ptypes[i], base + 8 + 8 * (size_t)i);
    }
    fputs(" }", stdout);
}

void astra_llvm_print_struct(const void *p) {
    if (astra_llvm_printed_any++) putchar(' ');
    astra_llvm_struct_body(p);
}

/* print de un valor-función: el VM imprime `<fn>` (value_print VAL_FN) sin
 * mirar el objeto, así que no hace falta desreferenciarlo (puede ser nil). */
void astra_llvm_print_fn(const void *p) {
    (void)p;
    if (astra_llvm_printed_any++) putchar(' ');
    fputs("<fn>", stdout);
}

/* Per-slot equality by ptype, shared by struct fields and boxed payloads:
 * floats by value (NaN != NaN, like VM value_eq), strings by content, boxes
 * recursively, arrays by handle identity (value_eq: pointer), structs by the
 * structural recursion below. */
static int32_t astra_llvm_value_eq_pty(int32_t pty, const char *a, const char *b) {
    switch (pty) {
        case 1: return *(const int8_t *)a == *(const int8_t *)b;
        case 3: { double x, y;
                  memcpy(&x, a, sizeof x); memcpy(&y, b, sizeof y);
                  return x == y; }
        case 4: { const AstraLLVMStr *x, *y;
                  memcpy(&x, a, sizeof x); memcpy(&y, b, sizeof y);
                  return astra_llvm_str_eq(x, y) ? 1 : 0; }
        case 5: { const void *x, *y;
                  memcpy(&x, a, sizeof x); memcpy(&y, b, sizeof y);
                  return astra_llvm_boxed_eq(x, y); }
        case 6: { const void *x, *y;
                  memcpy(&x, a, sizeof x); memcpy(&y, b, sizeof y);
                  return astra_llvm_array_eq(x, y); }
        case 7: { const void *x, *y;
                  memcpy(&x, a, sizeof x); memcpy(&y, b, sizeof y);
                  return astra_llvm_struct_eq(x, y); }
        case 8: { const void *x, *y;
                  memcpy(&x, a, sizeof x); memcpy(&y, b, sizeof y);
                  return astra_llvm_enum_eq(x, y); }
        case 9: { const void *x, *y;
                  memcpy(&x, a, sizeof x); memcpy(&y, b, sizeof y);
                  return x == y; }
        default: { int64_t x, y;
                   memcpy(&x, a, sizeof x); memcpy(&y, b, sizeof y);
                   return x == y; }
    }
}

/* VM value_eq's struct arm: same def name + field-by-field value_eq (two
 * distinct objects with equal fields are ==, structs/… — a real VM
 * behaviour, not identity). */
int32_t astra_llvm_struct_eq(const void *pa, const void *pb) {
    if (pa == pb) return 1;
    if (!pa || !pb) return 0;
    const AstraLLVMStructDef *da, *db;
    memcpy(&da, pa, sizeof da);
    memcpy(&db, pb, sizeof db);
    if (!da || !db) return 0;
    if (strcmp(da->name, db->name) != 0 || da->nfields != db->nfields) return 0;
    for (int32_t i = 0; i < da->nfields; i++) {
        if (!astra_llvm_value_eq_pty(da->ptypes[i],
                (const char *)pa + 8 + 8 * (size_t)i,
                (const char *)pb + 8 + 8 * (size_t)i))
            return 0;
    }
    return 1;
}

/* ---- enums (M2.c) ------------------------------------------------------- */

/* Like structs, enum values are heap handles with a static descriptor the
 * emitter emits per declaration — but with a `kind` that mirrors the VM's
 * two kinds (vm.c value_eq): the emitter's `Enum.Variant` value access and
 * match patterns are VAL_ENUM (names only, no payload), while `Variant(x)`
 * builds VAL_ENUM_DATA (structural, payloads compared). The object is
 *   { const AstraLLVMEnumDef *def; int32 variant; int32 kind; <payload@16> }
 * kind 0 = payload-less name object (eq by names), kind 1 = data object (eq
 * by names + payload slots by ptype). Payload slots are 8 bytes, from 16. */
typedef struct {
    const char *name;
    int32_t npayload;
    const int32_t *ptypes; /* [npayload]; read only when npayload > 0 */
} AstraLLVMVariantDef;

typedef struct {
    const char *name;
    int32_t nvariants;
    const AstraLLVMVariantDef *variants;
} AstraLLVMEnumDef;

/* VM value_print: VAL_ENUM → `Enum.Variant`; VAL_ENUM_DATA → the same plus
 * `(p)` / `(p1, p2)` when the variant carries payload. */
static void astra_llvm_enum_body(const void *p) {
    /* `let e: C` sin inicializador es nil: el VM imprime `nil`. */
    if (!p) { fputs("nil", stdout); return; }
    const AstraLLVMEnumDef *def;
    int32_t vi, kind;
    memcpy(&def, p, sizeof def);
    memcpy(&vi, (const char *)p + 8, sizeof vi);
    memcpy(&kind, (const char *)p + 12, sizeof kind);
    if (!def || vi < 0 || vi >= def->nvariants) { fputs("?", stdout); return; }
    printf("%s.%s", def->name, def->variants[vi].name);
    const int32_t np = def->variants[vi].npayload;
    if (kind == 1 && np > 0) {
        const char *base = (const char *)p;
        fputc('(', stdout);
        for (int32_t i = 0; i < np; i++) {
            if (i > 0) fputs(", ", stdout);
            astra_llvm_elem_print(def->variants[vi].ptypes[i], base + 16 + 8 * (size_t)i);
        }
        fputc(')', stdout);
    }
}

void astra_llvm_print_enum(const void *p) {
    if (astra_llvm_printed_any++) putchar(' ');
    astra_llvm_enum_body(p);
}

/* VM value_eq across the two kinds: same enum name + same variant name;
 * payload comparison only when BOTH sides are data (kind 1). A kind-0 side
 * has no payload to compare — this is what makes a pattern constant match
 * any data value of its variant and `Shape.Circle == Circle(2.5)` true. */
int32_t astra_llvm_enum_eq(const void *pa, const void *pb) {
    if (pa == pb) return 1;
    if (!pa || !pb) return 0;
    const AstraLLVMEnumDef *da, *db;
    int32_t va, vb, ka, kb;
    memcpy(&da, pa, sizeof da);
    memcpy(&db, pb, sizeof db);
    memcpy(&va, (const char *)pa + 8, sizeof va);
    memcpy(&vb, (const char *)pb + 8, sizeof vb);
    memcpy(&ka, (const char *)pa + 12, sizeof ka);
    memcpy(&kb, (const char *)pb + 12, sizeof kb);
    if (!da || !db || va != vb) return 0;
    if (strcmp(da->name, db->name) != 0) return 0;
    if (ka == 0 || kb == 0) return 1; /* cross-kind: names only */
    const AstraLLVMVariantDef *v = &da->variants[va];
    for (int32_t i = 0; i < v->npayload; i++) {
        if (!astra_llvm_value_eq_pty(v->ptypes[i],
                (const char *)pa + 16 + 8 * (size_t)i,
                (const char *)pb + 16 + 8 * (size_t)i))
            return 0;
    }
    return 1;
}

/* ---- object destruction (refcount reaches zero) ------------------------ */

/* Layout of a closure object (M1.d + refcount): code@0, env@8, the capture
 * ptypes array@16 and ncaps@24. The ptypes are needed to release the values
 * snapshotted in the env; named functions have ncaps = 0. */
typedef struct {
    void *code;
    void *env;
    const int32_t *cap_ptypes;
    int32_t ncaps;
} AstraLLVMFnObj;

/* Libera un slot que contiene un puntero según el código ptype del runtime
 * (4=str 5=boxed 6=array 7=struct 8=enum 9=fn). Los escalares (1/2/3) no
 * poseen nada. */
static void astra_llvm_release_slot(int32_t pty, const char *slot) {
    if (pty < 4 || pty > 9) return;
    void *child;
    memcpy(&child, slot, sizeof child);
    astra_llvm_release(child);
}

/* ---- copy (DEC-027, fase E2): deep structural copy ----
 *
 * Kind-driven walk (mirror of the destructor): fresh objects at rc=1 with
 * interior nodes parent-owned — unlike array_push, whose elements are
 * SHARED with the old array and therefore retained. Strings are immutable:
 * retain + same pointer. Depth-capped because cycles are constructible
 * (`n.kid = some(n)`); the wording matches vm.c / codegen_runtime.h byte
 * for byte. `p == NULL` is `none`/`nil` (no header — never touch the hdr).
 */
#define ASTRA_LLVM_COPY_MAX_DEPTH 64

static void *astra_llvm_copy_d(unsigned line, const void *p, int depth) {
    if (depth > ASTRA_LLVM_COPY_MAX_DEPTH)
        astra_llvm_fail(line, "copy depth limit exceeded");
    if (!p) return NULL;
    const AstraLLVMHdr *h = astra_llvm_hdr(p);
    switch (h->kind) {
    case ASTRA_LLVM_KIND_STR:
        astra_llvm_retain((void *)p);
        return (void *)p;
    case ASTRA_LLVM_KIND_BOX: {
        AstraLLVMBox b;
        memcpy(&b, p, sizeof b);
        AstraLLVMBox *nb = (AstraLLVMBox *)astra_llvm_alloc(line, sizeof b, ASTRA_LLVM_KIND_BOX);
        nb->tag = b.tag;
        nb->ptype = b.ptype;
        nb->payload = b.payload;
        if (b.ptype >= 4 && b.ptype <= 9)
            nb->payload = (int64_t)(intptr_t)astra_llvm_copy_d(line, (void *)(intptr_t)b.payload, depth + 1);
        return nb;
    }
    case ASTRA_LLVM_KIND_ARR: {
        int64_t len;
        int32_t pty;
        memcpy(&len, p, sizeof len);
        memcpy(&pty, (const char *)p + 8, sizeof pty);
        const int slot = astra_llvm_arr_slot(pty);
        void *np = astra_llvm_alloc(line, ASTRA_LLVM_ARR_HDR + (int64_t)slot * len, ASTRA_LLVM_KIND_ARR);
        memcpy(np, &len, sizeof len);
        memcpy((char *)np + 8, &pty, sizeof pty);
        for (int64_t i = 0; i < len; i++) {
            const char *src = (const char *)p + ASTRA_LLVM_ARR_HDR + (size_t)slot * (size_t)i;
            char *dst = (char *)np + ASTRA_LLVM_ARR_HDR + (size_t)slot * (size_t)i;
            if (pty <= 3) {
                memcpy(dst, src, (size_t)slot);
            } else {
                void *child = astra_llvm_copy_d(line, *(void *const *)src, depth + 1);
                memcpy(dst, &child, sizeof child);
            }
        }
        return np;
    }
    case ASTRA_LLVM_KIND_STRUCT: {
        const AstraLLVMStructDef *def;
        memcpy(&def, p, sizeof def);
        if (!def) return (void *)p;
        void *np = astra_llvm_alloc(line, 8 + 8 * (int64_t)def->nfields, ASTRA_LLVM_KIND_STRUCT);
        memcpy(np, &def, sizeof def);
        for (int32_t i = 0; i < def->nfields; i++) {
            const char *src = (const char *)p + 8 + 8 * (size_t)i;
            char *dst = (char *)np + 8 + 8 * (size_t)i;
            if (def->ptypes[i] <= 3) {
                memcpy(dst, src, 8);
            } else {
                void *child = astra_llvm_copy_d(line, *(void *const *)src, depth + 1);
                memcpy(dst, &child, sizeof child);
            }
        }
        return np;
    }
    case ASTRA_LLVM_KIND_ENUM: {
        const AstraLLVMEnumDef *def;
        int32_t vi, vkind;
        memcpy(&def, p, sizeof def);
        memcpy(&vi, (const char *)p + 8, sizeof vi);
        memcpy(&vkind, (const char *)p + 12, sizeof vkind);
        if (!def || vi < 0 || vi >= def->nvariants || vkind != 1) {
            /* Unit variant: share the object (its own rc tracks the owners). */
            astra_llvm_retain((void *)p);
            return (void *)p;
        }
        const AstraLLVMVariantDef *v = &def->variants[vi];
        void *np = astra_llvm_alloc(line, 16 + 8 * (int64_t)v->npayload, ASTRA_LLVM_KIND_ENUM);
        memcpy(np, &def, sizeof def);
        memcpy((char *)np + 8, &vi, sizeof vi);
        memcpy((char *)np + 12, &vkind, sizeof vkind);
        for (int32_t i = 0; i < v->npayload; i++) {
            const char *src = (const char *)p + 16 + 8 * (size_t)i;
            char *dst = (char *)np + 16 + 8 * (size_t)i;
            if (v->ptypes[i] <= 3) {
                memcpy(dst, src, 8);
            } else {
                void *child = astra_llvm_copy_d(line, *(void *const *)src, depth + 1);
                memcpy(dst, &child, sizeof child);
            }
        }
        return np;
    }
    case ASTRA_LLVM_KIND_FN: {
        const AstraLLVMFnObj *f = (const AstraLLVMFnObj *)p;
        AstraLLVMFnObj *g = (AstraLLVMFnObj *)astra_llvm_alloc(line, sizeof(AstraLLVMFnObj), ASTRA_LLVM_KIND_FN);
        g->code = f->code;
        g->cap_ptypes = f->cap_ptypes;
        g->ncaps = f->ncaps;
        g->env = NULL;
        if (f->env && f->ncaps > 0 && f->cap_ptypes) {
            void *nenv = astra_llvm_alloc(line, 8 * (int64_t)f->ncaps, ASTRA_LLVM_KIND_ENV);
            for (int32_t i = 0; i < f->ncaps; i++) {
                const char *src = (const char *)f->env + 8 * (size_t)i;
                char *dst = (char *)nenv + 8 * (size_t)i;
                if (f->cap_ptypes[i] <= 3) {
                    memcpy(dst, src, 8);
                } else {
                    void *child = astra_llvm_copy_d(line, *(void *const *)src, depth + 1);
                    memcpy(dst, &child, sizeof child);
                }
            }
            g->env = nenv;
        }
        return g;
    }
    case ASTRA_LLVM_KIND_ENV:
        /* The env is only reached through FN (copied there). */
        astra_llvm_retain((void *)p);
        return (void *)p;
    default:
        return (void *)p;
    }
}

void *astra_llvm_copy(unsigned line, const void *p) {
    return astra_llvm_copy_d(line, p, 0);
}

static void astra_llvm_destroy(int32_t kind, void *p) {
    switch (kind) {
        case ASTRA_LLVM_KIND_STR:
        case ASTRA_LLVM_KIND_ENV:
            /* La cadena no posee nada; el env ya liberó sus capturas en el
             * destructor del closure (evita liberarlas dos veces). */
            break;
        case ASTRA_LLVM_KIND_BOX: {
            const AstraLLVMBox *b = (const AstraLLVMBox *)p;
            if (b->ptype >= 4 && b->ptype <= 9)
                astra_llvm_release((void *)(intptr_t)b->payload);
            break;
        }
        case ASTRA_LLVM_KIND_ARR: {
            int64_t len;
            int32_t pty;
            memcpy(&len, p, sizeof len);
            memcpy(&pty, (const char *)p + 8, sizeof pty);
            const int slot = astra_llvm_arr_slot(pty);
            for (int64_t i = 0; i < len; i++)
                astra_llvm_release_slot(pty, (const char *)p + ASTRA_LLVM_ARR_HDR + (size_t)slot * (size_t)i);
            break;
        }
        case ASTRA_LLVM_KIND_STRUCT: {
            const AstraLLVMStructDef *def;
            memcpy(&def, p, sizeof def);
            if (!def) break;
            for (int32_t i = 0; i < def->nfields; i++)
                astra_llvm_release_slot(def->ptypes[i], (const char *)p + 8 + 8 * (size_t)i);
            break;
        }
        case ASTRA_LLVM_KIND_ENUM: {
            const AstraLLVMEnumDef *def;
            int32_t vi, vkind;
            memcpy(&def, p, sizeof def);
            memcpy(&vi, (const char *)p + 8, sizeof vi);
            memcpy(&vkind, (const char *)p + 12, sizeof vkind);
            if (!def || vi < 0 || vi >= def->nvariants || vkind != 1) break;
            const AstraLLVMVariantDef *v = &def->variants[vi];
            for (int32_t i = 0; i < v->npayload; i++)
                astra_llvm_release_slot(v->ptypes[i], (const char *)p + 16 + 8 * (size_t)i);
            break;
        }
        case ASTRA_LLVM_KIND_FN: {
            const AstraLLVMFnObj *f = (const AstraLLVMFnObj *)p;
            if (f->env) {
                if (f->cap_ptypes) {
                    for (int32_t i = 0; i < f->ncaps; i++)
                        astra_llvm_release_slot(f->cap_ptypes[i], (const char *)f->env + 8 * (size_t)i);
                }
                astra_llvm_release(f->env);
            }
            break;
        }
        default:
            break;
    }
}
