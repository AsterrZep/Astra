#include "priv.h"

typedef struct {
    const char *text;
    TokenKind   kind;
} Keyword;

static const Keyword keywords[] = {
    {"and",      TOKEN_AND},
    {"break",    TOKEN_BREAK},
    {"comptime", TOKEN_COMPTIME},
    {"const",    TOKEN_CONST},
    {"continue", TOKEN_CONTINUE},
    {"else",     TOKEN_ELSE},
    {"enum",     TOKEN_ENUM},
    {"err",      TOKEN_ERR},
    {"false",    TOKEN_FALSE},
    {"fn",       TOKEN_FN},
    {"for",      TOKEN_FOR},
    {"if",       TOKEN_IF},
    {"impl",     TOKEN_IMPL},
    {"in",       TOKEN_IN},
    {"let",      TOKEN_LET},
    {"match",    TOKEN_MATCH},
    {"mod",      TOKEN_MOD},
    {"mut",      TOKEN_MUT},
    {"none",     TOKEN_NONE},
    {"not",      TOKEN_NOT},
    {"ok",       TOKEN_OK},
    {"option",   TOKEN_OPTION},
    {"or",       TOKEN_OR},
    {"pub",      TOKEN_PUB},
    {"return",   TOKEN_RETURN},
    {"result",   TOKEN_RESULT},
    {"some",     TOKEN_SOME},
    {"struct",   TOKEN_STRUCT},
    {"trait",    TOKEN_TRAIT},
    {"true",     TOKEN_TRUE},
    {"use",      TOKEN_USE},
    {"var",      TOKEN_VAR},
    {"while",    TOKEN_WHILE},
};

static const size_t keyword_count = sizeof(keywords) / sizeof(keywords[0]);

static TokenKind check_keyword(const char *text, size_t len) {
    for (size_t i = 0; i < keyword_count; i++) {
        if (strlen(keywords[i].text) == len &&
            memcmp(keywords[i].text, text, len) == 0) {
            return keywords[i].kind;
        }
    }
    return TOKEN_IDENT;
}

/* Exposed so the construct registry can prove that every construct's
 * declared keyword is really lexed to the token it claims
 * (see src/constructs/construct.c). */
TokenKind lexer_keyword_token(const char *text, size_t len) {
    return check_keyword(text, len);
}

static Token make_token(Lexer *l, TokenKind kind, uint32_t line, uint32_t col,
                        uint32_t offset, const char *text, size_t len) {
    Token t = {0};
    t.kind = kind;
    t.text = string_intern(l->strings, text, len);
    t.loc  = srcloc_make(l->filename, line, col, offset);
    return t;
}

static Token make_error(Lexer *l, const char *msg, uint32_t line, uint32_t col,
                        uint32_t offset) {
    Token t = {0};
    t.kind = TOKEN_ERROR;
    t.text = string_intern_cstr(l->strings, msg);
    t.loc  = srcloc_make(l->filename, line, col, offset);
    return t;
}

static char peek_char(Lexer *l) {
    if (l->pos >= l->source_len) return '\0';
    return l->source[l->pos];
}

static char peek_char_next(Lexer *l) {
    if (l->pos + 1 >= l->source_len) return '\0';
    return l->source[l->pos + 1];
}

static char advance(Lexer *l) {
    if (l->pos >= l->source_len) return '\0';
    char c = l->source[l->pos];
    l->pos++;
    if (c == '\n') {
        l->line++;
        l->column = 1;
    } else {
        l->column++;
    }
    return c;
}

static void skip_whitespace(Lexer *l) {
    for (;;) {
        if (l->pos >= l->source_len) break;
        char c = peek_char(l);
        if (c == ' ' || c == '\t' || c == '\r') {
            advance(l);
        } else if (c == '/' && peek_char_next(l) == '/') {
            advance(l);
            advance(l);
            while (l->pos < l->source_len && peek_char(l) != '\n')
                advance(l);
        } else if (c == '/' && peek_char_next(l) == '*') {
            advance(l);
            advance(l);
            int depth = 1;
            while (l->pos < l->source_len && depth > 0) {
                if (peek_char(l) == '/' && peek_char_next(l) == '*') {
                    advance(l);
                    advance(l);
                    depth++;
                } else if (peek_char(l) == '*' && peek_char_next(l) == '/') {
                    advance(l);
                    advance(l);
                    depth--;
                } else {
                    advance(l);
                }
            }
        } else {
            break;
        }
    }
}

