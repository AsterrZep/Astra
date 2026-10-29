#include "priv.h"
#include "codegen.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

/* -----------------------------------------------------------
 * Codegen context
 * ----------------------------------------------------------- */

struct Codegen {
    Node        *module;
    Emitter     *emitter;
    const char  *filename;

    /* Output buffer */
    char        *buf;
    size_t       buf_len;
    size_t       buf_cap;

    /* Function registry: maps function name to generated C function name */
    struct { InternedString name; const char *c_name; } fn_map[512];
    size_t fn_map_count;

    /* Global variable registry */
    struct { InternedString name; const char *c_name; } global_map[256];
    size_t global_map_count;

    /* Struct/enum info borrowed from emitter */
    StructInfo  *structs;
    size_t       struct_count;
    EnumInfo    *enums;
    size_t       enum_count;

    /* Struct def registry: maps StructDef pointer to generated C name */
    struct { const StructDef *def; const char *c_name; } struct_defs[256];
    size_t struct_def_count;

    /* Enum def registry: maps EnumDef pointer to generated C name */
    struct { const EnumDef *def; const char *c_name; } enum_defs[256];
    size_t enum_def_count;

    /* Lambda/non-builtin FnObj registry: maps FnObj pointer to generated C name */
    struct { const FnObj *fn; const char *c_name; uint8_t param_count; } fn_obj_reg[512];
    size_t fn_obj_reg_count;

    /* Name registries above are fixed-size. A breach is recorded here and fails
     * the run; it must never index past a registry (see make_fn_cname /
     * make_global_cname). */
    size_t error_count;
};

/* -----------------------------------------------------------
 * Output buffer helpers
 * ----------------------------------------------------------- */

static void cg_ensure(Codegen *cg, size_t extra) {
    if (cg->buf_len + extra + 1 >= cg->buf_cap) {
        size_t new_cap = cg->buf_cap ? cg->buf_cap * 2 : 32768;
        while (new_cap < cg->buf_len + extra + 1) new_cap *= 2;
        cg->buf = realloc(cg->buf, new_cap);
        cg->buf_cap = new_cap;
    }
}

static void cg_write(Codegen *cg, const char *s) {
    size_t len = strlen(s);
    cg_ensure(cg, len);
    memcpy(cg->buf + cg->buf_len, s, len);
    cg->buf_len += len;
    cg->buf[cg->buf_len] = '\0';
}

static void cg_writef(Codegen *cg, const char *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    char tmp[2048];
    vsnprintf(tmp, sizeof(tmp), fmt, args);
    va_end(args);
    cg_write(cg, tmp);
}

/* Write a source string as the *body* of a generated C string literal. Astra
 * string data reaches codegen as a NUL-terminated byte sequence, so length
 * stays strlen-based; what this guards is that a quote, backslash or control
 * byte cannot close the literal early and inject arbitrary C into the output
 * (the generated .c is handed to a native compiler). */
static void cg_write_c_escaped(Codegen *cg, const char *s, size_t len) {
    for (size_t i = 0; s && i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '"' || c == '\\') {
            char esc[3] = { '\\', (char)c, '\0' };
            cg_write(cg, esc);
        } else if (c < 0x20 || c == 0x7f) {
            /* Three octal digits: never merges with a following literal char
             * (covers a NUL byte inside the literal, audit §2.14). */
            cg_writef(cg, "\\%03o", (unsigned)c);
        } else {
            char lit[2] = { (char)c, '\0' };
            cg_write(cg, lit);
        }
    }
}

/* Opcodes whose execution can raise a runtime error. Each such instruction
 * is annotated with its source line (astra_line) before it runs, so the C
 * runtime reports `file:line: runtime error: ...` like the VM's driver. */
static bool opcode_is_fallible(OpCode op) {
    switch (op) {
    case OPCODE_ADD: case OPCODE_SUB: case OPCODE_MUL: case OPCODE_DIV:
    case OPCODE_MOD: case OPCODE_NEG:
    case OPCODE_LT: case OPCODE_GT: case OPCODE_LE: case OPCODE_GE:
    case OPCODE_BIT_AND: case OPCODE_BIT_OR: case OPCODE_BIT_XOR:
    case OPCODE_SHL: case OPCODE_SHR: case OPCODE_BIT_NOT:
    case OPCODE_INDEX: case OPCODE_SET_INDEX:
    case OPCODE_LEN:
    case OPCODE_GET_FIELD: case OPCODE_SET_FIELD:
    case OPCODE_CALL: case OPCODE_TRY_UNWRAP:
    case OPCODE_MATCH_NONE:
        return true;
    default:
        return false;
    }
}

/* Value of the `last_line` dedup shadow meaning "the global astra_line does
 * NOT hold our line": nothing stored yet, or a call may have overwritten it.
 * No real source line equals it, so the next fallible op re-stores astra_line. */
#define CG_NO_LINE ((unsigned)-1)

/* Emits `astra_line = <line>;` only when the line changed: consecutive
 * fallible instructions from the same source line share one store. */
static void cg_set_line(Codegen *cg, unsigned *last_line, unsigned line) {
    if (line == *last_line) return;
    cg_writef(cg, "    astra_line = %u;\n", line);
    *last_line = line;
}

/* -----------------------------------------------------------
 * Name generation
 * ----------------------------------------------------------- */

/* Encode a source (or mangled) name as a C identifier fragment: `_` doubles
 * to `__`, every other non-[A-Za-z0-9] byte becomes `_` plus two lowercase
 * hex digits. The encoding is injective, so `f<[?i32]>` and `f<?[i32]>` —
 * which a one-char-per-char mapping collapsed onto the same `f__i32_` —
 * stay distinct, and so do the pre-existing method-global collisions
 * (`A.b_c` vs `A_b.c`). `dst` must have room for 3 * src_n + 1 bytes. */
static void cg_encode_ident(char *dst, const char *src, size_t src_n) {
    static const char hex[] = "0123456789abcdef";
    char *d = dst;
    for (size_t i = 0; i < src_n; i++) {
        unsigned char c = (unsigned char)src[i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9')) {
            *d++ = (char)c;
        } else if (c == '_') {
            *d++ = '_';
            *d++ = '_';
        } else {
            *d++ = '_';
            *d++ = hex[c >> 4];
            *d++ = hex[c & 0xf];
        }
    }
    *d = '\0';
}

static const char *make_fn_cname(Codegen *cg, InternedString name) {
    /* Check if already registered */
    for (size_t i = 0; i < cg->fn_map_count; i++) {
        if (cg->fn_map[i].name.str == name.str)
            return cg->fn_map[i].c_name;
    }
    if (cg->fn_map_count >= 512) {
        cg->error_count++;
        return NULL;
    }
    /* Generate: astra_fn_<encoded name> */
    size_t len = name.len * 3 + 16;
    char *buf = malloc(len);
    if (!buf) {
        cg->error_count++;
        return NULL;
    }
    snprintf(buf, len, "astra_fn_");
    cg_encode_ident(buf + 9, name.str, name.len);
    cg->fn_map[cg->fn_map_count].name = name;
    cg->fn_map[cg->fn_map_count].c_name = buf;
    cg->fn_map_count++;
    return buf;
}

static const char *make_global_cname(Codegen *cg, InternedString name) {
    for (size_t i = 0; i < cg->global_map_count; i++) {
        if (cg->global_map[i].name.str == name.str)
            return cg->global_map[i].c_name;
    }
    if (cg->global_map_count >= 256) {
        cg->error_count++;
        return NULL;
    }
    size_t len = name.len * 3 + 16;
    char *buf = malloc(len);
    if (!buf) {
        cg->error_count++;
        return NULL;
    }
    snprintf(buf, len, "g_");
    cg_encode_ident(buf + 2, name.str, name.len);
    cg->global_map[cg->global_map_count].name = name;
    cg->global_map[cg->global_map_count].c_name = buf;
    cg->global_map_count++;
    return buf;
}

/* -----------------------------------------------------------
 * Builtin table (research/028 §2.1 / PR1)
 * -----------------------------------------------------------
 * Every builtin exposed as a global `g_<name>` plus the runtime function
 * behind it (codegen_runtime.h). The sites that used to hardcode `print` —
 * the init function, the init call in main — walk this table, so a new
 * builtin is one row plus its `astra_builtin_*` implementation. The generic
 * CALL dispatch (fun(args, argc)) needs no change: the per-builtin function
 * pointer already lives in the AstraFn constant. */
typedef struct {
    const char *name;  /* Astra-level builtin name */
    const char *impl;  /* C function in codegen_runtime.h */
} BuiltinDef;

static const BuiltinDef cg_builtins[] = {
    { "print",     "astra_builtin_print"     },
    { "len",       "astra_builtin_len"       },
    { "to_string", "astra_builtin_to_string" },
    { "read_file", "astra_builtin_read_file" },
    { "ord",       "astra_builtin_ord"       },
    { "substr",    "astra_builtin_substr"    },
    { "push",      "astra_builtin_push"      },
    { "str_to_int","astra_builtin_str_to_int"},
    { "chr",       "astra_builtin_chr"       },
    { "read_line", "astra_builtin_read_line" },
    { "copy",      "astra_builtin_copy"      },
};

