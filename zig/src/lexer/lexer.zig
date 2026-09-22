const std = @import("std");

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: u32,
        end: u32,
    };

    pub const Tag = enum(u8) {
        // Literals
        int_literal,
        float_literal,
        string_literal,
        true_literal,
        false_literal,
        nil_literal,

        // Identifiers
        identifier,

        // Keywords
        kw_fn,
        kw_let,
        kw_mut,
        kw_struct,
        kw_enum,
        kw_trait,
        kw_impl,
        kw_if,
        kw_else,
        kw_while,
        kw_for,
        kw_in,
        kw_return,
        kw_break,
        kw_continue,
        kw_match,
        kw_as,
        kw_import,
        kw_from,
        kw_pub,
        kw_comptime,
        kw_unsafe,
        kw_type,
        kw_void,

        // Type keywords
        kw_i32,
        kw_i64,
        kw_u32,
        kw_u64,
        kw_f32,
        kw_f64,
        kw_bool,
        kw_string,

        // Operators
        plus, // +
        minus, // -
        star, // *
        slash, // /
        percent, // %
        amp, // &
        pipe, // |
        caret, // ^
        tilde, // ~
        bang, // !
        lt, // <
        gt, // >
        eq, // =
        dot, // .
        comma, // ,
        colon, // :
        semicolon, // ;
        arrow, // ->
        fat_arrow, // =>
        plus_eq, // +=
        minus_eq, // -=
        star_eq, // *=
        slash_eq, // /=
        percent_eq, // %=
        amp_eq, // &=
        pipe_eq, // |=
        caret_eq, // ^=
        lt_lt, // <<
        gt_gt, // >>
        lt_eq, // <=
        gt_eq, // >=
        eq_eq, // ==
        bang_eq, // !=
        amp_amp, // &&
        pipe_pipe, // ||
        dot_dot, // ..
        dot_dot_eq, // ..=
        question, // ?
        at, // @

        // Delimiters
        lparen, // (
        rparen, // )
        lbrace, // {
        rbrace, // }
        lbracket, // [
        rbracket, // ]

        // Special
        eof,
        err,

        pub fn isKeyword(self: Tag) bool {
            return @intFromEnum(self) >= @intFromEnum(Tag.kw_fn) and
                @intFromEnum(self) <= @intFromEnum(Tag.kw_string);
        }
    };
};

