//! Astra-0 lexer (Phase 2, Zig).
//!
//! Ported from the C seed (`seed/src/lexer.c`) so the Zig compiler accepts the
//! exact same token set. The important divergence from a naive tokenizer is
//! `newline`: in Astra-0 a line break terminates a statement (see
//! `research/010_grammar_and_parser_design.md` §4.2), so the parser needs to see
//! it. The seed exposes the same token as `TOKEN_NEWLINE`.
//!
//! Sources of truth mirrored here:
//! - `seed/src/lexer.c` (keyword table, numeric bases, escapes, ranges, S15)
//! - `seed/include/astra/astra.h` §5 (TokenKind)

const std = @import("std");

pub const Loc = struct {
    /// Byte offsets into the source, `[start, end)`.
    start: u32,
    end: u32,
    line: u32,
    col: u32,
};

pub const Tag = enum(u8) {
    // Literals
    int_literal,
    float_literal,
    string_literal,

    // Identifiers
    identifier,
    underscore, // `_`, kept distinct for wildcard patterns

    // Keywords (order matters for isKeyword)
    kw_fn,
    kw_let,
    kw_var,
    kw_if,
    kw_else,
    kw_while,
    kw_for,
    kw_match,
    kw_return,
    kw_break,
    kw_continue,
    kw_struct,
    kw_enum,
    kw_trait,
    kw_impl,
    kw_use,
    kw_mod,
    kw_pub,
    kw_mut,
    kw_true,
    kw_false,
    kw_ok,
    kw_err,
    kw_and,
    kw_or,
    kw_not,
    kw_comptime,
    kw_const,
    kw_in,
    kw_some,
    kw_none,
    kw_option,
    kw_result,

    // Operators
    plus, // +
    minus, // -
    star, // *
    slash, // /
    percent, // %
    eq, // =
    eq_eq, // ==
    neq, // !=
    lt, // <
    gt, // >
    le, // <=
    ge, // >=
    and_and, // &&
    or_or, // ||
    bang, // !
    amp, // &
    pipe, // |
    caret, // ^
    tilde, // ~
    shl, // <<
    shr, // >>
    arrow, // ->
    fat_arrow, // =>
    dot, // .
    comma, // ,
    semicolon, // ;
    colon, // :
    colon_colon, // ::
    lparen, // (
    rparen, // )
    lbracket, // [
    rbracket, // ]
    dotdot, // ..
    dotdot_eq, // ..=
    lbrace, // {
    rbrace, // }
    question, // ?

    // Special
    newline,
    eof,
    lex_err,

    pub fn isKeyword(self: Tag) bool {
        return @intFromEnum(self) >= @intFromEnum(Tag.kw_fn) and
            @intFromEnum(self) <= @intFromEnum(Tag.kw_result);
    }

    /// Human-readable name used by `--dump-tokens` and error messages. Kept in
    /// sync with `seed/src/driver.c`'s `token_name()`.
    pub fn name(self: Tag) []const u8 {
        return switch (self) {
            .int_literal => "INT",
            .float_literal => "FLOAT",
            .string_literal => "STRING",
            .identifier => "IDENT",
            .underscore => "_",
            .newline => "NEWLINE",
            .eof => "EOF",
            .lex_err => "ERROR",
            else => @tagName(self),
        };
    }
};

pub const Token = struct {
    tag: Tag,
    loc: Loc,
    /// Raw source slice for identifiers/keywords; decoded contents for strings.
    text: []const u8 = "",
    int_val: i64 = 0,
    float_val: f64 = 0,
};

/// Token produced by the closing `"` of an unterminated string or an invalid
/// escape; carries the message in `text`.
fn makeErr(self: *Tokenizer, start_line: u32, start_col: u32, start_off: u32, msg: []const u8) Token {
    return .{
        .tag = .lex_err,
        .loc = .{ .start = start_off, .end = self.pos, .line = start_line, .col = start_col },
        .text = msg,
    };
}

