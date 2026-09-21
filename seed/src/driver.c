#include "priv.h"

/* -----------------------------------------------------------
 * Token name lookup (for --dump-tokens)
 * ----------------------------------------------------------- */

const char *token_kind_name(TokenKind kind) {
    switch (kind) {
    case TOKEN_INT_LIT:    return "INT_LIT";
    case TOKEN_FLOAT_LIT:  return "FLOAT_LIT";
    case TOKEN_STRING_LIT: return "STRING_LIT";
    case TOKEN_IDENT:      return "IDENT";
    case TOKEN_FN:         return "fn";
    case TOKEN_LET:        return "let";
    case TOKEN_VAR:        return "var";
    case TOKEN_IF:         return "if";
    case TOKEN_ELSE:       return "else";
    case TOKEN_WHILE:      return "while";
    case TOKEN_FOR:        return "for";
    case TOKEN_MATCH:      return "match";
    case TOKEN_RETURN:     return "return";
    case TOKEN_BREAK:      return "break";
    case TOKEN_CONTINUE:   return "continue";
    case TOKEN_STRUCT:     return "struct";
    case TOKEN_ENUM:       return "enum";
    case TOKEN_TRAIT:      return "trait";
    case TOKEN_IMPL:       return "impl";
    case TOKEN_USE:        return "use";
    case TOKEN_MOD:        return "mod";
    case TOKEN_PUB:        return "pub";
    case TOKEN_MUT:        return "mut";
    case TOKEN_TRUE:       return "true";
    case TOKEN_FALSE:      return "false";
    case TOKEN_OK:         return "ok";
    case TOKEN_ERR:        return "err";
    case TOKEN_AND:        return "and";
    case TOKEN_OR:         return "or";
    case TOKEN_NOT:        return "not";
    case TOKEN_COMPTIME:   return "comptime";
    case TOKEN_CONST:      return "const";
    case TOKEN_IN:         return "in";
    case TOKEN_SOME:       return "some";
    case TOKEN_NONE:       return "none";
    case TOKEN_OPTION:     return "option";
    case TOKEN_RESULT:     return "result";
    case TOKEN_PLUS:       return "+";
    case TOKEN_MINUS:      return "-";
    case TOKEN_STAR:       return "*";
    case TOKEN_SLASH:      return "/";
    case TOKEN_PERCENT:    return "%";
    case TOKEN_EQ:         return "=";
    case TOKEN_EQ_EQ:      return "==";
    case TOKEN_NEQ:        return "!=";
    case TOKEN_LT:         return "<";
    case TOKEN_GT:         return ">";
    case TOKEN_LE:         return "<=";
    case TOKEN_GE:         return ">=";
    case TOKEN_AND_AND:    return "&&";
    case TOKEN_OR_OR:      return "||";
    case TOKEN_BANG:       return "!";
    case TOKEN_AMP:        return "&";
    case TOKEN_PIPE:       return "|";
    case TOKEN_CARET:      return "^";
    case TOKEN_TILDE:      return "~";
    case TOKEN_SHL:        return "<<";
    case TOKEN_SHR:        return ">>";
    case TOKEN_ARROW:      return "->";
    case TOKEN_FAT_ARROW:  return "=>";
    case TOKEN_DOT:        return ".";
    case TOKEN_COMMA:      return ",";
    case TOKEN_SEMICOLON:  return ";";
    case TOKEN_COLON:      return ":";
    case TOKEN_COLON_COLON:return "::";
    case TOKEN_LPAREN:     return "(";
    case TOKEN_RPAREN:     return ")";
    case TOKEN_LBRACKET:   return "[";
    case TOKEN_RBRACKET:   return "]";
    case TOKEN_LBRACE:     return "{";
    case TOKEN_RBRACE:     return "}";
    case TOKEN_QUESTION:   return "?";
    case TOKEN_DOTDOT:     return "..";
    case TOKEN_DOTDOT_EQ:  return "..=";
    case TOKEN_UNDERSCORE: return "_";
    case TOKEN_NEWLINE:    return "NEWLINE";
    case TOKEN_EOF:        return "EOF";
    case TOKEN_ERROR:      return "ERROR";
    }
    return "UNKNOWN";
}

/* -----------------------------------------------------------
 * Token printer (for --dump-tokens)
 * ----------------------------------------------------------- */

