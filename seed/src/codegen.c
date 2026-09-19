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

/* -----------------------------------------------------------
 * Name generation
 * ----------------------------------------------------------- */

static const char *make_fn_cname(Codegen *cg, InternedString name) {
    /* Check if already registered */
    for (size_t i = 0; i < cg->fn_map_count; i++) {
        if (cg->fn_map[i].name.str == name.str)
            return cg->fn_map[i].c_name;
    }
    /* Generate: astra_fn_<name> */
    size_t len = name.len + 16;
    char *buf = malloc(len);
    snprintf(buf, len, "astra_fn_%.*s", (int)name.len, name.str);
    /* Replace non-identifier chars */
    for (char *p = buf + 10; *p; p++) {
        if (*p == '.' || *p == '-' || *p == '/') *p = '_';
    }
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
    size_t len = name.len + 16;
    char *buf = malloc(len);
    snprintf(buf, len, "g_%.*s", (int)name.len, name.str);
    for (char *p = buf + 2; *p; p++) {
        if (*p == '.' || *p == '-' || *p == '/') *p = '_';
    }
    cg->global_map[cg->global_map_count].name = name;
    cg->global_map[cg->global_map_count].c_name = buf;
    cg->global_map_count++;
    return buf;
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
                    cg_write(cg, "AstraValue v; ");
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
                name.str = constants[name_idx].as.string_val;
                name.len = (size_t)strlen(constants[name_idx].as.string_val);
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
                        name.str = fn->constants[name_idx].as.string_val;
                        name.len = (size_t)strlen(fn->constants[name_idx].as.string_val);
                        make_global_cname(cg, name);
                    }
                }
            }
        }
    }

    for (size_t i = 0; i < cg->global_map_count; i++) {
        /* Check if this is the print builtin */
        if (strcmp(cg->global_map[i].name.str, "print") == 0) {
            cg_write(cg, "static AstraValue g_print;\n");
        } else {
            cg_writef(cg, "static AstraValue %s;\n", cg->global_map[i].c_name);
        }
    }
    if (cg->global_map_count > 0) cg_write(cg, "\n");

    /* Initialize print builtin */
    for (size_t i = 0; i < cg->global_map_count; i++) {
        if (strcmp(cg->global_map[i].name.str, "print") == 0) {
            cg_writef(cg, "static void %s_init(void) { "
                     "g_print = astra_fn_new((AstraFnPtr)astra_builtin_print, 255); }\n",
                     cg->global_map[i].c_name);
            break;
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
                        name.str = constants[name_idx].as.string_val;
                        name.len = (size_t)strlen(constants[name_idx].as.string_val);
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
                    strcmp(constants[name_idx].as.string_val, fname.str) == 0 &&
                    fn_idx < const_len && constants[fn_idx].kind == VAL_FN) {
                    emit_fn_body(cg, cname, constants[fn_idx].as.fn_val);
                    break;
                }
            }
        }
    }
}

/* -----------------------------------------------------------
 * Emit a single function body
 * ----------------------------------------------------------- */

