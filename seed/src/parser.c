#include "priv.h"

/* ============================================================
 * Astra Seed Compiler — Parser
 * Recursive descent + Pratt parsing
 * ============================================================ */

struct Parser {
    Lexer        *lexer;
    Arena        *arena;
    StringTable  *strings;
    Token         current;
    Token         previous;
    bool          had_error;
    /* Set while parsing a construct whose trailing `{` belongs to the
     * construct itself (if/while/for conditions), so an identifier followed
     * by `{` is not mistaken for a struct literal. */
    bool          no_struct_lit;
    /* True when the statement just parsed was terminated by a `;`. A block's
     * trailing expression must NOT be: `Block ::= "{" Statement* Expression?
     * "}"` is how research/010 §4.2 says a value is discarded. Without this
     * flag an expression statement ending in `;` was indistinguishable from a
     * tail expression, because optional_semi swallows both `;` and newlines. */
    bool          last_stmt_semi;
};

/* -----------------------------------------------------------
 * Utility
 * ----------------------------------------------------------- */

static void parser_error(Parser *p, const char *msg) {
    fprintf(stderr, "error:");
    srcloc_print(p->current.loc);
    fprintf(stderr, ": %s\n", msg);
    p->had_error = true;
}

static void advance(Parser *p) {
    p->previous = p->current;
    p->current  = lexer_next(p->lexer);
}

static bool check(Parser *p, TokenKind kind) {
    return p->current.kind == kind;
}

static bool match(Parser *p, TokenKind kind) {
    if (check(p, kind)) {
        advance(p);
        return true;
    }
    return false;
}

static void expect(Parser *p, TokenKind kind, const char *msg) {
    if (check(p, kind)) {
        advance(p);
    } else {
        fprintf(stderr, "error:");
        srcloc_print(p->current.loc);
        fprintf(stderr, ": expected %s, got %s\n", msg, token_kind_name(p->current.kind));
        p->had_error = true;
    }
}

/* Skip newlines */
static void skip_newlines(Parser *p) {
    while (check(p, TOKEN_NEWLINE)) advance(p);
}

/* Error recovery: skip tokens until a sync point */
static void synchronize(Parser *p) {
    while (!check(p, TOKEN_EOF)) {
        if (check(p, TOKEN_SEMICOLON) || check(p, TOKEN_RBRACE)) return;
        switch (p->current.kind) {
            case TOKEN_FN: case TOKEN_STRUCT: case TOKEN_ENUM:
            case TOKEN_LET: case TOKEN_CONST: case TOKEN_USE:
            case TOKEN_IF: case TOKEN_WHILE: case TOKEN_FOR:
            case TOKEN_RETURN: case TOKEN_BREAK: case TOKEN_CONTINUE:
                return;
            default:
                break;
        }
        advance(p);
    }
}

/* Consume optional semicolons and newlines, recording whether a real `;` was
 * seen: a statement terminated by one has no value (research/010 §4.2). */
static void optional_semi(Parser *p) {
    while (check(p, TOKEN_NEWLINE) || check(p, TOKEN_SEMICOLON)) {
        if (check(p, TOKEN_SEMICOLON)) p->last_stmt_semi = true;
        advance(p);
    }
}

/* -----------------------------------------------------------
 * Forward declarations
 * ----------------------------------------------------------- */

static Node *parse_statement(Parser *p);
static Node *parse_declaration(Parser *p);
static Node *parse_block(Parser *p);
static Node *parse_type(Parser *p);

/* -----------------------------------------------------------
 * Growable list helper (arena-backed)
 * ----------------------------------------------------------- */

static void node_list_push(Parser *p, Node ***data, size_t *len, size_t *cap, Node *n) {
    if (*len >= *cap) {
        size_t new_cap = *cap == 0 ? 8 : *cap * 2;
        Node **nd = arena_new_array(p->arena, Node *, new_cap);
        if (*data) memcpy(nd, *data, sizeof(Node *) * (*len));
        *data = nd;
        *cap  = new_cap;
    }
    (*data)[(*len)++] = n;
}

static void istring_list_push(Parser *p, InternedString **data, size_t *len,
                              size_t *cap, InternedString s) {
    if (*len >= *cap) {
        size_t new_cap = *cap == 0 ? 8 : *cap * 2;
        InternedString *nd = arena_new_array(p->arena, InternedString, new_cap);
        if (*data) memcpy(nd, *data, sizeof(InternedString) * (*len));
        *data = nd;
        *cap  = new_cap;
    }
    (*data)[(*len)++] = s;
}

/* -----------------------------------------------------------
 * Pratt parsing — expression precedence
 * ----------------------------------------------------------- */

typedef enum {
    PREC_NONE,
    PREC_ASSIGN,   /* = */
    PREC_RANGE,    /* .. ..= */
    PREC_OR,       /* || */
    PREC_AND,      /* && */
    PREC_BIT_OR,   /* | */
    PREC_BIT_XOR,  /* ^ */
    PREC_BIT_AND,  /* & */
    PREC_EQ,       /* == != */
    PREC_COMP,     /* < > <= >= */
    PREC_SHIFT,    /* << >> */
    PREC_ADD,      /* + - */
    PREC_MUL,      /* * / % */
    PREC_UNARY,    /* - ! ~ & * */
    PREC_POSTFIX,  /* () [] . */
    PREC_PRIMARY,
} Precedence;

typedef Node *(*ParseFn)(Parser *p, Node *left, Precedence prec);

/* -----------------------------------------------------------
 * Forward declarations (after Precedence)
 * ----------------------------------------------------------- */

static Node *parse_expression(Parser *p);
static Node *parse_expression_with_prec(Parser *p, Precedence min_prec);

/* -----------------------------------------------------------
 * Primary expressions
 * ----------------------------------------------------------- */

static Node *parse_int_lit(Parser *p, Node *left, Precedence prec) {
    (void)left; (void)prec;
    Node *n = node_new(p->arena, NODE_INT_LIT, p->previous.loc);
    n->as.int_lit.value = p->previous.literal.int_val;
    return n;
}