void token_print(Token t) {
    printf("%u:%u  %-14s", t.loc.line, t.loc.column, token_kind_name(t.kind));

    if (t.kind == TOKEN_INT_LIT) {
        printf("  %ld", (long)t.literal.int_val);
    } else if (t.kind == TOKEN_FLOAT_LIT) {
        printf("  %g", t.literal.float_val);
    } else if (t.kind == TOKEN_STRING_LIT || t.kind == TOKEN_IDENT) {
        printf("  \"%.*s\"", (int)t.text.len, t.text.str);
    }

    printf("\n");
}

/* -----------------------------------------------------------
 * AST dump (for --dump-ast)
 * ----------------------------------------------------------- */

static void indent_print(int indent) {
    for (int i = 0; i < indent; i++) printf("  ");
}

static void dump_node(Node *node, int indent);

static void dump_block(BlockExpr *b, int indent) {
    for (size_t i = 0; i < b->stmts.len; i++) {
        dump_node(b->stmts.data[i], indent);
    }
    if (b->last_expr) {
        dump_node(b->last_expr, indent);
    }
}

void ast_dump(Node *node, int indent) {
    dump_node(node, indent);
}

static void dump_node(Node *node, int indent) {
    if (!node) {
        indent_print(indent);
        printf("(null)\n");
        return;
    }

    indent_print(indent);

    switch (node->kind) {
    case NODE_INT_LIT:
        printf("IntLit(%ld)\n", (long)node->as.int_lit.value);
        break;
    case NODE_PAYLOAD: {
        printf("Payload\n");
        for (size_t i = 0; i < node->as.payload.fields.len; i++) {
            indent_print(indent + 1);
            PayloadField *pf = &node->as.payload.fields.data[i];
            if (pf->name.str) {
                printf("Field(%.*s:)\n", (int)pf->name.len, pf->name.str);
            } else {
                printf("Field\n");
            }
            dump_node(pf->type, indent + 2);
        }
    } break;
    case NODE_FLOAT_LIT:
        printf("FloatLit(%g)\n", node->as.float_lit.value);
        break;
    case NODE_STRING_LIT:
        printf("StringLit(\"%.*s\")\n",
               (int)node->as.string_lit.value.len,
               node->as.string_lit.value.str);
        break;
    case NODE_BOOL_LIT:
        printf("BoolLit(%s)\n", node->as.bool_lit.value ? "true" : "false");
        break;
    case NODE_IDENT:
        printf("Ident(%.*s)\n",
               (int)node->as.ident.name.len,
               node->as.ident.name.str);
        break;
    case NODE_BINARY_OP: {
        const char *op = "?";
        switch (node->as.binary.op) {
        case OP_ADD:      op = "+";  break;
        case OP_SUB:      op = "-";  break;
        case OP_MUL:      op = "*";  break;
        case OP_DIV:      op = "/";  break;
        case OP_MOD:      op = "%";  break;
        case OP_EQ:       op = "=="; break;
        case OP_NEQ:      op = "!="; break;
        case OP_LT:       op = "<";  break;
        case OP_GT:       op = ">";  break;
        case OP_LE:       op = "<="; break;
        case OP_GE:       op = ">="; break;
        case OP_AND:      op = "and"; break;
        case OP_OR:       op = "or";  break;
        case OP_BIT_AND:  op = "&";  break;
        case OP_BIT_OR:   op = "|";  break;
        case OP_BIT_XOR:  op = "^";  break;
        case OP_SHL:      op = "<<"; break;
        case OP_SHR:      op = ">>"; break;
        }
        printf("BinaryOp(%s)\n", op);
        dump_node(node->as.binary.left, indent + 1);
        dump_node(node->as.binary.right, indent + 1);
        break;
    }
    case NODE_UNARY_OP: {
        const char *op = "?";
        switch (node->as.unary.op) {
        case UNOP_NEG:      op = "-";  break;
        case UNOP_NOT:      op = "!";  break;
        case UNOP_BIT_NOT:  op = "~";  break;
        case UNOP_REF:      op = "&";  break;
        case UNOP_DEREF:    op = "*";  break;
        }
        printf("UnaryOp(%s)\n", op);
        dump_node(node->as.unary.operand, indent + 1);
        break;
    }
    case NODE_CALL:
        printf("Call\n");
        dump_node(node->as.call.callee, indent + 1);
        for (size_t i = 0; i < node->as.call.args.len; i++) {
            dump_node(node->as.call.args.data[i], indent + 1);
        }
        break;
    case NODE_PATTERN_WILDCARD:
        printf("PatternWildcard\n");
        break;
    case NODE_PATTERN_OR:
        printf("PatternOr(%zu)\n", node->as.pattern_or.alts.len);
        for (size_t i = 0; i < node->as.pattern_or.alts.len; i++) {
            dump_node(node->as.pattern_or.alts.data[i], indent + 1);
        }
        break;
    case NODE_INDEX:
        printf("Index\n");
        dump_node(node->as.index.object, indent + 1);
        dump_node(node->as.index.index, indent + 1);
        break;
    case NODE_ARRAY_LIT:
        printf("ArrayLit(%zu)\n", node->as.array_lit.elems.len);
        for (size_t i = 0; i < node->as.array_lit.elems.len; i++) {
            dump_node(node->as.array_lit.elems.data[i], indent + 1);
        }
        break;
    case NODE_RANGE:
        printf("Range(%s)\n", node->as.range.inclusive ? "..=" : "..");
        if (node->as.range.start) dump_node(node->as.range.start, indent + 1);
        if (node->as.range.end)   dump_node(node->as.range.end, indent + 1);
        break;
    case NODE_STRUCT_LIT:
        printf("StructLit(%.*s)\n",
               (int)node->as.struct_lit.name.len,
               node->as.struct_lit.name.str);
        for (size_t i = 0; i < node->as.struct_lit.field_names.len; i++) {
            indent_print(indent + 1);
            printf("Field(%.*s)\n",
                   (int)node->as.struct_lit.field_names.data[i].len,
                   node->as.struct_lit.field_names.data[i].str);
            dump_node(node->as.struct_lit.field_values.data[i], indent + 2);
        }
        break;
    case NODE_FIELD_ACCESS:
        printf("FieldAccess(%.*s)\n",
               (int)node->as.field_access.field.len,
               node->as.field_access.field.str);
        dump_node(node->as.field_access.object, indent + 1);
        break;
    case NODE_OPTIONAL_CHAIN:
        printf("OptionalChain\n");
        break;
    case NODE_BLOCK:
        printf("Block\n");
        dump_block(&node->as.block, indent + 1);
        break;
    case NODE_IF:
        printf("If\n");
        dump_node(node->as.if_expr.cond, indent + 1);
        dump_node(node->as.if_expr.then_block, indent + 1);
        if (node->as.if_expr.else_block) {
            indent_print(indent + 1);
            printf("Else\n");
            dump_node(node->as.if_expr.else_block, indent + 2);
        }
        break;
    case NODE_WHILE:
        printf("While\n");
        dump_node(node->as.while_expr.cond, indent + 1);
        dump_node(node->as.while_expr.body, indent + 1);
        break;
    case NODE_FOR:
        printf("For(%.*s)\n",
               (int)node->as.for_expr.var.len,
               node->as.for_expr.var.str);
        dump_node(node->as.for_expr.iter, indent + 1);
        dump_node(node->as.for_expr.body, indent + 1);
        break;
    case NODE_MATCH:
        printf("Match\n");
        dump_node(node->as.match_expr.target, indent + 1);
        for (size_t i = 0; i < node->as.match_expr.arms.len; i++) {
            indent_print(indent + 1);
            printf("Arm\n");
            dump_node(node->as.match_expr.arms.data[i].pattern, indent + 2);
            dump_node(node->as.match_expr.arms.data[i].body, indent + 2);
        }
        break;
    case NODE_RETURN:
        printf("Return\n");
        if (node->as.return_expr.value) {
            dump_node(node->as.return_expr.value, indent + 1);
        }
        break;
    case NODE_BREAK:
        printf("Break\n");
        break;
    case NODE_CONTINUE:
        printf("Continue\n");
        break;
    case NODE_ASSIGN:
        printf("Assign\n");
        if (node->as.assign.target) {
            dump_node(node->as.assign.target, indent + 1);
        } else {
            /* Ident targets keep the name mirror for cheap dumps. */
            indent_print(indent + 1);
            printf("Assign(%.*s)\n",
                   (int)node->as.assign.name.len,
                   node->as.assign.name.str);
        }
        dump_node(node->as.assign.value, indent + 1);
        break;
    case NODE_FN_DECL:
        printf("FnDecl(%.*s)\n",
               (int)node->as.fn_decl.name.len,
               node->as.fn_decl.name.str);
        for (size_t i = 0; i < node->as.fn_decl.params.len; i++) {
            indent_print(indent + 1);
            printf("Param(%.*s)\n",
                   (int)node->as.fn_decl.params.data[i].len,
                   node->as.fn_decl.params.data[i].str);
            dump_node(node->as.fn_decl.param_types.data[i], indent + 2);
        }
        if (node->as.fn_decl.return_type) {
            indent_print(indent + 1);
            printf("ReturnType\n");
            dump_node(node->as.fn_decl.return_type, indent + 2);
        }
        dump_node(node->as.fn_decl.body, indent + 1);
        break;
    case NODE_STRUCT_DECL:
        printf("StructDecl(%.*s)\n",
               (int)node->as.struct_decl.name.len,
               node->as.struct_decl.name.str);
        for (size_t i = 0; i < node->as.struct_decl.field_names.len; i++) {
            indent_print(indent + 1);
            printf("Field(%.*s)\n",
                   (int)node->as.struct_decl.field_names.data[i].len,
                   node->as.struct_decl.field_names.data[i].str);
            dump_node(node->as.struct_decl.field_types.data[i], indent + 2);
        }
        break;
    case NODE_ENUM_DECL:
        printf("EnumDecl(%.*s)\n",
               (int)node->as.enum_decl.name.len,
               node->as.enum_decl.name.str);
        for (size_t i = 0; i < node->as.enum_decl.variants.len; i++) {
            indent_print(indent + 1);
            printf("Variant(%.*s)\n",
                   (int)node->as.enum_decl.variants.data[i].len,
                   node->as.enum_decl.variants.data[i].str);
            Node *payload = node->as.enum_decl.variant_payloads.len > i
                ? node->as.enum_decl.variant_payloads.data[i] : NULL;
            if (payload) {
                for (size_t j = 0; j < payload->as.payload.fields.len; j++) {
                    indent_print(indent + 2);
                    PayloadField *pf = &payload->as.payload.fields.data[j];
                    if (pf->name.str) {
                        printf("Field(%.*s:)\n", (int)pf->name.len, pf->name.str);
                    } else {
                        printf("Field\n");
                    }
                    dump_node(pf->type, indent + 3);
                }
            }
        }
        break;
    case NODE_CONST_DECL:
        printf("ConstDecl(%.*s)\n",
               (int)node->as.const_decl.name.len,
               node->as.const_decl.name.str);
        if (node->as.const_decl.type) dump_node(node->as.const_decl.type, indent + 1);
        if (node->as.const_decl.value) dump_node(node->as.const_decl.value, indent + 1);
        break;
    case NODE_VAR_DECL:
        printf("VarDecl(%.*s%s)\n",
               (int)node->as.var_decl.name.len,
               node->as.var_decl.name.str,
               node->as.var_decl.is_mut ? ", mut" : "");
        if (node->as.var_decl.type) dump_node(node->as.var_decl.type, indent + 1);
        if (node->as.var_decl.value) dump_node(node->as.var_decl.value, indent + 1);
        break;
    case NODE_TYPE_IDENT:
        printf("TypeIdent(%.*s)\n",
               (int)node->as.type_ident.name.len,
               node->as.type_ident.name.str);
        break;
    case NODE_TYPE_OPTIONAL:
        printf("TypeOptional\n");
        dump_node(node->as.type_optional.inner, indent + 1);
        break;
    case NODE_TYPE_ARRAY:
        printf("TypeArray\n");
        dump_node(node->as.type_array.elem_type, indent + 1);
        if (node->as.type_array.size) dump_node(node->as.type_array.size, indent + 1);
        break;
    case NODE_TYPE_FN:
        printf("TypeFn\n");
        for (size_t i = 0; i < node->as.type_fn.param_types.len; i++) {
            dump_node(node->as.type_fn.param_types.data[i], indent + 1);
        }
        if (node->as.type_fn.return_type) dump_node(node->as.type_fn.return_type, indent + 1);
        break;
    case NODE_MODULE:
        printf("Module\n");
        for (size_t i = 0; i < node->as.module.items.len; i++) {
            dump_node(node->as.module.items.data[i], indent + 1);
        }
        break;
    case NODE_USE:
        printf("Use\n");
        break;
    case NODE_IMPL:
        printf("Impl\n");
        break;
    case NODE_COMPOUND_ASSIGN:
        printf("CompoundAssign\n");
        break;
    }
}

