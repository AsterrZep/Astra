#include "priv.h"

#define INITIAL_TABLE_SIZE 64
#define LOAD_FACTOR_NUM    7
#define LOAD_FACTOR_DENOM  10

StringTable *string_table_create(Arena *a) {
    if (!a) return NULL;

    StringTable *st = arena_alloc_zero(a, sizeof(StringTable), _Alignof(StringTable));
    if (!st) return NULL;

    st->arena    = a;
    st->capacity = INITIAL_TABLE_SIZE;
    st->count    = 0;
    st->entries  = arena_alloc_zero(a, sizeof(InternedString) * st->capacity, _Alignof(InternedString));
    return st;
}

static bool slot_empty(InternedString *s) {
    return s->str == NULL;
}

static void st_insert_direct(StringTable *st, InternedString entry) {
    size_t idx = entry.hash % st->capacity;
    for (;;) {
        if (slot_empty(&st->entries[idx])) {
            st->entries[idx] = entry;
            st->count++;
            return;
        }
        if (st->entries[idx].hash == entry.hash &&
            st->entries[idx].len  == entry.len  &&
            memcmp(st->entries[idx].str, entry.str, entry.len) == 0) {
            return;
        }
        idx = (idx + 1) % st->capacity;
    }
}

static void st_grow(StringTable *st) {
    size_t old_cap = st->capacity;
    InternedString *old = st->entries;

    st->capacity = old_cap * 2;
    st->entries  = arena_alloc_zero(st->arena, sizeof(InternedString) * st->capacity, _Alignof(InternedString));
    st->count    = 0;

    for (size_t i = 0; i < old_cap; i++) {
        if (!slot_empty(&old[i])) {
            st_insert_direct(st, old[i]);
        }
    }
}

InternedString string_intern(StringTable *st, const char *str, size_t len) {
    InternedString empty = {0};
    if (!st || !str || len == 0) return empty;

    if (st->count * LOAD_FACTOR_DENOM >= st->capacity * LOAD_FACTOR_NUM) {
        st_grow(st);
    }

    uint32_t hash = fnv1a(str, len);
    size_t idx = hash % st->capacity;

    for (;;) {
        if (slot_empty(&st->entries[idx])) {
            char *dup = arena_strdup(st->arena, str, len);
            if (!dup) return empty;
            st->entries[idx].str  = dup;
            st->entries[idx].len  = len;
            st->entries[idx].hash = hash;
            st->count++;
            return st->entries[idx];
        }

        if (st->entries[idx].hash == hash &&
            st->entries[idx].len  == len &&
            memcmp(st->entries[idx].str, str, len) == 0) {
            return st->entries[idx];
        }

        idx = (idx + 1) % st->capacity;
    }
}

InternedString string_intern_cstr(StringTable *st, const char *str) {
    if (!str) {
        InternedString empty = {0};
        return empty;
    }
    return string_intern(st, str, strlen(str));
}

bool string_eq(InternedString a, InternedString b) {
    return a.hash == b.hash &&
           a.len  == b.len  &&
           a.str  == b.str;
}
