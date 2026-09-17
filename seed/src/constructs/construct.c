#include "constructs/construct.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

/* ============================================================
 * Construct registry — queries, dumps and the registry self-check.
 *
 * The table itself lives in registry.c (one entry per construct file)
 * and the operator table in operator_table.c. Everything here is
 * generic: it never names a specific construct.
 * ============================================================ */

extern const ConstructSpec *const astra_constructs[];
extern const size_t               astra_construct_count;

/* ------------------------------------------------------------
 * Queries
 * ------------------------------------------------------------ */

const ConstructSpec *construct_table(size_t *out_count) {
    if (out_count) *out_count = astra_construct_count;
    return astra_constructs[0];
}

const ConstructSpec *construct_lookup(const char *name) {
    if (!name) return NULL;
    for (size_t i = 0; i < astra_construct_count; i++) {
        if (strcmp(astra_constructs[i]->name, name) == 0) return astra_constructs[i];
    }
    return NULL;
}

const ConstructSpec *construct_by_token(TokenKind kind) {
    for (size_t i = 0; i < astra_construct_count; i++) {
        const ConstructSpec *s = astra_constructs[i];
        if (s->role != CONSTRUCT_LEAD) continue;
        if (s->keyword && s->token == kind) return s;
    }
    return NULL;
}

/* True when `s` owns node kind `kind`, either as its primary node or
 * through its `also_nodes` list. */
static bool owns_node_kind(const ConstructSpec *s, NodeKind kind) {
    if (kind == CONSTRUCT_NO_NODE) return false;
    if (s->node_kind == kind) return true;
    for (size_t i = 0; s->also_nodes && s->also_nodes[i] != CONSTRUCT_NO_NODE; i++) {
        if (s->also_nodes[i] == kind) return true;
    }
    return false;
}

const ConstructSpec *construct_by_node(NodeKind kind) {
    for (size_t i = 0; i < astra_construct_count; i++) {
        if (owns_node_kind(astra_constructs[i], kind)) return astra_constructs[i];
    }
    return NULL;
}

const ConstructSpec *construct_by_keyword(const char *text, size_t len) {
    if (!text) return NULL;
    for (size_t i = 0; i < astra_construct_count; i++) {
        const ConstructSpec *s = astra_constructs[i];
        if (!s->keyword) continue;
        if (strlen(s->keyword) == len && memcmp(s->keyword, text, len) == 0) return s;
    }
    return NULL;
}

/* A construct is fully migrated when it owns every phase its position
 * implies: LEAD constructs need parsing, checking and emitting; SUB
 * constructs are entered through their parent and only need the phases
 * they declare in `deps`-reachable code, so they count as migrated when
 * their declared phases match what they set out to own (i.e. all three,
 * or none — the registry never claims a phase it does not use). */
size_t construct_fully_migrated_count(void) {
    size_t n = 0;
    for (size_t i = 0; i < astra_construct_count; i++) {
        if (astra_constructs[i]->phases == CONSTRUCT_ALL_PHASES) n++;
    }
    return n;
}

/* ------------------------------------------------------------
 * Report builder
 * ------------------------------------------------------------ */

typedef struct {
    char  *buf;
    size_t cap;
    size_t len;
    int    failures;
} Report;

static void report(Report *r, const char *fmt, ...) {
    if (!r->buf || r->len + 2 >= r->cap) return;
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(r->buf + r->len, r->cap - r->len, fmt, ap);
    va_end(ap);
    if (n > 0) {
        r->len += (size_t)n;
        if (r->len >= r->cap) r->len = r->cap - 1;
    }
}

static void fail(Report *r, const char *fmt, ...) {
    r->failures++;
    if (!r->buf || r->len + 2 >= r->cap) return;
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(r->buf + r->len, r->cap - r->len, "  FAIL ", ap);
    va_end(ap);
    if (n > 0) r->len += (size_t)n;
    va_start(ap, fmt);
    n = vsnprintf(r->buf + r->len, r->cap - r->len, fmt, ap);
    va_end(ap);
    if (n > 0) r->len += (size_t)n;
    report(r, "\n");
}

static bool bits_match_hook(uint32_t phases, uint32_t bit, bool has_hook) {
    bool has_bit = (phases & bit) != 0;
    return has_bit == has_hook;
}