static const BuiltinDef *find_builtin(const char *name) {
    if (!name) return NULL;
    for (size_t i = 0; i < sizeof(cg_builtins) / sizeof(cg_builtins[0]); i++) {
        if (strcmp(name, cg_builtins[i].name) == 0) return &cg_builtins[i];
    }
    return NULL;
}

/* -----------------------------------------------------------
 * FnObj registry helpers (lambdas and non-builtin FnObjs)
 * ----------------------------------------------------------- */

static const char *register_fn_obj(Codegen *cg, const FnObj *fn) {
    if (!fn) return NULL;
    for (size_t i = 0; i < cg->fn_obj_reg_count; i++) {
        if (cg->fn_obj_reg[i].fn == fn) return cg->fn_obj_reg[i].c_name;
    }
    if (cg->fn_obj_reg_count >= 512) return "astra_too_many_fns";
    size_t idx = cg->fn_obj_reg_count;
    char *buf = malloc(32);
    snprintf(buf, 32, "astra_lambda_%zu", idx);
    cg->fn_obj_reg[idx].fn = fn;
    cg->fn_obj_reg[idx].c_name = buf;
    cg->fn_obj_reg[idx].param_count = fn->param_count;
    cg->fn_obj_reg_count++;
    return buf;
}

static const char *find_fn_obj_cname(Codegen *cg, const FnObj *fn) {
    if (!fn) return NULL;
    for (size_t i = 0; i < cg->fn_obj_reg_count; i++) {
        if (cg->fn_obj_reg[i].fn == fn) return cg->fn_obj_reg[i].c_name;
    }
    return NULL;
}

/* Recursively scan constants for non-builtin, non-named FnObjs (lambdas).
 * Named functions (CONST + SET_GLOBAL at module level) are excluded. */
static void scan_lambda_fns(Codegen *cg, const Value *constants, size_t const_len,
                             const bool *named_mask) {
    for (size_t i = 0; i < const_len; i++) {
        if (constants[i].kind == VAL_FN && constants[i].as.fn_val) {
            FnObj *fn = constants[i].as.fn_val;
            if (fn->param_count == 255 && fn->code == NULL) continue;
            if (!named_mask || !named_mask[i]) {
                register_fn_obj(cg, fn);
            }
            /* Recurse into nested FnObj constants (finds lambdas inside lambdas) */
            scan_lambda_fns(cg, fn->constants, fn->const_len, NULL);
        }
    }
}

static void scan_all_lambda_fns(Codegen *cg) {
    size_t code_len = 0;
    const Instruction *code = emitter_get_code(cg->emitter, &code_len);
    size_t const_len = 0;
    const Value *constants = emitter_get_constants(cg->emitter, &const_len);

    /* Build mask of named FnObjs (CONST + SET_GLOBAL at module level) */
    bool *named_mask = const_len > 0 ? calloc(const_len, sizeof(bool)) : NULL;
    for (size_t i = 0; i < code_len - 1; i++) {
        if (code[i].op == OPCODE_CONST && code[i+1].op == OPCODE_SET_GLOBAL) {
            uint32_t fn_idx = code[i].arg.index;
            if (fn_idx < const_len && constants[fn_idx].kind == VAL_FN) {
                named_mask[fn_idx] = true;
            }
        }
    }

    scan_lambda_fns(cg, constants, const_len, named_mask);
    free(named_mask);
}

/* -----------------------------------------------------------
 * Forward declaration: emit code for one function
 * ----------------------------------------------------------- */
static void emit_fn_body(Codegen *cg, const char *c_name, FnObj *fn);

/* -----------------------------------------------------------
 * Emit struct type definitions
 * ----------------------------------------------------------- */

static void emit_struct_decls(Codegen *cg) {
    Emitter *e = cg->emitter;
    for (size_t i = 0; i < e->struct_count; i++) {
        StructInfo *si = &e->structs[i];
        const char *name = si->name.str;
        cg_writef(cg, "typedef struct AstraStruct_%s AstraStruct_%s;\n", name, name);
        cg_writef(cg, "struct AstraStruct_%s {\n", name);
        cg_write(cg, "    AstraTag _tag;\n");
        cg_write(cg, "    const char *_type_name;\n");
        for (size_t j = 0; j < si->field_count; j++) {
            cg_writef(cg, "    AstraValue %.*s;\n",
                      (int)si->fields[j].len, si->fields[j].str);
        }
        cg_write(cg, "};\n\n");
    }
}

/* -----------------------------------------------------------
 * Emit enum type definitions
 * ----------------------------------------------------------- */

static void emit_enum_decls(Codegen *cg) {
    Emitter *e = cg->emitter;
    for (size_t i = 0; i < e->enum_count; i++) {
        EnumInfo *ei = &e->enums[i];
        const char *name = ei->name.str;

        /* Tag enum */
        cg_writef(cg, "typedef enum {\n");
        for (size_t j = 0; j < ei->variant_count; j++) {
            cg_writef(cg, "    %s_%.*s = %zu",
                      name, (int)ei->variants[j].len, ei->variants[j].str, j);
            if (j < ei->variant_count - 1) cg_write(cg, ",");
            cg_write(cg, "\n");
        }
        cg_writef(cg, "} %s_Tag;\n\n", name);

        /* Enum struct */
        cg_writef(cg, "typedef struct {\n");
        cg_writef(cg, "    %s_Tag tag;\n", name);
        /* Payload union: only if any variant has fields */
        bool has_payload = false;
        for (size_t j = 0; j < ei->variant_count; j++) {
            if (ei->field_counts[j] > 0) { has_payload = true; break; }
        }
        if (has_payload) {
            cg_write(cg, "    union {\n");
            for (size_t j = 0; j < ei->variant_count; j++) {
                if (ei->field_counts[j] == 0) continue;
                cg_writef(cg, "        struct { ");
                for (uint32_t k = 0; k < ei->field_counts[j]; k++) {
                    cg_writef(cg, "AstraValue v%u; ", k);
                }
                cg_writef(cg, "} %.*s;\n", (int)ei->variants[j].len, ei->variants[j].str);
            }
            cg_write(cg, "    } payload;\n");
        }
        cg_writef(cg, "} AstraEnum_%s;\n\n", name);
    }
}

/* -----------------------------------------------------------
 * Register and emit struct defs as static globals
 * ----------------------------------------------------------- */

static const char *register_struct_def(Codegen *cg, const StructDef *def) {
    /* Check if already registered */
    for (size_t i = 0; i < cg->struct_def_count; i++) {
        if (cg->struct_defs[i].def == def) return cg->struct_defs[i].c_name;
    }
    /* Register new struct def */
    if (cg->struct_def_count >= 256) return NULL;
    char *cname = (char *)malloc(64);
    snprintf(cname, 64, "g_structdef_%zu", cg->struct_def_count);
    cg->struct_defs[cg->struct_def_count].def = def;
    cg->struct_defs[cg->struct_def_count].c_name = cname;
    cg->struct_def_count++;
    return cname;
}

static void emit_struct_def_globals(Codegen *cg) {
    for (size_t i = 0; i < cg->struct_def_count; i++) {
        const StructDef *def = cg->struct_defs[i].def;
        const char *cname = cg->struct_defs[i].c_name;
        /* Emit field names array */
        cg_writef(cg, "static const char *%s_field_names[] = { ", cname);
        for (size_t j = 0; j < def->field_count; j++) {
            cg_writef(cg, "\"%s\"", def->field_names[j]);
            if (j < def->field_count - 1) cg_write(cg, ", ");
        }
        cg_write(cg, " };\n");
        /* Emit StructDef global */
        cg_writef(cg, "static const AstraStructDef %s = { \"%s\", %s_field_names, %zu };\n\n",
                  cname, def->name ? def->name : "?", cname, def->field_count);
    }
}

/* -----------------------------------------------------------
 * Register and emit enum defs as static globals
 * ----------------------------------------------------------- */

static const char *register_enum_def(Codegen *cg, const EnumDef *def) {
    if (!def) return NULL;
    for (size_t i = 0; i < cg->enum_def_count; i++) {
        if (cg->enum_defs[i].def == def) return cg->enum_defs[i].c_name;
    }
    if (cg->enum_def_count >= 256) return NULL;
    char *cname = (char *)malloc(64);
    snprintf(cname, 64, "g_enumdef_%zu", cg->enum_def_count);
    cg->enum_defs[cg->enum_def_count].def = def;
    cg->enum_defs[cg->enum_def_count].c_name = cname;
    cg->enum_def_count++;
    return cname;
}

/* No forward declarations are needed for enum defs: unlike struct defs, they
 * are emitted before every function body, so nothing can reference an
 * undefined `g_enumdef_N`. */