pub const Tokenizer = struct {
    source: []const u8,
    pos: u32,

    pub fn init(source: []const u8) Tokenizer {
        return .{
            .source = source,
            .pos = 0,
        };
    }

    pub fn next(self: *Tokenizer) Token {
        self.skipWhitespace();
        if (self.pos >= self.source.len) {
            return .{ .tag = .eof, .loc = .{ .start = self.pos, .end = self.pos } };
        }

        const start = self.pos;
        const ch = self.source[self.pos];

        if (isAlpha(ch) or ch == '_') {
            return self.readIdentifier(start);
        }
        if (isDigit(ch)) {
            return self.readNumber(start);
        }
        if (ch == '"') {
            return self.readString(start);
        }

        return self.readOperator(start);
    }

    fn skipWhitespace(self: *Tokenizer) void {
        while (self.pos < self.source.len) {
            switch (self.source[self.pos]) {
                ' ', '\t', '\r' => self.pos += 1,
                '\n' => self.pos += 1,
                '/' => {
                    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '/') {
                        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                            self.pos += 1;
                        }
                    } else {
                        break;
                    }
                },
                else => break,
            }
        }
    }

    fn readIdentifier(self: *Tokenizer, start: u32) Token {
        while (self.pos < self.source.len and (isAlpha(self.source[self.pos]) or isDigit(self.source[self.pos]) or self.source[self.pos] == '_')) {
            self.pos += 1;
        }
        const text = self.source[start..self.pos];
        const tag = KeywordMap.get(text) orelse .identifier;
        return .{ .tag = tag, .loc = .{ .start = start, .end = self.pos } };
    }

    fn readNumber(self: *Tokenizer, start: u32) Token {
        while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
            self.pos += 1;
        }
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            self.pos += 1;
            while (self.pos < self.source.len and isDigit(self.source[self.pos])) {
                self.pos += 1;
            }
            return .{ .tag = .float_literal, .loc = .{ .start = start, .end = self.pos } };
        }
        return .{ .tag = .int_literal, .loc = .{ .start = start, .end = self.pos } };
    }

    fn readString(self: *Tokenizer, start: u32) Token {
        self.pos += 1; // skip opening quote
        while (self.pos < self.source.len and self.source[self.pos] != '"') {
            if (self.source[self.pos] == '\\') {
                self.pos += 1; // skip escape char
            }
            self.pos += 1;
        }
        if (self.pos < self.source.len) {
            self.pos += 1; // skip closing quote
        }
        return .{ .tag = .string_literal, .loc = .{ .start = start, .end = self.pos } };
    }

    fn readOperator(self: *Tokenizer, start: u32) Token {
        const ch = self.source[self.pos];
        self.pos += 1;

        const tag: Token.Tag = switch (ch) {
            '+' => if (self.peek() == '=') blk: { self.pos += 1; break :blk .plus_eq; } else .plus,
            '-' => if (self.peek() == '>') blk: { self.pos += 1; break :blk .arrow; } else if (self.peek() == '=') blk: { self.pos += 1; break :blk .minus_eq; } else .minus,
            '*' => if (self.peek() == '=') blk: { self.pos += 1; break :blk .star_eq; } else .star,
            '/' => if (self.peek() == '=') blk: { self.pos += 1; break :blk .slash_eq; } else .slash,
            '%' => if (self.peek() == '=') blk: { self.pos += 1; break :blk .percent_eq; } else .percent,
            '&' => if (self.peek() == '&') blk: { self.pos += 1; break :blk .amp_amp; } else if (self.peek() == '=') blk: { self.pos += 1; break :blk .amp_eq; } else .amp,
            '|' => if (self.peek() == '|') blk: { self.pos += 1; break :blk .pipe_pipe; } else if (self.peek() == '=') blk: { self.pos += 1; break :blk .pipe_eq; } else .pipe,
            '^' => if (self.peek() == '=') blk: { self.pos += 1; break :blk .caret_eq; } else .caret,
            '~' => .tilde,
            '!' => if (self.peek() == '=') blk: { self.pos += 1; break :blk .bang_eq; } else .bang,
            '<' => if (self.peek() == '<') blk: { self.pos += 1; break :blk .lt_lt; } else if (self.peek() == '=') blk: { self.pos += 1; break :blk .lt_eq; } else .lt,
            '>' => if (self.peek() == '>') blk: { self.pos += 1; break :blk .gt_gt; } else if (self.peek() == '=') blk: { self.pos += 1; break :blk .gt_eq; } else .gt,
            '=' => if (self.peek() == '=') blk: { self.pos += 1; break :blk .eq_eq; } else if (self.peek() == '>') blk: { self.pos += 1; break :blk .fat_arrow; } else .eq,
            '.' => if (self.peek() == '.') blk: { self.pos += 1; if (self.peek() == '=') { self.pos += 1; break :blk .dot_dot_eq; } else break :blk .dot_dot; } else .dot,
            ',' => .comma,
            ':' => .colon,
            ';' => .semicolon,
            '(' => .lparen,
            ')' => .rparen,
            '{' => .lbrace,
            '}' => .rbrace,
            '[' => .lbracket,
            ']' => .rbracket,
            '?' => .question,
            '@' => .at,
            else => .err,
        };

        return .{ .tag = tag, .loc = .{ .start = start, .end = self.pos } };
    }

    fn peek(self: *Tokenizer) u8 {
        if (self.pos >= self.source.len) return 0;
        return self.source[self.pos];
    }

    fn isAlpha(ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or ch == '_';
    }

    fn isDigit(ch: u8) bool {
        return ch >= '0' and ch <= '9';
    }
};