/* ------------------------------------------------------------
 * Self-check
 * ------------------------------------------------------------ */

int construct_self_check(char *buf, size_t cap) {
    Report r = { .buf = buf, .cap = cap, .len = 0, .failures = 0 };
    if (buf && cap) buf[0] = '\0';

    report(&r, "construct registry: %zu constructs\n", astra_construct_count);

    size_t migrated = 0;
    size_t sub = 0;

    for (size_t i = 0; i < astra_construct_count; i++) {
        const ConstructSpec *s = astra_constructs[i];

        /* --- required metadata ------------------------------------ */
        if (!s->name || !*s->name) {
            fail(&r, "[%zu] construct has no name", i);
            continue;
        }
        if (!s->grammar || !*s->grammar) {
            fail(&r, "`%s`: no EBNF production recorded", s->name);
        }
        if (!s->research || !*s->research) {
            fail(&r, "`%s`: not traceable to a research report", s->name);
        }
        if (s->position == 0) {
            fail(&r, "`%s`: declares no grammar position", s->name);
        }
        if (s->role == CONSTRUCT_SUB && s->position == 0) {
            fail(&r, "`%s`: sub-construct without a position", s->name);
        }
        if (s->phases & ~(uint32_t)CONSTRUCT_ALL_PHASES) {
            fail(&r, "`%s`: unknown phase bits 0x%x", s->name, s->phases & ~(uint32_t)CONSTRUCT_ALL_PHASES);
        }

        /* --- hook / phase agreement ------------------------------- */
        if (!bits_match_hook(s->phases, CONSTRUCT_PARSE, s->parse != NULL)) {
            fail(&r, "`%s`: parse hook and CONSTRUCT_PARSE bit disagree", s->name);
        }
        if (!bits_match_hook(s->phases, CONSTRUCT_CHECK, s->check != NULL)) {
            fail(&r, "`%s`: check hook and CONSTRUCT_CHECK bit disagree", s->name);
        }
        if (!bits_match_hook(s->phases, CONSTRUCT_EMIT, s->emit != NULL)) {
            fail(&r, "`%s`: emit hook and CONSTRUCT_EMIT bit disagree", s->name);
        }

        /* --- what is out of scope must say why --------------------- */
        if (!s->in_astra0 && !s->note) {
            fail(&r, "`%s`: excluded from Astra-0 without a note", s->name);
        }
        if (s->has_braces && (s->position & CONSTRUCT_TYPE)) {
            fail(&r, "`%s`: a type cannot have a brace body", s->name);
        }

        /* --- keyword / token agreement with the lexer -------------- */
        if (s->keyword) {
            TokenKind lexed = lexer_keyword_token(s->keyword, strlen(s->keyword));
            if (lexed != s->token) {
                fail(&r, "`%s`: keyword \"%s\" lexes to %s but the construct declares %s",
                     s->name, s->keyword, token_kind_name(lexed), token_kind_name(s->token));
            }
        } else if (s->role == CONSTRUCT_LEAD && s->node_kind != CONSTRUCT_NO_NODE &&
                   s->token == TOKEN_IDENT && (s->position & (CONSTRUCT_STMT | CONSTRUCT_ITEM))) {
            fail(&r, "`%s`: statement/item construct without a keyword or punctuation token", s->name);
        }

        /* --- dependencies ----------------------------------------- */
        if (s->deps) {
            for (size_t d = 0; s->deps[d]; d++) {
                if (!construct_lookup(s->deps[d])) {
                    fail(&r, "`%s`: depends on unknown construct `%s`", s->name, s->deps[d]);
                }
                if (strcmp(s->deps[d], s->name) == 0) {
                    fail(&r, "`%s`: depends on itself", s->name);
                }
            }
        }

        if (s->role == CONSTRUCT_SUB) sub++;
        if (s->phases == CONSTRUCT_ALL_PHASES) migrated++;
    }

    /* --- global uniqueness --------------------------------------- */
    for (size_t i = 0; i < astra_construct_count; i++) {
        const ConstructSpec *a = astra_constructs[i];
        if (!a->name) continue;

        for (size_t j = i + 1; j < astra_construct_count; j++) {
            const ConstructSpec *b = astra_constructs[j];
            if (!b->name) continue;

            if (strcmp(a->name, b->name) == 0) {
                fail(&r, "duplicate construct name `%s`", a->name);
            }
            if (owns_node_kind(a, b->node_kind)) {
                fail(&r, "`%s` and `%s` both claim node kind %d",
                     a->name, b->name, (int)b->node_kind);
            }
            for (size_t k = 0; a->also_nodes && a->also_nodes[k] != CONSTRUCT_NO_NODE; k++) {
                if (owns_node_kind(b, a->also_nodes[k])) {
                    fail(&r, "`%s` and `%s` both claim node kind %d",
                         a->name, b->name, (int)a->also_nodes[k]);
                }
            }
            for (size_t k = 0; b->also_nodes && b->also_nodes[k] != CONSTRUCT_NO_NODE; k++) {
                if (owns_node_kind(a, b->also_nodes[k])) {
                    fail(&r, "`%s` and `%s` both claim node kind %d",
                         a->name, b->name, (int)b->also_nodes[k]);
                }
            }
            if (a->role == CONSTRUCT_LEAD && b->role == CONSTRUCT_LEAD &&
                a->keyword && b->keyword && a->token == b->token) {
                fail(&r, "`%s` and `%s` both claim token %s",
                     a->name, b->name, token_kind_name(a->token));
            }
        }
    }

    /* --- every sub-construct must be reachable -------------------- */
    for (size_t i = 0; i < astra_construct_count; i++) {
        const ConstructSpec *s = astra_constructs[i];
        if (s->role != CONSTRUCT_SUB) continue;

        bool referenced = false;
        for (size_t j = 0; j < astra_construct_count && !referenced; j++) {
            const ConstructSpec *p = astra_constructs[j];
            if (p == s || !p->deps) continue;
            for (size_t d = 0; p->deps[d]; d++) {
                if (strcmp(p->deps[d], s->name) == 0) { referenced = true; break; }
            }
        }
        if (!referenced) {
            fail(&r, "`%s` is a sub-construct that no parent depends on (orphan grammar rule)",
                 s->name);
        }
    }

    /* --- operator table agrees with the parser --------------------
     * Prefix forms are parsed by unary_op.c rather than through the Pratt
     * led-loop, so they have no entry in the parser's precedence table and
     * are compared by arity on the other side instead. */
    size_t op_count = 0;
    const OperatorSpec *ops = operator_table(&op_count);
    for (size_t i = 0; i < op_count; i++) {
        const OperatorSpec *op = &ops[i];

        if (op->arity == OPERATOR_PREFIX) {
            if (op->bin_op != OPERATOR_NO_BIN_OP) {
                fail(&r, "prefix operator `%s` claims a BinaryOp", op->spelling);
            }
            if (op->un_op == OPERATOR_NO_UN_OP) {
                fail(&r, "prefix operator `%s` claims no UnaryOp", op->spelling);
            }
            continue;
        }

        if (op->binding_power == 0) continue;  /* unimplemented: no Pratt entry */

        uint8_t actual_bp = parser_precedence_of(op->token);
        if (actual_bp != op->binding_power) {
            fail(&r, "operator `%s`: registry says binding power %u, parser says %u",
                 op->spelling, op->binding_power, actual_bp);
        }
        if (op->arity == OPERATOR_BINARY && op->bin_op != OPERATOR_NO_BIN_OP) {
            BinaryOp actual = parser_binary_op_of(op->token);
            if (actual != op->bin_op) {
                fail(&r, "operator `%s`: registry and parser disagree on the BinaryOp", op->spelling);
            }
        }
    }

    report(&r, "sub-constructs: %zu\n", sub);
    report(&r, "migrated (all three phases): %zu / %zu\n", migrated, astra_construct_count);
    report(&r, "operator table: %zu entries\n", op_count);
    if (r.failures == 0) {
        report(&r, "OK — registry, lexer, parser and operator table agree\n");
    } else {
        report(&r, "%d failure(s)\n", r.failures);
    }
    return r.failures;
}

