#include "priv.h"
#include "codegen.h"
#include "constructs/construct.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ASTRA_VERSION "0.1.0"

static void print_usage(const char *prog) {
    fprintf(stderr,
        "Usage: %s [options] <file.astra>\n"
        "\n"
        "Options:\n"
        "  --help           Show this help message\n"
        "  --version        Show version\n"
        "  --dump-tokens    Lex and dump all tokens\n"
        "  --dump-ast       Parse and dump the AST\n"
        "  --dump-constructs  Dump the construct registry (grammar, research, deps)\n"
        "  --dump-operators   Dump the operator precedence table\n"
        "  --check-constructs Check registry invariants; exit 1 on failure\n"
        "  --emit-c         Generate C code to <file>.c\n",
        prog);
}

/* Read entire file into a malloc'd buffer.
 * Caller must free(*out_src) when done.
 * Returns 0 on success, -1 on error. */
static int read_file(const char *filename, char **out_src, size_t *out_len) {
    FILE *f = fopen(filename, "rb");
    if (!f) {
        fprintf(stderr, "error: cannot open file '%s'\n", filename);
        return -1;
    }

    fseek(f, 0, SEEK_END);
    long file_size = ftell(f);
    fseek(f, 0, SEEK_SET);

    if (file_size < 0) {
        fprintf(stderr, "error: cannot determine size of '%s'\n", filename);
        fclose(f);
        return -1;
    }

    char *buf = malloc((size_t)file_size + 1);
    if (!buf) {
        fprintf(stderr, "error: out of memory reading '%s'\n", filename);
        fclose(f);
        return -1;
    }

    size_t nread = fread(buf, 1, (size_t)file_size, f);
    fclose(f);

    if ((long)nread != file_size) {
        fprintf(stderr, "error: short read on '%s'\n", filename);
        free(buf);
        return -1;
    }

    buf[file_size] = '\0';
    *out_src = buf;
    *out_len = (size_t)file_size;
    return 0;
}

/* Diagnostics that describe the compiler itself rather than a program.
 * They take no input file and terminate immediately. */
static int run_registry_diagnostic(const char *flag) {
    static char buf[512 * 1024];

    if (strcmp(flag, "--dump-constructs") == 0) {
        construct_dump(buf, sizeof(buf));
        fputs(buf, stdout);
        return 0;
    }
    if (strcmp(flag, "--dump-operators") == 0) {
        operator_table_dump(buf, sizeof(buf));
        fputs(buf, stdout);
        return 0;
    }
    if (strcmp(flag, "--check-constructs") == 0) {
        int failures = construct_self_check(buf, sizeof(buf));
        fputs(buf, stdout);
        return failures == 0 ? 0 : 1;
    }
    return -1;
}

int main(int argc, char **argv) {
    bool dump_tokens = false;
    bool dump_ast    = false;
    bool emit_c      = false;
    const char *filename = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        } else if (strcmp(argv[i], "--version") == 0) {
            printf("astra-seed %s\n", ASTRA_VERSION);
            return 0;
        } else if (strcmp(argv[i], "--dump-constructs") == 0 ||
                   strcmp(argv[i], "--dump-operators") == 0 ||
                   strcmp(argv[i], "--check-constructs") == 0) {
            return run_registry_diagnostic(argv[i]);
        } else if (strcmp(argv[i], "--dump-tokens") == 0) {
            dump_tokens = true;
        } else if (strcmp(argv[i], "--dump-ast") == 0) {
            dump_ast = true;
        } else if (strcmp(argv[i], "--emit-c") == 0) {
            emit_c = true;
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "error: unknown option '%s'\n", argv[i]);
            fprintf(stderr, "Usage: %s [options] <file.astra>\n", argv[0]);
            return 1;
        } else {
            if (filename) {
                fprintf(stderr, "error: unexpected argument '%s'\n", argv[i]);
                fprintf(stderr, "Usage: %s [options] <file.astra>\n", argv[0]);
                return 1;
            }
            filename = argv[i];
        }
    }

    if (!filename) {
        fprintf(stderr, "error: no input file\n");
        fprintf(stderr, "Usage: %s [options] <file.astra>\n", argv[0]);
        return 1;
    }

    char *source = NULL;
    size_t source_len = 0;
    if (read_file(filename, &source, &source_len) < 0) {
        return 1;
    }

    Compiler *c = driver_create(filename, source, source_len, dump_tokens, dump_ast);

    if (!c) {
        fprintf(stderr, "error: failed to initialize compiler\n");
        free(source);
        return 1;
    }

    if (emit_c) {
        /* Run pipeline up to emitter, then generate C */
        Node *module = parser_parse_module(c->parser);
        if (!module || parser_had_error(c->parser)) {
            fprintf(stderr, "error: parse failed\n");
            free(source);
            compiler_destroy(c);
            return 1;
        }

        TypeChecker *tc = typechecker_create(c->arena, c->strings);
        if (!tc) {
            fprintf(stderr, "error: out of memory\n");
            free(source);
            compiler_destroy(c);
            return 1;
        }
        c->checker = tc;

        Type *result = typecheck(tc, module);
        if (!result || typechecker_error_count(tc) > 0) {
            fprintf(stderr, "error: type check failed with %d error(s)\n",
                    typechecker_error_count(tc));
            free(source);
            compiler_destroy(c);
            return 1;
        }

        Emitter *emitter = emitter_create(c->arena, c->strings);
        if (!emitter) {
            fprintf(stderr, "error: out of memory\n");
            free(source);
            compiler_destroy(c);
            return 1;
        }
        c->emitter = emitter;

        emitter_emit(emitter, module);

        if (emitter_error_count(emitter) > 0) {
            fprintf(stderr, "error: code generation failed with %d error(s)\n",
                    emitter_error_count(emitter));
            free(source);
            compiler_destroy(c);
            return 1;
        }

        /* Generate output path: replace .astra with .c */
        size_t fn_len = strlen(filename);
        char *out_path = malloc(fn_len + 4);
        memcpy(out_path, filename, fn_len);
        /* Strip .astra extension if present */
        if (fn_len >= 6 && strcmp(filename + fn_len - 6, ".astra") == 0) {
            memcpy(out_path + fn_len - 6, ".c", 3);
        } else {
            memcpy(out_path + fn_len, ".c", 4);
        }

        Codegen *cg = codegen_create(module, emitter, filename);
        if (!cg) {
            fprintf(stderr, "error: out of memory\n");
            free(out_path);
            free(source);
            compiler_destroy(c);
            return 1;
        }

        bool ok = codegen_emit_to_file(cg, out_path);
        codegen_destroy(cg);
        free(out_path);
        free(source);
        compiler_destroy(c);
        return ok ? 0 : 1;
    }

    VMResult result = compiler_run(c);
    free(source);
    compiler_destroy(c);

    return result == VM_OK ? 0 : 1;
}