pub const Tokenizer = struct {
    source: []const u8,
    pos: u32,
    line: u32,
    col: u32,
    allocator: std.mem.Allocator,
    cached: ?Token = null,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Tokenizer {
        return .{
            .source = source,
            .pos = 0,
            .line = 1,
            .col = 1,
            .allocator = allocator,
        };
    }

    pub fn next(self: *Tokenizer) Token {
        if (self.cached) |t| {
            self.cached = null;
            return t;
        }
        return self.scan();
    }

    pub fn peek(self: *Tokenizer) Token {
        if (self.cached) |t| return t;
        const t = self.scan();
        self.cached = t;
        return t;
    }

    fn atEnd(self: *Tokenizer) bool {
        return self.pos >= self.source.len;
    }

    fn peekChar(self: *Tokenizer) u8 {
        if (self.atEnd()) return 0;
        return self.source[self.pos];
    }

    fn peekCharNext(self: *Tokenizer) u8 {
        if (self.pos + 1 >= self.source.len) return 0;
        return self.source[self.pos + 1];
    }

    fn advance(self: *Tokenizer) u8 {
        if (self.atEnd()) return 0;
        const c = self.source[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return c;
    }

    fn make(self: *Tokenizer, tag: Tag, start_off: u32, line: u32, col: u32, text: []const u8) Token {
        return .{ .tag = tag, .loc = .{ .start = start_off, .end = self.pos, .line = line, .col = col }, .text = text };
    }

    fn scan(self: *Tokenizer) Token {
        self.skipWhitespace();
        if (self.atEnd()) {
            return .{ .tag = .eof, .loc = .{ .start = self.pos, .end = self.pos, .line = self.line, .col = self.col } };
        }

        const start_off = self.pos;
        const start_line = self.line;
        const start_col = self.col;
        const c = self.peekChar();

        if (isAlpha(c)) return self.readIdentifier(start_off, start_line, start_col);
        if (isDigit(c)) return self.readNumber(start_off, start_line, start_col);
        if (c == '"') return self.readString(start_off, start_line, start_col);
        if (c == '\n') {
            _ = self.advance();
            return self.make(.newline, start_off, start_line, start_col, "\n");
        }

        return self.readOperator(start_off, start_line, start_col);
    }

    fn skipWhitespace(self: *Tokenizer) void {
        while (!self.atEnd()) {
            switch (self.peekChar()) {
                ' ', '\t', '\r' => _ = self.advance(),
                '/' => {
                    if (self.peekCharNext() == '/') {
                        while (!self.atEnd() and self.peekChar() != '\n') _ = self.advance();
                    } else if (self.peekCharNext() == '*') {
                        // Block comment (seed/src/lexer.c). Consume until `*/` or EOF.
                        _ = self.advance();
                        _ = self.advance();
                        while (!self.atEnd()) {
                            if (self.peekChar() == '*' and self.peekCharNext() == '/') {
                                _ = self.advance();
                                _ = self.advance();
                                break;
                            }
                            _ = self.advance();
                        }
                    } else return;
                },
                else => return,
            }
        }
    }

    fn readIdentifier(self: *Tokenizer, start_off: u32, line: u32, col: u32) Token {
        const start = self.pos;
        while (!self.atEnd() and (isAlpha(self.peekChar()) or isDigit(self.peekChar()))) _ = self.advance();
        const text = self.source[start..self.pos];
        if (std.mem.eql(u8, text, "_")) return self.make(.underscore, start_off, line, col, text);
        return self.make(keywordOrIdent(text), start_off, line, col, text);
    }

    fn readNumber(self: *Tokenizer, start_off: u32, line: u32, col: u32) Token {
        const start = self.pos;

        // Bases: 0x / 0b / 0o (seed/src/lexer.c read_number).
        if (self.peekChar() == '0' and (self.pos + 1 < self.source.len)) {
            const n = self.peekCharNext();
            const base: u8 = switch (n) {
                'x', 'X' => 16,
                'b', 'B' => 2,
                'o', 'O' => 8,
                else => 0,
            };
            if (base != 0) {
                _ = self.advance();
                _ = self.advance();
                while (!self.atEnd() and (isHexDigit(self.peekChar()) or self.peekChar() == '_')) _ = self.advance();
                const raw = self.source[start..self.pos];
                // Skip the `0x`/`0b`/`0o` prefix: parseInt expects bare digits.
                const digits = self.stripUnderscores(raw[2..]);
                const val = std.fmt.parseInt(i64, digits, base) catch {
                    return makeErr(self, line, col, start_off, "integer literal is out of range for i64");
                };
                var t = self.make(.int_literal, start_off, line, col, raw);
                t.int_val = val;
                return t;
            }
        }

        while (!self.atEnd() and (isDigit(self.peekChar()) or self.peekChar() == '_')) _ = self.advance();

        var is_float = false;
        // A `.` only starts a fraction when followed by a digit, so `0..5` lexes
        // as INT DOTDOT INT, not as a float.
        if (self.peekChar() == '.' and isDigit(self.peekCharNext())) {
            is_float = true;
            _ = self.advance();
            while (!self.atEnd() and (isDigit(self.peekChar()) or self.peekChar() == '_')) _ = self.advance();
        }

        if (self.peekChar() == 'e' or self.peekChar() == 'E') {
            is_float = true;
            _ = self.advance();
            if (self.peekChar() == '+' or self.peekChar() == '-') _ = self.advance();
            while (!self.atEnd() and isDigit(self.peekChar())) _ = self.advance();
        }

        const raw = self.source[start..self.pos];
        const cleaned = self.stripUnderscores(raw);
        if (is_float) {
            const val = std.fmt.parseFloat(f64, cleaned) catch 0.0;
            var t = self.make(.float_literal, start_off, line, col, raw);
            t.float_val = val;
            return t;
        }
        const val = std.fmt.parseInt(i64, cleaned, 10) catch {
            return makeErr(self, line, col, start_off, "integer literal is out of range for i64");
        };
        var t = self.make(.int_literal, start_off, line, col, raw);
        t.int_val = val;
        return t;
    }

    /// Remove `_` separators into an arena-owned buffer, matching the seed's
    /// handling of `1_000_000`.
    fn stripUnderscores(self: *Tokenizer, raw: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, raw, '_') == null) return raw;
        var buf = self.allocator.alloc(u8, raw.len) catch return raw;
        var n: usize = 0;
        for (raw) |c| {
            if (c == '_') continue;
            buf[n] = c;
            n += 1;
        }
        return buf[0..n];
    }

    fn readString(self: *Tokenizer, start_off: u32, line: u32, col: u32) Token {
        _ = self.advance(); // opening quote
        var buf = std.ArrayListUnmanaged(u8).empty;
        while (!self.atEnd()) {
            const c = self.peekChar();
            if (c == '"') {
                _ = self.advance();
                const owned = buf.toOwnedSlice(self.allocator) catch "";
                return self.make(.string_literal, start_off, line, col, owned);
            }
            if (c == '\n') return makeErr(self, line, col, start_off, "unterminated string literal");
            _ = self.advance();
            if (c == '\\') {
                if (self.atEnd()) return makeErr(self, line, col, start_off, "unterminated escape sequence");
                const esc = self.advance();
                const resolved: u8 = switch (esc) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '"' => '"',
                    '0' => 0,
                    else => return makeErr(self, line, col, start_off, "invalid escape sequence"),
                };
                buf.append(self.allocator, resolved) catch {};
            } else {
                buf.append(self.allocator, c) catch {};
            }
        }
        return makeErr(self, line, col, start_off, "unterminated string literal");
    }

    fn readOperator(self: *Tokenizer, start_off: u32, line: u32, col: u32) Token {
        const c = self.advance();
        const two = self.peekChar();
        const tag: Tag = switch (c) {
            '+' => .plus,
            '-' => if (two == '>') blk: {
                _ = self.advance();
                break :blk .arrow;
            } else .minus,
            '*' => .star,
            '/' => .slash,
            '%' => .percent,
            '=' => if (two == '=') blk: {
                _ = self.advance();
                break :blk .eq_eq;
            } else if (two == '>') blk: {
                _ = self.advance();
                break :blk .fat_arrow;
            } else .eq,
            '!' => if (two == '=') blk: {
                _ = self.advance();
                break :blk .neq;
            } else .bang,
            '<' => if (two == '<') blk: {
                _ = self.advance();
                break :blk .shl;
            } else if (two == '=') blk: {
                _ = self.advance();
                break :blk .le;
            } else .lt,
            '>' => if (two == '>') blk: {
                _ = self.advance();
                break :blk .shr;
            } else if (two == '=') blk: {
                _ = self.advance();
                break :blk .ge;
            } else .gt,
            '&' => if (two == '&') blk: {
                _ = self.advance();
                break :blk .and_and;
            } else .amp,
            '|' => if (two == '|') blk: {
                _ = self.advance();
                break :blk .or_or;
            } else .pipe,
            '^' => .caret,
            '~' => .tilde,
            '.' => if (two == '.') blk: {
                _ = self.advance();
                if (self.peekChar() == '=') {
                    _ = self.advance();
                    break :blk .dotdot_eq;
                }
                break :blk .dotdot;
            } else .dot,
            ':' => if (two == ':') blk: {
                _ = self.advance();
                break :blk .colon_colon;
            } else .colon,
            ',' => .comma,
            ';' => .semicolon,
            '(' => .lparen,
            ')' => .rparen,
            '[' => .lbracket,
            ']' => .rbracket,
            '{' => .lbrace,
            '}' => .rbrace,
            '?' => .question,
            else => return makeErr(self, line, col, start_off, "unexpected character"),
        };
        return self.make(tag, start_off, line, col, self.source[start_off..self.pos]);
    }

    fn isAlpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }
    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }
    fn isHexDigit(c: u8) bool {
        return isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }
};