static Node *parse_float_lit(Parser *p, Node *left, Precedence prec) {
    (void)left; (void)prec;
    Node *n = node_new(p->arena, NODE_FLOAT_LIT, p->previous.loc);
    n->as.float_lit.value = p->previous.literal.float_val;
    return n;
}

static Node *parse_string_lit(Parser *p, Node *left, Precedence prec) {
    (void)left; (void)prec;
    Node *n = node_new(p->arena, NODE_STRING_LIT, p->previous.loc);
    n->as.string_lit.value = p->previous.text;
    return n;
}

static Node *parse_bool_lit(Parser *p, Node *left, Precedence prec) {
    (void)left; (void)prec;
    Node *n = node_new(p->arena, NODE_BOOL_LIT, p->previous.loc);
    n->as.bool_lit.value = (p->previous.kind == TOKEN_TRUE);
    return n;
}

static Node *parse_null_lit(Parser *p, Node *left, Precedence prec) {
    (void)left; (void)prec;
    return node_new(p->arena, NODE_NULL_LIT, p->previous.loc);
}

static Node *parse_ident(Parser *p, Node *left, Precedence prec) {
    (void)left; (void)prec;
    Node *n = node_new(p->arena, NODE_IDENT, p->previous.loc);
    n->as.ident.name = p->previous.text;
    return n;
}

static Node *parse_paren(Parser *p, Node *left, Precedence prec) {
    (void)left; (void)prec;
    /* Parenthesised expressions may contain struct literals. */
    bool saved = p->no_struct_lit;
    p->no_struct_lit = false;
    Node *expr = parse_expression_with_prec(p, PREC_NONE);
    p->no_struct_lit = saved;
    expect(p, TOKEN_RPAREN, "')'");
    return expr;
}

/* -----------------------------------------------------------
 * Pratt — infix operators
 * ----------------------------------------------------------- */

static BinaryOp token_to_binary_op(TokenKind kind) {
    switch (kind) {
        case TOKEN_PLUS:    return OP_ADD;
        case TOKEN_MINUS:   return OP_SUB;
        case TOKEN_STAR:    return OP_MUL;
        case TOKEN_SLASH:   return OP_DIV;
        case TOKEN_PERCENT: return OP_MOD;
        case TOKEN_EQ_EQ:   return OP_EQ;
        case TOKEN_NEQ:     return OP_NEQ;
        case TOKEN_LT:      return OP_LT;
        case TOKEN_GT:      return OP_GT;
        case TOKEN_LE:      return OP_LE;
        case TOKEN_GE:      return OP_GE;
        case TOKEN_AND_AND: return OP_AND;
        case TOKEN_OR_OR:   return OP_OR;
        case TOKEN_AMP:     return OP_BIT_AND;
        case TOKEN_PIPE:    return OP_BIT_OR;
        case TOKEN_CARET:   return OP_BIT_XOR;
        case TOKEN_SHL:     return OP_SHL;
        case TOKEN_SHR:     return OP_SHR;
        default:            return OP_ADD; /* unreachable */
    }
}

static Precedence token_to_prec(TokenKind kind) {
    switch (kind) {
        case TOKEN_EQ:
            return PREC_ASSIGN;
        case TOKEN_OR_OR:
            return PREC_OR;
        case TOKEN_AND_AND:
            return PREC_AND;
        case TOKEN_PIPE:
            return PREC_BIT_OR;
        case TOKEN_CARET:
            return PREC_BIT_XOR;
        case TOKEN_AMP:
            return PREC_BIT_AND;
        case TOKEN_EQ_EQ: case TOKEN_NEQ:
            return PREC_EQ;
        case TOKEN_LT: case TOKEN_GT: case TOKEN_LE: case TOKEN_GE:
            return PREC_COMP;
        case TOKEN_SHL: case TOKEN_SHR:
            return PREC_SHIFT;
        case TOKEN_PLUS: case TOKEN_MINUS:
            return PREC_ADD;
        case TOKEN_STAR: case TOKEN_SLASH: case TOKEN_PERCENT:
            return PREC_MUL;
        case TOKEN_DOTDOT: case TOKEN_DOTDOT_EQ:
            return PREC_RANGE;
        case TOKEN_LPAREN: case TOKEN_LBRACKET: case TOKEN_DOT:
            return PREC_POSTFIX;
        default:
            return PREC_NONE;
    }
}

static Node *parse_binary(Parser *p, Node *left, Precedence prec) {
    TokenKind op_kind = p->previous.kind;
    SrcLoc loc = p->previous.loc;
    Precedence next = (Precedence)((int)prec + 1);
    Node *right = parse_expression_with_prec(p, next);
    Node *n = node_new(p->arena, NODE_BINARY_OP, loc);
    n->as.binary.op   = token_to_binary_op(op_kind);
    n->as.binary.left  = left;
    n->as.binary.right = right;
    return n;
}

static Node *parse_assignment(Parser *p, Node *left, Precedence prec) {
    if (left->kind != NODE_IDENT) {
        parser_error(p, "invalid assignment target");
        return left;
    }
    SrcLoc loc = left->loc;
    InternedString name = left->as.ident.name;
    Node *value = parse_expression_with_prec(p, prec);
    Node *n = node_new(p->arena, NODE_ASSIGN, loc);
    n->as.assign.name  = name;
    n->as.assign.value = value;
    return n;
}

static Node *parse_call(Parser *p, Node *left, Precedence prec) {
    (void)prec;
    SrcLoc loc = left->loc;
    Node *n = node_new(p->arena, NODE_CALL, loc);
    n->as.call.callee = left;
    /* parse argument list */
    if (!check(p, TOKEN_RPAREN)) {
        do {
            Node *arg = parse_expression(p);
            /* da_push for args */
            if (n->as.call.args.len >= n->as.call.args.cap) {
                size_t new_cap = n->as.call.args.cap == 0 ? 8 : n->as.call.args.cap * 2;
                Node **new_data = arena_new_array(p->arena, Node *, new_cap);
                if (n->as.call.args.data) {
                    memcpy(new_data, n->as.call.args.data, sizeof(Node *) * n->as.call.args.len);
                }
                n->as.call.args.data = new_data;
                n->as.call.args.cap  = new_cap;
            }
            n->as.call.args.data[n->as.call.args.len++] = arg;
        } while (match(p, TOKEN_COMMA));
    }
    expect(p, TOKEN_RPAREN, "')'");
    return n;
}