static void emit_enum_def_globals(Codegen *cg) {
    /* We need the C runtime to have an EnumDef struct. Since codegen_runtime.h
     * doesn't define it, we emit a compatible layout inline. */
    for (size_t i = 0; i < cg->enum_def_count; i++) {
        const EnumDef *def = cg->enum_defs[i].def;
        const char *cname = cg->enum_defs[i].c_name;
        /* Emit variant names array */
        cg_writef(cg, "static const char *%s_variant_names[] = { ", cname);
        for (size_t j = 0; j < def->variant_count; j++) {
            cg_writef(cg, "\"%s\"", def->variants[j].name ? def->variants[j].name : "?");
            if (j < def->variant_count - 1) cg_write(cg, ", ");
        }
        cg_write(cg, " };\n");
        /* Emit field counts array */
        cg_writef(cg, "static const size_t %s_field_counts[] = { ", cname);
        for (size_t j = 0; j < def->variant_count; j++) {
            cg_writef(cg, "%zu", def->variants[j].field_count);
            if (j < def->variant_count - 1) cg_write(cg, ", ");
        }
        cg_write(cg, " };\n");
        /* Emit a simple struct: { name, variant_count, variant_names, field_counts }.
         * We define a local CEnumDef type that matches what the generated code needs. */
        cg_writef(cg, "static const struct { const char *name; size_t variant_count; "
                  "const char **variant_names; const size_t *field_counts; } %s = "
                  "{ \"%s\", %zu, %s_variant_names, %s_field_counts };\n\n",
                  cname, def->name ? def->name : "?", def->variant_count, cname, cname);
    }
}

static void emit_struct_def_fwd_decls(Codegen *cg) {
    for (size_t i = 0; i < cg->struct_def_count; i++) {
        const char *cname = cg->struct_defs[i].c_name;
        cg_writef(cg, "static const AstraStructDef %s;\n", cname);
    }
    if (cg->struct_def_count > 0) cg_write(cg, "\n");
}

/* Scan bytecodes to discover all struct defs upfront */
static void scan_struct_defs(Codegen *cg, const Instruction *code, size_t code_len,
                             const Value *constants, size_t const_len) {
    for (size_t i = 0; i < code_len; i++) {
        if (code[i].op == OPCODE_CONST && code[i].arg.index < const_len) {
            Value v = constants[code[i].arg.index];
            if (v.kind == VAL_STRUCT_DEF) {
                register_struct_def(cg, v.as.struct_def);
            } else if (v.kind == VAL_FN && v.as.fn_val) {
                /* Recurse into nested function constants */
                FnObj *fn = v.as.fn_val;
                scan_struct_defs(cg, fn->code, fn->code_len, fn->constants, fn->const_len);
            }
        } else if (code[i].op == OPCODE_CLOSURE) {
            /* OPCODE_CLOSURE's operand packs (fn_const << 8) | capture_count —
             * the same packing its emission reads (case OPCODE_CLOSURE below).
             * A lambda reached only this way is never a CONST operand, so a
             * struct used solely inside its body registered *during* body
             * emission — after the forward declarations — and gcc reported
             * `g_structdef_0 undeclared` (audit §5.5). Follow it here, at
             * scan time. */
            uint32_t fn_const = code[i].arg.index >> 8;
            if (fn_const < const_len && constants[fn_const].kind == VAL_FN &&
                constants[fn_const].as.fn_val) {
                FnObj *fn = constants[fn_const].as.fn_val;
                scan_struct_defs(cg, fn->code, fn->code_len, fn->constants, fn->const_len);
            }
        }
    }
}

static void scan_all_struct_defs(Codegen *cg) {
    /* Scan module-level code */
    size_t code_len = 0;
    const Instruction *code = emitter_get_code(cg->emitter, &code_len);
    size_t const_len = 0;
    const Value *constants = emitter_get_constants(cg->emitter, &const_len);
    scan_struct_defs(cg, code, code_len, constants, const_len);

    /* Scan module-level constants (may contain FnObjs with nested struct defs) */
    scan_struct_defs(cg, NULL, 0, constants, const_len);
}

/* Scan bytecodes to discover all enum defs upfront */
static void scan_enum_defs(Codegen *cg, const Instruction *code, size_t code_len,
                           const Value *constants, size_t const_len) {
    for (size_t i = 0; i < code_len; i++) {
        if (code[i].op == OPCODE_CONST && code[i].arg.index < const_len) {
            Value v = constants[code[i].arg.index];
            if (v.kind == VAL_ENUM_DEF) {
                register_enum_def(cg, v.as.enum_def);
            } else if (v.kind == VAL_FN && v.as.fn_val) {
                FnObj *fn = v.as.fn_val;
                scan_enum_defs(cg, fn->code, fn->code_len, fn->constants, fn->const_len);
            }
        } else if (code[i].op == OPCODE_CLOSURE) {
            /* Same (fn_const << 8) | capture_count packing as the emission —
             * see scan_struct_defs: a lambda reached only through CLOSURE is
             * never a CONST operand, so an enum used solely inside its body
             * would miss the scan and `g_enumdef_0` would be undeclared at the
             * point the lambda body references it (audit §5.5). */
            uint32_t fn_const = code[i].arg.index >> 8;
            if (fn_const < const_len && constants[fn_const].kind == VAL_FN &&
                constants[fn_const].as.fn_val) {
                FnObj *fn = constants[fn_const].as.fn_val;
                scan_enum_defs(cg, fn->code, fn->code_len, fn->constants, fn->const_len);
            }
        }
    }
}

static void scan_all_enum_defs(Codegen *cg) {
    size_t code_len = 0;
    const Instruction *code = emitter_get_code(cg->emitter, &code_len);
    size_t const_len = 0;
    const Value *constants = emitter_get_constants(cg->emitter, &const_len);
    scan_enum_defs(cg, code, code_len, constants, const_len);
    scan_enum_defs(cg, NULL, 0, constants, const_len);
}

/* -----------------------------------------------------------
 * Emit global variable declarations
 * ----------------------------------------------------------- */

static void emit_global_decls(Codegen *cg) {
    /* Scan module bytecode for SET_GLOBAL instructions to find globals */
    size_t code_len = 0;
    const Instruction *code = emitter_get_code(cg->emitter, &code_len);
    size_t const_len = 0;
    const Value *constants = emitter_get_constants(cg->emitter, &const_len);

    /* Scan module code */
    for (size_t i = 0; i < code_len; i++) {
        if (code[i].op == OPCODE_SET_GLOBAL || code[i].op == OPCODE_GET_GLOBAL) {
            uint32_t name_idx = code[i].arg.index;
            if (name_idx < const_len && constants[name_idx].kind == VAL_STRING) {
                InternedString name = {0};
                name.str = constants[name_idx].as.string_val.str;
                name.len = constants[name_idx].as.string_val.len;
                make_global_cname(cg, name);
            }
        }
    }

    /* Also scan function bytecodes for globals */
    for (size_t i = 0; i < const_len; i++) {
        if (constants[i].kind == VAL_FN && constants[i].as.fn_val) {
            FnObj *fn = constants[i].as.fn_val;
            for (size_t j = 0; j < fn->code_len; j++) {
                if (fn->code[j].op == OPCODE_SET_GLOBAL || fn->code[j].op == OPCODE_GET_GLOBAL) {
                    uint32_t name_idx = fn->code[j].arg.index;
                    if (name_idx < fn->const_len && fn->constants[name_idx].kind == VAL_STRING) {
                        InternedString name = {0};
                        name.str = fn->constants[name_idx].as.string_val.str;
                        name.len = fn->constants[name_idx].as.string_val.len;
                        make_global_cname(cg, name);
                    }
                }
            }
        }
    }

    for (size_t i = 0; i < cg->global_map_count; i++) {
        /* Builtins and ordinary globals share the plain `g_<name>` declaration
         * (for print the old special case wrote exactly this string). */
        cg_writef(cg, "static AstraValue %s;\n", cg->global_map[i].c_name);
    }
    if (cg->global_map_count > 0) cg_write(cg, "\n");

    /* Initialize the builtin globals that this program actually references —
     * one `g_<name>_init()` per table row found in the global map. */
    for (size_t i = 0; i < cg->global_map_count; i++) {
        const BuiltinDef *b = find_builtin(cg->global_map[i].name.str);
        if (b) {
            cg_writef(cg, "static void %s_init(void) { "
                     "%s = astra_builtin_fn_new((AstraFnPtr)%s, 255); }\n",
                     cg->global_map[i].c_name,
                     cg->global_map[i].c_name,
                     b->impl);
        }
    }
    if (cg->global_map_count > 0) cg_write(cg, "\n");
}

/* -----------------------------------------------------------
 * Emit function forward declarations
 * ----------------------------------------------------------- */

static void emit_fn_forward_decls(Codegen *cg) {
    size_t code_len = 0;
    const Instruction *code = emitter_get_code(cg->emitter, &code_len);
    size_t const_len = 0;
    const Value *constants = emitter_get_constants(cg->emitter, &const_len);

    /* Find all FnObj constants and register them */
    for (size_t i = 0; i < const_len; i++) {
        if (constants[i].kind == VAL_FN && constants[i].as.fn_val) {
            /* Find the corresponding name — scan backwards for SET_GLOBAL
             * right after this CONST. Or we can scan all SET_GLOBALs. */
            /* Actually, we need the function name. Let's scan the bytecode
             * for CONST i followed by SET_GLOBAL name_idx. */
            for (size_t j = 0; j < code_len - 1; j++) {
                if (code[j].op == OPCODE_CONST && code[j].arg.index == i &&
                    code[j+1].op == OPCODE_SET_GLOBAL) {
                    uint32_t name_idx = code[j+1].arg.index;
                    if (name_idx < const_len && constants[name_idx].kind == VAL_STRING) {
                        InternedString name = {0};
                        name.str = constants[name_idx].as.string_val.str;
                        name.len = constants[name_idx].as.string_val.len;
                        make_fn_cname(cg, name);
                    }
                    break;
                }
            }
        }
    }

    for (size_t i = 0; i < cg->fn_map_count; i++) {
        cg_writef(cg, "static AstraValue %s(AstraValue*, uint8_t);\n",
                  cg->fn_map[i].c_name);
    }
    if (cg->fn_map_count > 0) cg_write(cg, "\n");
}