/* ------------------------------------------------------------
 * Dump
 * ------------------------------------------------------------ */

static const char *role_name(ConstructRole role) {
    return role == CONSTRUCT_SUB ? "sub " : "lead";
}

static void position_names(uint32_t position, char *out, size_t cap) {
    out[0] = '\0';
    static const struct { uint32_t bit; const char *name; } names[] = {
        { CONSTRUCT_STMT,    "stmt"    },
        { CONSTRUCT_EXPR,    "expr"    },
        { CONSTRUCT_ITEM,    "item"    },
        { CONSTRUCT_PATTERN, "pattern" },
        { CONSTRUCT_TYPE,    "type"    },
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        if (!(position & names[i].bit)) continue;
        if (out[0]) strncat(out, "|", cap - strlen(out) - 1);
        strncat(out, names[i].name, cap - strlen(out) - 1);
    }
}

static void phase_names(uint32_t phases, char *out, size_t cap) {
    snprintf(out, cap, "parse %s / check %s / emit %s",
             (phases & CONSTRUCT_PARSE) ? "yes" : "no ",
             (phases & CONSTRUCT_CHECK) ? "yes" : "no ",
             (phases & CONSTRUCT_EMIT)  ? "yes" : "no ");
}

size_t construct_dump(char *buf, size_t cap) {
    Report r = { .buf = buf, .cap = cap, .len = 0, .failures = 0 };
    if (buf && cap) buf[0] = '\0';

    for (size_t i = 0; i < astra_construct_count; i++) {
        const ConstructSpec *s = astra_constructs[i];
        char pos[64];
        char ph[64];
        position_names(s->position, pos, sizeof(pos));
        phase_names(s->phases, ph, sizeof(ph));

        report(&r, "%-16s %s  %-22s %-24s %s%s\n",
               s->name, role_name(s->role), pos,
               s->keyword ? s->keyword : (s->node_kind == CONSTRUCT_NO_NODE ? "-" : "(punctuation)"),
               ph,
               s->in_astra0 ? "" : "  [outside Astra-0]");

        report(&r, "%-16s   grammar : %s\n", "", s->grammar);
        report(&r, "%-16s   research: %s\n", "", s->research);

        if (s->deps && s->deps[0]) {
            report(&r, "%-16s   deps    :", "");
            for (size_t d = 0; s->deps[d]; d++) report(&r, " %s", s->deps[d]);
            report(&r, "\n");
        }
        if (s->note) report(&r, "%-16s   note    : %s\n", "", s->note);
        report(&r, "\n");
    }
    return r.len;
}