static Node *parse_range(Parser *p, Node *left, TokenKind kind) {
    SrcLoc loc = left->loc;
    Precedence next = (Precedence)((int)token_to_prec(kind) + 1);
    Node *end = NULL;
    /* Open-ended ranges (`0..`) are allowed when the following token cannot
     * start an expression. */
    switch (p->current.kind) {
        case TOKEN_RBRACE: case TOKEN_RPAREN: case TOKEN_RBRACKET:
        case TOKEN_SEMICOLON: case TOKEN_NEWLINE: case TOKEN_EOF:
        case TOKEN_COMMA:
            break;
        default:
            end = parse_expression_with_prec(p, next);
            break;
    }
    Node *n = node_new(p->arena, NODE_RANGE, loc);
    n->as.range.start     = left;
    n->as.range.end       = end;
    n->as.range.inclusive = (kind == TOKEN_DOTDOT_EQ);
    return n;
}

static Node *parse_array_literal(Parser *p) {
    SrcLoc loc = p->previous.loc;
    Node *n = node_new(p->arena, NODE_ARRAY_LIT, loc);
    n->as.array_lit.elems.data = NULL;
    n->as.array_lit.elems.len  = 0;
    n->as.array_lit.elems.cap  = 0;

    skip_newlines(p);
    if (!check(p, TOKEN_RBRACKET)) {
        for (;;) {
            skip_newlines(p);
            Node *elem = parse_expression(p);
            node_list_push(p, &n->as.array_lit.elems.data,
                           &n->as.array_lit.elems.len,
                           &n->as.array_lit.elems.cap, elem);
            skip_newlines(p);
            if (!match(p, TOKEN_COMMA)) break;
            if (check(p, TOKEN_RBRACKET)) break; /* trailing comma */
        }
    }
    expect(p, TOKEN_RBRACKET, "']'");
    return n;
}

/* Parse `Name { field: value, ... }`. `p->current` is the `{`. */
static Node *parse_struct_literal(Parser *p, InternedString name, SrcLoc loc) {
    Node *n = node_new(p->arena, NODE_STRUCT_LIT, loc);
    n->as.struct_lit.name = name;
    n->as.struct_lit.field_names.data = NULL;
    n->as.struct_lit.field_names.len  = 0;
    n->as.struct_lit.field_names.cap  = 0;
    n->as.struct_lit.field_values.data = NULL;
    n->as.struct_lit.field_values.len  = 0;
    n->as.struct_lit.field_values.cap  = 0;

    expect(p, TOKEN_LBRACE, "'{'");
    skip_newlines(p);

    while (!check(p, TOKEN_RBRACE) && !check(p, TOKEN_EOF)) {
        expect(p, TOKEN_IDENT, "field name");
        InternedString fname = p->previous.text;
        expect(p, TOKEN_COLON, "':'");

        bool saved = p->no_struct_lit;
        p->no_struct_lit = false;
        Node *value = parse_expression(p);
        p->no_struct_lit = saved;

        istring_list_push(p, &n->as.struct_lit.field_names.data,
                          &n->as.struct_lit.field_names.len,
                          &n->as.struct_lit.field_names.cap, fname);
        node_list_push(p, &n->as.struct_lit.field_values.data,
                       &n->as.struct_lit.field_values.len,
                       &n->as.struct_lit.field_values.cap, value);

        skip_newlines(p);
        if (!match(p, TOKEN_COMMA)) break;
        skip_newlines(p);
    }
    expect(p, TOKEN_RBRACE, "'}'");
    return n;
}

static Node *parse_index(Parser *p, Node *left, Precedence prec) {
    (void)prec;
    SrcLoc loc = left->loc;
    Node *index = parse_expression(p);
    expect(p, TOKEN_RBRACKET, "']'");
    Node *n = node_new(p->arena, NODE_INDEX, loc);
    n->as.index.object = left;
    n->as.index.index  = index;
    return n;
}

static Node *parse_field_access(Parser *p, Node *left, Precedence prec) {
    (void)prec;
    expect(p, TOKEN_IDENT, "field name");
    SrcLoc loc = left->loc;
    Node *n = node_new(p->arena, NODE_FIELD_ACCESS, loc);
    n->as.field_access.object = left;
    n->as.field_access.field  = p->previous.text;
    return n;
}

/* -----------------------------------------------------------
 * Prefix operators
 * ----------------------------------------------------------- */

static Node *parse_unary(Parser *p) {
    TokenKind kind = p->previous.kind;
    SrcLoc loc = p->previous.loc;
    /* Bind the operand tightly so `-5 + 8` is `(-5) + 8`, not `-(5 + 8)`. */
    Node *operand = parse_expression_with_prec(p, PREC_UNARY);
    Node *n = node_new(p->arena, NODE_UNARY_OP, loc);
    switch (kind) {
        case TOKEN_MINUS:  n->as.unary.op = UNOP_NEG; break;
        case TOKEN_BANG:   n->as.unary.op = UNOP_NOT; break;
        case TOKEN_TILDE:  n->as.unary.op = UNOP_BIT_NOT; break;
        case TOKEN_AMP:    n->as.unary.op = UNOP_REF; break;
        case TOKEN_STAR:   n->as.unary.op = UNOP_DEREF; break;
        default: break;
    }
    n->as.unary.operand = operand;
    return n;
}

/* -----------------------------------------------------------
 * Block expression
 * ----------------------------------------------------------- */