/// Keyword table, identical to `seed/src/lexer.c`.
const Keyword = struct { text: []const u8, tag: Tag };
const keyword_table = [_]Keyword{
    .{ .text = "and", .tag = .kw_and },
    .{ .text = "break", .tag = .kw_break },
    .{ .text = "comptime", .tag = .kw_comptime },
    .{ .text = "const", .tag = .kw_const },
    .{ .text = "continue", .tag = .kw_continue },
    .{ .text = "else", .tag = .kw_else },
    .{ .text = "enum", .tag = .kw_enum },
    .{ .text = "err", .tag = .kw_err },
    .{ .text = "false", .tag = .kw_false },
    .{ .text = "fn", .tag = .kw_fn },
    .{ .text = "for", .tag = .kw_for },
    .{ .text = "if", .tag = .kw_if },
    .{ .text = "impl", .tag = .kw_impl },
    .{ .text = "in", .tag = .kw_in },
    .{ .text = "let", .tag = .kw_let },
    .{ .text = "match", .tag = .kw_match },
    .{ .text = "mod", .tag = .kw_mod },
    .{ .text = "mut", .tag = .kw_mut },
    .{ .text = "none", .tag = .kw_none },
    .{ .text = "not", .tag = .kw_not },
    .{ .text = "ok", .tag = .kw_ok },
    .{ .text = "option", .tag = .kw_option },
    .{ .text = "or", .tag = .kw_or },
    .{ .text = "pub", .tag = .kw_pub },
    .{ .text = "return", .tag = .kw_return },
    .{ .text = "result", .tag = .kw_result },
    .{ .text = "some", .tag = .kw_some },
    .{ .text = "struct", .tag = .kw_struct },
    .{ .text = "trait", .tag = .kw_trait },
    .{ .text = "true", .tag = .kw_true },
    .{ .text = "use", .tag = .kw_use },
    .{ .text = "var", .tag = .kw_var },
    .{ .text = "while", .tag = .kw_while },
};

