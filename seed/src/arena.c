#include "priv.h"

SrcLoc srcloc_make(const char *filename, uint32_t line, uint32_t column,
                   uint32_t offset) {
    SrcLoc loc;
    loc.filename = filename;
    loc.line     = line;
    loc.column   = column;
    loc.offset   = offset;
    return loc;
}

Arena *arena_create(size_t initial_size) {
    Arena *a = malloc(sizeof(Arena));
    if (!a) return NULL;

    size_t block_size = initial_size > BLOCK_SIZE_DEFAULT ? initial_size : BLOCK_SIZE_DEFAULT;
    a->block_size = block_size;

    Block *b = malloc(sizeof(Block) + block_size);
    if (!b) { free(a); return NULL; }
    b->next     = NULL;
    b->capacity = block_size;
    b->used     = 0;

    a->head = b;
    return a;
}

static Block *arena_grow(Arena *a, size_t min_size) {
    size_t block_size = a->block_size;
    while (block_size < min_size) block_size *= 2;

    Block *b = malloc(sizeof(Block) + block_size);
    if (!b) return NULL;
    b->next     = a->head;
    b->capacity = block_size;
    b->used     = 0;

    a->head = b;
    return b;
}

void *arena_alloc(Arena *a, size_t size, size_t align) {
    if (!a || size == 0) return NULL;

    Block *b = a->head;
    size_t offset = align_up(b->used, align);

    if (offset + size > b->capacity) {
        size_t min_size = align_up(size, align) + align;
        b = arena_grow(a, min_size);
        if (!b) return NULL;
        offset = 0;
    }

    void *ptr = b->data + offset;
    b->used = offset + size;
    return ptr;
}

void *arena_alloc_zero(Arena *a, size_t size, size_t align) {
    void *ptr = arena_alloc(a, size, align);
    if (ptr) memset(ptr, 0, size);
    return ptr;
}

char *arena_strdup(Arena *a, const char *s, size_t len) {
    if (!a || !s || len == 0) return NULL;

    char *dup = arena_alloc(a, len + 1, _Alignof(char));
    if (!dup) return NULL;
    memcpy(dup, s, len);
    dup[len] = '\0';
    return dup;
}

void arena_destroy(Arena *a) {
    if (!a) return;

    Block *b = a->head;
    while (b) {
        Block *next = b->next;
        free(b);
        b = next;
    }
    free(a);
}