size_t operator_table_dump(char *buf, size_t cap) {
    Report r = { .buf = buf, .cap = cap, .len = 0, .failures = 0 };
    if (buf && cap) buf[0] = '\0';

    size_t count = 0;
    const OperatorSpec *ops = operator_table(&count);

    report(&r, "%-6s %-9s %-8s %-10s %8s %8s  %s\n",
           "op", "arity", "assoc", "token", "binding", "spec", "note");
    for (size_t i = 0; i < count; i++) {
        const OperatorSpec *op = &ops[i];
        const char *arity = op->arity == OPERATOR_BINARY ? "binary"
                          : op->arity == OPERATOR_PREFIX ? "prefix" : "postfix";
        const char *assoc = op->assoc == OPERATOR_LEFT ? "left"
                          : op->assoc == OPERATOR_RIGHT ? "right" : "nonassoc";
        char doc[8];
        char bp[8];
        if (op->doc_precedence) snprintf(doc, sizeof(doc), "%u", op->doc_precedence);
        else snprintf(doc, sizeof(doc), "-");
        if (op->binding_power) snprintf(bp, sizeof(bp), "%u", op->binding_power);
        else snprintf(bp, sizeof(bp), "-");

        report(&r, "%-6s %-9s %-8s %-10s %8s %8s  %s\n",
               op->spelling, arity, assoc, token_kind_name(op->token),
               bp, doc, op->note ? op->note : "");
    }

    size_t pending_count = 0;
    const OperatorSpec *pending = operator_pending_table(&pending_count);
    if (pending_count) {
        report(&r, "\nspecified by research/010 §12.2 but not implemented:\n");
        for (size_t i = 0; i < pending_count; i++) {
            report(&r, "%-6s %-9s %-8s %-10s %8s %8u  %s\n",
                   pending[i].spelling, "binary",
                   pending[i].assoc == OPERATOR_RIGHT ? "right" : "left",
                   token_kind_name(pending[i].token), "-", pending[i].doc_precedence,
                   pending[i].note ? pending[i].note : "");
        }
    }
    return r.len;
}