static Node *parse_block(Parser *p) {
    SrcLoc loc = p->previous.loc;
    Node *n = node_new(p->arena, NODE_BLOCK, loc);
    n->as.block.stmts.data = NULL;
    n->as.block.stmts.len  = 0;
    n->as.block.stmts.cap  = 0;
    n->as.block.last_expr  = NULL;

    skip_newlines(p);
    while (!check(p, TOKEN_RBRACE) && !check(p, TOKEN_EOF)) {
        /* Check if this is an expression that could be the last expr in the block */
        if (check(p, TOKEN_IDENT) || check(p, TOKEN_INT_LIT) || check(p, TOKEN_FLOAT_LIT) ||
            check(p, TOKEN_STRING_LIT) || check(p, TOKEN_TRUE) || check(p, TOKEN_FALSE) ||
            check(p, TOKEN_NULL) || check(p, TOKEN_MINUS) || check(p, TOKEN_BANG) ||
            check(p, TOKEN_LPAREN) || check(p, TOKEN_LBRACE) || check(p, TOKEN_IF) ||
            check(p, TOKEN_WHILE) || check(p, TOKEN_FOR) || check(p, TOKEN_MATCH)) {

            /* Peek ahead: if next meaningful token is ; it's a statement */
            /* For simplicity, parse as statement and check for last expr */
        }

        Node *stmt = parse_statement(p);
        if (stmt) {
            /* This is the block's tail expression only when it is the last item
             * in the block AND was not terminated by a `;`. A `;` discards the
             * value, which is what makes `{ 7; }` void and `{ 7 }` an i32. */
            if (!p->last_stmt_semi &&
                (check(p, TOKEN_RBRACE) || check(p, TOKEN_EOF))) {
                if (stmt->kind != NODE_FN_DECL && stmt->kind != NODE_STRUCT_DECL &&
                    stmt->kind != NODE_ENUM_DECL && stmt->kind != NODE_CONST_DECL &&
                    stmt->kind != NODE_VAR_DECL && stmt->kind != NODE_RETURN &&
                    stmt->kind != NODE_BREAK && stmt->kind != NODE_CONTINUE) {
                    n->as.block.last_expr = stmt;
                    break;
                }
            }
            /* da_push for stmts */
            if (n->as.block.stmts.len >= n->as.block.stmts.cap) {
                size_t new_cap = n->as.block.stmts.cap == 0 ? 16 : n->as.block.stmts.cap * 2;
                Node **new_data = arena_new_array(p->arena, Node *, new_cap);
                if (n->as.block.stmts.data) {
                    memcpy(new_data, n->as.block.stmts.data, sizeof(Node *) * n->as.block.stmts.len);
                }
                n->as.block.stmts.data = new_data;
                n->as.block.stmts.cap  = new_cap;
            }
            n->as.block.stmts.data[n->as.block.stmts.len++] = stmt;
        }
        skip_newlines(p);
    }
    expect(p, TOKEN_RBRACE, "'}'");
    return n;
}

/* -----------------------------------------------------------
 * If expression
 * ----------------------------------------------------------- */

static Node *parse_if(Parser *p) {
    SrcLoc loc = p->previous.loc;
    Node *n = node_new(p->arena, NODE_IF, loc);
    skip_newlines(p);
    bool saved_nsl = p->no_struct_lit;
    p->no_struct_lit = true;
    n->as.if_expr.cond = parse_expression(p);
    p->no_struct_lit = saved_nsl;
    skip_newlines(p);
    expect(p, TOKEN_LBRACE, "'{' for if body");
    n->as.if_expr.then_block = parse_block(p);
    n->as.if_expr.else_block = NULL;
    if (match(p, TOKEN_ELSE)) {
        skip_newlines(p);
        if (check(p, TOKEN_IF)) {
            advance(p);
            /* Create an if node for else-if */
            Node *elif = parse_if(p);
            /* Wrap in a block */
            Node *blk = node_new(p->arena, NODE_BLOCK, elif->loc);
            blk->as.block.stmts.data = arena_new_array(p->arena, Node *, 1);
            blk->as.block.stmts.len = 1;
            blk->as.block.stmts.cap = 1;
            blk->as.block.stmts.data[0] = elif;
            blk->as.block.last_expr = NULL;
            n->as.if_expr.else_block = blk;
        } else {
            expect(p, TOKEN_LBRACE, "'{' for else body");
            n->as.if_expr.else_block = parse_block(p);
        }
    }
    return n;
}

/* -----------------------------------------------------------
 * While expression
 * ----------------------------------------------------------- */

static Node *parse_while(Parser *p) {
    SrcLoc loc = p->previous.loc;
    Node *n = node_new(p->arena, NODE_WHILE, loc);
    skip_newlines(p);
    bool saved_nsl = p->no_struct_lit;
    p->no_struct_lit = true;
    n->as.while_expr.cond = parse_expression(p);
    p->no_struct_lit = saved_nsl;
    skip_newlines(p);
    expect(p, TOKEN_LBRACE, "'{' for while body");
    n->as.while_expr.body = parse_block(p);
    return n;
}

/* -----------------------------------------------------------
 * For expression
 * ----------------------------------------------------------- */

static Node *parse_for(Parser *p) {
    SrcLoc loc = p->previous.loc;
    Node *n = node_new(p->arena, NODE_FOR, loc);
    skip_newlines(p);
    expect(p, TOKEN_IDENT, "loop variable name");
    n->as.for_expr.var = p->previous.text;
    skip_newlines(p);
    expect(p, TOKEN_IN, "'in'");
    skip_newlines(p);
    bool saved_nsl = p->no_struct_lit;
    p->no_struct_lit = true;
    n->as.for_expr.iter = parse_expression(p);
    p->no_struct_lit = saved_nsl;
    skip_newlines(p);
    expect(p, TOKEN_LBRACE, "'{' for for body");
    n->as.for_expr.body = parse_block(p);
    return n;
}

/* -----------------------------------------------------------
 * Patterns (match arms)
 * -----------------------------------------------------------
 * Astra-0 supports: wildcard `_`, literals, enum variants `Enum.Variant`
 * and or-patterns `A | B`. Binding patterns are a later tier.
 */