/* -----------------------------------------------------------
 * Emit all function bodies
 * ----------------------------------------------------------- */

static void emit_fn_bodies(Codegen *cg) {
    size_t const_len = 0;
    const Value *constants = emitter_get_constants(cg->emitter, &const_len);

    for (size_t i = 0; i < cg->fn_map_count; i++) {
        /* Find the FnObj for this function name */
        InternedString fname = cg->fn_map[i].name;
        const char *cname = cg->fn_map[i].c_name;

        /* Scan bytecode for CONST of FnObj followed by SET_GLOBAL with this name */
        size_t code_len = 0;
        const Instruction *code = emitter_get_code(cg->emitter, &code_len);
        for (size_t j = 0; j < code_len - 1; j++) {
            if (code[j].op == OPCODE_CONST && code[j+1].op == OPCODE_SET_GLOBAL) {
                uint32_t fn_idx = code[j].arg.index;
                uint32_t name_idx = code[j+1].arg.index;
                if (name_idx < const_len && constants[name_idx].kind == VAL_STRING &&
                    strcmp(constants[name_idx].as.string_val.str, fname.str) == 0 &&
                    fn_idx < const_len && constants[fn_idx].kind == VAL_FN) {
                    emit_fn_body(cg, cname, constants[fn_idx].as.fn_val);
                    break;
                }
            }
        }
    }
}

/* -----------------------------------------------------------
 * Emit forward declarations for lambda/non-builtin FnObjs
 * ----------------------------------------------------------- */

static void emit_fnobj_forward_decls(Codegen *cg) {
    for (size_t i = 0; i < cg->fn_obj_reg_count; i++) {
        cg_writef(cg, "static AstraValue %s(AstraValue*, uint8_t);\n",
                  cg->fn_obj_reg[i].c_name);
    }
    if (cg->fn_obj_reg_count > 0) cg_write(cg, "\n");
}

/* -----------------------------------------------------------
 * Emit all lambda/non-builtin FnObj bodies
 * ----------------------------------------------------------- */

static void emit_fnobj_bodies(Codegen *cg) {
    for (size_t i = 0; i < cg->fn_obj_reg_count; i++) {
        emit_fn_body(cg, cg->fn_obj_reg[i].c_name, (FnObj *)cg->fn_obj_reg[i].fn);
    }
}

/* -----------------------------------------------------------
 * Emit a single function body
 * ----------------------------------------------------------- */

/* ---------------------------------------------------------------
 * Shared bytecode -> C instruction emission (PHASE1 section 4bis #32)
 *
 * One switch for both function bodies (emit_fn_body) and module-level
 * code (emit_module_code).  The two used to be parallel copies kept in
 * sync by hand, and that duplication produced four bugs before it was
 * unified (PHASE1_PROGRESS section 3c): module-level POP, module-level
 * bitwise operators, S4's duplicated module emit path, and the missing
 * VAL_STRUCT_DEF handler that made top-level struct literals
 * dereference a NULL definition.
 *
 * Callers differ only in prologue/epilogue (frame setup, max_slot,
 * return expression).  `constants`/`const_len` are parameters because
 * function constants live on the FnObj while module constants live on
 * the emitter; `code` is always the stream being translated.
 * --------------------------------------------------------------- */