pub fn keywordOrIdent(text: []const u8) Tag {
    for (keyword_table) |kw| {
        if (std.mem.eql(u8, kw.text, text)) return kw.tag;
    }
    return .identifier;
}

/// Keyword token for a text, or `.identifier`. Exposed for parity tests against
/// the seed's construct registry (`lexer_keyword_token`).
pub fn keywordToken(text: []const u8) Tag {
    return keywordOrIdent(text);
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn collect(a: std.mem.Allocator, source: []const u8) ![]Tag {
    var tk = Tokenizer.init(a, source);
    var tags = std.ArrayListUnmanaged(Tag).empty;
    while (true) {
        const t = tk.next();
        if (t.tag == .eof) break;
        try tags.append(a, t.tag);
    }
    return tags.toOwnedSlice(a);
}

test "tokenizer basic" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tags = try collect(a, "let x = 42;");
    try testing.expectEqualSlices(Tag, &.{ .kw_let, .identifier, .eq, .int_literal, .semicolon }, tags);
}

test "newlines are tokens" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tags = try collect(arena.allocator(), "a\nb");
    try testing.expectEqualSlices(Tag, &.{ .identifier, .newline, .identifier }, tags);
}

test "block comments are skipped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tags = try collect(arena.allocator(), "a /* x */ b // y\nc");
    try testing.expectEqualSlices(Tag, &.{ .identifier, .identifier, .newline, .identifier }, tags);
}

test "numeric bases, underscores and floats" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var tk = Tokenizer.init(arena.allocator(), "0x1f 0b1010 0o17 1_000 2.5 3");
    try testing.expectEqual(@as(i64, 31), tk.next().int_val);
    try testing.expectEqual(@as(i64, 10), tk.next().int_val);
    try testing.expectEqual(@as(i64, 15), tk.next().int_val);
    try testing.expectEqual(@as(i64, 1000), tk.next().int_val);
    try testing.expectEqual(@as(f64, 2.5), tk.next().float_val);
    try testing.expectEqual(@as(i64, 3), tk.next().int_val);
}

test "range does not lex as float" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tags = try collect(arena.allocator(), "0..5");
    try testing.expectEqualSlices(Tag, &.{ .int_literal, .dotdot, .int_literal }, tags);
}

test "string escapes are resolved" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var tk = Tokenizer.init(arena.allocator(), "\"a\\nb\"");
    const t = tk.next();
    try testing.expectEqual(Tag.string_literal, t.tag);
    try testing.expectEqualStrings("a\nb", t.text);
}

test "underscore is its own token" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tags = try collect(arena.allocator(), "_ _x");
    try testing.expectEqualSlices(Tag, &.{ .underscore, .identifier }, tags);
}