static Node *parse_pattern_primary(Parser *p) {
    SrcLoc loc = p->current.loc;

    switch (p->current.kind) {
    case TOKEN_UNDERSCORE:
        advance(p);
        return node_new(p->arena, NODE_PATTERN_WILDCARD, loc);

    case TOKEN_INT_LIT:
        advance(p);
        return parse_int_lit(p, NULL, PREC_PRIMARY);

    case TOKEN_FLOAT_LIT:
        advance(p);
        return parse_float_lit(p, NULL, PREC_PRIMARY);

    case TOKEN_STRING_LIT:
        advance(p);
        return parse_string_lit(p, NULL, PREC_PRIMARY);

    case TOKEN_TRUE:
    case TOKEN_FALSE:
        advance(p);
        return parse_bool_lit(p, NULL, PREC_PRIMARY);

    case TOKEN_MINUS: {
        advance(p);
        if (p->current.kind != TOKEN_INT_LIT && p->current.kind != TOKEN_FLOAT_LIT) {
            parser_error(p, "expected a numeric literal after '-' in pattern");
            return node_new(p->arena, NODE_PATTERN_WILDCARD, loc);
        }
        return parse_unary(p);
    }

    case TOKEN_IDENT: {
        advance(p);
        Token id = p->previous;
        if (match(p, TOKEN_DOT)) {
            expect(p, TOKEN_IDENT, "variant name");
            Node *obj = node_new(p->arena, NODE_IDENT, id.loc);
            obj->as.ident.name = id.text;
            Node *n = node_new(p->arena, NODE_FIELD_ACCESS, id.loc);
            n->as.field_access.object = obj;
            n->as.field_access.field  = p->previous.text;
            return n;
        }
        parser_error(p, "unsupported pattern: binding patterns are not supported in Astra-0");
        Node *n = node_new(p->arena, NODE_IDENT, id.loc);
        n->as.ident.name = id.text;
        return n;
    }

    default:
        parser_error(p, "expected a pattern ('_', literal or Enum.Variant)");
        advance(p);
        return node_new(p->arena, NODE_PATTERN_WILDCARD, loc);
    }
}

static Node *parse_pattern(Parser *p) {
    Node *first = parse_pattern_primary(p);
    if (!check(p, TOKEN_PIPE)) return first;

    Node *n = node_new(p->arena, NODE_PATTERN_OR, first->loc);
    n->as.pattern_or.alts.data = NULL;
    n->as.pattern_or.alts.len  = 0;
    n->as.pattern_or.alts.cap  = 0;
    node_list_push(p, &n->as.pattern_or.alts.data,
                   &n->as.pattern_or.alts.len,
                   &n->as.pattern_or.alts.cap, first);

    while (match(p, TOKEN_PIPE)) {
        Node *alt = parse_pattern_primary(p);
        node_list_push(p, &n->as.pattern_or.alts.data,
                       &n->as.pattern_or.alts.len,
                       &n->as.pattern_or.alts.cap, alt);
    }
    return n;
}

static Node *parse_match(Parser *p) {
    SrcLoc loc = p->previous.loc;
    Node *n = node_new(p->arena, NODE_MATCH, loc);
    n->as.match_expr.arms.data = NULL;
    n->as.match_expr.arms.len  = 0;
    n->as.match_expr.arms.cap  = 0;

    bool saved_nsl = p->no_struct_lit;
    p->no_struct_lit = true;
    n->as.match_expr.target = parse_expression(p);
    p->no_struct_lit = saved_nsl;

    skip_newlines(p);
    expect(p, TOKEN_LBRACE, "'{' for match");
    skip_newlines(p);

    while (!check(p, TOKEN_RBRACE) && !check(p, TOKEN_EOF)) {
        Node *pattern = parse_pattern(p);

        if (check(p, TOKEN_IF)) {
            parser_error(p, "match guards are not supported in Astra-0");
            advance(p);
            (void)parse_expression(p);
        }
        expect(p, TOKEN_FAT_ARROW, "'=>'");
        skip_newlines(p);

        Node *body;
        if (check(p, TOKEN_LBRACE)) {
            advance(p);
            body = parse_block(p);
        } else {
            body = parse_expression(p);
        }

        MatchArm *arm = arena_new(p->arena, MatchArm);
        arm->pattern = pattern;
        arm->body    = body;
        if (n->as.match_expr.arms.len >= n->as.match_expr.arms.cap) {
            size_t new_cap = n->as.match_expr.arms.cap == 0 ? 8 : n->as.match_expr.arms.cap * 2;
            MatchArm *nd = arena_new_array(p->arena, MatchArm, new_cap);
            if (n->as.match_expr.arms.data) {
                memcpy(nd, n->as.match_expr.arms.data, sizeof(MatchArm) * n->as.match_expr.arms.len);
            }
            n->as.match_expr.arms.data = nd;
            n->as.match_expr.arms.cap  = new_cap;
        }
        n->as.match_expr.arms.data[n->as.match_expr.arms.len++] = *arm;

        skip_newlines(p);
        if (!match(p, TOKEN_COMMA)) break;
        skip_newlines(p);
    }
    expect(p, TOKEN_RBRACE, "'}'");
    return n;
}

/* -----------------------------------------------------------
 * Return statement
 * ----------------------------------------------------------- */

static Node *parse_return(Parser *p) {
    SrcLoc loc = p->previous.loc;
    Node *n = node_new(p->arena, NODE_RETURN, loc);
    n->as.return_expr.value = NULL;
    if (!check(p, TOKEN_SEMICOLON) && !check(p, TOKEN_NEWLINE) && !check(p, TOKEN_RBRACE)) {
        n->as.return_expr.value = parse_expression(p);
    }
    optional_semi(p);
    return n;
}

/* -----------------------------------------------------------
 * Function declaration
 * ----------------------------------------------------------- */