static void emit_instructions(Codegen *cg,
                              const Instruction *code, size_t code_len,
                              const Value *constants, size_t const_len,
                              unsigned *last_line) {
    /* First pass: emit labels for jump targets */
    bool *is_label = calloc(code_len, sizeof(bool));
    for (size_t i = 0; i < code_len; i++) {
        switch (code[i].op) {
        case OPCODE_JUMP:
        case OPCODE_JUMP_IF_FALSE:
        case OPCODE_JUMP_IF_TRUE: {
            int32_t target = (int32_t)i + code[i].arg.offset;
            if (target >= 0 && (size_t)target < code_len)
                is_label[target] = true;
        } break;
        default: break;
        }
    }

    /* Second pass: translate bytecode */
    for (size_t ip = 0; ip < code_len; ip++) {
        if (is_label[ip]) {
            cg_writef(cg, "    L_%zu: ;\n", ip);
            /* A label is reachable from several predecessors, so the
             * textually-last `astra_line` store may not have run on this
             * path. Forget the dedup shadow and let the next fallible op
             * re-store its line (see cg_set_line). */
            *last_line = CG_NO_LINE;
        }

        Instruction inst = code[ip];
        if (opcode_is_fallible(inst.op)) cg_set_line(cg, last_line, inst.line);

        switch (inst.op) {
        case OPCODE_CONST: {
            uint32_t idx = inst.arg.index;
            if (idx < const_len) {
                Value v = constants[idx];
                switch (v.kind) {
                case VAL_NIL:
                    cg_writef(cg, "    ASTRA_PUSH(frame, sp, astra_nil());\n");
                    break;
                case VAL_BOOL:
                    cg_writef(cg, "    ASTRA_PUSH(frame, sp, astra_bool(%s));\n",
                              v.as.bool_val ? "1" : "0");
                    break;
                case VAL_INT:
                    cg_writef(cg, "    ASTRA_PUSH(frame, sp, astra_int(%ldL));\n",
                              (long)v.as.int_val);
                    break;
                case VAL_FLOAT:
                    cg_writef(cg, "    ASTRA_PUSH(frame, sp, astra_float(%g));\n",
                              v.as.float_val);
                    break;
                case VAL_STRING:
                    cg_write(cg, "    ASTRA_PUSH(frame, sp, astra_string_new(\"");
                    cg_write_c_escaped(cg, v.as.string_val.str, v.as.string_val.len);
                    cg_writef(cg, "\", %ld));\n", (long)v.as.string_val.len);
                    break;
                case VAL_FN: {
                    FnObj *fn_obj = v.as.fn_val;
                    /* Builtin markers never reach the constant pool: the
                     * emitter emits builtins as GET_GLOBAL <name> (resolved
                     * per name in codegen.c/vm.c), and only lambdas and named
                     * functions travel as CONST FnObj. The arm is defensive
                     * only — a marker has no id to tell print from len, which
                     * is exactly why the pool must stay builtin-free. */
                    if (fn_obj && fn_obj->param_count == 255 && fn_obj->code == NULL) {
                        cg_write(cg, "    ASTRA_PUSH(frame, sp, astra_builtin_fn_new((AstraFnPtr)astra_builtin_print, 255));\n");
                    } else if (fn_obj) {
                        const char *cname = find_fn_obj_cname(cg, fn_obj);
                        if (cname) {
                            cg_writef(cg, "    ASTRA_PUSH(frame, sp, astra_fn_new((AstraFnPtr)%s, %u));\n",
                                      cname, (unsigned)fn_obj->param_count);
                        } else {
                            /* Fall back to named-function lookup: scan for the
                             * definition pattern (CONST idx + SET_GLOBAL name).
                             * Merged from the old module dispatcher, but with a
                             * NULL push instead of its `unknown_fn`: emitting an
                             * undefined C symbol would break the gcc link where
                             * a runtime diagnostic suffices. */
                            const char *fname = NULL;
                            for (size_t fi = 0; fi < cg->fn_map_count && !fname; fi++) {
                                for (size_t j = 0; j + 1 < code_len; j++) {
                                    if (code[j].op == OPCODE_CONST && code[j].arg.index == idx &&
                                        code[j + 1].op == OPCODE_SET_GLOBAL) {
                                        uint32_t nidx = code[j + 1].arg.index;
                                        if (nidx < const_len && constants[nidx].kind == VAL_STRING &&
                                            strcmp(constants[nidx].as.string_val.str,
                                                   cg->fn_map[fi].name.str) == 0) {
                                            fname = cg->fn_map[fi].c_name;
                                            break;
                                        }
                                    }
                                }
                            }
                            if (fname) {
                                cg_writef(cg, "    ASTRA_PUSH(frame, sp, astra_fn_new((AstraFnPtr)%s, 0));\n",
                                          fname);
                            } else {
                                cg_write(cg, "    ASTRA_PUSH(frame, sp, astra_fn_new((AstraFnPtr)NULL, 0));\n");
                            }
                        }
                    } else {
                        cg_write(cg, "    ASTRA_PUSH(frame, sp, astra_fn_new((AstraFnPtr)NULL, 0));\n");
                    }
                } break;
                case VAL_STRUCT_DEF: {
                    /* The definition object a struct literal pops. Without this
                     * case it fell through to `default` and pushed nil, so a
                     * top-level `let p = P { ... }` built a struct from a NULL
                     * definition pointer - a segfault in generated code, not a
                     * diagnostic (PHASE1_PROGRESS section 6, S16). */
                    const StructDef *def = v.as.struct_def;
                    const char *cname = register_struct_def(cg, def);
                    if (cname) {
                        cg_writef(cg, "    ASTRA_PUSH(frame, sp, astra_ptr(&%s));\n", cname);
                    } else {
                        cg_write(cg, "    ASTRA_PUSH(frame, sp, astra_nil());\n");
                    }
                } break;
                case VAL_ENUM_DEF: {
                    const EnumDef *def = v.as.enum_def;
                    const char *cname = register_enum_def(cg, def);
                    if (cname) {
                        cg_writef(cg, "    ASTRA_PUSH(frame, sp, astra_ptr(&%s));\n", cname);
                    } else {
                        cg_write(cg, "    ASTRA_PUSH(frame, sp, astra_nil());\n");
                    }
                } break;
                case VAL_ENUM: {
                    const char *ename = v.as.enum_val.enum_name ? v.as.enum_val.enum_name : "";
                    const char *vname = v.as.enum_val.variant_name ? v.as.enum_val.variant_name : "";
                    cg_writef(cg, "    ASTRA_PUSH(frame, sp, astra_enum_val(\"%s\", \"%s\"));\n",
                              ename, vname);
                } break;
                default:
                    cg_writef(cg, "    ASTRA_PUSH(frame, sp, astra_nil());\n");
                    break;
                }
            }
        } break;

        case OPCODE_POP: {
            /* The operand is a count and zero means one, exactly as in vm.c;
             * reachable whenever a statement discards its value. */
            uint8_t n = inst.arg.index ? inst.arg.index : 1;
            cg_writef(cg, "    sp -= %u;\n", n);
        } break;

        case OPCODE_DUP: {
            cg_write(cg, "    ASTRA_PUSH(frame, sp, frame[sp-1]);\n");
        } break;

        case OPCODE_SWAP: {
            cg_write(cg, "    { AstraValue _tmp = frame[sp-1]; "
                     "frame[sp-1] = frame[sp-2]; frame[sp-2] = _tmp; }\n");
        } break;

        case OPCODE_GET_LOCAL: {
            cg_writef(cg, "    ASTRA_PUSH(frame, sp, frame[%u]);\n", inst.arg.index);
        } break;

        case OPCODE_SET_LOCAL: {
            /* vm.c pops the value and then pads the frame with nil up to the
             * slot before storing, so a fresh slot (at or above the current
             * height) *extends* the frame instead of merely writing into it.
             * Keeping that behaviour — together with starting sp at
             * local_count in emit_fn_body — makes this backend's frame
             * evolve exactly like the VM's, which is what lets the emitter
             * address inline value constructs' hidden slots and closes
             * statically in both backends (audit §4.7). */
            cg_writef(cg,
                "    { AstraValue _sv = frame[--sp];\n"
                "      while (%u >= sp) { ASTRA_PUSH(frame, sp, astra_nil()); }\n"
                "      frame[%u] = _sv; }\n",
                inst.arg.index, inst.arg.index);
        } break;

        case OPCODE_GET_GLOBAL: {
            uint32_t name_idx = inst.arg.index;
            const char *gname = "g_unknown";
            if (name_idx < const_len && constants[name_idx].kind == VAL_STRING) {
                InternedString is = {0};
                is.str = constants[name_idx].as.string_val.str;
                is.len = constants[name_idx].as.string_val.len;
                gname = make_global_cname(cg, is);
            }
            cg_writef(cg, "    ASTRA_PUSH(frame, sp, %s);\n", gname);
        } break;

        case OPCODE_SET_GLOBAL: {
            uint32_t name_idx = inst.arg.index;
            const char *gname = "g_unknown";
            if (name_idx < const_len && constants[name_idx].kind == VAL_STRING) {
                InternedString is = {0};
                is.str = constants[name_idx].as.string_val.str;
                is.len = constants[name_idx].as.string_val.len;
                gname = make_global_cname(cg, is);
            }
            cg_writef(cg, "    %s = frame[--sp];\n", gname);
        } break;

        case OPCODE_ADD:
            cg_write(cg, "    frame[sp-2] = astra_add(frame[sp-2], frame[sp-1]); sp--;\n");
            break;
        case OPCODE_SUB:
            cg_write(cg, "    frame[sp-2] = astra_sub(frame[sp-2], frame[sp-1]); sp--;\n");
            break;
        case OPCODE_MUL:
            cg_write(cg, "    frame[sp-2] = astra_mul(frame[sp-2], frame[sp-1]); sp--;\n");
            break;
        case OPCODE_DIV:
            cg_write(cg, "    frame[sp-2] = astra_div(frame[sp-2], frame[sp-1]); sp--;\n");
            break;
        case OPCODE_MOD:
            cg_write(cg, "    frame[sp-2] = astra_mod(frame[sp-2], frame[sp-1]); sp--;\n");
            break;
        case OPCODE_NEG:
            cg_write(cg, "    frame[sp-1] = astra_neg(frame[sp-1]);\n");
            break;
        case OPCODE_EQ:
            cg_write(cg, "    frame[sp-2] = astra_eq(frame[sp-2], frame[sp-1]); sp--;\n");
            break;
        case OPCODE_NEQ:
            cg_write(cg, "    frame[sp-2] = astra_neq(frame[sp-2], frame[sp-1]); sp--;\n");
            break;
        case OPCODE_LT:
            cg_write(cg, "    frame[sp-2] = astra_lt(frame[sp-2], frame[sp-1]); sp--;\n");
            break;
        case OPCODE_GT:
            cg_write(cg, "    frame[sp-2] = astra_gt(frame[sp-2], frame[sp-1]); sp--;\n");
            break;
        case OPCODE_LE:
            cg_write(cg, "    frame[sp-2] = astra_le(frame[sp-2], frame[sp-1]); sp--;\n");
            break;
        case OPCODE_GE:
            cg_write(cg, "    frame[sp-2] = astra_ge(frame[sp-2], frame[sp-1]); sp--;\n");
            break;
        case OPCODE_AND:
            cg_write(cg, "    frame[sp-2] = astra_bool(astra_truthy(frame[sp-2]) "
                     "&& astra_truthy(frame[sp-1])); sp--;\n");
            break;
        case OPCODE_OR:
            cg_write(cg, "    frame[sp-2] = astra_bool(astra_truthy(frame[sp-2]) "
                     "|| astra_truthy(frame[sp-1])); sp--;\n");
            break;
        case OPCODE_NOT:
            cg_write(cg, "    frame[sp-1] = astra_not(frame[sp-1]);\n");
            break;
        case OPCODE_BIT_AND:
            cg_write(cg, "    frame[sp-2] = astra_bit_and(frame[sp-2], frame[sp-1]); sp--;\n");
            break;
        case OPCODE_BIT_OR:
            cg_write(cg, "    frame[sp-2] = astra_bit_or(frame[sp-2], frame[sp-1]); sp--;\n");
            break;
        case OPCODE_BIT_XOR:
            cg_write(cg, "    frame[sp-2] = astra_bit_xor(frame[sp-2], frame[sp-1]); sp--;\n");
            break;
        case OPCODE_SHL:
            cg_write(cg, "    frame[sp-2] = astra_shl(frame[sp-2], frame[sp-1]); sp--;\n");
            break;
        case OPCODE_SHR:
            cg_write(cg, "    frame[sp-2] = astra_shr(frame[sp-2], frame[sp-1]); sp--;\n");
            break;
        case OPCODE_BIT_NOT:
            cg_write(cg, "    frame[sp-1] = astra_bit_not(frame[sp-1]);\n");
            break;

        case OPCODE_JUMP: {
            int32_t offset = inst.arg.offset;
            cg_writef(cg, "    goto L_%zu;\n", ip + (size_t)offset);
            /* Nothing falls out of a goto: the next instruction is reached
             * from a label or from an earlier conditional branch, so the
             * textual shadow no longer describes astra_line. */
            *last_line = CG_NO_LINE;
        } break;

        case OPCODE_JUMP_IF_FALSE: {
            int32_t offset = inst.arg.offset;
            cg_writef(cg, "    if (!astra_truthy(frame[--sp])) goto L_%zu;\n",
                      ip + (size_t)offset);
        } break;
        case OPCODE_JUMP_IF_TRUE: {
            int32_t offset = inst.arg.offset;
            cg_writef(cg, "    if (astra_truthy(frame[--sp])) goto L_%zu;\n",
                      ip + (size_t)offset);
        } break;

        case OPCODE_PRINT: {
            cg_write(cg, "    astra_builtin_print(&frame[sp - 1], 1); sp--;\n");
        } break;

        case OPCODE_CALL: {
            uint8_t argc = inst.arg.arg_count;
            cg_writef(cg, "    {\n");
            cg_writef(cg, "        int _fn_slot = sp - 1 - %u;\n", argc);
            cg_writef(cg, "        AstraValue _fnv = frame[_fn_slot];\n");
            /* The try context is a single global pair (codegen_runtime.h):
             * a callee that uses `?` installs its own setjmp over the
             * caller's, and if it returned normally the caller's next `?`
             * would longjmp into that callee's popped frame. Save the
             * enclosing context around every call so each frame's `?`
             * lands on its own live setjmp, chain by chain. */
            cg_writef(cg, "        jmp_buf _save_jmp;\n");
            cg_writef(cg, "        int _save_active = astra_error_active;\n");
            cg_writef(cg, "        AstraValue _save_value = astra_error_value;\n");
            cg_writef(cg, "        memcpy(_save_jmp, astra_error_jmp, sizeof(jmp_buf));\n");
            /* Builtin dispatch mirrors vm.c exactly: `param_count == 255` is
             * the builtin marker *only together with* `code == NULL`
             * (vm.c OPCODE_CALL). Checking the count alone sent a closure
             * with exactly 255 params down the builtin path — it called
             * fun(args, 255) as if args were the print argv and returned
             * nil instead of the 255th parameter (audit §5.6). */
            cg_writef(cg, "        if (_fnv.tag == AST_FN && _fnv.as.fn_val && "
                     "_fnv.as.fn_val->param_count == 255 && "
                     "_fnv.as.fn_val->code == NULL) {\n");
            cg_writef(cg, "            frame[_fn_slot] = "
                     "_fnv.as.fn_val->fun(frame + _fn_slot + 1, %u);\n", argc);
            cg_writef(cg, "            sp = _fn_slot + 1;\n");
            cg_writef(cg, "        } else if (_fnv.tag == AST_FN && _fnv.as.fn_val) {\n");
            /* Mirror vm_push_frame: a user call that would exceed the shared
             * frame bound fails with the VM's own message at the call-site
             * line astra_line already carries, instead of running on until
             * the operand stack gave out (audit §1.1, PRE_LLVM_AUDIT.md). */
            cg_writef(cg, "            if (astra_depth >= ASTRA_CALL_DEPTH)\n");
            cg_writef(cg, "                astra_runtime_error(\"call depth exceeded\");\n");
            cg_writef(cg, "            astra_depth++;\n");
            cg_writef(cg, "            frame[_fn_slot] = "
                     "_fnv.as.fn_val->fun(frame + _fn_slot, %u);\n", argc);
            cg_writef(cg, "            astra_depth--;\n");
            cg_writef(cg, "            sp = _fn_slot + 1;\n");
            cg_writef(cg, "        } else {\n");
            cg_writef(cg, "            astra_runtime_error(\"cannot call non-function value\");\n");
            cg_writef(cg, "        }\n");
            cg_writef(cg, "        memcpy(astra_error_jmp, _save_jmp, sizeof(jmp_buf));\n");
            cg_writef(cg, "        astra_error_active = _save_active;\n");
            cg_writef(cg, "        astra_error_value = _save_value;\n");
            cg_writef(cg, "    }\n");
            /* The callee overwrites the global astra_line while it runs (its
             * own fallible ops store their lines), so this stream's dedup
             * shadow is stale after every call: an op that follows on the SAME
             * source line would be skipped by cg_set_line and the error would
             * report the callee's line (audit §5.4). Invalidate the shadow so
             * the next fallible op re-stores astra_line. */
            *last_line = CG_NO_LINE;
        } break;

        case OPCODE_RET: {
            cg_write(cg, "    return frame[sp - 1];\n");
            /* Same reasoning as OPCODE_JUMP: the epilogue that follows is
             * not reached by falling out of this return. */
            *last_line = CG_NO_LINE;
        } break;

        case OPCODE_CLOSURE: {
            uint32_t packed = inst.arg.index;
            uint32_t fn_const = packed >> 8;
            uint32_t n_cap = packed & 0xFF;
            const char *cname = "NULL";
            unsigned pc = 0;
            if (fn_const < const_len &&
                constants[fn_const].kind == VAL_FN &&
                constants[fn_const].as.fn_val) {
                const char *found =
                    find_fn_obj_cname(cg, constants[fn_const].as.fn_val);
                if (found) {
                    cname = found;
                    pc = constants[fn_const].as.fn_val->param_count;
                }
            }
            /* The captured values are already on the stack, in env order. */
            cg_writef(cg, "    /* CLOSURE fn=%u captures=%u */\n", fn_const, n_cap);
            cg_write(cg, "    {\n");
            if (n_cap > 0) {
                cg_writef(cg, "        AstraValue _env[%u];\n", n_cap);
                for (uint32_t j = 0; j < n_cap; j++) {
                    cg_writef(cg, "        _env[%u] = frame[sp - %u];\n",
                              j, n_cap - j);
                }
                cg_writef(cg, "        sp -= %u;\n", n_cap);
                cg_writef(cg, "        ASTRA_PUSH(frame, sp, "
                         "astra_closure_new((AstraFnPtr)%s, %u, _env, %u));\n",
                          cname, pc, n_cap);
            } else {
                cg_writef(cg, "        ASTRA_PUSH(frame, sp, "
                         "astra_closure_new((AstraFnPtr)%s, %u, NULL, 0));\n",
                          cname, pc);
            }
            cg_write(cg, "    }\n");
        } break;

        case OPCODE_GET_CAPTURE: {
            /* Slot 0 of a user-function frame is the callee for the whole call
             * (CALL passes frame + _fn_slot), same contract the VM relies on. */
            cg_writef(cg, "    ASTRA_PUSH(frame, sp, frame[0].as.fn_val->env[%u]);\n",
                      inst.arg.index);
        } break;

        case OPCODE_NEW_ARRAY: {
            uint32_t n = inst.arg.index;
            cg_writef(cg, "    {\n");
            cg_writef(cg, "        AstraValue _elems[%u];\n", n);
            for (uint32_t j = 0; j < n; j++) {
                cg_writef(cg, "        _elems[%u] = frame[sp - %u];\n", j, n - j);
            }
            cg_writef(cg, "        sp -= %u;\n", n);
            cg_writef(cg, "        ASTRA_PUSH(frame, sp, astra_array_new(_elems, %u));\n", n);
            cg_writef(cg, "    }\n");
        } break;

        case OPCODE_INDEX: {
            /* Bounds-checked via astra_array_get, never raw elems[]: direct
             * access used to read out of bounds and keep going with garbage
             * (PHASE1_PROGRESS section 6, S10/S11). The receiver and index
             * guards mirror vm.c OPCODE_INDEX word for word (audit §5.3):
             * `_arr.as.array_val` used to be dereferenced unchecked, so
             * `let a: [i32]; a[0]` segfaulted instead of reporting the VM's
             * "cannot index nil". The string arm (DEC-013 `s[i]`) mirrors the
             * seed VM's string arm in the same order: receiver, int, bounds. */
            cg_write(cg, "    {\n");
            cg_write(cg, "        AstraValue _idx = frame[--sp];\n");
            cg_write(cg, "        AstraValue _arr = frame[sp - 1];\n");
            cg_write(cg, "        if (_arr.tag == AST_STRING && _arr.as.string_val) {\n");
            cg_write(cg, "            if (_idx.tag != AST_INT)\n");
            cg_write(cg, "                astra_errorf(\"array index must be int, got %s\", astra_tag_name(_idx.tag));\n");
            cg_write(cg, "            frame[sp - 1] = astra_string_get(_arr.as.string_val, _idx.as.int_val);\n");
            cg_write(cg, "        } else if (_arr.tag != AST_ARRAY || !_arr.as.array_val) {\n");
            cg_write(cg, "            astra_errorf(\"cannot index %s\", astra_tag_name(_arr.tag));\n");
            cg_write(cg, "        } else {\n");
            cg_write(cg, "            if (_idx.tag != AST_INT)\n");
            cg_write(cg, "                astra_errorf(\"array index must be int, got %s\", astra_tag_name(_idx.tag));\n");
            cg_write(cg, "            frame[sp - 1] = astra_array_get(_arr.as.array_val, _idx.as.int_val);\n");
            cg_write(cg, "        }\n");
            cg_write(cg, "    }\n");
        } break;

        case OPCODE_LEN: {
            /* vm.c OPCODE_LEN accepts array and string receivers and words
             * anything else as "cannot take length of %s" (audit §5.3): the
             * old code read `frame[sp-1].as.array_val->len` unchecked, so a
             * nil iterable in `for x in a` segfaulted. */
            cg_write(cg, "    {\n");
            cg_write(cg, "        AstraValue _len_v = frame[sp - 1];\n");
            cg_write(cg, "        if (_len_v.tag == AST_ARRAY && _len_v.as.array_val) {\n");
            cg_write(cg, "            frame[sp - 1] = astra_int(_len_v.as.array_val->len);\n");
            cg_write(cg, "        } else if (_len_v.tag == AST_STRING && _len_v.as.string_val) {\n");
            cg_write(cg, "            frame[sp - 1] = astra_int(_len_v.as.string_val->len);\n");
            cg_write(cg, "        } else {\n");
            cg_write(cg, "            astra_errorf(\"cannot take length of %s\", astra_tag_name(_len_v.tag));\n");
            cg_write(cg, "        }\n");
            cg_write(cg, "    }\n");
        } break;

        case OPCODE_SET_INDEX: {
            /* Receiver/index guards mirror vm.c OPCODE_SET_INDEX (audit §5.3):
             * writing through a nil array used to be a heap wild-pointer
             * write, now it is the VM's "cannot index nil". */
            cg_write(cg, "    {\n");
            cg_write(cg, "        AstraValue _val = frame[--sp];\n");
            cg_write(cg, "        AstraValue _idx = frame[--sp];\n");
            cg_write(cg, "        AstraValue _arr = frame[sp - 1];\n");
            cg_write(cg, "        if (_arr.tag != AST_ARRAY || !_arr.as.array_val)\n");
            cg_write(cg, "            astra_errorf(\"cannot index %s\", astra_tag_name(_arr.tag));\n");
            cg_write(cg, "        if (_idx.tag != AST_INT)\n");
            cg_write(cg, "            astra_errorf(\"array index must be int, got %s\", astra_tag_name(_idx.tag));\n");
            cg_write(cg, "        astra_array_set(_arr.as.array_val, _idx.as.int_val, _val);\n");
            cg_write(cg, "        frame[sp - 1] = _val;\n");
            cg_write(cg, "    }\n");
        } break;

        case OPCODE_NEW_STRUCT: {
            uint32_t n = inst.arg.index;
            cg_writef(cg, "    /* NEW_STRUCT %u fields */\n", n);
            cg_writef(cg, "    {\n");
            cg_writef(cg, "        AstraValue _def = frame[sp - %u - 1];\n", n);
            cg_writef(cg, "        AstraStruct *_s = astra_struct_new((const AstraStructDef *)_def.as.ptr_val);\n");
            for (uint32_t i = 0; i < n; i++) {
                cg_writef(cg, "        _s->fields[%u] = frame[sp - %u + %u];\n",
                          i, n, i);
            }
            cg_writef(cg, "        sp -= %u;\n", n);
            cg_writef(cg, "        frame[sp-1].tag = AST_STRUCT; "
                     "frame[sp-1].as.struct_val = _s;\n");
            cg_writef(cg, "    }\n");
        } break;

        case OPCODE_GET_FIELD: {
            uint32_t name_idx = inst.arg.index;
            const char *fname = (name_idx < const_len && constants[name_idx].kind == VAL_STRING)
                               ? constants[name_idx].as.string_val.str : "";
            cg_writef(cg, "    /* GET_FIELD '%s' */\n", fname);
            cg_writef(cg, "    {\n");
            cg_writef(cg, "        AstraValue _obj = frame[--sp];\n");
            /* Receiver guard mirrors vm.c GET_FIELD (audit §5.3): a nil
             * receiver used to fall straight through to `_s->def->field_count`
             * and segfault; the VM says "cannot access field on %s". */
            cg_writef(cg, "        if (_obj.tag != AST_STRUCT || !_obj.as.struct_val)\n");
            cg_writef(cg, "            astra_errorf(\"cannot access field on %%s\", astra_tag_name(_obj.tag));\n");
            cg_writef(cg, "        AstraStruct *_s = (AstraStruct *)_obj.as.struct_val;\n");
            cg_writef(cg, "        if (!_s->def)\n");
            cg_writef(cg, "            astra_errorf(\"cannot access field on %%s\", astra_tag_name(_obj.tag));\n");
            cg_writef(cg, "        int _fi = -1;\n");
            cg_writef(cg, "        for (size_t _i = 0; _i < _s->def->field_count; _i++) {\n");
            cg_writef(cg, "            if (strcmp(_s->def->field_names[_i], \"%s\") == 0) { _fi = (int)_i; break; }\n", fname);
            cg_writef(cg, "        }\n");
            cg_writef(cg, "        ASTRA_PUSH(frame, sp, (_fi >= 0) ? _s->fields[_fi] : astra_nil());\n");
            cg_writef(cg, "    }\n");
        } break;

        case OPCODE_SET_FIELD: {
            uint32_t name_idx = inst.arg.index;
            const char *fname = (name_idx < const_len && constants[name_idx].kind == VAL_STRING)
                               ? constants[name_idx].as.string_val.str : "";
            cg_writef(cg, "    /* SET_FIELD '%s' */\n", fname);
            cg_writef(cg, "    {\n");
            cg_writef(cg, "        AstraValue _val = frame[--sp];\n");
            /* Same receiver guard as GET_FIELD (vm.c OPCODE_SET_FIELD): a nil
             * receiver used to be a wild write through a NULL struct pointer. */
            cg_writef(cg, "        if (frame[sp-1].tag != AST_STRUCT || !frame[sp-1].as.struct_val)\n");
            cg_writef(cg, "            astra_errorf(\"cannot access field on %%s\", astra_tag_name(frame[sp-1].tag));\n");
            cg_writef(cg, "        AstraStruct *_s = (AstraStruct *)frame[sp-1].as.struct_val;\n");
            cg_writef(cg, "        if (!_s->def)\n");
            cg_writef(cg, "            astra_errorf(\"cannot access field on %%s\", astra_tag_name(frame[sp-1].tag));\n");
            cg_writef(cg, "        int _fi = -1;\n");
            cg_writef(cg, "        for (size_t _i = 0; _i < _s->def->field_count; _i++) {\n");
            cg_writef(cg, "            if (strcmp(_s->def->field_names[_i], \"%s\") == 0) { _fi = (int)_i; break; }\n", fname);
            cg_writef(cg, "        }\n");
            cg_writef(cg, "        if (_fi >= 0) _s->fields[_fi] = _val;\n");
            cg_writef(cg, "        frame[sp-1] = _val;\n");
            cg_writef(cg, "    }\n");
        } break;

        case OPCODE_NEW_ENUM: {
            uint32_t packed = inst.arg.index;
            uint32_t variant_idx = packed >> 16;
            uint32_t field_count = packed & 0xFFFF;

            /* Scan backwards to find the CONST that pushed the enum def */
            const char *enum_name = "";
            const char *variant_name = "";
            for (size_t back = 1; back <= ip; back++) {
                if (code[ip - back].op == OPCODE_CONST) {
                    uint32_t def_idx = code[ip - back].arg.index;
                    if (def_idx < const_len && constants[def_idx].kind == VAL_ENUM_DEF) {
                        const EnumDef *def = constants[def_idx].as.enum_def;
                        if (def) {
                            enum_name = def->name ? def->name : "";
                            if (variant_idx < def->variant_count && def->variants[variant_idx].name)
                                variant_name = def->variants[variant_idx].name;
                        }
                        break;
                    }
                    /* If we hit a non-CONST opcode, stop */
                    if (code[ip - back].op != OPCODE_CONST) break;
                }
            }

            cg_writef(cg, "    {\n");
            cg_writef(cg, "        AstraEnumObj *_e = malloc(sizeof(AstraEnumObj));\n");
            cg_writef(cg, "        _e->def = NULL;\n");
            cg_writef(cg, "        _e->variant = %u;\n", variant_idx);
            cg_writef(cg, "        _e->fields = malloc(%u * sizeof(AstraValue));\n", field_count);
            /* Recorded so that structural equality of two data-carrying variants
             * can compare payloads without the enum definition (the VM reads the
             * count from EnumDef; the generated object has no def). */
            cg_writef(cg, "        _e->field_count = %u;\n", field_count);
            for (uint32_t j = 0; j < field_count; j++) {
                cg_writef(cg, "        _e->fields[%u] = frame[sp - %u];\n",
                          j, field_count - j);
            }
            cg_writef(cg, "        _e->enum_name = \"%s\";\n", enum_name);
            cg_writef(cg, "        _e->variant_name = \"%s\";\n", variant_name);
            cg_writef(cg, "        sp -= %u;\n", field_count);
            /* Pop the enum def that was pushed by CONST */
            cg_writef(cg, "        sp--;\n");
            cg_writef(cg, "        frame[sp].tag = AST_ENUM_DATA; "
                     "frame[sp].as.enum_obj = _e; sp++;\n");
            cg_writef(cg, "    }\n");
        } break;

        case OPCODE_GET_ENUM_FIELD: {
            uint32_t field_idx = inst.arg.index;
            cg_writef(cg, "    {\n");
            cg_writef(cg, "        AstraEnumObj *_e = (AstraEnumObj *)frame[sp-1].as.enum_obj;\n");
            cg_writef(cg, "        frame[sp-1] = _e->fields[%u];\n", field_idx);
            cg_writef(cg, "    }\n");
        } break;

        case OPCODE_WRAP_OK: {
            cg_write(cg, "    frame[sp-1] = astra_wrap_ok(frame[sp-1]);\n");
        } break;
        case OPCODE_WRAP_ERR: {
            cg_write(cg, "    frame[sp-1] = astra_wrap_err(frame[sp-1]);\n");
        } break;
        case OPCODE_WRAP_SOME: {
            cg_write(cg, "    frame[sp-1] = astra_wrap_some(frame[sp-1]);\n");
        } break;
        case OPCODE_TAG_IS: {
            /* VM indices: 0=OK, 1=ERR, 2=SOME, 3=NONE.
             * C runtime AstraTag: AST_OK=10, AST_ERR=11, AST_SOME=12, AST_NIL=0. */
            static const unsigned tag_map[] = {10, 11, 12, 0};
            unsigned real_tag = (inst.arg.index < 4) ? tag_map[inst.arg.index] : 0;
            cg_writef(cg, "    frame[sp-1] = astra_bool(frame[sp-1].tag == %u);\n",
                      real_tag);
        } break;
        case OPCODE_UNWRAP: {
            cg_write(cg, "    frame[sp-1] = astra_unwrap(frame[sp-1]);\n");
        } break;
        case OPCODE_MATCH_NONE: {
            /* Backstop of the exhaustiveness checker (audit §3.8): the VM
             * aborts with `file:line: runtime error: no match arm matched`;
             * astra_line was stored by the fallible-op annotation above. */
            cg_write(cg, "    astra_runtime_error(\"no match arm matched\");\n");
        } break;
        case OPCODE_TRY_UNWRAP: {
            cg_write(cg, "    ASTRA_TRY_UNWRAP(frame[sp-1]);\n");
        } break;

        case OPCODE_HALT: {
            cg_write(cg, "    return 0;\n");
        } break;

        default:
            /* Never emit a placeholder comment: dropping an instruction yields a
             * program that silently computes the wrong answer. Any opcode the
             * VM knows but this backend does not must fail the whole run. */
            fprintf(stderr, "error: C codegen has no handler for opcode %d at ip %zu"
                            " (name it with ASTRA_DUMP_VM=1)\n", (int)inst.op, ip);
            cg->error_count++;
            break;
        }
    }

    free(is_label);
}