static void emit_fn_body(Codegen *cg, const char *c_name, FnObj *fn) {
    /* Forward declare */
    cg_writef(cg, "static AstraValue %s(AstraValue *frame, uint8_t argc) {\n", c_name);

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

    cg_writef(cg, "    uint16_t sp = %u;\n", (unsigned)max_slot);
    cg_write(cg, "    (void)argc;\n");
    for (uint16_t i = 0; i < max_slot; i++) {
        cg_writef(cg, "    (void)frame[%u];\n", i);
    }

    /* First pass: emit labels for jump targets */
    bool *is_label = calloc(fn->code_len, sizeof(bool));
    for (size_t i = 0; i < fn->code_len; i++) {
        switch (fn->code[i].op) {
        case OPCODE_JUMP:
        case OPCODE_JUMP_IF_FALSE:
        case OPCODE_JUMP_IF_TRUE: {
            int32_t target = (int32_t)i + fn->code[i].arg.offset;
            if (target >= 0 && (size_t)target < fn->code_len)
                is_label[target] = true;
        } break;
        default: break;
        }
    }

    /* Translate bytecode */
    size_t ip = 0;
    while (ip < fn->code_len) {
        if (is_label[ip]) {
            cg_writef(cg, "    L_%zu: ;\n", ip);
        }

        Instruction inst = fn->code[ip];

        switch (inst.op) {
        case OPCODE_CONST: {
            uint32_t idx = inst.arg.index;
            if (idx < fn->const_len) {
                Value v = fn->constants[idx];
                switch (v.kind) {
                case VAL_NIL:
                    cg_writef(cg, "    frame[sp] = astra_nil(); sp++;\n");
                    break;
                case VAL_BOOL:
                    cg_writef(cg, "    frame[sp] = astra_bool(%s); sp++;\n",
                              v.as.bool_val ? "1" : "0");
                    break;
                case VAL_INT:
                    cg_writef(cg, "    frame[sp] = astra_int(%ldL); sp++;\n",
                              (long)v.as.int_val);
                    break;
                case VAL_FLOAT:
                    cg_writef(cg, "    frame[sp] = astra_float(%g); sp++;\n",
                              v.as.float_val);
                    break;
                case VAL_STRING:
                    cg_writef(cg, "    frame[sp] = astra_string_new(\"%s\", %ld); sp++;\n",
                              v.as.string_val, (long)strlen(v.as.string_val));
                    break;
                case VAL_FN: {
                    FnObj *fn_obj = v.as.fn_val;
                    if (fn_obj && fn_obj->param_count == 255 && fn_obj->code == NULL) {
                        cg_write(cg, "    frame[sp] = astra_fn_new((AstraFnPtr)astra_builtin_print, 255); sp++;\n");
                    } else {
                        cg_write(cg, "    frame[sp] = astra_fn_new((AstraFnPtr)NULL, 0); sp++;\n");
                    }
                } break;
                case VAL_STRUCT_DEF: {
                    const StructDef *def = v.as.struct_def;
                    const char *cname = register_struct_def(cg, def);
                    if (cname) {
                        cg_writef(cg, "    frame[sp].tag = AST_PTR; frame[sp].as.ptr_val = (void *)&%s; sp++;\n", cname);
                    } else {
                        cg_write(cg, "    frame[sp] = astra_nil(); sp++;\n");
                    }
                } break;
                case VAL_ENUM: {
                    const char *ename = v.as.enum_val.enum_name ? v.as.enum_val.enum_name : "";
                    const char *vname = v.as.enum_val.variant_name ? v.as.enum_val.variant_name : "";
                    cg_writef(cg, "    frame[sp].tag = AST_ENUM; frame[sp].as.enum_val.enum_name = \"%s\"; frame[sp].as.enum_val.variant_name = \"%s\"; sp++;\n",
                              ename, vname);
                } break;
                    break;
                default:
                    cg_writef(cg, "    frame[sp] = astra_nil(); sp++;\n");
                    break;
                }
            }
        } break;

        case OPCODE_POP: {
            uint8_t n = inst.arg.index ? inst.arg.index : 1;
            cg_writef(cg, "    sp -= %u;\n", n);
        } break;

        case OPCODE_DUP: {
            cg_write(cg, "    frame[sp] = frame[sp-1]; sp++;\n");
        } break;

        case OPCODE_SWAP: {
            cg_write(cg, "    { AstraValue _tmp = frame[sp-1]; "
                     "frame[sp-1] = frame[sp-2]; frame[sp-2] = _tmp; }\n");
        } break;

        case OPCODE_GET_LOCAL: {
            cg_writef(cg, "    frame[sp] = frame[%u]; sp++;\n", inst.arg.index);
        } break;

        case OPCODE_SET_LOCAL: {
            cg_writef(cg, "    frame[%u] = frame[--sp];\n", inst.arg.index);
        } break;

        case OPCODE_GET_GLOBAL: {
            uint32_t name_idx = inst.arg.index;
            const char *gname = "g_unknown";
            if (name_idx < fn->const_len && fn->constants[name_idx].kind == VAL_STRING) {
                InternedString is = {0};
                is.str = fn->constants[name_idx].as.string_val;
                is.len = strlen(fn->constants[name_idx].as.string_val);
                gname = make_global_cname(cg, is);
            }
            cg_writef(cg, "    frame[sp] = %s; sp++;\n", gname);
        } break;

        case OPCODE_SET_GLOBAL: {
            uint32_t name_idx = inst.arg.index;
            const char *gname = "g_unknown";
            if (name_idx < fn->const_len && fn->constants[name_idx].kind == VAL_STRING) {
                InternedString is = {0};
                is.str = fn->constants[name_idx].as.string_val;
                is.len = strlen(fn->constants[name_idx].as.string_val);
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

        case OPCODE_JUMP: {
            int32_t offset = inst.arg.offset;
            cg_writef(cg, "    goto L_%zu;\n", ip + (size_t)offset);
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
            cg_writef(cg, "        if (_fnv.tag == AST_FN && _fnv.as.fn_val && "
                     "_fnv.as.fn_val->param_count == 255) {\n");
            cg_writef(cg, "            frame[_fn_slot] = "
                     "_fnv.as.fn_val->fun(frame + _fn_slot + 1, %u);\n", argc);
            cg_writef(cg, "            sp = _fn_slot + 1;\n");
            cg_writef(cg, "        } else if (_fnv.tag == AST_FN && _fnv.as.fn_val) {\n");
            cg_writef(cg, "            frame[_fn_slot] = "
                     "_fnv.as.fn_val->fun(frame + _fn_slot, %u);\n", argc);
            cg_writef(cg, "            sp = _fn_slot + 1;\n");
            cg_writef(cg, "        } else {\n");
            cg_writef(cg, "            astra_runtime_error(\"cannot call non-function\");\n");
            cg_writef(cg, "        }\n");
            cg_writef(cg, "    }\n");
        } break;

        case OPCODE_RET: {
            cg_write(cg, "    return frame[sp - 1];\n");
        } break;

        case OPCODE_NEW_ARRAY: {
            uint32_t n = inst.arg.index;
            cg_writef(cg, "    {\n");
            cg_writef(cg, "        AstraValue _elems[%u];\n", n);
            for (uint32_t j = 0; j < n; j++) {
                cg_writef(cg, "        _elems[%u] = frame[sp - %u];\n", j, n - j);
            }
            cg_writef(cg, "        sp -= %u;\n", n);
            cg_writef(cg, "        frame[sp] = astra_array_new(_elems, %u); sp++;\n", n);
            cg_writef(cg, "    }\n");
        } break;

        case OPCODE_INDEX: {
            cg_write(cg, "    {\n");
            cg_write(cg, "        AstraValue _idx = frame[--sp];\n");
            cg_write(cg, "        AstraValue _arr = frame[sp - 1];\n");
            cg_write(cg, "        frame[sp - 1] = _arr.as.array_val->elems[_idx.as.int_val];\n");
            cg_write(cg, "    }\n");
        } break;

        case OPCODE_LEN: {
            cg_write(cg, "    frame[sp-1] = astra_int(frame[sp-1].as.array_val->len);\n");
        } break;

        case OPCODE_SET_INDEX: {
            cg_write(cg, "    {\n");
            cg_write(cg, "        AstraValue _val = frame[--sp];\n");
            cg_write(cg, "        AstraValue _idx = frame[--sp];\n");
            cg_write(cg, "        AstraValue _arr = frame[sp - 1];\n");
            cg_write(cg, "        _arr.as.array_val->elems[_idx.as.int_val] = _val;\n");
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
            const char *fname = (name_idx < fn->const_len && fn->constants[name_idx].kind == VAL_STRING)
                               ? fn->constants[name_idx].as.string_val : "";
            cg_writef(cg, "    /* GET_FIELD '%s' */\n", fname);
            cg_writef(cg, "    {\n");
            cg_writef(cg, "        AstraValue _obj = frame[--sp];\n");
            cg_writef(cg, "        AstraStruct *_s = (AstraStruct *)_obj.as.struct_val;\n");
            cg_writef(cg, "        int _fi = -1;\n");
            cg_writef(cg, "        for (size_t _i = 0; _i < _s->def->field_count; _i++) {\n");
            cg_writef(cg, "            if (strcmp(_s->def->field_names[_i], \"%s\") == 0) { _fi = (int)_i; break; }\n", fname);
            cg_writef(cg, "        }\n");
            cg_writef(cg, "        frame[sp] = (_fi >= 0) ? _s->fields[_fi] : astra_nil(); sp++;\n");
            cg_writef(cg, "    }\n");
        } break;

        case OPCODE_SET_FIELD: {
            uint32_t name_idx = inst.arg.index;
            const char *fname = (name_idx < fn->const_len && fn->constants[name_idx].kind == VAL_STRING)
                               ? fn->constants[name_idx].as.string_val : "";
            cg_writef(cg, "    /* SET_FIELD '%s' */\n", fname);
            cg_writef(cg, "    {\n");
            cg_writef(cg, "        AstraValue _val = frame[--sp];\n");
            cg_writef(cg, "        AstraStruct *_s = (AstraStruct *)frame[sp-1].as.struct_val;\n");
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
            cg_writef(cg, "    {\n");
            cg_writef(cg, "        AstraEnum *_e = malloc(sizeof(AstraEnum));\n");
            cg_writef(cg, "        _e->tag = %u;\n", variant_idx);
            for (uint32_t j = 0; j < field_count; j++) {
                cg_writef(cg, "        _e->payload.variant_%u[%u] = frame[sp - %u];\n",
                          variant_idx, j, field_count - j);
            }
            cg_writef(cg, "        sp -= %u;\n", field_count);
            cg_writef(cg, "        frame[sp].tag = AST_ENUM_DATA; "
                     "frame[sp].as.enum_val = _e; sp++;\n");
            cg_writef(cg, "    }\n");
        } break;

        case OPCODE_GET_ENUM_FIELD: {
            uint32_t field_idx = inst.arg.index;
            cg_writef(cg, "    {\n");
            cg_writef(cg, "        AstraEnum *_e = frame[sp-1].as.enum_val;\n");
            cg_writef(cg, "        frame[sp-1] = _e->payload.variant_fields[%u];\n", field_idx);
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
            cg_writef(cg, "    frame[sp-1] = astra_bool(frame[sp-1].tag == %u);\n",
                      inst.arg.index);
        } break;
        case OPCODE_UNWRAP: {
            cg_write(cg, "    frame[sp-1] = astra_unwrap(frame[sp-1]);\n");
        } break;
        case OPCODE_TRY_UNWRAP: {
            cg_write(cg, "    ASTRA_TRY_UNWRAP(frame[sp-1]);\n");
        } break;

        case OPCODE_HALT: {
            cg_write(cg, "    return 0;\n");
        } break;

        default:
            cg_writef(cg, "    /* TODO: opcode %d */\n", inst.op);
            break;
        }

        ip++;
    }

    free(is_label);
    cg_write(cg, "    return frame[sp > 0 ? sp - 1 : 0];\n");
    cg_write(cg, "}\n\n");
}

/* -----------------------------------------------------------
 * Emit module-level code
 * ----------------------------------------------------------- */

static void emit_module_code(Codegen *cg) {
    cg_write(cg, "static int astra_module_main(void) {\n");
    cg_write(cg, "    AstraValue frame[1024];\n");
    cg_write(cg, "    uint16_t sp = 0;\n");
    cg_write(cg, "    (void)frame; (void)sp;\n\n");

    /* Initialize builtins */
    for (size_t i = 0; i < cg->global_map_count; i++) {
        if (strcmp(cg->global_map[i].name.str, "print") == 0) {
            cg_write(cg, "    g_print_init();\n");
            break;
        }
    }
    cg_write(cg, "\n");

    size_t code_len = 0;
    const Instruction *code = emitter_get_code(cg->emitter, &code_len);
    size_t const_len = 0;
    const Value *constants = emitter_get_constants(cg->emitter, &const_len);

    /* First pass: emit labels for jump targets */
    /* We need to know which ip values are jump targets */
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

    /* Second pass: emit code */
    for (size_t ip = 0; ip < code_len; ip++) {
        if (is_label[ip]) {
            cg_writef(cg, "    L_%zu: ;\n", ip);
        }

        Instruction inst = code[ip];

        switch (inst.op) {
        case OPCODE_CONST: {
            uint32_t idx = inst.arg.index;
            if (idx < const_len) {
                Value v = constants[idx];
                switch (v.kind) {
                case VAL_NIL:
                    cg_writef(cg, "    frame[sp] = astra_nil(); sp++;\n");
                    break;
                case VAL_BOOL:
                    cg_writef(cg, "    frame[sp] = astra_bool(%s); sp++;\n",
                              v.as.bool_val ? "1" : "0");
                    break;
                case VAL_INT:
                    cg_writef(cg, "    frame[sp] = astra_int(%ldL); sp++;\n",
                              (long)v.as.int_val);
                    break;
                case VAL_FLOAT:
                    cg_writef(cg, "    frame[sp] = astra_float(%g); sp++;\n",
                              v.as.float_val);
                    break;
                case VAL_STRING:
                    cg_writef(cg, "    frame[sp] = astra_string_new(\"%s\", %ld); sp++;\n",
                              v.as.string_val, (long)strlen(v.as.string_val));
                    break;
                case VAL_FN: {
                    FnObj *fn_obj = v.as.fn_val;
                    if (fn_obj && fn_obj->param_count == 255 && fn_obj->code == NULL) {
                        /* Print builtin */
                        cg_write(cg, "    frame[sp] = astra_fn_new((AstraFnPtr)astra_builtin_print, 255); sp++;\n");
                    } else {
                        /* Function reference — look up by name */
                        const char *fname = "unknown_fn";
                        for (size_t fi = 0; fi < cg->fn_map_count; fi++) {
                            for (size_t j = 0; j < code_len - 1; j++) {
                                if (code[j].op == OPCODE_CONST && code[j].arg.index == idx &&
                                    code[j+1].op == OPCODE_SET_GLOBAL) {
                                    uint32_t nidx = code[j+1].arg.index;
                                    if (nidx < const_len && constants[nidx].kind == VAL_STRING &&
                                        strcmp(constants[nidx].as.string_val, cg->fn_map[fi].name.str) == 0) {
                                        fname = cg->fn_map[fi].c_name;
                                        break;
                                    }
                                }
                            }
                        }
                        cg_writef(cg, "    frame[sp] = astra_fn_new((AstraFnPtr)%s, 0); sp++;\n", fname);
                    }
                } break;
                default:
                    cg_writef(cg, "    frame[sp] = astra_nil(); sp++;\n");
                    break;
                }
            }
        } break;

        case OPCODE_POP: {
            uint8_t n = inst.arg.index ? inst.arg.index : 1;
            cg_writef(cg, "    sp -= %u;\n", n);
        } break;

        case OPCODE_DUP:
            cg_write(cg, "    frame[sp] = frame[sp-1]; sp++;\n");
            break;

        case OPCODE_SWAP:
            cg_write(cg, "    { AstraValue _t = frame[sp-1]; "
                     "frame[sp-1] = frame[sp-2]; frame[sp-2] = _t; }\n");
            break;

        case OPCODE_GET_LOCAL:
            cg_writef(cg, "    frame[sp] = frame[%u]; sp++;\n", inst.arg.index);
            break;
        case OPCODE_SET_LOCAL:
            cg_writef(cg, "    frame[%u] = frame[--sp];\n", inst.arg.index);
            break;

        case OPCODE_GET_GLOBAL: {
            uint32_t name_idx = inst.arg.index;
            const char *gname = "g_unknown";
            if (name_idx < const_len && constants[name_idx].kind == VAL_STRING) {
                InternedString is = {0};
                is.str = constants[name_idx].as.string_val;
                is.len = strlen(constants[name_idx].as.string_val);
                gname = make_global_cname(cg, is);
            }
            cg_writef(cg, "    frame[sp] = %s; sp++;\n", gname);
        } break;

        case OPCODE_SET_GLOBAL: {
            uint32_t name_idx = inst.arg.index;
            const char *gname = "g_unknown";
            if (name_idx < const_len && constants[name_idx].kind == VAL_STRING) {
                InternedString is = {0};
                is.str = constants[name_idx].as.string_val;
                is.len = strlen(constants[name_idx].as.string_val);
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

        case OPCODE_JUMP: {
            int32_t offset = inst.arg.offset;
            cg_writef(cg, "    goto L_%zu;\n", ip + (size_t)offset);
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

        case OPCODE_PRINT:
            cg_write(cg, "    astra_builtin_print(&frame[sp - 1], 1); sp--;\n");
            break;

        case OPCODE_CALL: {
            uint8_t argc = inst.arg.arg_count;
            cg_writef(cg, "    {\n");
            cg_writef(cg, "        int _fn_slot = sp - 1 - %u;\n", argc);
            cg_writef(cg, "        AstraValue _fnv = frame[_fn_slot];\n");
            cg_writef(cg, "        if (_fnv.tag == AST_FN && _fnv.as.fn_val && "
                     "_fnv.as.fn_val->param_count == 255) {\n");
            cg_writef(cg, "            frame[_fn_slot] = "
                     "_fnv.as.fn_val->fun(frame + _fn_slot + 1, %u);\n", argc);
            cg_writef(cg, "            sp = _fn_slot + 1;\n");
            cg_writef(cg, "        } else if (_fnv.tag == AST_FN && _fnv.as.fn_val) {\n");
            cg_writef(cg, "            frame[_fn_slot] = "
                     "_fnv.as.fn_val->fun(frame + _fn_slot, %u);\n", argc);
            cg_writef(cg, "            sp = _fn_slot + 1;\n");
            cg_writef(cg, "        } else {\n");
            cg_writef(cg, "            fprintf(stderr, \"runtime error: cannot call non-function\\n\");\n");
            cg_writef(cg, "            return 1;\n");
            cg_writef(cg, "        }\n");
            cg_writef(cg, "    }\n");
        } break;

        case OPCODE_RET:
            cg_write(cg, "    return frame[sp - 1];\n");
            break;

        case OPCODE_HALT:
            cg_write(cg, "    return 0;\n");
            break;

        case OPCODE_NEW_ARRAY: {
            uint32_t n = inst.arg.index;
            cg_writef(cg, "    {\n");
            cg_writef(cg, "        AstraValue _elems[%u];\n", n);
            for (uint32_t j = 0; j < n; j++) {
                cg_writef(cg, "        _elems[%u] = frame[sp - %u];\n", j, n - j);
            }
            cg_writef(cg, "        sp -= %u;\n", n);
            cg_writef(cg, "        frame[sp] = astra_array_new(_elems, %u); sp++;\n", n);
            cg_writef(cg, "    }\n");
        } break;

        case OPCODE_INDEX: {
            cg_write(cg, "    {\n");
            cg_write(cg, "        AstraValue _idx = frame[--sp];\n");
            cg_write(cg, "        frame[sp-1] = frame[sp-1].as.array_val->elems[_idx.as.int_val];\n");
            cg_write(cg, "    }\n");
        } break;

        case OPCODE_LEN:
            cg_write(cg, "    frame[sp-1] = astra_int(frame[sp-1].as.array_val->len);\n");
            break;

        case OPCODE_SET_INDEX: {
            cg_write(cg, "    {\n");
            cg_write(cg, "        AstraValue _val = frame[--sp];\n");
            cg_write(cg, "        AstraValue _idx = frame[--sp];\n");
            cg_write(cg, "        frame[sp-1].as.array_val->elems[_idx.as.int_val] = _val;\n");
            cg_write(cg, "        frame[sp-1] = _val;\n");
            cg_write(cg, "    }\n");
        } break;

        case OPCODE_WRAP_OK:
            cg_write(cg, "    frame[sp-1] = astra_wrap_ok(frame[sp-1]);\n");
            break;
        case OPCODE_WRAP_ERR:
            cg_write(cg, "    frame[sp-1] = astra_wrap_err(frame[sp-1]);\n");
            break;
        case OPCODE_WRAP_SOME:
            cg_write(cg, "    frame[sp-1] = astra_wrap_some(frame[sp-1]);\n");
            break;
        case OPCODE_TAG_IS:
            cg_writef(cg, "    frame[sp-1] = astra_bool(frame[sp-1].tag == %u);\n",
                      inst.arg.index);
            break;
        case OPCODE_UNWRAP:
            cg_write(cg, "    frame[sp-1] = astra_unwrap(frame[sp-1]);\n");
            break;
        case OPCODE_TRY_UNWRAP:
            cg_write(cg, "    ASTRA_TRY_UNWRAP(frame[sp-1]);\n");
            break;

        default:
            cg_writef(cg, "    /* TODO: opcode %d at ip %zu */\n", inst.op, ip);
            break;
        }
    }

    free(is_label);
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

    /* Phase 2: Type declarations */
    emit_struct_decls(cg);
    emit_enum_decls(cg);

    /* Phase 2b: Struct def forward declarations */
    emit_struct_def_fwd_decls(cg);

    /* Phase 3: Global variables */
    emit_global_decls(cg);

    /* Phase 4: Function forward declarations */
    emit_fn_forward_decls(cg);

    /* Phase 5: Function bodies */
    emit_fn_bodies(cg);

    /* Phase 6: Module-level code */
    emit_module_code(cg);

    /* Phase 6b: Struct def definitions */
    emit_struct_def_globals(cg);

    /* Phase 7: main() */
    emit_main(cg);

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
    free(cg);
}