const keyword_map_entry = struct { []const u8, Token.Tag };
const keyword_map = [_]keyword_map_entry{
    .{ "fn", .kw_fn },
    .{ "let", .kw_let },
    .{ "mut", .kw_mut },
    .{ "struct", .kw_struct },
    .{ "enum", .kw_enum },
    .{ "trait", .kw_trait },
    .{ "impl", .kw_impl },
    .{ "if", .kw_if },
    .{ "else", .kw_else },
    .{ "while", .kw_while },
    .{ "for", .kw_for },
    .{ "in", .kw_in },
    .{ "return", .kw_return },
    .{ "break", .kw_break },
    .{ "continue", .kw_continue },
    .{ "match", .kw_match },
    .{ "as", .kw_as },
    .{ "import", .kw_import },
    .{ "from", .kw_from },
    .{ "pub", .kw_pub },
    .{ "comptime", .kw_comptime },
    .{ "unsafe", .kw_unsafe },
    .{ "type", .kw_type },
    .{ "void", .kw_void },
    .{ "true", .true_literal },
    .{ "false", .false_literal },
    .{ "nil", .nil_literal },
    .{ "i32", .kw_i32 },
    .{ "i64", .kw_i64 },
    .{ "u32", .kw_u32 },
    .{ "u64", .kw_u64 },
    .{ "f32", .kw_f32 },
    .{ "f64", .kw_f64 },
    .{ "bool", .kw_bool },
    .{ "string", .kw_string },
};

const KeywordMap = struct {
    fn get(key: []const u8) ?Token.Tag {
        inline for (keyword_map) |entry| {
            if (std.mem.eql(u8, entry[0], key)) {
                return entry[1];
            }
        }
        return null;
    }
};

test "tokenizer basic" {
    const source = "let x = 42;";
    var tok = Tokenizer.init(source);

    const t1 = tok.next();
    try std.testing.expectEqual(Token.Tag.kw_let, t1.tag);

    const t2 = tok.next();
    try std.testing.expectEqual(Token.Tag.identifier, t2.tag);

    const t3 = tok.next();
    try std.testing.expectEqual(Token.Tag.eq, t3.tag);

    const t4 = tok.next();
    try std.testing.expectEqual(Token.Tag.int_literal, t4.tag);

    const t5 = tok.next();
    try std.testing.expectEqual(Token.Tag.semicolon, t5.tag);

    const t6 = tok.next();
    try std.testing.expectEqual(Token.Tag.eof, t6.tag);
}

test "tokenizer string" {
    const source = "\"hello world\"";
    var tok = Tokenizer.init(source);
    const t = tok.next();
    try std.testing.expectEqual(Token.Tag.string_literal, t.tag);
}

test "tokenizer operators" {
    const source = "+ - * / % & | ^ ~ ! < > = -> => += -= *= /= %= &= |= ^= << >> <= >= == != && || .. ..= ? @";
    var tok = Tokenizer.init(source);

    const expected = [_]Token.Tag{
        .plus,   .minus,  .star,   .slash,  .percent,
        .amp,    .pipe,   .caret,  .tilde,  .bang,
        .lt,     .gt,     .eq,     .arrow,  .fat_arrow,
        .plus_eq, .minus_eq, .star_eq, .slash_eq, .percent_eq,
        .amp_eq, .pipe_eq, .caret_eq, .lt_lt, .gt_gt,
        .lt_eq,  .gt_eq,  .eq_eq,  .bang_eq, .amp_amp,
        .pipe_pipe, .dot_dot, .dot_dot_eq, .question, .at,
    };

    for (expected) |exp| {
        const t = tok.next();
        try std.testing.expectEqual(exp, t.tag);
    }
}
