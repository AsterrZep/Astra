#include "priv.h"

Node *node_new(Arena *a, NodeKind kind, SrcLoc loc) {
    Node *n = arena_new(a, Node);
    n->kind = kind;
    n->loc  = loc;
    return n;
}

void srcloc_print(SrcLoc loc) {
    fprintf(stderr, "%s:%u:%u", loc.filename ? loc.filename : "<unknown>", loc.line, loc.column);
}
