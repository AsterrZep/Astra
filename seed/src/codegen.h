#ifndef ASTRA_CODEGEN_H
#define ASTRA_CODEGEN_H

#include "astra/astra.h"
#include <stdbool.h>

/* Opaque codegen context */
typedef struct Codegen Codegen;

/* Create a codegen context. Takes ownership of nothing.
 * module: the parsed AST module node
 * emitter: the emitter after emit (provides bytecode + constants + struct/enum info)
 * filename: source filename (for error messages)
 */
Codegen *codegen_create(Node *module, Emitter *emitter, const char *filename);

/* Emit C code to the given file path.
 * Returns true on success, false on error (messages to stderr).
 */
bool codegen_emit_to_file(Codegen *cg, const char *output_path);

/* Free codegen context */
void codegen_destroy(Codegen *cg);

#endif /* ASTRA_CODEGEN_H */
