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
        case 2: printf("%ld", (long)b->payload); break;
        case 3: { double d; memcpy(&d, &b->payload, sizeof d); printf("%g", d); break; }
        case 4: { const AstraLLVMStr *s = (const AstraLLVMStr *)b->payload;
                  fwrite(s->data, 1, (size_t)s->len, stdout); break; }
        case 5: astra_llvm_boxed_body((const void *)b->payload); break;
        case 6: astra_llvm_array_body((const void *)b->payload); break;
        case 7: astra_llvm_struct_body((const void *)b->payload); break;
        case 8: astra_llvm_enum_body((const void *)b->payload); break;
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
 * 1=bool 2=i64 3=f64 4=str 5=boxed 6=array. `==` is pointer identity (VM
 * value_eq: a.as.array_val == b.as.array_val) and ordering is rejected by the
 * emitter ("cannot compare array and array"), so no cmp lives here. */
#define ASTRA_LLVM_ARR_HDR 16

static int astra_llvm_arr_slot(int32_t pty) { return pty == 1 ? 1 : 8; }

static void astra_llvm_elem_print(int32_t pty, const char *slot);

static void astra_llvm_array_body(const void *p) {
    if (!p) { fputs("[]", stdout); return; } /* VM prints a NULL array as [] */
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
        case 2: { int64_t v; memcpy(&v, slot, sizeof v); printf("%ld", (long)v); break; }
        case 3: { double d; memcpy(&d, slot, sizeof d); printf("%g", d); break; }
        case 4: { const AstraLLVMStr *s; memcpy(&s, slot, sizeof s);
                  fwrite(s->data, 1, (size_t)s->len, stdout); break; }
        case 5: { const void *b; memcpy(&b, slot, sizeof b); astra_llvm_boxed_body(b); break; }
        case 6: { const void *a; memcpy(&a, slot, sizeof a); astra_llvm_array_body(a); break; }
        case 7: { const void *s; memcpy(&s, slot, sizeof s); astra_llvm_struct_body(s); break; }
        case 8: { const void *e; memcpy(&e, slot, sizeof e); astra_llvm_enum_body(e); break; }
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
    for (int64_t i = 0; i < la; i++) {
        if (!astra_llvm_value_eq_pty(ea,
                (const char *)pa + 16 + 8 * (size_t)i,
                (const char *)pb + 16 + 8 * (size_t)i))
            return 0;
    }
    return 1;
}

/* Bounds check (VM OPCODE_INDEX & OPCODE_INDEX_SET): fatal
 * `index i out of bounds (len n)` with file:line. The happy path is an inline
 * icmp + load/store in the IR; only the failing arm calls here. */
void astra_llvm_index_fail(unsigned line, int64_t idx, int64_t len) {
    char buf[96];
    snprintf(buf, sizeof buf, "index %ld out of bounds (len %ld)",
             (long)idx, (long)len);
    astra_llvm_fail(line, buf);
}

/* Nil receiver (VM OPCODE_INDEX): `let a: [i32]` with no initializer is nil
 * (NULL in this model), and `a[i]` must report `cannot index nil` — the same
 * guard audit §5.3 added to the C backend — instead of GEPping NULL. */
void astra_llvm_index_nil_fail(unsigned line) {
    astra_llvm_fail(line, "cannot index nil");
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
    if (!p) { fputs("?", stdout); return; }
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