static Token read_string(Lexer *l, uint32_t start_line, uint32_t start_col,
                         uint32_t start_offset) {
    advance(l);

    size_t buf_cap = 64;
    size_t buf_len = 0;
    char *buf = arena_alloc(l->arena, buf_cap, _Alignof(char));
    if (!buf) return make_error(l, "out of memory", start_line, start_col, start_offset);

    for (;;) {
        if (l->pos >= l->source_len)
            return make_error(l, "unterminated string literal", start_line, start_col, start_offset);

        char c = peek_char(l);
        if (c == '"') {
            advance(l);
            return make_token(l, TOKEN_STRING_LIT, start_line, start_col,
                              start_offset, buf, buf_len);
        }
        if (c == '\n')
            return make_error(l, "unterminated string literal", start_line, start_col, start_offset);

        advance(l);

        if (c == '\\') {
            if (l->pos >= l->source_len)
                return make_error(l, "unterminated escape sequence", start_line, start_col, start_offset);
            char esc = advance(l);
            char resolved;
            switch (esc) {
            case 'n':  resolved = '\n'; break;
            case 't':  resolved = '\t'; break;
            case 'r':  resolved = '\r'; break;
            case '\\': resolved = '\\'; break;
            case '"':  resolved = '"';  break;
            case '0':  resolved = '\0'; break;
            default:
                return make_error(l, "invalid escape sequence", start_line, start_col, start_offset);
            }
            if (buf_len >= buf_cap) {
                size_t new_cap = buf_cap * 2;
                char *new_buf = arena_alloc(l->arena, new_cap, _Alignof(char));
                if (!new_buf) return make_error(l, "out of memory", start_line, start_col, start_offset);
                memcpy(new_buf, buf, buf_len);
                buf = new_buf;
                buf_cap = new_cap;
            }
            buf[buf_len++] = resolved;
        } else {
            if (buf_len >= buf_cap) {
                size_t new_cap = buf_cap * 2;
                char *new_buf = arena_alloc(l->arena, new_cap, _Alignof(char));
                if (!new_buf) return make_error(l, "out of memory", start_line, start_col, start_offset);
                memcpy(new_buf, buf, buf_len);
                buf = new_buf;
                buf_cap = new_cap;
            }
            buf[buf_len++] = c;
        }
    }
}

static Token read_number(Lexer *l, uint32_t start_line, uint32_t start_col,
                         uint32_t start_offset) {
    const char *start = l->source + l->pos;

    if (peek_char(l) == '0' && l->pos + 1 < l->source_len) {
        char next = peek_char_next(l);
        if (next == 'x' || next == 'X') {
            advance(l);
            advance(l);
            while (l->pos < l->source_len) {
                char c = peek_char(l);
                if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') ||
                    (c >= 'A' && c <= 'F') || c == '_')
                    advance(l);
                else break;
            }
            size_t len = l->pos - (size_t)(start - l->source);
            char *text = arena_strdup(l->arena, start, len);
            int64_t val = 0;
            for (size_t i = 2; i < len; i++) {
                char c = text[i];
                if (c == '_') continue;
                val <<= 4;
                if (c >= '0' && c <= '9') val |= (c - '0');
                else if (c >= 'a' && c <= 'f') val |= (c - 'a' + 10);
                else val |= (c - 'A' + 10);
            }
            Token t = make_token(l, TOKEN_INT_LIT, start_line, start_col,
                                 start_offset, text, len);
            t.literal.int_val = val;
            return t;
        }
        if (next == 'b' || next == 'B') {
            advance(l);
            advance(l);
            while (l->pos < l->source_len) {
                char c = peek_char(l);
                if (c == '0' || c == '1' || c == '_') advance(l);
                else break;
            }
            size_t len = l->pos - (size_t)(start - l->source);
            char *text = arena_strdup(l->arena, start, len);
            int64_t val = 0;
            for (size_t i = 2; i < len; i++) {
                char c = text[i];
                if (c == '_') continue;
                val = (val << 1) | (c - '0');
            }
            Token t = make_token(l, TOKEN_INT_LIT, start_line, start_col,
                                 start_offset, text, len);
            t.literal.int_val = val;
            return t;
        }
        if (next == 'o' || next == 'O') {
            advance(l);
            advance(l);
            while (l->pos < l->source_len) {
                char c = peek_char(l);
                if ((c >= '0' && c <= '7') || c == '_') advance(l);
                else break;
            }
            size_t len = l->pos - (size_t)(start - l->source);
            char *text = arena_strdup(l->arena, start, len);
            int64_t val = 0;
            for (size_t i = 2; i < len; i++) {
                char c = text[i];
                if (c == '_') continue;
                val = (val << 3) | (c - '0');
            }
            Token t = make_token(l, TOKEN_INT_LIT, start_line, start_col,
                                 start_offset, text, len);
            t.literal.int_val = val;
            return t;
        }
    }

    bool is_float = false;

    while (l->pos < l->source_len) {
        char c = peek_char(l);
        if ((c >= '0' && c <= '9') || c == '_') advance(l);
        else break;
    }

    if (peek_char(l) == '.' && l->pos + 1 < l->source_len &&
        peek_char_next(l) >= '0' && peek_char_next(l) <= '9') {
        is_float = true;
        advance(l);
        while (l->pos < l->source_len) {
            char c = peek_char(l);
            if ((c >= '0' && c <= '9') || c == '_') advance(l);
            else break;
        }
    }

    if (peek_char(l) == 'e' || peek_char(l) == 'E') {
        is_float = true;
        advance(l);
        if (peek_char(l) == '+' || peek_char(l) == '-') advance(l);
        while (l->pos < l->source_len) {
            char c = peek_char(l);
            if (c >= '0' && c <= '9') advance(l);
            else break;
        }
    }

    size_t len = l->pos - (size_t)(start - l->source);
    char *text = arena_strdup(l->arena, start, len);

    if (is_float) {
        Token t = make_token(l, TOKEN_FLOAT_LIT, start_line, start_col,
                             start_offset, text, len);
        char buf[64];
        size_t j = 0;
        for (size_t i = 0; i < len && j < sizeof(buf) - 1; i++) {
            if (text[i] != '_') buf[j++] = text[i];
        }
        buf[j] = '\0';
        t.literal.float_val = strtod(buf, NULL);
        return t;
    } else {
        Token t = make_token(l, TOKEN_INT_LIT, start_line, start_col,
                             start_offset, text, len);
        int64_t val = 0;
        for (size_t i = 0; i < len; i++) {
            char c = text[i];
            if (c == '_') continue;
            val = val * 10 + (c - '0');
        }
        t.literal.int_val = val;
        return t;
    }
}