static void emit_fn_body(Codegen *cg, const char *c_name, FnObj *fn) {
    /* Forward declare */
    cg_writef(cg, "static AstraValue %s(AstraValue *frame, uint8_t argc) {\n", c_name);

    /* Check if this function uses TRY_UNWRAP */
    bool uses_try = false;
    for (size_t i = 0; i < fn->code_len; i++) {
        if (fn->code[i].op == OPCODE_TRY_UNWRAP) { uses_try = true; break; }
    }

    /* Local variable declarations: slot 0 = ret, slots 1..param_count = params,
     * slots param_count+1..local_count-1 = locals */
    /* Find the maximum slot index used in the bytecode */
    uint16_t max_slot = 0;
    for (size_t i = 0; i < fn->code_len; i++) {
        switch (fn->code[i].op) {
        case OPCODE_GET_LOCAL:
        case OPCODE_SET_LOCAL:
            if (fn->code[i].arg.index >= max_slot)
                max_slot = fn->code[i].arg.index + 1;
            break;
        default: break;
        }
    }
    if (max_slot < (uint16_t)fn->local_count)
        max_slot = fn->local_count;

    /* Start sp at local_count, not max_slot: at entry the VM's frame holds
     * exactly the callee slot plus the parameters, and body locals appear as
     * their SET_LOCALs execute (vm.c pads up to the slot). Mirroring that
     * keeps both backends' frames in the same coordinates, which the
     * emitter's static close targets rely on (audit §4.7). max_slot still
     * sizes and pre-touches the frame array. */
    cg_writef(cg, "    uint16_t sp = %u;\n", (unsigned)fn->local_count);
    cg_write(cg, "    (void)argc;\n");
    for (uint16_t i = 0; i < max_slot; i++) {
        cg_writef(cg, "    (void)frame[%u];\n", i);
    }

    /* If this function uses ?, set up error recovery context */
    if (uses_try) {
        cg_write(cg, "    if (ASTRA_TRY_CONTEXT()) { astra_error_active = 0; return astra_error_value; }\n");
    }

    /* Translate bytecode */
    unsigned fn_line = CG_NO_LINE;
    emit_instructions(cg, fn->code, fn->code_len,
                      fn->constants, fn->const_len, &fn_line);

    cg_write(cg, "    return frame[sp > 0 ? sp - 1 : 0];\n");
    cg_write(cg, "}\n\n");
}