/* -----------------------------------------------------------
 * Create compiler with mode flags
 * ----------------------------------------------------------- */

Compiler *driver_create(const char *filename, const char *source,
                        size_t source_len, bool dump_tokens, bool dump_ast) {
    Arena *arena = arena_create(source_len + 4096);
    if (!arena) {
        fprintf(stderr, "error: out of memory\n");
        return NULL;
    }

    StringTable *strings = string_table_create(arena);
    Lexer *lexer = lexer_create(filename, source, source_len, strings, arena);
    Parser *parser = NULL;

    /* Don't create parser in dump-tokens mode — parser_create consumes first token */
    if (!dump_tokens) {
        parser = parser_create(lexer, arena, strings);
    }

    if (!strings || !lexer || (!dump_tokens && !parser)) {
        fprintf(stderr, "error: out of memory\n");
        arena_destroy(arena);
        return NULL;
    }

    CompilerDriver *d = arena_new(arena, CompilerDriver);
    if (!d) {
        arena_destroy(arena);
        return NULL;
    }

    d->base.arena   = arena;
    d->base.strings = strings;
    d->base.lexer   = lexer;
    d->base.parser  = parser;
    d->base.checker = NULL;
    d->base.emitter = NULL;
    d->base.vm      = NULL;
    d->dump_tokens  = dump_tokens;
    d->dump_ast     = dump_ast;
    return &d->base;
}