static Node *parse_fn_decl(Parser *p) {
    SrcLoc loc = p->previous.loc;
    expect(p, TOKEN_IDENT, "function name");
    Node *n = node_new(p->arena, NODE_FN_DECL, loc);
    n->as.fn_decl.name = p->previous.text;
    n->as.fn_decl.params.data    = NULL;
    n->as.fn_decl.params.len     = 0;
    n->as.fn_decl.params.cap     = 0;
    n->as.fn_decl.param_types.data = NULL;
    n->as.fn_decl.param_types.len  = 0;
    n->as.fn_decl.param_types.cap  = 0;
    n->as.fn_decl.return_type = NULL;

    /* Parameters */
    expect(p, TOKEN_LPAREN, "'('");
    if (!check(p, TOKEN_RPAREN)) {
        do {
            expect(p, TOKEN_IDENT, "parameter name");
            /* param name */
            if (n->as.fn_decl.params.len >= n->as.fn_decl.params.cap) {
                size_t new_cap = n->as.fn_decl.params.cap == 0 ? 8 : n->as.fn_decl.params.cap * 2;
                InternedString *new_data = arena_new_array(p->arena, InternedString, new_cap);
                if (n->as.fn_decl.params.data) {
                    memcpy(new_data, n->as.fn_decl.params.data, sizeof(InternedString) * n->as.fn_decl.params.len);
                }
                n->as.fn_decl.params.data = new_data;
                n->as.fn_decl.params.cap  = new_cap;
            }
            n->as.fn_decl.params.data[n->as.fn_decl.params.len++] = p->previous.text;

            /* parameter type */
            expect(p, TOKEN_COLON, "':'");
            Node *ptype = parse_type(p);
            if (n->as.fn_decl.param_types.len >= n->as.fn_decl.param_types.cap) {
                size_t new_cap = n->as.fn_decl.param_types.cap == 0 ? 8 : n->as.fn_decl.param_types.cap * 2;
                Node **new_data = arena_new_array(p->arena, Node *, new_cap);
                if (n->as.fn_decl.param_types.data) {
                    memcpy(new_data, n->as.fn_decl.param_types.data, sizeof(Node *) * n->as.fn_decl.param_types.len);
                }
                n->as.fn_decl.param_types.data = new_data;
                n->as.fn_decl.param_types.cap  = new_cap;
            }
            n->as.fn_decl.param_types.data[n->as.fn_decl.param_types.len++] = ptype;
        } while (match(p, TOKEN_COMMA));
    }
    expect(p, TOKEN_RPAREN, "')'");

    /* Return type */
    if (match(p, TOKEN_ARROW)) {
        n->as.fn_decl.return_type = parse_type(p);
    }

    /* Body */
    skip_newlines(p);
    expect(p, TOKEN_LBRACE, "'{' for function body");
    n->as.fn_decl.body = parse_block(p);
    return n;
}

/* -----------------------------------------------------------
 * Struct declaration
 * ----------------------------------------------------------- */

static Node *parse_struct_decl(Parser *p) {
    SrcLoc loc = p->previous.loc;
    expect(p, TOKEN_IDENT, "struct name");
    Node *n = node_new(p->arena, NODE_STRUCT_DECL, loc);
    n->as.struct_decl.name = p->previous.text;
    n->as.struct_decl.field_names.data = NULL;
    n->as.struct_decl.field_names.len  = 0;
    n->as.struct_decl.field_names.cap  = 0;
    n->as.struct_decl.field_types.data = NULL;
    n->as.struct_decl.field_types.len  = 0;
    n->as.struct_decl.field_types.cap  = 0;

    expect(p, TOKEN_LBRACE, "'{'");
    skip_newlines(p);
    while (!check(p, TOKEN_RBRACE) && !check(p, TOKEN_EOF)) {
        expect(p, TOKEN_IDENT, "field name");
        /* field name */
        if (n->as.struct_decl.field_names.len >= n->as.struct_decl.field_names.cap) {
            size_t new_cap = n->as.struct_decl.field_names.cap == 0 ? 8 : n->as.struct_decl.field_names.cap * 2;
            InternedString *new_data = arena_new_array(p->arena, InternedString, new_cap);
            if (n->as.struct_decl.field_names.data) {
                memcpy(new_data, n->as.struct_decl.field_names.data,
                       sizeof(InternedString) * n->as.struct_decl.field_names.len);
            }
            n->as.struct_decl.field_names.data = new_data;
            n->as.struct_decl.field_names.cap  = new_cap;
        }
        n->as.struct_decl.field_names.data[n->as.struct_decl.field_names.len++] = p->previous.text;

        expect(p, TOKEN_COLON, "':'");
        Node *ftype = parse_type(p);
        if (n->as.struct_decl.field_types.len >= n->as.struct_decl.field_types.cap) {
            size_t new_cap = n->as.struct_decl.field_types.cap == 0 ? 8 : n->as.struct_decl.field_types.cap * 2;
            Node **new_data = arena_new_array(p->arena, Node *, new_cap);
            if (n->as.struct_decl.field_types.data) {
                memcpy(new_data, n->as.struct_decl.field_types.data,
                       sizeof(Node *) * n->as.struct_decl.field_types.len);
            }
            n->as.struct_decl.field_types.data = new_data;
            n->as.struct_decl.field_types.cap  = new_cap;
        }
        n->as.struct_decl.field_types.data[n->as.struct_decl.field_types.len++] = ftype;

        optional_semi(p);
        skip_newlines(p);
    }
    expect(p, TOKEN_RBRACE, "'}'");
    return n;
}

/* -----------------------------------------------------------
 * Enum declaration
 * ----------------------------------------------------------- */

static Node *parse_enum_decl(Parser *p) {
    SrcLoc loc = p->previous.loc;
    expect(p, TOKEN_IDENT, "enum name");
    Node *n = node_new(p->arena, NODE_ENUM_DECL, loc);
    n->as.enum_decl.name = p->previous.text;
    n->as.enum_decl.variants.data = NULL;
    n->as.enum_decl.variants.len  = 0;
    n->as.enum_decl.variants.cap  = 0;

    expect(p, TOKEN_LBRACE, "'{'");
    skip_newlines(p);
    while (!check(p, TOKEN_RBRACE) && !check(p, TOKEN_EOF)) {
        expect(p, TOKEN_IDENT, "variant name");
        if (n->as.enum_decl.variants.len >= n->as.enum_decl.variants.cap) {
            size_t new_cap = n->as.enum_decl.variants.cap == 0 ? 8 : n->as.enum_decl.variants.cap * 2;
            InternedString *new_data = arena_new_array(p->arena, InternedString, new_cap);
            if (n->as.enum_decl.variants.data) {
                memcpy(new_data, n->as.enum_decl.variants.data,
                       sizeof(InternedString) * n->as.enum_decl.variants.len);
            }
            n->as.enum_decl.variants.data = new_data;
            n->as.enum_decl.variants.cap  = new_cap;
        }
        n->as.enum_decl.variants.data[n->as.enum_decl.variants.len++] = p->previous.text;
        optional_semi(p);
        skip_newlines(p);
    }
    expect(p, TOKEN_RBRACE, "'}'");
    return n;
}

