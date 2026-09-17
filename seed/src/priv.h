#ifndef ASTRA_PRIV_H
#define ASTRA_PRIV_H

#include "astra/astra.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BLOCK_SIZE_DEFAULT (64 * 1024)

/* -----------------------------------------------------------
 * Arena (private)
 * ----------------------------------------------------------- */

typedef struct Block {
    struct Block *next;
    size_t        capacity;
    size_t        used;
    uint8_t       data[];
} Block;

struct Arena {
    Block *head;
    size_t block_size;
};

/* -----------------------------------------------------------
 * StringTable (private)
 * ----------------------------------------------------------- */

struct StringTable {
    Arena          *arena;
    InternedString *entries;
    size_t          capacity;
    size_t          count;
};

/* -----------------------------------------------------------
 * Lexer (private)
 * ----------------------------------------------------------- */

struct Lexer {
    const char   *filename;
    const char   *source;
    size_t        source_len;
    size_t        pos;
    uint32_t      line;
    uint32_t      column;
    StringTable  *strings;
    Arena        *arena;
    Token         cached;
    bool          has_cached;
};

/* -----------------------------------------------------------
 * Emitter (private)
 * ----------------------------------------------------------- */

#define EMITTER_MAX_LOCALS 256
#define EMITTER_MAX_CODE   (1024 * 1024)
#define EMITTER_MAX_CONSTS (1024 * 1024)

typedef struct {
    InternedString name;
    uint8_t        slot;
    uint8_t        depth;
} Local;

/* Pending jump sites for the enclosing loop, patched once the loop
 * body finishes and the exit / continue targets are known. */
#define EMITTER_MAX_LOOP_DEPTH 32

typedef struct {
    size_t *breaks;
    size_t  break_len;
    size_t  break_cap;
    size_t *conts;
    size_t  cont_len;
    size_t  cont_cap;
    size_t  continue_target;
} LoopPatch;

struct Emitter {
    Arena        *arena;
    StringTable  *strings;

    Instruction  *code;
    size_t         code_len;
    size_t         code_cap;

    Value        *constants;
    size_t         const_len;
    size_t         const_cap;

    Local          locals[EMITTER_MAX_LOCALS];
    uint16_t       local_count;
    uint8_t        scope_depth;

    LoopPatch      loops[EMITTER_MAX_LOOP_DEPTH];
    int            loop_depth;

    int            error_count;
};

/* -----------------------------------------------------------
 * VM (private)
 * ----------------------------------------------------------- */

#define VM_STACK_SIZE  1024
#define VM_CALL_DEPTH  256
#define VM_MAX_GLOBALS 256

typedef struct {
    const char *name;
    Value       value;
} Global;

typedef struct {
    const Instruction *ip;
    uint16_t           base;
    /* Saved state for restoring when returning */
    const Instruction *saved_code;
    size_t             saved_code_len;
    const Value       *saved_constants;
    size_t             saved_const_len;
} CallFrame;

struct VM {
    Arena      *arena;

    Value       stack[VM_STACK_SIZE];
    uint16_t    sp;

    CallFrame   frames[VM_CALL_DEPTH];
    uint16_t    frame_count;

    const Instruction *code;
    size_t             code_len;
    const Value       *constants;
    size_t             const_len;

    Global      globals[VM_MAX_GLOBALS];
    uint16_t    global_count;

    FnObj      *builtin_print_fn;

    const char *error_msg;
    uint32_t    error_line;
};

/* -----------------------------------------------------------
 * Compiler Driver (internal, holds mode flags)
 * ----------------------------------------------------------- */

typedef struct {
    Compiler  base;     /* must be first for pointer punning */
    bool      dump_tokens;
    bool      dump_ast;
} CompilerDriver;

/* -----------------------------------------------------------
 * Utility helpers
 * ----------------------------------------------------------- */

static inline size_t align_up(size_t value, size_t align) {
    size_t mask = align - 1;
    return (value + mask) & ~mask;
}

static inline uint32_t fnv1a(const char *data, size_t len) {
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < len; i++) {
        h ^= (uint8_t)data[i];
        h *= 16777619u;
    }
    return h;
}

/* -----------------------------------------------------------
 * Driver creation (with mode flags)
 * ----------------------------------------------------------- */

Compiler *driver_create(const char *filename, const char *source,
                        size_t source_len, bool dump_tokens, bool dump_ast);

/* -----------------------------------------------------------
 * Internal helpers shared across compilation units
 * ----------------------------------------------------------- */

const char *token_kind_name(TokenKind kind);
void        token_print(Token t);
void        ast_dump(Node *node, int indent);

#endif /* ASTRA_PRIV_H */