static Token read_identifier(Lexer *l, uint32_t start_line, uint32_t start_col,
                             uint32_t start_offset) {
    const char *start = l->source + l->pos;
    while (l->pos < l->source_len) {
        char c = peek_char(l);
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '_')
            advance(l);
        else break;
    }
    size_t len = l->pos - (size_t)(start - l->source);

    if (len == 1 && start[0] == '_')
        return make_token(l, TOKEN_UNDERSCORE, start_line, start_col,
                          start_offset, start, len);

    TokenKind kind = check_keyword(start, len);
    return make_token(l, kind, start_line, start_col, start_offset, start, len);
}

static Token next_token(Lexer *l) {
    skip_whitespace(l);

    uint32_t start_line = l->line;
    uint32_t start_col  = l->column;
    uint32_t start_off  = (uint32_t)l->pos;

    if (l->pos >= l->source_len)
        return make_token(l, TOKEN_EOF, start_line, start_col, start_off, "", 0);

    char c = peek_char(l);

    if (c == '\n') {
        advance(l);
        return make_token(l, TOKEN_NEWLINE, start_line, start_col, start_off, "\n", 1);
    }

    if (c == '"')
        return read_string(l, start_line, start_col, start_off);

    if (c >= '0' && c <= '9')
        return read_number(l, start_line, start_col, start_off);

    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_')
        return read_identifier(l, start_line, start_col, start_off);

    advance(l);
    char next = peek_char(l);

    switch (c) {
    case '+':
        return make_token(l, TOKEN_PLUS, start_line, start_col, start_off, "+", 1);
    case '-':
        if (next == '>') {
            advance(l);
            return make_token(l, TOKEN_ARROW, start_line, start_col, start_off, "->", 2);
        }
        return make_token(l, TOKEN_MINUS, start_line, start_col, start_off, "-", 1);
    case '*':
        return make_token(l, TOKEN_STAR, start_line, start_col, start_off, "*", 1);
    case '/':
        return make_token(l, TOKEN_SLASH, start_line, start_col, start_off, "/", 1);
    case '%':
        return make_token(l, TOKEN_PERCENT, start_line, start_col, start_off, "%", 1);
    case '=':
        if (next == '=') {
            advance(l);
            return make_token(l, TOKEN_EQ_EQ, start_line, start_col, start_off, "==", 2);
        }
        if (next == '>') {
            advance(l);
            return make_token(l, TOKEN_FAT_ARROW, start_line, start_col, start_off, "=>", 2);
        }
        return make_token(l, TOKEN_EQ, start_line, start_col, start_off, "=", 1);
    case '!':
        if (next == '=') {
            advance(l);
            return make_token(l, TOKEN_NEQ, start_line, start_col, start_off, "!=", 2);
        }
        return make_token(l, TOKEN_NOT, start_line, start_col, start_off, "!", 1);
    case '<':
        if (next == '=') {
            advance(l);
            return make_token(l, TOKEN_LE, start_line, start_col, start_off, "<=", 2);
        }
        if (next == '<') {
            advance(l);
            return make_token(l, TOKEN_SHL, start_line, start_col, start_off, "<<", 2);
        }
        return make_token(l, TOKEN_LT, start_line, start_col, start_off, "<", 1);
    case '>':
        if (next == '=') {
            advance(l);
            return make_token(l, TOKEN_GE, start_line, start_col, start_off, ">=", 2);
        }
        if (next == '>') {
            advance(l);
            return make_token(l, TOKEN_SHR, start_line, start_col, start_off, ">>", 2);
        }
        return make_token(l, TOKEN_GT, start_line, start_col, start_off, ">", 1);
    case '&':
        if (next == '&') {
            advance(l);
            return make_token(l, TOKEN_AND_AND, start_line, start_col, start_off, "&&", 2);
        }
        return make_token(l, TOKEN_AMP, start_line, start_col, start_off, "&", 1);
    case '|':
        if (next == '|') {
            advance(l);
            return make_token(l, TOKEN_OR_OR, start_line, start_col, start_off, "||", 2);
        }
        return make_token(l, TOKEN_PIPE, start_line, start_col, start_off, "|", 1);
    case '^':
        return make_token(l, TOKEN_CARET, start_line, start_col, start_off, "^", 1);
    case '~':
        return make_token(l, TOKEN_TILDE, start_line, start_col, start_off, "~", 1);
    case '.':
        if (next == '.') {
            advance(l);
            if (peek_char(l) == '=') {
                advance(l);
                return make_token(l, TOKEN_DOTDOT_EQ, start_line, start_col, start_off, "..=", 3);
            }
            return make_token(l, TOKEN_DOTDOT, start_line, start_col, start_off, "..", 2);
        }
        return make_token(l, TOKEN_DOT, start_line, start_col, start_off, ".", 1);
    case ',':
        return make_token(l, TOKEN_COMMA, start_line, start_col, start_off, ",", 1);
    case ';':
        return make_token(l, TOKEN_SEMICOLON, start_line, start_col, start_off, ";", 1);
    case ':':
        if (next == ':') {
            advance(l);
            return make_token(l, TOKEN_COLON_COLON, start_line, start_col, start_off, "::", 2);
        }
        return make_token(l, TOKEN_COLON, start_line, start_col, start_off, ":", 1);
    case '(':
        return make_token(l, TOKEN_LPAREN, start_line, start_col, start_off, "(", 1);
    case ')':
        return make_token(l, TOKEN_RPAREN, start_line, start_col, start_off, ")", 1);
    case '[':
        return make_token(l, TOKEN_LBRACKET, start_line, start_col, start_off, "[", 1);
    case ']':
        return make_token(l, TOKEN_RBRACKET, start_line, start_col, start_off, "]", 1);
    case '{':
        return make_token(l, TOKEN_LBRACE, start_line, start_col, start_off, "{", 1);
    case '}':
        return make_token(l, TOKEN_RBRACE, start_line, start_col, start_off, "}", 1);
    case '?':
        return make_token(l, TOKEN_QUESTION, start_line, start_col, start_off, "?", 1);
    default:
        return make_error(l, "unexpected character", start_line, start_col, start_off);
    }
}

Lexer *lexer_create(const char *filename, const char *source, size_t source_len,
                    StringTable *strings, Arena *arena) {
    Lexer *l = arena_new(arena, Lexer);
    if (!l) return NULL;
    l->filename  = filename;
    l->source    = source;
    l->source_len = source_len;
    l->pos       = 0;
    l->line      = 1;
    l->column    = 1;
    l->strings   = strings;
    l->arena     = arena;
    l->has_cached = false;
    return l;
}

Token lexer_next(Lexer *l) {
    if (l->has_cached) {
        l->has_cached = false;
        return l->cached;
    }
    return next_token(l);
}

Token lexer_peek(Lexer *l) {
    if (!l->has_cached) {
        l->cached = next_token(l);
        l->has_cached = true;
    }
    return l->cached;
}

void lexer_destroy(Lexer *l) {
    (void)l;
}