/* -----------------------------------------------------------
 * Emit module-level code
 * ----------------------------------------------------------- */

static void emit_module_code(Codegen *cg) {
    cg_write(cg, "static int astra_module_main(void) {\n");
    cg_write(cg, "    AstraValue *frame = astra_frame;\n");
    cg_write(cg, "    uint16_t sp = 0;\n");
    cg_write(cg, "    (void)frame; (void)sp;\n\n");

    /* Arm the try context for module-level code. Since audit §5.2 hard
     * runtime errors exit(1) directly and never longjmp, this context only
     * catches the `?` none/err unwind of a module-level TRY_UNWRAP (which
     * lands here and ends the run with exit 1, as before). */
    cg_write(cg, "    if (ASTRA_TRY_CONTEXT()) { astra_error_active = 0; return 1; }\n");

    /* Source file for runtime-error positions; set before any user code
     * runs so every error prints `file:line: ` like the VM driver. */
    cg_write(cg, "    astra_file = \"");
    cg_write_c_escaped(cg, cg->filename ? cg->filename : "<input>",
                       cg->filename ? strlen(cg->filename) : strlen("<input>"));
    cg_write(cg, "\";\n");

    size_t code_len = 0;
    const Instruction *code = emitter_get_code(cg->emitter, &code_len);

    /* Initialize the builtins this program references (table-driven, one
     * call per builtin — no break: several may coexist now). */
    for (size_t i = 0; i < cg->global_map_count; i++) {
        if (find_builtin(cg->global_map[i].name.str)) {
            cg_writef(cg, "    %s_init();\n", cg->global_map[i].c_name);
        }
    }
    cg_write(cg, "\n");

    size_t const_len = 0;
    const Value *constants = emitter_get_constants(cg->emitter, &const_len);

    /* Translate bytecode */
    unsigned mod_line = CG_NO_LINE;
    emit_instructions(cg, code, code_len, constants, const_len, &mod_line);

    cg_write(cg, "    return 0;\n");
    cg_write(cg, "}\n\n");
}