/* -----------------------------------------------------------
 * Let/Var declaration
 * ----------------------------------------------------------- */

static Node *parse_var_decl(Parser *p, bool is_const) {
    SrcLoc loc = p->previous.loc;
    bool is_mut = false;
    if (!is_const && match(p, TOKEN_MUT)) {
        is_mut = true;
    }
    expect(p, TOKEN_IDENT, "variable name");
    InternedString name = p->previous.text;

    Node *type_annot = NULL;
    if (match(p, TOKEN_COLON)) {
        type_annot = parse_type(p);
    }

    Node *value = NULL;
    if (match(p, TOKEN_EQ)) {
        value = parse_expression(p);
    }

    optional_semi(p);

    if (is_const) {
        Node *n = node_new(p->arena, NODE_CONST_DECL, loc);
        n->as.const_decl.name  = name;
        n->as.const_decl.type  = type_annot;
        n->as.const_decl.value = value;
        return n;
    } else {
        Node *n = node_new(p->arena, NODE_VAR_DECL, loc);
        n->as.var_decl.name   = name;
        n->as.var_decl.type   = type_annot;
        n->as.var_decl.value  = value;
        n->as.var_decl.is_mut = is_mut;
        return n;
    }
}

/* -----------------------------------------------------------
 * Use declaration
 * ----------------------------------------------------------- */

static Node *parse_use(Parser *p) {
    SrcLoc loc = p->previous.loc;
    /* Parse path: ident (:: ident)* */
    expect(p, TOKEN_IDENT, "module path");
    while (match(p, TOKEN_COLON_COLON)) {
        expect(p, TOKEN_IDENT, "module path segment");
    }
    optional_semi(p);
    /* For now, just return a use node (not fully implemented) */
    Node *n = node_new(p->arena, NODE_USE, loc);
    return n;
}

/* -----------------------------------------------------------
 * Type parsing
 * ----------------------------------------------------------- */

static Node *parse_type(Parser *p) {
    if (check(p, TOKEN_IDENT)) {
        advance(p);
        Node *n = node_new(p->arena, NODE_TYPE_IDENT, p->previous.loc);
        n->as.type_ident.name = p->previous.text;
        return n;
    }
    if (match(p, TOKEN_LBRACKET)) {
        SrcLoc loc = p->previous.loc;
        Node *elem = parse_type(p);
        Node *size = NULL;
        if (match(p, TOKEN_SEMICOLON)) {
            size = parse_expression(p);
        }
        expect(p, TOKEN_RBRACKET, "']'");
        Node *n = node_new(p->arena, NODE_TYPE_ARRAY, loc);
        n->as.type_array.elem_type = elem;
        n->as.type_array.size      = size;
        return n;
    }
    if (match(p, TOKEN_FN)) {
        SrcLoc loc = p->previous.loc;
        Node *n = node_new(p->arena, NODE_TYPE_FN, loc);
        n->as.type_fn.param_types.data = NULL;
        n->as.type_fn.param_types.len  = 0;
        n->as.type_fn.param_types.cap  = 0;
        n->as.type_fn.return_type = NULL;
        expect(p, TOKEN_LPAREN, "'('");
        if (!check(p, TOKEN_RPAREN)) {
            do {
                Node *pt = parse_type(p);
                if (n->as.type_fn.param_types.len >= n->as.type_fn.param_types.cap) {
                    size_t new_cap = n->as.type_fn.param_types.cap == 0 ? 8 : n->as.type_fn.param_types.cap * 2;
                    Node **new_data = arena_new_array(p->arena, Node *, new_cap);
                    if (n->as.type_fn.param_types.data) {
                        memcpy(new_data, n->as.type_fn.param_types.data,
                               sizeof(Node *) * n->as.type_fn.param_types.len);
                    }
                    n->as.type_fn.param_types.data = new_data;
                    n->as.type_fn.param_types.cap  = new_cap;
                }
                n->as.type_fn.param_types.data[n->as.type_fn.param_types.len++] = pt;
            } while (match(p, TOKEN_COMMA));
        }
        expect(p, TOKEN_RPAREN, "')'");
        if (match(p, TOKEN_ARROW)) {
            n->as.type_fn.return_type = parse_type(p);
        }
        return n;
    }
    parser_error(p, "expected type");
    /* Return a void type as fallback */
    Node *n = node_new(p->arena, NODE_TYPE_IDENT, p->current.loc);
    n->as.type_ident.name = string_intern_cstr(p->strings, "void");
    return n;
}

/* -----------------------------------------------------------
 * Statements
 * ----------------------------------------------------------- */

static Node *parse_statement(Parser *p) {
    skip_newlines(p);

    p->last_stmt_semi = false;

    if (check(p, TOKEN_EOF)) return NULL;

    /* Declaration keywords */
    if (check(p, TOKEN_FN))     { advance(p); return parse_fn_decl(p); }
    if (check(p, TOKEN_STRUCT)) { advance(p); return parse_struct_decl(p); }
    if (check(p, TOKEN_ENUM))   { advance(p); return parse_enum_decl(p); }
    if (check(p, TOKEN_CONST))  { advance(p); return parse_var_decl(p, true); }
    if (check(p, TOKEN_USE))    { advance(p); return parse_use(p); }

    /* Let/Var declaration (uses 'let' keyword) */
    if (check(p, TOKEN_LET)) {
        advance(p);
        return parse_var_decl(p, false);
    }

    /* Statements */
    if (check(p, TOKEN_IF))    { advance(p); return parse_if(p); }
    if (check(p, TOKEN_WHILE)) { advance(p); return parse_while(p); }
    if (check(p, TOKEN_FOR))   { advance(p); return parse_for(p); }
    if (check(p, TOKEN_RETURN)) { advance(p); return parse_return(p); }
    if (check(p, TOKEN_MATCH))  { advance(p); return parse_match(p); }

    if (check(p, TOKEN_BREAK)) {
        advance(p);
        optional_semi(p);
        return node_new(p->arena, NODE_BREAK, p->previous.loc);
    }
    if (check(p, TOKEN_CONTINUE)) {
        advance(p);
        optional_semi(p);
        return node_new(p->arena, NODE_CONTINUE, p->previous.loc);
    }

    /* Block */
    if (check(p, TOKEN_LBRACE)) {
        advance(p);
        return parse_block(p);
    }

    /* Expression statement */
    Node *expr = parse_expression(p);
    optional_semi(p);
    return expr;
}

