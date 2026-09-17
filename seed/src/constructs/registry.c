/* ============================================================
 * Construct registry — the index.
 *
 * This file is the ONLY place that knows the full set of
 * constructs. Every entry points at a spec defined in its own
 * file under src/constructs/; nothing about a construct is
 * described here beyond its address.
 *
 * Order is deliberate and groups the registry the way the grammar
 * reads: module items, statements, control flow, patterns,
 * expressions, then the constructs the full grammar specifies but
 * Astra-0 deliberately excludes (research/011 §5.2, §5.4).
 *
 * Adding a construct: create constructs/<name>.c with a
 * `const ConstructSpec construct_<name>`, add it below, then run
 * `./astra-seed --check-constructs`.
 * ============================================================ */

#include "constructs/construct.h"

/* --- module items -------------------------------------------- */
extern const ConstructSpec construct_fn;
extern const ConstructSpec construct_struct;
extern const ConstructSpec construct_struct_lit;
extern const ConstructSpec construct_enum;
extern const ConstructSpec construct_enum_variant;
extern const ConstructSpec construct_variant_path;
extern const ConstructSpec construct_const_decl;
extern const ConstructSpec construct_use;
extern const ConstructSpec construct_type_annotation;

/* --- statements ---------------------------------------------- */
extern const ConstructSpec construct_binding;
extern const ConstructSpec construct_assign;
extern const ConstructSpec construct_return;
extern const ConstructSpec construct_break;
extern const ConstructSpec construct_continue;
extern const ConstructSpec construct_block;

/* --- control flow -------------------------------------------- */
extern const ConstructSpec construct_if;
extern const ConstructSpec construct_else;
extern const ConstructSpec construct_while;
extern const ConstructSpec construct_for;
extern const ConstructSpec construct_in;
extern const ConstructSpec construct_match;
extern const ConstructSpec construct_match_arm;

/* --- patterns ------------------------------------------------ */
extern const ConstructSpec construct_pattern_or;
extern const ConstructSpec construct_pattern_wildcard;
extern const ConstructSpec construct_pattern_literal;
extern const ConstructSpec construct_pattern_enum;
extern const ConstructSpec construct_pattern_ident;

/* --- expressions --------------------------------------------- */
extern const ConstructSpec construct_binary_op;
extern const ConstructSpec construct_operator_table;
extern const ConstructSpec construct_unary_op;
extern const ConstructSpec construct_literal;
extern const ConstructSpec construct_ident;
extern const ConstructSpec construct_array_lit;
extern const ConstructSpec construct_range;
extern const ConstructSpec construct_call;
extern const ConstructSpec construct_index;
extern const ConstructSpec construct_field_access;

/* --- specified by the full grammar, outside Astra-0 ---------- */
extern const ConstructSpec construct_trait;
extern const ConstructSpec construct_impl;
extern const ConstructSpec construct_import;
extern const ConstructSpec construct_type_alias;
extern const ConstructSpec construct_comptime;
extern const ConstructSpec construct_lambda;
extern const ConstructSpec construct_tuple_lit;

const ConstructSpec *const astra_constructs[] = {
    /* module items */
    &construct_fn,
    &construct_struct,
    &construct_struct_lit,
    &construct_enum,
    &construct_enum_variant,
    &construct_variant_path,
    &construct_const_decl,
    &construct_use,
    &construct_type_annotation,

    /* statements */
    &construct_binding,
    &construct_assign,
    &construct_return,
    &construct_break,
    &construct_continue,
    &construct_block,

    /* control flow */
    &construct_if,
    &construct_else,
    &construct_while,
    &construct_for,
    &construct_in,
    &construct_match,
    &construct_match_arm,

    /* patterns */
    &construct_pattern_or,
    &construct_pattern_wildcard,
    &construct_pattern_literal,
    &construct_pattern_enum,
    &construct_pattern_ident,

    /* expressions */
    &construct_binary_op,
    &construct_operator_table,
    &construct_unary_op,
    &construct_literal,
    &construct_ident,
    &construct_array_lit,
    &construct_range,
    &construct_call,
    &construct_index,
    &construct_field_access,

    /* outside Astra-0 */
    &construct_trait,
    &construct_impl,
    &construct_import,
    &construct_type_alias,
    &construct_comptime,
    &construct_lambda,
    &construct_tuple_lit,
};

const size_t astra_construct_count = sizeof(astra_constructs) / sizeof(astra_constructs[0]);