/* -----------------------------------------------------------
 * Emit main()
 * ----------------------------------------------------------- */

static void emit_main(Codegen *cg) {
    cg_write(cg, "int main(void) {\n");
    cg_write(cg, "    astra_runtime_init();\n");
    cg_write(cg, "    int result = astra_module_main();\n");
    cg_write(cg, "    astra_runtime_cleanup();\n");
    cg_write(cg, "    return result;\n");
    cg_write(cg, "}\n");
}

/* -----------------------------------------------------------
 * Public API
 * ----------------------------------------------------------- */

Codegen *codegen_create(Node *module, Emitter *emitter, const char *filename) {
    Codegen *cg = calloc(1, sizeof(Codegen));
    if (!cg) return NULL;
    cg->module = module;
    cg->emitter = emitter;
    cg->filename = filename;
    return cg;
}

bool codegen_emit_to_file(Codegen *cg, const char *output_path) {
    /* Phase 1: Header */
    cg_write(cg, "/* Generated by astra-seed --emit-c */\n");
    cg_write(cg, "#include \"codegen_runtime.h\"\n\n");

    /* Phase 1b: Scan for struct defs */
    scan_all_struct_defs(cg);

    /* Phase 1c: Scan for enum defs */
    scan_all_enum_defs(cg);

    /* Phase 1d: Scan for lambda/non-builtin FnObjs */
    scan_all_lambda_fns(cg);

    /* Phase 2: Type declarations */
    emit_struct_decls(cg);
    emit_enum_decls(cg);

    /* Phase 2b: Struct def forward declarations */
    emit_struct_def_fwd_decls(cg);

    /* Phase 2c: Enum def globals (must be before functions that reference them) */
    emit_enum_def_globals(cg);

    /* Phase 3: Global variables */
    emit_global_decls(cg);

    /* Phase 4: Function forward declarations */
    emit_fn_forward_decls(cg);

    /* Phase 4b: Lambda/non-builtin FnObj forward declarations */
    emit_fnobj_forward_decls(cg);

    /* Phase 5: Function bodies */
    emit_fn_bodies(cg);

    /* Phase 5b: Lambda/non-builtin FnObj bodies */
    emit_fnobj_bodies(cg);

    /* Phase 6: Module-level code */
    emit_module_code(cg);

    /* Phase 6b: Struct def definitions */
    emit_struct_def_globals(cg);

    /* Phase 7: main() */
    emit_main(cg);

    /* A registry breach is recorded, never written past: fail here rather than
     * emitting a file that references names which were never registered. */
    if (cg->error_count > 0) {
        fprintf(stderr, "error: C codegen registry overflow (%zu name(s) rejected)\n",
                cg->error_count);
        return false;
    }

    /* Write to file */
    FILE *f = fopen(output_path, "w");
    if (!f) {
        fprintf(stderr, "error: cannot open '%s' for writing\n", output_path);
        return false;
    }
    fwrite(cg->buf, 1, cg->buf_len, f);
    fclose(f);
    return true;
}

void codegen_destroy(Codegen *cg) {
    if (!cg) return;
    free(cg->buf);
    for (size_t i = 0; i < cg->fn_map_count; i++) {
        free((char *)cg->fn_map[i].c_name);
    }
    for (size_t i = 0; i < cg->global_map_count; i++) {
        free((char *)cg->global_map[i].c_name);
    }
    for (size_t i = 0; i < cg->fn_obj_reg_count; i++) {
        free((char *)cg->fn_obj_reg[i].c_name);
    }
    /* struct_defs / enum_defs also own malloc'd names: omitting them leaked one
     * 64-byte string per struct/enum and made `--emit-c` fail under LSan. */
    for (size_t i = 0; i < cg->struct_def_count; i++) {
        free((char *)cg->struct_defs[i].c_name);
    }
    for (size_t i = 0; i < cg->enum_def_count; i++) {
        free((char *)cg->enum_defs[i].c_name);
    }
    free(cg);
}
