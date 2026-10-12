/* fuzz_compile — libFuzzer target for the seed compiler frontend.
 *
 * Feeds arbitrary bytes through the full compile pipeline minus the VM:
 * lexer -> parser -> typechecker -> emitter (bytecode), the same phases
 * `--emit-c` walks in src/main.c before codegen. The VM is left out on
 * purpose: a mutated program can contain `while true {}`, and a hung
 * interpretation would burn the fuzzer's timeout budget instead of
 * finding frontend bugs. PHASE1_PROGRESS §4bis#23 scopes the target to
 * the lexer/parser; the two later phases ride along because they are
 * cheap and arena-confined.
 *
 * Rules for this file (fuzzing skill):
 *   - never exit()/abort() on bad input: diagnostics and error counts are
 *     normal outcomes, a crash is a finding;
 *   - do not redirect stderr — ASan/UBSan reports travel through it;
 *   - keep the target fast: one malloc, one compile, one free per input.
 */

#include "astra/astra.h"

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* Generous cap: past every conformance file. Larger inputs are dropped
 * before they reach the lexer so the fuzzer cannot blow the RSS limit
 * with one giant token stream. */
#define FUZZ_MAX_LEN (64u * 1024u)

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size > FUZZ_MAX_LEN)
        return 0;

    /* read_file() hands the compiler a NUL-terminated buffer; mirror that
     * shape. NUL is not special to the lexer (it takes a length), but the
     * terminator keeps the fuzzed buffer indistinguishable from a real one. */
    char *source = malloc(size + 1);
    if (!source)
        return 0; /* OOM: skip this input, keep fuzzing */
    memcpy(source, data, size);
    source[size] = '\0';

    Compiler *c = compiler_create("fuzz.astra", source, size);
    if (!c) {
        free(source);
        return 0; /* arena OOM: reported by driver_create, nothing to do */
    }

    Node *module = parser_parse_module(c->parser);
    if (module && !parser_had_error(c->parser)) {
        TypeChecker *tc = typechecker_create(c->arena, c->strings);
        if (tc) {
            c->checker = tc;
            Type *t = typecheck(tc, module);
            if (t && typechecker_error_count(tc) == 0) {
                Emitter *e = emitter_create(c->arena, c->strings);
                if (e) {
                    c->emitter = e;
                    emitter_emit(e, module);
                    (void)emitter_error_count(e);
                }
            }
        }
    } else {
        /* The parser stops consuming at the first hard error, so the tail
         * of the input would otherwise never reach the lexer. Drain to EOF
         * (or TOKEN_ERROR): no guard here — if the lexer cannot advance,
         * libFuzzer's -timeout must see it as a finding, not be masked. */
        Token t;
        do {
            t = lexer_next(c->lexer);
        } while (t.kind != TOKEN_EOF && t.kind != TOKEN_ERROR);
    }

    compiler_destroy(c);
    free(source);
    return 0;
}
