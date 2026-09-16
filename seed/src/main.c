#include "priv.h"
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
        "  --dump-ast       Parse and dump the AST\n",
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

int main(int argc, char **argv) {
    bool dump_tokens = false;
    bool dump_ast    = false;
    const char *filename = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        } else if (strcmp(argv[i], "--version") == 0) {
            printf("astra-seed %s\n", ASTRA_VERSION);
            return 0;
        } else if (strcmp(argv[i], "--dump-tokens") == 0) {
            dump_tokens = true;
        } else if (strcmp(argv[i], "--dump-ast") == 0) {
            dump_ast = true;
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

    VMResult result = compiler_run(c);
    free(source);
    compiler_destroy(c);

    return result == VM_OK ? 0 : 1;
}