/* -----------------------------------------------------------
 * Pipeline phases
 * ----------------------------------------------------------- */

static bool run_dump_tokens(Compiler *c) {
    Token t;
    for (;;) {
        t = lexer_next(c->lexer);
        token_print(t);
        if (t.kind == TOKEN_EOF || t.kind == TOKEN_ERROR) break;
    }
    return t.kind != TOKEN_ERROR;
}

static bool run_dump_ast(Compiler *c) {
    Node *module = parser_parse_module(c->parser);
    if (!module) {
        fprintf(stderr, "error: parse failed\n");
        return false;
    }
    ast_dump(module, 0);
    return true;
}

static bool run_full_pipeline(Compiler *c) {
    Node *module = parser_parse_module(c->parser);
    if (!module || parser_had_error(c->parser)) {
        fprintf(stderr, "error: parse failed\n");
        return false;
    }

    TypeChecker *tc = typechecker_create(c->arena, c->strings);
    if (!tc) {
        fprintf(stderr, "error: out of memory\n");
        return false;
    }
    c->checker = tc;

    Type *result = typecheck(tc, module);
    if (!result || typechecker_error_count(tc) > 0) {
        fprintf(stderr, "error: type check failed with %d error(s)\n",
                typechecker_error_count(tc));
        return false;
    }

    Emitter *emitter = emitter_create(c->arena, c->strings);
    if (!emitter) {
        fprintf(stderr, "error: out of memory\n");
        return false;
    }
    c->emitter = emitter;

    emitter_emit(emitter, module);

    if (emitter_error_count(emitter) > 0) {
        fprintf(stderr, "error: code generation failed with %d error(s)\n",
                emitter_error_count(emitter));
        return false;
    }

    size_t code_len = 0, const_len = 0;
    const Instruction *code = emitter_get_code(emitter, &code_len);
    const Value *constants = emitter_get_constants(emitter, &const_len);

    VM *vm = vm_create(c->arena);
    if (!vm) {
        fprintf(stderr, "error: out of memory\n");
        return false;
    }
    c->vm = vm;

    Value *consts_copy = NULL;
    if (const_len > 0) {
        consts_copy = arena_alloc(c->arena, sizeof(Value) * const_len, _Alignof(Value));
        if (!consts_copy) {
            fprintf(stderr, "error: out of memory\n");
            return false;
        }
        memcpy(consts_copy, constants, sizeof(Value) * const_len);
    }

    VMResult res = vm_run(vm, code, code_len, consts_copy, const_len);
    if (res != VM_OK) {
        const char *file = (c->lexer && c->lexer->filename) ? c->lexer->filename : "<input>";
        if (vm->error_msg) {
            fprintf(stderr, "%s:%u: runtime error: %s\n",
                    file, vm->error_line, vm->error_msg);
        } else {
            fprintf(stderr, "%s: runtime error\n", file);
        }
        return false;
    }

    return true;
}

/* -----------------------------------------------------------
 * Public API (delegates to internal driver)
 * ----------------------------------------------------------- */

Compiler *compiler_create(const char *filename, const char *source, size_t source_len) {
    return driver_create(filename, source, source_len, false, false);
}

VMResult compiler_run(Compiler *c) {
    CompilerDriver *d = (CompilerDriver *)c;
    bool ok;

    if (d->dump_tokens) {
        ok = run_dump_tokens(c);
    } else if (d->dump_ast) {
        ok = run_dump_ast(c);
    } else {
        ok = run_full_pipeline(c);
    }

    return ok ? VM_OK : VM_RUNTIME_ERROR;
}

void compiler_destroy(Compiler *c) {
    if (!c) return;

    CompilerDriver *d = (CompilerDriver *)c;
    Arena *arena = c->arena;

    if (c->vm) vm_destroy(c->vm);
    if (c->lexer) lexer_destroy(c->lexer);

    (void)d;
    arena_destroy(arena);
}