/* -----------------------------------------------------------
 * Pratt parser — main expression entry
 * ----------------------------------------------------------- */

static Node *parse_expression_with_prec(Parser *p, Precedence min_prec) {
    /* nud: prefix tokens */
    Node *left = NULL;
    switch (p->current.kind) {
        case TOKEN_INT_LIT:
            advance(p);
            left = parse_int_lit(p, NULL, PREC_PRIMARY);
            break;
        case TOKEN_FLOAT_LIT:
            advance(p);
            left = parse_float_lit(p, NULL, PREC_PRIMARY);
            break;
        case TOKEN_STRING_LIT:
            advance(p);
            left = parse_string_lit(p, NULL, PREC_PRIMARY);
            break;
        case TOKEN_TRUE: case TOKEN_FALSE:
            advance(p);
            left = parse_bool_lit(p, NULL, PREC_PRIMARY);
            break;
        case TOKEN_NULL:
            advance(p);
            left = parse_null_lit(p, NULL, PREC_PRIMARY);
            break;
        case TOKEN_IDENT: {
            advance(p);
            Token id = p->previous;
            if (!p->no_struct_lit && check(p, TOKEN_LBRACE)) {
                left = parse_struct_literal(p, id.text, id.loc);
            } else {
                left = parse_ident(p, NULL, PREC_PRIMARY);
            }
        } break;
        case TOKEN_LPAREN:
            advance(p);
            left = parse_paren(p, NULL, PREC_PRIMARY);
            break;
        case TOKEN_LBRACE:
            advance(p);
            left = parse_block(p);
            break;
        case TOKEN_LBRACKET:
            advance(p);
            left = parse_array_literal(p);
            break;
        case TOKEN_IF:
            advance(p);
            left = parse_if(p);
            break;
        case TOKEN_MATCH:
            advance(p);
            left = parse_match(p);
            break;
        case TOKEN_MINUS: case TOKEN_BANG: case TOKEN_TILDE:
        case TOKEN_AMP: case TOKEN_STAR:
            advance(p);
            left = parse_unary(p);
            break;
        default:
            parser_error(p, "unexpected token in expression");
            advance(p);
            /* Return a dummy ident node */
            left = node_new(p->arena, NODE_IDENT, p->previous.loc);
            left->as.ident.name = string_intern_cstr(p->strings, "<?>");
            return left;
    }

    /* led: infix operators — consume while precedence >= min_prec */
    for (;;) {
        Precedence prec = token_to_prec(p->current.kind);
        if (prec == PREC_NONE) break;
        if ((int)prec < (int)min_prec) break;

        TokenKind kind = p->current.kind;
        advance(p);

        switch (kind) {
            case TOKEN_EQ:
                left = parse_assignment(p, left, prec);
                break;
            case TOKEN_LPAREN:
                left = parse_call(p, left, prec);
                break;
            case TOKEN_LBRACKET:
                left = parse_index(p, left, prec);
                break;
            case TOKEN_DOT:
                left = parse_field_access(p, left, prec);
                break;
            case TOKEN_DOTDOT:
            case TOKEN_DOTDOT_EQ:
                left = parse_range(p, left, kind);
                break;
            default:
                left = parse_binary(p, left, prec);
                break;
        }
    }

    return left;
}

static Node *parse_expression(Parser *p) {
    return parse_expression_with_prec(p, PREC_NONE);
}

/* -----------------------------------------------------------
 * Module (top-level)
 * ----------------------------------------------------------- */

static Node *parse_declaration(Parser *p) {
    skip_newlines(p);
    if (check(p, TOKEN_EOF)) return NULL;
    size_t err_before = p->had_error;
    Node *decl = parse_statement(p);
    if (p->had_error && !err_before) {
        synchronize(p);
        return NULL;
    }
    return decl;
}

/* -----------------------------------------------------------
 * Public API
 * ----------------------------------------------------------- */

Parser *parser_create(Lexer *lexer, Arena *arena, StringTable *strings) {
    Parser *p = arena_new(arena, Parser);
    p->lexer   = lexer;
    p->arena   = arena;
    p->strings = strings;
    p->had_error = false;
    p->no_struct_lit = false;
    /* Load first token */
    advance(p);
    return p;
}

Node *parser_parse_module(Parser *p) {
    SrcLoc loc = p->current.loc;
    Node *mod = node_new(p->arena, NODE_MODULE, loc);
    mod->as.module.items.data = NULL;
    mod->as.module.items.len  = 0;
    mod->as.module.items.cap  = 0;

    while (!check(p, TOKEN_EOF)) {
        Node *decl = parse_declaration(p);
        if (decl) {
            if (mod->as.module.items.len >= mod->as.module.items.cap) {
                size_t new_cap = mod->as.module.items.cap == 0 ? 16 : mod->as.module.items.cap * 2;
                Node **new_data = arena_new_array(p->arena, Node *, new_cap);
                if (mod->as.module.items.data) {
                    memcpy(new_data, mod->as.module.items.data, sizeof(Node *) * mod->as.module.items.len);
                }
                mod->as.module.items.data = new_data;
                mod->as.module.items.cap  = new_cap;
            }
            mod->as.module.items.data[mod->as.module.items.len++] = decl;
        }
        skip_newlines(p);
    }

    return mod;
}

bool parser_had_error(Parser *p) {
    return p ? p->had_error : true;
}

void parser_destroy(Parser *p) {
    (void)p; /* arena handles cleanup */
}

/* -----------------------------------------------------------
 * Exposed for the construct registry self-check, so that the
 * operator table in src/constructs/operator_table.c and this
 * parser cannot drift apart (see ConstructSpec up in
 * src/constructs/construct.h).
 * ----------------------------------------------------------- */

uint8_t parser_precedence_of(TokenKind kind) {
    return (uint8_t)token_to_prec(kind);
}

BinaryOp parser_binary_op_of(TokenKind kind) {
    return token_to_binary_op(kind);
}
