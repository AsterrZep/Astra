//! Astra-0 parser (Phase 2, Zig).
//!
//! A direct port of `seed/src/parser.c`: recursive descent for declarations and
//! statements, Pratt parsing for expressions. It accepts the same language the
//! seed accepts, which is the contract `PHASE2_KICKOFF.md` requires (the Zig
//! compiler must pass the seed's test suite before it grows new features).
//!
//! Two rules from `research/010_grammar_and_parser_design.md` drive the shape of
//! this file and are easy to get wrong:
//!
//! 1. **A line break terminates a statement** (`§4.2`). Both `;` and `newline`
//!    end one (`optionalSemi`); only a real `;` marks the statement as having no
//!    value, which is what makes `{ 7 }` an i32 and `{ 7; }` void.
//! 2. **The parser is the trust boundary** (`§3.4` in the seed design). Both the
//!    expression and the block entry points are depth-guarded, because nested
//!    blocks reach the parser by a different path and a 20k-deep input used to
//!    segfault the C seed.
//!
//! Errors are fail-fast: the first syntax error records a message and aborts the
//! parse. The seed recovers at statement level for better diagnostics; that is a
//! follow-up, not a prerequisite for parity (`research/011` §Appendix C puts
//! error recovery at "phrase-level, not over-engineered").

const std = @import("std");
const lexer = @import("../lexer/lexer.zig");
const ast = @import("../ast/ast.zig");
const diagnostics_mod = @import("../diagnostics.zig");

pub const PARSER_MAX_DEPTH: u32 = 256;

/// Pratt precedence, identical to the seed's `Precedence` enum. The numeric
/// values matter: binary operators recurse with `prec + 1` (left-associative),
/// assignment with `prec` (right-associative).
const Prec = struct {
    const none: u8 = 0;
    const assign: u8 = 1;
    const range: u8 = 2;
    const or_: u8 = 3;
    const and_: u8 = 4;
    const bit_or: u8 = 5;
    const bit_xor: u8 = 6;
    const bit_and: u8 = 7;
    const eq: u8 = 8;
    const comp: u8 = 9;
    const shift: u8 = 10;
    const add: u8 = 11;
    const mul: u8 = 12;
    const unary: u8 = 13;
    const postfix: u8 = 14;
};

fn precOf(tag: lexer.Tag) u8 {
    return switch (tag) {
        .eq => Prec.assign,
        .dotdot, .dotdot_eq => Prec.range,
        .or_or => Prec.or_,
        .and_and => Prec.and_,
        .pipe => Prec.bit_or,
        .caret => Prec.bit_xor,
        .amp => Prec.bit_and,
        .eq_eq, .neq => Prec.eq,
        .lt, .gt, .le, .ge => Prec.comp,
        .shl, .shr => Prec.shift,
        .plus, .minus => Prec.add,
        .star, .slash, .percent => Prec.mul,
        .lparen, .lbracket, .dot, .question => Prec.postfix,
        else => Prec.none,
    };
}

/// True when `left` can appear on the left of `=`
/// (`LValue ::= Identifier | LValue "." Identifier | LValue "[" Expr "]"`,
/// `research/010` §12.1, completed by the seed's Hallazgo B).
fn isLValue(node: ast.Node) bool {
    return switch (node) {
        .identifier => true,
        .field_access => true,
        .index_expr => true,
        else => false,
    };
}

fn binaryOpName(tag: lexer.Tag) []const u8 {
    return @tagName(tag);
}

pub const Parser = struct {
    tokenizer: lexer.Tokenizer,
    tree: *ast.Tree,
    allocator: std.mem.Allocator,
    current: lexer.Token,
    previous: lexer.Token,
    had_error: bool = false,
    /// Number of errors reported. Recovery continues past each, so a file can
    /// produce more than one; `had_error` stays the boolean the callers use.
    error_count: usize = 0,
    aborted: bool = false,
    depth: u32 = 0,
    no_struct_lit: bool = false,
    last_stmt_semi: bool = false,
    /// True while parsing the items of a trait or impl block: a typeless
    /// `self` receiver is legal only there (research/010 §12.1 FunctionParam;
    /// `self` stays a plain identifier everywhere else, so `let self = 5`
    /// keeps compiling).
    allow_self: bool = false,
    /// True only inside a trait block: a method may be a signature without a
    /// body (`fn show(self)`), the trait-item form of research/010 §12.1.
    allow_sig_only: bool = false,
    err_msg: []const u8 = "",
    err_loc: lexer.Loc = .{ .start = 0, .end = 0, .line = 0, .col = 0 },
    /// File being parsed, for diagnostics. Empty when the caller does not
    /// care (unit tests); the driver and the module loader set it.
    filename: []const u8 = "",
    /// Optional sink: when wired, errors are recorded there (and echoed to
    /// stderr); when null, they print directly. Both paths share one format.
    diag: ?*diagnostics_mod.Sink = null,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, tree: *ast.Tree) Parser {
        var p = Parser{
            .tokenizer = lexer.Tokenizer.init(allocator, source),
            .tree = tree,
            .allocator = allocator,
            .current = undefined,
            .previous = undefined,
        };
        p.advance();
        return p;
    }

    // ── Token helpers ─────────────────────────────────────────────

    fn check(self: *Parser, tag: lexer.Tag) bool {
        return self.current.tag == tag;
    }

    fn advance(self: *Parser) void {
        self.previous = self.current;
        self.current = self.tokenizer.next();
    }

    fn match(self: *Parser, tag: lexer.Tag) bool {
        if (self.check(tag)) {
            self.advance();
            return true;
        }
        return false;
    }

    fn failFmt(self: *Parser, comptime fmt: []const u8, args: anytype) anyerror {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "parse error";
        return self.fail(msg);
    }

    fn fail(self: *Parser, msg: []const u8) anyerror {
        // Report *every* error: the module loop recovers after each and keeps
        // parsing, so a file with two bad declarations should name both (the
        // seed's `parser_error` does the same).
        self.report(msg);
        return error.ParseError;
    }

    /// Record and emit a diagnostic *without* aborting the current parse
    /// function — the report-and-continue shape the seed's `parser_error`
    /// has (trait/impl bodies swallow the rest of the block after one).
    fn report(self: *Parser, msg: []const u8) void {
        // Mirror of seed `parser_error` (parser.c): a lex_err token carries
        // the lexer's own diagnostic in its text (out-of-range literal,
        // unterminated string…) and that text wins over the parser's generic
        // message — the single place every lexer error reaches the user. The
        // seed never appends a "found …" tail either: both sides print
        // `LOC: error: msg` (audit §1.3).
        if (self.current.tag == .lex_err) {
            self.reportExact(self.current.text);
            return;
        }
        self.reportExact(msg);
    }

    fn reportExact(self: *Parser, msg: []const u8) void {
        // Remember the first error for callers.
        if (!self.had_error) {
            self.err_msg = msg;
            self.err_loc = self.current.loc;
        }
        self.had_error = true;
        self.error_count += 1;
        diagnostics_mod.emit(self.diag, self.filename, self.current.loc, "{s}", .{msg});
    }

    /// Is this token a point where a fresh statement may start? Mirrors the
    /// seed's `synchronize` list.
    fn isSyncToken(tag: lexer.Tag) bool {
        return switch (tag) {
            .semicolon, .rbrace => true,
            .kw_fn, .kw_struct, .kw_enum, .kw_trait, .kw_impl, .kw_let, .kw_const, .kw_use, .kw_if, .kw_while, .kw_for, .kw_return, .kw_break, .kw_continue => true,
            else => false,
        };
    }

    /// Error recovery at statement level: skip tokens until something that can
    /// begin a new declaration. Does not consume the sync token itself.
    fn synchronize(self: *Parser) void {
        while (!self.check(.eof)) {
            if (isSyncToken(self.current.tag)) return;
            self.advance();
        }
    }

    /// The seed never calls `expect()` bare: every site passes its own
    /// description — quoted punctuation (`')'`, `':'`, `'in'`…) or a context
    /// phrase (`function name`, `loop variable name`…). Sites whose seed
    /// counterpart uses a stable quoted spelling resolve through this table
    /// so `expect(tag)` alone already prints the seed's text (audit §6.1);
    /// identifier-context sites pass their phrase through `expectMsg`
    /// instead, mirroring the seed call site one-for-one.
    fn seedExpectName(tag: lexer.Tag) []const u8 {
        return switch (tag) {
            .lparen => "'('",
            .rparen => "')'",
            .lbracket => "'['",
            .rbracket => "']'",
            .lbrace => "'{'",
            .rbrace => "'}'",
            .colon => "':'",
            .comma => "','",
            .semicolon => "';'",
            .eq => "'='",
            .arrow => "'->'",
            .fat_arrow => "'=>'",
            .lt => "'<'",
            .gt => "'>'",
            .pipe => "'|'",
            .question => "'?'",
            .at => "'@'",
            .kw_in => "'in'",
            // The one keyword the seed expects by bare spelling:
            // `expect(p, TOKEN_IMPORT, "import")` (parse_from).
            .kw_import => "import",
            else => tag.seedName(),
        };
    }

    fn expect(self: *Parser, tag: lexer.Tag) anyerror!void {
        return self.expectMsg(tag, seedExpectName(tag));
    }

    /// Seed-shaped `expect(p, kind, msg)`: prints
    /// `expected %s, got %s` with the seed's own spellings for the token
    /// actually found (`token_kind_name`, driver.c = `Tag.seedName`) and the
    /// caller's description of what was expected (audit §1.3).
    fn expectMsg(self: *Parser, tag: lexer.Tag, msg: []const u8) anyerror!void {
        if (!self.check(tag)) {
            self.reportExpected(msg);
            return error.ParseError;
        }
        self.advance();
        // A `>` closed a `<...>` list: drop out of generic mode so a later
        // `>>` lexes as a shift again (paired with the increments in
        // parseGenericParams and parseType).
        if (tag == .gt and self.tokenizer.gt_depth > 0) {
            self.tokenizer.gt_depth -= 1;
        }
    }

    /// The shared `expected %s, got %s` report behind `expectMsg` and
    /// `expectOr`: the token actually found is spelled with the seed's
    /// `token_kind_name`, what was expected with the caller's description.
    fn reportExpected(self: *Parser, msg: []const u8) void {
        var buf: [256]u8 = undefined;
        const m = std.fmt.bufPrint(&buf, "expected {s}, got {s}", .{
            msg,
            self.current.tag.seedName(),
        }) catch "parse error";
        self.reportExact(m);
    }

    /// Report-and-continue form of `expectMsg`: prints the same line, records
    /// the error and returns whether the token was there — the shape of the
    /// seed's `expect()` where the caller *ignores* the return value and lets
    /// a progress guard decide when to bail (struct/enum bodies: audit §6.1,
    /// `parse_struct_decl` / `parse_enum_decl`).
    fn expectOr(self: *Parser, tag: lexer.Tag, msg: []const u8) bool {
        if (self.check(tag)) {
            self.advance();
            if (tag == .gt and self.tokenizer.gt_depth > 0) {
                self.tokenizer.gt_depth -= 1;
            }
            return true;
        }
        self.reportExpected(msg);
        return false;
    }

    /// Consume `;` and newlines. Records whether a genuine `;` was seen so the
    /// enclosing block can tell a tail expression from a discarded statement.
    fn optionalSemi(self: *Parser) void {
        while (self.check(.newline) or self.check(.semicolon)) {
            if (self.check(.semicolon)) self.last_stmt_semi = true;
            self.advance();
        }
    }

    fn skipNewlines(self: *Parser) void {
        while (self.check(.newline)) self.advance();
    }

    fn enter(self: *Parser) bool {
        if (self.aborted) return false;
        if (self.depth >= PARSER_MAX_DEPTH) {
            self.aborted = true;
            self.had_error = true;
            self.error_count += 1;
            self.err_msg = "nesting too deep";
            self.err_loc = self.current.loc;
            diagnostics_mod.emit(self.diag, self.filename, self.current.loc, "nesting too deep (max {d})", .{PARSER_MAX_DEPTH});
            return false;
        }
        self.depth += 1;
        return true;
    }

    fn leave(self: *Parser) void {
        if (self.depth > 0) self.depth -= 1;
    }

    fn add(self: *Parser, node: ast.Node, loc: lexer.Loc) !u32 {
        return self.tree.addNode(node, loc);
    }

    // ── Module ────────────────────────────────────────────────────

    pub fn parse(self: *Parser) anyerror!u32 {
        const loc = self.current.loc;
        var items: std.ArrayListUnmanaged(u32) = .empty;
        defer items.deinit(self.allocator);

        self.skipNewlines();
        while (!self.check(.eof) and !self.aborted) {
            const decl = self.parseDeclaration() catch |e| blk: {
                if (e != error.ParseError) return e; // OOM and friends are fatal
                const at = self.current.loc.start;
                self.synchronize();
                // Guarantee forward progress. If the offending token is itself a
                // sync point (a stray `;` at top level), `synchronize` stops
                // where it already is; the seed gets past this because its
                // `parse_statement` consumes the `;` via `optional_semi` before
                // the error unwinds. Advancing past it here also stops the loop
                // from re-parsing it and reporting the same error twice.
                if (!self.check(.eof) and self.current.loc.start == at) self.advance();
                self.skipNewlines();
                break :blk @as(?u32, null);
            };
            if (decl) |idx| try items.append(self.allocator, idx);
            self.skipNewlines();
        }

        const list = try self.tree.addExtra(items.items);
        const module = try self.add(.{ .source_file = list }, loc);
        // The tree is returned only when clean; callers treat a parse error as
        // a hard failure (exit 1), exactly as before recovery was added.
        if (self.had_error) return error.ParseError;
        return module;
    }

    fn parseDeclaration(self: *Parser) anyerror!?u32 {
        self.skipNewlines();
        if (self.check(.eof)) return null;
        return try self.parseStatement();
    }

    // ── Statements ────────────────────────────────────────────────

    fn parseStatement(self: *Parser) anyerror!?u32 {
        self.skipNewlines();
        self.last_stmt_semi = false;
        if (self.check(.eof) or self.aborted) return null;

        // `pub` marks a declaration as exported (ARCHITECTURE §10.2). Recorded
        // on the AST node; per-module visibility kicks in with the module
        // system. research/010 §12.1 allows repeated qualifiers (`pub*`);
        // only the exportable kinds take it here (`impl` never is — it
        // attaches to a type).
        var is_pub = false;
        while (self.match(.kw_pub)) is_pub = true;
        if (is_pub and !self.check(.kw_fn) and !self.check(.kw_struct) and
            !self.check(.kw_enum) and !self.check(.kw_trait) and
            !self.check(.kw_const))
        {
            return self.fail("'pub' can only precede fn, struct, enum, trait or const");
        }

        if (self.match(.kw_fn)) return try self.parseFnDecl(is_pub);
        if (self.match(.kw_struct)) return try self.parseStructDecl(is_pub);
        if (self.match(.kw_enum)) return try self.parseEnumDecl(is_pub);
        if (self.match(.kw_trait)) return try self.parseTraitDecl(is_pub);
        if (self.match(.kw_impl)) return try self.parseImplBlock();
        if (self.match(.kw_const)) return try self.parseVarDecl(true, is_pub);
        if (self.match(.kw_let)) return try self.parseVarDecl(false, false);
        // `var` is a leftover keyword with no binding syntax (ARCH §8.1:
        // the canonical form is `let` / `let mut`). The stray entry below
        // used to parse `var x = 5` as an immutable let, so the *decl*
        // compiled and only the later assignment failed (audit §2.5);
        // seed rejects `var` at the token, and so does zig now.
        if (self.match(.kw_use)) return try self.parseUse();
        if (self.match(.kw_import)) return try self.parseImport();
        if (self.match(.kw_from)) return try self.parseFrom();

        if (self.match(.kw_if)) return try self.parseIf();
        if (self.match(.kw_while)) return try self.parseWhile();
        if (self.match(.kw_for)) return try self.parseFor();
        if (self.match(.kw_return)) return try self.parseReturn();
        if (self.match(.kw_match)) return try self.parseMatch();

        if (self.match(.kw_break)) {
            const loc = self.previous.loc;
            // A bare `break` ends at a statement boundary; anything else right
            // after it can only be a break-with-value, which Astra-0 does not
            // support. Newlines are tokens, so the next statement on its own
            // line is not mistaken for a value (mirrors the seed parser).
            if (!self.check(.semicolon) and !self.check(.newline) and
                !self.check(.rbrace) and !self.check(.eof))
            {
                return self.fail("break with a value is not supported in Astra-0");
            }
            self.optionalSemi();
            return try self.add(.{ .break_stmt = {} }, loc);
        }
        if (self.match(.kw_continue)) {
            const loc = self.previous.loc;
            self.optionalSemi();
            return try self.add(.{ .continue_stmt = {} }, loc);
        }

        if (self.match(.lbrace)) return try self.parseBlock();

        const expr = try self.parseExpression();
        self.optionalSemi();
        return expr;
    }

    /// `parseBlock` assumes the opening `{` was already consumed and
    /// `self.previous` is it (matching the seed).
    fn parseBlock(self: *Parser) anyerror!u32 {
        if (!self.enter()) return error.ParseError;
        defer self.leave();

        const loc = self.previous.loc;
        var stmts: std.ArrayListUnmanaged(u32) = .empty;
        defer stmts.deinit(self.allocator);
        var tail: ?u32 = null;

        self.skipNewlines();
        while (!self.check(.rbrace) and !self.check(.eof) and !self.aborted) {
            const stmt = try self.parseStatement();
            if (stmt) |s| {
                // Newlines between the last statement and `}` do not discard
                // its value — only `;` does (research/010 §4.2). Compound
                // statements (`match`, `if`, a nested block) never run
                // optional_semi, so the newline was still in front of `}` here
                // and they were never promoted: a lambda/void fn silently
                // returned nil (audit §4.9, mirrored from seed/src/parser.c
                // parse_block_impl).
                self.skipNewlines();
                if (!self.last_stmt_semi and (self.check(.rbrace) or self.check(.eof))) {
                    if (isTailCandidate(self.tree.node(s))) {
                        tail = s;
                        break;
                    }
                }
                try stmts.append(self.allocator, s);
            }
            self.skipNewlines();
        }
        try self.expect(.rbrace);

        const list = try self.tree.addExtra(stmts.items);
        return self.add(.{ .block = .{ .stmts = list, .tail = tail } }, loc);
    }

    fn parseIf(self: *Parser) anyerror!u32 {
        // Guarded entry (PARSER_MAX_DEPTH): the `else if` chain recurses
        // through parseIf without a block or expression frame between links
        // (audit §2.2, seed parse_if does the same).
        if (!self.enter()) return error.ParseError;
        defer self.leave();
        const loc = self.previous.loc;
        self.skipNewlines();
        const saved = self.no_struct_lit;
        self.no_struct_lit = true;
        const cond = try self.parseExpression();
        self.no_struct_lit = saved;
        self.skipNewlines();
        try self.expectMsg(.lbrace, "'{' for if body");
        const then_block = try self.parseBlock();

        var else_block: ?u32 = null;
        if (self.match(.kw_else)) {
            self.skipNewlines();
            if (self.check(.kw_if)) {
                self.advance();
                const elif = try self.parseIf();
                const one = try self.tree.addExtra(&.{elif});
                else_block = try self.add(.{ .block = .{ .stmts = one, .tail = null } }, self.tree.loc(elif));
            } else {
                try self.expectMsg(.lbrace, "'{' for else body");
                else_block = try self.parseBlock();
            }
        }
        return self.add(.{ .if_expr = .{ .cond = cond, .then_block = then_block, .else_block = else_block } }, loc);
    }

    fn parseWhile(self: *Parser) anyerror!u32 {
        const loc = self.previous.loc;
        self.skipNewlines();
        const saved = self.no_struct_lit;
        self.no_struct_lit = true;
        const cond = try self.parseExpression();
        self.no_struct_lit = saved;
        self.skipNewlines();
        try self.expectMsg(.lbrace, "'{' for while body");
        const body = try self.parseBlock();
        return self.add(.{ .while_expr = .{ .cond = cond, .body = body } }, loc);
    }

    fn parseFor(self: *Parser) anyerror!u32 {
        const loc = self.previous.loc;
        self.skipNewlines();
        try self.expectMsg(.identifier, "loop variable name");
        const name = self.previous.text;
        self.skipNewlines();
        try self.expect(.kw_in);
        self.skipNewlines();
        const saved = self.no_struct_lit;
        self.no_struct_lit = true;
        const iter = try self.parseExpression();
        self.no_struct_lit = saved;
        self.skipNewlines();
        try self.expectMsg(.lbrace, "'{' for for body");
        const body = try self.parseBlock();
        return self.add(.{ .for_expr = .{ .var_name = name, .iter = iter, .body = body } }, loc);
    }

    fn parseMatch(self: *Parser) anyerror!u32 {
        const loc = self.previous.loc;
        const saved = self.no_struct_lit;
        self.no_struct_lit = true;
        const target = try self.parseExpression();
        self.no_struct_lit = saved;

        self.skipNewlines();
        try self.expectMsg(.lbrace, "'{' for match");
        self.skipNewlines();

        var arms: std.ArrayListUnmanaged(u32) = .empty;
        defer arms.deinit(self.allocator);

        while (!self.check(.rbrace) and !self.check(.eof)) {
            const pattern = try self.parsePattern();
            var guard: ?u32 = null;
            if (self.match(.kw_if)) guard = try self.parseExpression();
            try self.expectMsg(.fat_arrow, "'=>'");
            self.skipNewlines();
            var body: u32 = undefined;
            if (self.check(.lbrace)) {
                self.advance();
                body = try self.parseBlock();
            } else {
                body = try self.parseExpression();
            }
            try arms.append(self.allocator, try self.add(.{ .match_arm = .{ .pattern = pattern, .guard = guard, .body = body } }, self.tree.loc(pattern)));
            self.skipNewlines();
            if (!self.match(.comma)) break;
            self.skipNewlines();
        }
        try self.expect(.rbrace);
        const list = try self.tree.addExtra(arms.items);
        return self.add(.{ .match_expr = .{ .target = target, .arms = list } }, loc);
    }

    fn parseReturn(self: *Parser) anyerror!u32 {
        const loc = self.previous.loc;
        var value: ?u32 = null;
        if (!self.check(.semicolon) and !self.check(.newline) and !self.check(.rbrace) and !self.check(.eof)) {
            value = try self.parseExpression();
        }
        self.optionalSemi();
        return self.add(.{ .return_stmt = value }, loc);
    }

    // ── Declarations ──────────────────────────────────────────────

    /// `<T, U: Show + Debug>` (research/010 §7.3). Phase 2.4 step 1: parsed
    /// on every declaration site into `TypeParam` nodes and left inert; the
    /// common case has no `<` and yields an empty list. Strict inside the
    /// brackets (no newline skipping), no trailing comma.
    fn parseGenericParams(self: *Parser) anyerror!ast.List {
        var params: std.ArrayListUnmanaged(u32) = .empty;
        defer params.deinit(self.allocator);
        if (!self.check(.lt)) return self.tree.addExtra(@as([]const u32, &.{}));
        self.tokenizer.gt_depth += 1;
        self.advance();
        var count: usize = 0;
        while (true) {
            // Matches the typechecker's generic-stack cap: the check side
            // keeps at most 32 bindings, so a longer list would be silently
            // dropped there and its parameters left unresolvable.
            if (count >= 32) {
                self.report("too many type parameters (max 32)");
                break;
            }
            try self.expectMsg(.identifier, "type parameter name");
            const name = self.previous.text;
            var bounds: std.ArrayListUnmanaged(u32) = .empty;
            defer bounds.deinit(self.allocator);
            if (self.match(.colon)) {
                while (true) {
                    try self.expectMsg(.identifier, "trait name");
                    const b = self.previous.text;
                    try bounds.append(self.allocator, try self.add(.{ .type_ident = .{ .name = b } }, self.previous.loc));
                    if (!self.match(.plus)) break;
                }
            }
            const blist = try self.tree.addExtra(bounds.items);
            try params.append(self.allocator, try self.add(.{ .type_param = .{ .name = name, .bounds = blist } }, self.previous.loc));
            count += 1;
            if (!self.match(.comma)) break;
        }
        try self.expect(.gt);
        return self.tree.addExtra(params.items);
    }

    fn parseFnDecl(self: *Parser, is_pub: bool) anyerror!u32 {
        const loc = self.previous.loc;
        try self.expectMsg(.identifier, "function name");
        const name = self.previous.text;
        const generics = try self.parseGenericParams();

        var params: std.ArrayListUnmanaged(u32) = .empty;
        defer params.deinit(self.allocator);

        try self.expect(.lparen);
        if (!self.check(.rparen)) {
            while (true) {
                try self.expectMsg(.identifier, "parameter name");
                const pname = self.previous.text;
                // A typeless `self` receiver: the name stands alone (`,` or
                // `)` follows), so `self: Point` keeps meaning an ordinary
                // parameter literally named `self` (research/010 §12.1).
                if (std.mem.eql(u8, pname, "self") and !self.check(.colon)) {
                    if (!self.allow_self) return self.fail("'self' parameter outside a trait or impl");
                    if (params.items.len > 0) return self.fail("'self' must be the first parameter");
                    try params.append(self.allocator, try self.add(.{ .param = .{ .name = pname, .type_node = null } }, self.previous.loc));
                } else {
                    try self.expect(.colon);
                    const ptype = try self.parseType();
                    try params.append(self.allocator, try self.add(.{ .param = .{ .name = pname, .type_node = ptype } }, self.previous.loc));
                }
                if (!self.match(.comma)) break;
            }
        }
        try self.expect(.rparen);

        // A trait/impl item is a method: the receiver is params[0]. One
        // without it would be a static function with no call syntax in the
        // language, so reject it at the source instead of leaving it
        // uncallable. (Typed `self: T` counts too — same name, same slot.)
        if (self.allow_self and
            (params.items.len == 0 or
            !std.mem.eql(u8, self.tree.node(params.items[0]).param.name, "self")))
        {
            return self.fail("'self' is required as the first parameter of a method");
        }

        var ret: ?u32 = null;
        if (self.match(.arrow)) ret = try self.parseType();

        // Body. Inside a trait a method may stop at its signature
        // (research/010 §12.1 TraitItem); an empty block stands in for the
        // missing body so every later phase sees a well-formed function.
        self.skipNewlines();
        const body = if (self.allow_sig_only and !self.check(.lbrace)) blk: {
            _ = self.match(.semicolon); // optional terminator: `fn show(self);`
            const empty = try self.tree.addExtra(@as([]const u32, &.{}));
            break :blk try self.add(.{ .block = .{ .stmts = empty, .tail = null } }, loc);
        } else blk: {
            try self.expectMsg(.lbrace, "'{' for function body");
            break :blk try self.parseBlock();
        };
        const list = try self.tree.addExtra(params.items);
        return self.add(.{ .fn_decl = .{ .name = name, .params = list, .ret = ret, .body = body, .is_pub = is_pub, .generics = generics } }, loc);
    }

    fn parseStructDecl(self: *Parser, is_pub: bool) anyerror!u32 {
        const loc = self.previous.loc;
        try self.expectMsg(.identifier, "struct name");
        const name = self.previous.text;
        const generics = try self.parseGenericParams();

        try self.expectMsg(.lbrace, "'{'");
        self.skipNewlines();
        var fields: std.ArrayListUnmanaged(u32) = .empty;
        defer fields.deinit(self.allocator);
        // Seed shape (`parse_struct_decl`): a failed `expect` inside the field
        // loop is *not* fatal — each missing piece is reported and the loop
        // keeps going, the progress guard at the bottom is what bails, and the
        // rest of the body is swallowed up to its closing brace (audit §6.1 /
        // §1.5: without this zig lost the seed's `expected ':'` →
        // `expected type` → `aborting struct body` cascade and jumped straight
        // to `unexpected token in expression` at the stray `}`).
        while (!self.check(.rbrace) and !self.check(.eof) and !self.aborted) {
            const iter_start = self.current.loc.start;
            _ = self.expectOr(.identifier, "field name");
            const fname = self.previous.text;
            _ = self.expectOr(.colon, "':'");
            const ftype = try self.parseType();
            try fields.append(self.allocator, try self.add(.{ .field_decl = .{ .name = fname, .type_node = ftype } }, self.previous.loc));
            self.optionalSemi();
            self.skipNewlines();
            if (self.current.loc.start == iter_start) {
                self.reportExact("aborting struct body after parse error");
                break;
            }
        }
        // A malformed body is swallowed up to its closing brace (the expect
        // below consumes it) so the stray '}' is not re-reported at module
        // level — seed does the same.
        while (!self.check(.rbrace) and !self.check(.eof)) self.advance();
        try self.expect(.rbrace);
        const list = try self.tree.addExtra(fields.items);
        return self.add(.{ .struct_decl = .{ .name = name, .fields = list, .is_pub = is_pub, .generics = generics } }, loc);
    }

    fn parseEnumDecl(self: *Parser, is_pub: bool) anyerror!u32 {
        const loc = self.previous.loc;
        try self.expectMsg(.identifier, "enum name");
        const name = self.previous.text;
        const generics = try self.parseGenericParams();

        try self.expectMsg(.lbrace, "'{'");
        self.skipNewlines();
        var variants: std.ArrayListUnmanaged(u32) = .empty;
        defer variants.deinit(self.allocator);
        while (!self.check(.rbrace) and !self.check(.eof) and !self.aborted) {
            // Seed checks `had_error && no progress` right after the name
            // expect; a failed `expect` consumes nothing, so that condition
            // holds exactly when the expect below fails — hence no separate
            // progress variable here (the seed's bottom-of-loop twin cannot
            // fire: a successful expect always moves `offset`).
            if (!self.expectOr(.identifier, "variant name")) {
                // Seed (`parse_enum_decl`): the body bails instead of looping
                // — the `aborting enum body` line is the seed's, at the same
                // position (audit §6.1 cheap win a).
                self.reportExact("aborting enum body after parse error");
                break;
            }
            const vname = self.previous.text;

            var payload: ?u32 = null;
            if (self.match(.lparen)) {
                const ploc = self.previous.loc;
                var pfields: std.ArrayListUnmanaged(u32) = .empty;
                defer pfields.deinit(self.allocator);
                self.skipNewlines();
                if (!self.check(.rparen)) {
                    while (true) {
                        var fname: []const u8 = "";
                        var ftype: u32 = undefined;
                        if (self.check(.identifier)) {
                            self.advance();
                            const maybe_name = self.previous.text;
                            if (self.match(.colon)) {
                                fname = maybe_name;
                                ftype = try self.parseType();
                            } else {
                                // The identifier *was* the type (`Paso(i32)`).
                                ftype = try self.add(.{ .type_ident = .{ .name = maybe_name } }, self.previous.loc);
                            }
                        } else {
                            ftype = try self.parseType();
                        }
                        try pfields.append(self.allocator, try self.add(.{ .field_decl = .{ .name = fname, .type_node = ftype } }, self.previous.loc));
                        if (!self.match(.comma)) break;
                        self.skipNewlines();
                    }
                }
                try self.expectMsg(.rparen, "')' after variant payload");
                const plist = try self.tree.addExtra(pfields.items);
                payload = try self.add(.{ .payload = plist }, ploc);
            }
            try variants.append(self.allocator, try self.add(.{ .enum_variant = .{ .name = vname, .payload = payload } }, self.previous.loc));
            self.optionalSemi();
            self.skipNewlines();
        }
        // Seed: swallow a malformed body up to its closing brace so the stray
        // '}' is not re-reported at module level.
        while (!self.check(.rbrace) and !self.check(.eof)) self.advance();
        try self.expect(.rbrace);
        const list = try self.tree.addExtra(variants.items);
        return self.add(.{ .enum_decl = .{ .name = name, .variants = list, .is_pub = is_pub, .generics = generics } }, loc);
    }

    /// `trait Name { fn ... }` (research/010 §12.1 TraitDef). Items are `fn`
    /// only and a method may be a signature without a body; a `<...>` list
    /// (step 1, inert until Phase 2.4 step 2) follows the name.
    fn parseTraitDecl(self: *Parser, is_pub: bool) anyerror!u32 {
        const loc = self.previous.loc;
        try self.expectMsg(.identifier, "trait name");
        const name = self.previous.text;
        const generics = try self.parseGenericParams();

        var items: std.ArrayListUnmanaged(u32) = .empty;
        defer items.deinit(self.allocator);

        try self.expectMsg(.lbrace, "'{'");
        const saved_self = self.allow_self;
        const saved_sig = self.allow_sig_only;
        self.allow_self = true;
        self.allow_sig_only = true;
        defer {
            self.allow_self = saved_self;
            self.allow_sig_only = saved_sig;
        }

        self.skipNewlines();
        while (!self.check(.rbrace) and !self.check(.eof) and !self.aborted) {
            if (!self.check(.kw_fn)) {
                // Report and keep going: the loop below swallows the rest of
                // the body up to `}`, exactly as the seed does.
                self.report("only 'fn' items are supported in a trait");
                break;
            }
            self.advance();
            try items.append(self.allocator, try self.parseFnDecl(false));
            self.skipNewlines();
        }
        while (!self.check(.rbrace) and !self.check(.eof)) self.advance();
        try self.expect(.rbrace);
        const list = try self.tree.addExtra(items.items);
        return self.add(.{ .trait_decl = .{ .name = name, .items = list, .is_pub = is_pub, .generics = generics } }, loc);
    }

    /// `impl [TraitName for] Type { fn methods }` (research/010 §12.1
    /// ImplBlock). An inherent impl omits `for`; every item is a method taking
    /// a typeless `self` as its first parameter. A `<...>` list (step 1,
    /// inert until Phase 2.4 step 2) sits between `impl` and the names.
    fn parseImplBlock(self: *Parser) anyerror!u32 {
        const loc = self.previous.loc;
        const generics = try self.parseGenericParams();
        try self.expectMsg(.identifier, "type name");
        const first = self.previous.text;

        var trait_name: ?[]const u8 = null;
        var type_name: []const u8 = undefined;
        if (self.match(.kw_for)) {
            trait_name = first;
            try self.expectMsg(.identifier, "type name");
            type_name = self.previous.text;
        } else {
            type_name = first;
        }

        var items: std.ArrayListUnmanaged(u32) = .empty;
        defer items.deinit(self.allocator);

        try self.expectMsg(.lbrace, "'{'");
        const saved_self = self.allow_self;
        const saved_sig = self.allow_sig_only;
        self.allow_self = true;
        self.allow_sig_only = false; // an impl method always has a body
        defer {
            self.allow_self = saved_self;
            self.allow_sig_only = saved_sig;
        }

        self.skipNewlines();
        while (!self.check(.rbrace) and !self.check(.eof) and !self.aborted) {
            if (!self.check(.kw_fn)) {
                self.report("only 'fn' items are supported in an impl block");
                break;
            }
            self.advance();
            try items.append(self.allocator, try self.parseFnDecl(false));
            self.skipNewlines();
        }
        while (!self.check(.rbrace) and !self.check(.eof)) self.advance();
        try self.expect(.rbrace);
        const list = try self.tree.addExtra(items.items);
        return self.add(.{ .impl_decl = .{ .trait_name = trait_name, .type_name = type_name, .items = list, .generics = generics } }, loc);
    }

    fn parseVarDecl(self: *Parser, is_const: bool, is_pub: bool) anyerror!u32 {
        const loc = self.previous.loc;
        var is_mut = false;
        if (!is_const and self.match(.kw_mut)) is_mut = true;

        try self.expectMsg(.identifier, "variable name");
        const name = self.previous.text;

        var type_node: ?u32 = null;
        if (self.match(.colon)) type_node = try self.parseType();

        var value: ?u32 = null;
        if (self.match(.eq)) value = try self.parseExpression();

        self.optionalSemi();

        // `is_pub` only reaches here as false for let/var: `pub` before them
        // is rejected in parseStatement.
        const decl = ast.VarDecl{ .name = name, .type_node = type_node, .value = value, .is_mut = is_mut, .is_pub = is_pub };
        return if (is_const)
            self.add(.{ .const_decl = decl }, loc)
        else
            self.add(.{ .var_decl = decl }, loc);
    }

    /// `ImportPath ::= ("@" "/")? Identifier (("." | "/") Identifier)*`
    /// (`research/010` §12.1, ARCHITECTURE §10.4 rules 3-4). Dot-separated —
    /// the separator the rest of the language uses for paths (`Color.Rojo`,
    /// `s.field`) — plus `/` as an equivalent module separator and the `@/`
    /// project-root prefix. The seed's `parse_use` used to match `::` while
    /// its own grammar said `.`; Phase 2.2 fixed the seed, and the path is
    /// now parsed in exactly one place in each compiler, rejecting `::`
    /// identically. Returns the source text of the whole path as written
    /// (prefix, separators and spacing included), e.g. "@/utils/logger".
    fn parseImportPath(self: *Parser) anyerror![]const u8 {
        const start = self.current.loc.start;
        if (self.match(.at)) {
            try self.expectMsg(.slash, "/ after @");
        }
        try self.expectMsg(.identifier, "module path");
        while (self.check(.dot) or self.check(.slash)) {
            self.advance();
            try self.expectMsg(.identifier, "module path segment");
        }
        return self.tree.source[start..self.previous.loc.end];
    }

    /// `ExportStmt ::= "use" ImportPath`.
    fn parseUse(self: *Parser) anyerror!u32 {
        const loc = self.previous.loc;
        const path = try self.parseImportPath();
        self.optionalSemi();
        return self.add(.{ .use_decl = path }, loc);
    }

    /// `import ImportPath ("as" Identifier)?`.
    fn parseImport(self: *Parser) anyerror!u32 {
        const loc = self.previous.loc;
        const path = try self.parseImportPath();
        self.skipNewlines();
        var alias: ?[]const u8 = null;
        if (self.match(.kw_as)) {
            try self.expectMsg(.identifier, "alias");
            alias = self.previous.text;
        }
        self.optionalSemi();
        return self.add(.{ .import_decl = .{ .path = path, .alias = alias } }, loc);
    }

    /// `from ImportPath import ImportItem ("," ImportItem)*`.
    fn parseFrom(self: *Parser) anyerror!u32 {
        const loc = self.previous.loc;
        const path = try self.parseImportPath();
        self.skipNewlines();
        try self.expect(.kw_import);
        self.skipNewlines();

        var items: std.ArrayListUnmanaged(u32) = .empty;
        defer items.deinit(self.allocator);
        // Seed loop shape (parse_from): the EOF check keeps `from x import`
        // with nothing after it out of the loop, so the "at least one item"
        // rule below sees an empty list instead of failing on expect.
        while (!self.check(.eof) and !self.aborted) {
            try self.expectMsg(.identifier, "import item");
            const name = self.previous.text;
            const item_loc = self.previous.loc;
            var alias: ?[]const u8 = null;
            if (self.match(.kw_as)) {
                try self.expectMsg(.identifier, "alias");
                alias = self.previous.text;
            }
            try items.append(self.allocator, try self.add(.{ .import_item = .{ .name = name, .alias = alias } }, item_loc));
            self.skipNewlines();
            if (!self.match(.comma)) break;
            self.skipNewlines();
        }
        // The production requires at least one item: `from a.b import` alone
        // would otherwise parse as an empty list that silently imports
        // nothing (seed parser.c parse_from, same wording).
        if (items.items.len == 0 and !self.had_error) {
            self.report("expected at least one import item");
        }
        self.optionalSemi();
        const list = try self.tree.addExtra(items.items);
        return self.add(.{ .from_decl = .{ .path = path, .items = list } }, loc);
    }

    // ── Types ─────────────────────────────────────────────────────

    fn parseType(self: *Parser) anyerror!u32 {
        // Guarded entry (PARSER_MAX_DEPTH): with real type arguments,
        // `Vec<Vec<Vec<...>>>` recurses once per nesting level, where the old
        // skip loop was iterative. The seed guards `parse_type` the same way.
        if (!self.enter()) return error.ParseError;
        defer self.leave();
        return self.parseTypeImpl();
    }

    fn parseTypeImpl(self: *Parser) anyerror!u32 {
        var n: u32 = undefined;
        if (self.check(.identifier)) {
            self.advance();
            const loc = self.previous.loc;
            const name = self.previous.text;
            var args: std.ArrayListUnmanaged(u32) = .empty;
            defer args.deinit(self.allocator);
            // Type arguments are real nodes now (Phase 2.4 step 3a): the
            // checker still resolves only the base name until step 3b, but
            // they reach the AST dump and survive a closing `>>`.
            if (self.check(.lt)) {
                self.tokenizer.gt_depth += 1;
                self.advance();
                var count: usize = 0;
                while (true) {
                    // Mirrors the seed: an argument list longer than the
                    // typechecker's binding cap would be dead weight.
                    if (count >= 32) {
                        self.report("too many type arguments (max 32)");
                        break;
                    }
                    try args.append(self.allocator, try self.parseType());
                    count += 1;
                    if (!self.match(.comma)) break;
                }
                try self.expect(.gt);
            }
            const glist = try self.tree.addExtra(@as([]const u32, args.items));
            n = try self.add(.{ .type_ident = .{ .name = name, .generics = glist } }, loc);
        } else if (self.match(.lbracket)) {
            const loc = self.previous.loc;
            const elem = try self.parseType();
            var size: ?u32 = null;
            if (self.match(.semicolon)) size = try self.parseExpression();
            try self.expect(.rbracket);
            n = try self.add(.{ .type_array = .{ .elem = elem, .size = size } }, loc);
        } else if (self.match(.kw_fn)) {
            const loc = self.previous.loc;
            var params: std.ArrayListUnmanaged(u32) = .empty;
            defer params.deinit(self.allocator);
            try self.expect(.lparen);
            if (!self.check(.rparen)) {
                while (true) {
                    try params.append(self.allocator, try self.parseType());
                    if (!self.match(.comma)) break;
                }
            }
            try self.expect(.rparen);
            var ret: ?u32 = null;
            if (self.match(.arrow)) ret = try self.parseType();
            const list = try self.tree.addExtra(params.items);
            return self.add(.{ .type_fn = .{ .params = list, .ret = ret } }, loc);
        } else {
            // Seed (`parse_type_impl`): `parser_error(p, "expected type")`
            // and a `void` fallback node — reporting must NOT abort the caller,
            // or the struct/enum body loops lose the progress guard that
            // produces the seed's `aborting … body` line (audit §6.1).
            self.report("expected type");
            n = try self.add(.{ .type_ident = .{ .name = "void" } }, self.current.loc);
        }

        if (self.match(.question)) {
            const loc = self.previous.loc;
            n = try self.add(.{ .type_optional = n }, loc);
        }
        return n;
    }

    // ── Expressions (Pratt) ───────────────────────────────────────

    fn parseExpression(self: *Parser) anyerror!u32 {
        return self.parseExprPrec(Prec.none);
    }

    fn parseExprPrec(self: *Parser, min_prec: u8) anyerror!u32 {
        if (!self.enter()) return error.ParseError;
        defer self.leave();
        return self.parseExprImpl(min_prec);
    }

    fn parseExprImpl(self: *Parser, min_prec: u8) anyerror!u32 {
        var left = try self.parsePrefix();
        if (self.aborted) return error.ParseError;

        // Each iteration wraps `left` one level deeper; a flat chain is
        // iterative for the parser but recursive for the typechecker and
        // emitter, which overflowed their C stacks at ~300 terms in the
        // seed debug build (audit §4.6, mirror of the seed). Cap the chain
        // the way PARSER_MAX_DEPTH caps nesting.
        var chain_len: u32 = 0;
        while (true) {
            if (self.aborted) return error.ParseError;
            const prec = precOf(self.current.tag);
            if (prec == Prec.none or prec < min_prec) break;
            chain_len += 1;
            if (chain_len > PARSER_MAX_DEPTH) {
                diagnostics_mod.emit(self.diag, self.filename, self.current.loc, "expression chain too deep (max {d})", .{PARSER_MAX_DEPTH});
                return error.ParseError;
            }

            const kind = self.current.tag;
            self.advance();

            switch (kind) {
                .eq => left = try self.parseAssignment(left, prec),
                .lparen => left = try self.parseCall(left),
                .lbracket => left = try self.parseIndex(left),
                .dot => left = try self.parseFieldAccess(left),
                .dotdot, .dotdot_eq => left = try self.parseRange(left, kind),
                .question => {
                    const loc = self.previous.loc;
                    left = try self.add(.{ .try_expr = left }, loc);
                },
                else => {
                    const loc = self.previous.loc;
                    const right = try self.parseExprPrec(prec + 1);
                    left = try self.add(.{ .binary_expr = .{ .op = kind, .left = left, .right = right } }, loc);
                    _ = binaryOpName(kind);
                },
            }
        }
        return left;
    }

    fn parsePrefix(self: *Parser) anyerror!u32 {
        switch (self.current.tag) {
            .int_literal => {
                const tok = self.current;
                self.advance();
                return self.add(.{ .int_literal = tok.int_val }, tok.loc);
            },
            .float_literal => {
                const tok = self.current;
                self.advance();
                return self.add(.{ .float_literal = tok.float_val }, tok.loc);
            },
            .string_literal => {
                const tok = self.current;
                self.advance();
                return self.add(.{ .string_literal = tok.text }, tok.loc);
            },
            .kw_true, .kw_false => {
                const tok = self.current;
                self.advance();
                return self.add(.{ .bool_literal = tok.tag == .kw_true }, tok.loc);
            },
            .identifier => {
                const tok = self.current;
                self.advance();
                if (!self.no_struct_lit and self.check(.lbrace)) {
                    return self.parseStructLiteral(tok.text, tok.loc);
                }
                return self.add(.{ .identifier = tok.text }, tok.loc);
            },
            .lparen => {
                self.advance();
                const saved = self.no_struct_lit;
                self.no_struct_lit = false;
                const expr = try self.parseExprPrec(Prec.none);
                self.no_struct_lit = saved;
                try self.expect(.rparen);
                return expr;
            },
            .lbrace => {
                self.advance();
                return self.parseBlock();
            },
            .lbracket => {
                self.advance();
                return self.parseArrayLiteral();
            },
            .kw_if => {
                self.advance();
                return self.parseIf();
            },
            // `while`/`for` are STATEMENTS in Astra-0: they never produce a
            // value (`break` with a value is unsupported — ui/break_value),
            // so as expressions they could only ever be void. Accepting them
            // here made `let x = while …` fall through to a void-in-let error
            // and `print(while …)` reach the emitter as a call argument with
            // no value — an *internal* stack-imbalance error (audit §7.15,
            // research/021). The seed never had these cases; the statement
            // path in parseStatement dispatches them before parseExpression.
            .kw_match => {
                self.advance();
                return self.parseMatch();
            },
            .minus, .bang, .tilde => {
                const tok = self.current;
                self.advance();
                const operand = try self.parseExprPrec(Prec.unary);
                return self.add(.{ .unary_expr = .{ .op = tok.tag, .operand = operand } }, tok.loc);
            },
            .kw_some => return self.parseBuiltinCtor(.some_expr),
            .kw_ok => return self.parseBuiltinCtor(.ok_expr),
            .kw_err => return self.parseBuiltinCtor(.err_expr),
            .kw_none => {
                const tok = self.current;
                self.advance();
                return self.add(.{ .none_expr = {} }, tok.loc);
            },
            .pipe => {
                self.advance(); // consume the opening `|`
                return self.parseLambda();
            },
            else => return self.failFmt("unexpected token in expression", .{}),
        }
    }

    const BuiltinCtor = enum { some_expr, ok_expr, err_expr };

    fn parseBuiltinCtor(self: *Parser, comptime tag: BuiltinCtor) anyerror!u32 {
        const tok = self.current;
        self.advance();
        // Seed wording differs per constructor (`'(' after some` / `ok` /
        // `err`); the closing `')'` is the same for all three.
        try self.expectMsg(.lparen, switch (tag) {
            .some_expr => "'(' after some",
            .ok_expr => "'(' after ok",
            .err_expr => "'(' after err",
        });
        const value = try self.parseExpression();
        try self.expect(.rparen);
        return switch (tag) {
            .some_expr => self.add(.{ .some_expr = value }, tok.loc),
            .ok_expr => self.add(.{ .ok_expr = value }, tok.loc),
            .err_expr => self.add(.{ .err_expr = value }, tok.loc),
        };
    }

    fn parseLambda(self: *Parser) anyerror!u32 {
        const loc = self.previous.loc; // the opening `|`
        var params: std.ArrayListUnmanaged(u32) = .empty;
        defer params.deinit(self.allocator);

        if (!self.check(.pipe)) {
            while (true) {
                try self.expectMsg(.identifier, "parameter name");
                const pname = self.previous.text;
                var ptype: ?u32 = null;
                if (self.match(.colon)) ptype = try self.parseType();
                try params.append(self.allocator, try self.add(.{ .param = .{ .name = pname, .type_node = ptype } }, self.previous.loc));
                if (!self.match(.comma)) break;
            }
        }
        try self.expectMsg(.pipe, "'|' after lambda parameters");

        var ret: ?u32 = null;
        if (self.match(.arrow)) ret = try self.parseType();

        self.skipNewlines();
        try self.expectMsg(.lbrace, "'{' for lambda body");
        const body = try self.parseBlock();
        const list = try self.tree.addExtra(params.items);
        return self.add(.{ .lambda_expr = .{ .params = list, .ret = ret, .body = body } }, loc);
    }

    fn parseAssignment(self: *Parser, left: u32, prec: u8) anyerror!u32 {
        if (!isLValue(self.tree.node(left))) {
            return self.fail("invalid assignment target");
        }
        const loc = self.tree.loc(left);
        const value = try self.parseExprPrec(prec); // right-associative
        return self.add(.{ .assignment = .{ .target = left, .value = value } }, loc);
    }

    fn parseCall(self: *Parser, callee: u32) anyerror!u32 {
        const loc = self.tree.loc(callee);
        var args: std.ArrayListUnmanaged(u32) = .empty;
        defer args.deinit(self.allocator);
        if (!self.check(.rparen)) {
            while (true) {
                try args.append(self.allocator, try self.parseExpression());
                if (!self.match(.comma)) break;
                self.skipNewlines();
            }
        }
        try self.expect(.rparen);
        const list = try self.tree.addExtra(args.items);
        return self.add(.{ .call_expr = .{ .callee = callee, .args = list } }, loc);
    }

    fn parseIndex(self: *Parser, object: u32) anyerror!u32 {
        const loc = self.tree.loc(object);
        const index = try self.parseExpression();
        try self.expect(.rbracket);
        return self.add(.{ .index_expr = .{ .object = object, .index = index } }, loc);
    }

    fn parseFieldAccess(self: *Parser, object: u32) anyerror!u32 {
        try self.expectMsg(.identifier, "field name");
        const field = self.previous.text;
        const loc = self.tree.loc(object);
        return self.add(.{ .field_access = .{ .object = object, .field = field } }, loc);
    }

    fn parseRange(self: *Parser, left: u32, kind: lexer.Tag) anyerror!u32 {
        const loc = self.tree.loc(left);
        var end: ?u32 = null;
        switch (self.current.tag) {
            .rbrace, .rparen, .rbracket, .semicolon, .newline, .eof, .comma => {},
            else => end = try self.parseExprPrec(Prec.range + 1),
        }
        return self.add(.{ .range_expr = .{ .start_node = left, .end_node = end, .inclusive = kind == .dotdot_eq } }, loc);
    }

    fn parseArrayLiteral(self: *Parser) anyerror!u32 {
        const loc = self.previous.loc; // the `[`
        var elems: std.ArrayListUnmanaged(u32) = .empty;
        defer elems.deinit(self.allocator);
        self.skipNewlines();
        if (!self.check(.rbracket)) {
            while (true) {
                self.skipNewlines();
                try elems.append(self.allocator, try self.parseExpression());
                self.skipNewlines();
                if (!self.match(.comma)) break;
                if (self.check(.rbracket)) break; // trailing comma
            }
        }
        try self.expect(.rbracket);
        const list = try self.tree.addExtra(elems.items);
        return self.add(.{ .array_literal = list }, loc);
    }

    fn parseStructLiteral(self: *Parser, name: []const u8, loc: lexer.Loc) anyerror!u32 {
        try self.expectMsg(.lbrace, "'{'");
        self.skipNewlines();
        var fields: std.ArrayListUnmanaged(u32) = .empty;
        defer fields.deinit(self.allocator);
        while (!self.check(.rbrace) and !self.check(.eof)) {
            try self.expectMsg(.identifier, "field name");
            const fname = self.previous.text;
            try self.expect(.colon);
            const saved = self.no_struct_lit;
            self.no_struct_lit = false;
            const value = try self.parseExpression();
            self.no_struct_lit = saved;
            try fields.append(self.allocator, try self.add(.{ .struct_init_field = .{ .name = fname, .value = value } }, self.previous.loc));
            self.skipNewlines();
            if (!self.match(.comma)) break;
            self.skipNewlines();
        }
        try self.expect(.rbrace);
        const list = try self.tree.addExtra(fields.items);
        return self.add(.{ .struct_literal = .{ .name = name, .fields = list } }, loc);
    }

    // ── Patterns ──────────────────────────────────────────────────

    fn parsePattern(self: *Parser) anyerror!u32 {
        // Guarded entry (PARSER_MAX_DEPTH): parsePattern and
        // parsePatternPrimary call each other through builtin-variant
        // payloads (`some(some(...))`) — a cycle the expression guard never
        // sees (audit §2.3, seed parse_pattern does the same).
        if (!self.enter()) return error.ParseError;
        defer self.leave();
        const first = try self.parsePatternPrimary();
        if (!self.check(.pipe)) return first;

        var alts: std.ArrayListUnmanaged(u32) = .empty;
        defer alts.deinit(self.allocator);
        try alts.append(self.allocator, first);
        while (self.match(.pipe)) {
            try alts.append(self.allocator, try self.parsePatternPrimary());
        }
        const list = try self.tree.addExtra(alts.items);
        return self.add(.{ .pattern_or = list }, self.tree.loc(first));
    }

    fn parsePatternPrimary(self: *Parser) anyerror!u32 {
        switch (self.current.tag) {
            .underscore => {
                const loc = self.current.loc;
                self.advance();
                return self.add(.{ .pattern_wildcard = {} }, loc);
            },
            .int_literal => {
                const tok = self.current;
                self.advance();
                return self.add(.{ .int_literal = tok.int_val }, tok.loc);
            },
            .float_literal => {
                const tok = self.current;
                self.advance();
                return self.add(.{ .float_literal = tok.float_val }, tok.loc);
            },
            .string_literal => {
                const tok = self.current;
                self.advance();
                return self.add(.{ .string_literal = tok.text }, tok.loc);
            },
            .kw_true, .kw_false => {
                const tok = self.current;
                self.advance();
                return self.add(.{ .bool_literal = tok.tag == .kw_true }, tok.loc);
            },
            .minus => {
                const tok = self.current;
                self.advance();
                if (self.current.tag != .int_literal and self.current.tag != .float_literal) {
                    return self.fail("expected a numeric literal after '-' in pattern");
                }
                const operand = try self.parseExprPrec(Prec.unary);
                return self.add(.{ .unary_expr = .{ .op = tok.tag, .operand = operand } }, tok.loc);
            },
            .kw_ok, .kw_err, .kw_some => {
                const tok = self.current;
                const kind: ast.BuiltinKind = switch (tok.tag) {
                    .kw_ok => .ok,
                    .kw_err => .err,
                    else => .some,
                };
                self.advance();
                var payload: ?u32 = null;
                if (self.match(.lparen)) {
                    payload = try self.parsePattern();
                    try self.expectMsg(.rparen, "')' after pattern");
                }
                return self.add(.{ .pattern_builtin_variant = .{ .kind = kind, .payload = payload } }, tok.loc);
            },
            .kw_none => {
                const tok = self.current;
                self.advance();
                return self.add(.{ .pattern_builtin_variant = .{ .kind = .none, .payload = null } }, tok.loc);
            },
            .identifier => {
                const tok = self.current;
                self.advance();
                if (self.match(.dot)) {
                    try self.expectMsg(.identifier, "variant name");
                    const variant_name = self.previous.text;
                    const obj = try self.add(.{ .identifier = tok.text }, tok.loc);
                    const variant = try self.add(.{ .field_access = .{ .object = obj, .field = variant_name } }, tok.loc);
                    if (self.match(.lparen)) {
                        var bindings: std.ArrayListUnmanaged(u32) = .empty;
                        defer bindings.deinit(self.allocator);
                        self.skipNewlines();
                        if (!self.check(.rparen)) {
                            while (true) {
                                try self.expectMsg(.identifier, "binding name");
                                const bname = self.previous.text;
                                try bindings.append(self.allocator, try self.add(.{ .pattern_bind = bname }, self.previous.loc));
                                if (!self.match(.comma)) break;
                                self.skipNewlines();
                            }
                        }
                        try self.expectMsg(.rparen, "')' after variant bindings");
                        const list = try self.tree.addExtra(bindings.items);
                        return self.add(.{ .pattern_variant_bind = .{ .variant = variant, .bindings = list } }, tok.loc);
                    }
                    return variant;
                }
                return self.add(.{ .pattern_bind = tok.text }, tok.loc);
            },
            else => return self.fail("expected a pattern ('_', literal or Enum.Variant)"),
        }
    }
};

/// A block's trailing expression is a value-producing node; declarations,
/// returns and jumps close the block without a value. Value-less loops
/// (`while`, `for`) belong to that same group: promoting one to a tail made
/// `fn main() { while false { print(1) } }` (closing braces on one line)
/// demand a value the emitter never computes — "stack imbalance in … block".
/// Audit §7.1, mirrored from seed/src/parser.c.
fn isTailCandidate(node: ast.Node) bool {
    return switch (node) {
        .fn_decl, .struct_decl, .enum_decl, .const_decl, .var_decl, .return_stmt, .break_stmt, .continue_stmt, .while_expr, .for_expr => false,
        else => true,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

const Parsed = struct { tree: ast.Tree, root: u32 };

fn parseSource(alloc: std.mem.Allocator, source: []const u8) !Parsed {
    var tree = ast.Tree.init(alloc, source);
    var p = Parser.init(alloc, source, &tree);
    const root = p.parse() catch |e| {
        std.debug.print("source failed to parse:\n{s}\n", .{source});
        return e;
    };
    try testing.expectEqual(ast.Tag.source_file, std.meta.activeTag(tree.node(root)));
    return .{ .tree = tree, .root = root };
}

/// First top-level declaration of a parsed module.
fn firstDecl(p: Parsed) ast.Node {
    const items = p.tree.extraSlice(p.tree.node(p.root).source_file);
    return p.tree.node(items[0]);
}

test "parses a function with params and return" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parsed = try parseSource(arena.allocator(),
        \\fn add(a: i32, b: i32) -> i32 {
        \\    return a + b;
        \\}
    );
    defer parsed.tree.deinit();
    const f = firstDecl(parsed).fn_decl;
    try testing.expectEqualStrings("add", f.name);
    // Regression: params used to be skipped entirely (`// TODO: parse params`).
    try testing.expectEqual(@as(u32, 2), f.params.len);
}

test "newline terminates a statement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parsed = try parseSource(arena.allocator(),
        \\fn main() {
        \\    let inc = |x: i32| -> i32 { x + 1 }
        \\    print(inc)
        \\}
    );
    defer parsed.tree.deinit();
    const main = firstDecl(parsed).fn_decl;
    const body = parsed.tree.node(main.body).block;
    // `let inc = ...` is a statement; `print(inc)` is the block's tail value.
    try testing.expectEqual(@as(u32, 1), body.stmts.len);
    try testing.expect(body.tail != null);
}

test "if expression keeps both branches" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parsed = try parseSource(arena.allocator(),
        \\fn main() {
        \\    let y = if x > 5 { 10 } else { 20 };
        \\}
    );
    defer parsed.tree.deinit();
    const main = firstDecl(parsed).fn_decl;
    const body = parsed.tree.node(main.body).block;
    const decl = parsed.tree.node(parsed.tree.extraSlice(body.stmts)[0]).var_decl;
    const ifn = parsed.tree.node(decl.value.?).if_expr;
    try testing.expect(ifn.else_block != null);
    try testing.expectEqual(ast.Tag.block, std.meta.activeTag(parsed.tree.node(ifn.then_block)));
}

test "block tail expression vs statement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parsed = try parseSource(arena.allocator(),
        \\fn main() {
        \\    let a = { 1 + 2 };
        \\    let b = { let t = 3; t * 4 };
        \\}
    );
    defer parsed.tree.deinit();
    const main = firstDecl(parsed).fn_decl;
    const body = parsed.tree.node(main.body).block;
    const a_block = parsed.tree.node(parsed.tree.node(parsed.tree.extraSlice(body.stmts)[0]).var_decl.value.?).block;
    try testing.expect(a_block.tail != null); // `{ 1 + 2 }` is an i32
    const b_block = parsed.tree.node(parsed.tree.node(parsed.tree.extraSlice(body.stmts)[1]).var_decl.value.?).block;
    try testing.expectEqual(@as(u32, 1), b_block.stmts.len);
    try testing.expect(b_block.tail != null);
}

test "enum with data variants and match patterns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parsed = try parseSource(arena.allocator(),
        \\enum Color {
        \\    Rgb(i32, i32, i32)
        \\    Named(string)
        \\}
        \\fn main() {
        \\    let c = Rgb(10, 20, 30);
        \\    match c {
        \\        Color.Rgb(r, g, b) => { print(r); },
        \\        Color.Named(name) => { print(name); },
        \\    }
        \\}
    );
    defer parsed.tree.deinit();
    const e = firstDecl(parsed).enum_decl;
    try testing.expectEqual(@as(u32, 2), e.variants.len);
    const v0 = parsed.tree.node(parsed.tree.extraSlice(e.variants)[0]).enum_variant;
    try testing.expect(v0.payload != null);
}

test "pub is recorded on exportable declarations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\pub fn helper() -> i32 { 1 }
        \\pub struct Point { x: i32 }
        \\pub enum Shape { Circle }
        \\pub const LIMIT = 5
        \\fn main() { print(LIMIT) }
    ;
    var tree = ast.Tree.init(arena.allocator(), src);
    var p = Parser.init(arena.allocator(), src, &tree);
    defer tree.deinit();
    const root = try p.parse();
    const items = tree.extraSlice(tree.node(root).source_file);
    try testing.expect(tree.node(items[0]).fn_decl.is_pub);
    try testing.expect(tree.node(items[1]).struct_decl.is_pub);
    try testing.expect(tree.node(items[2]).enum_decl.is_pub);
    try testing.expect(tree.node(items[3]).const_decl.is_pub);
    try testing.expect(!tree.node(items[4]).fn_decl.is_pub);
}

test "pub before let/var is rejected" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\pub let x = 1
        \\fn main() { print(x) }
    ;
    var tree = ast.Tree.init(arena.allocator(), src);
    var p = Parser.init(arena.allocator(), src, &tree);
    defer tree.deinit();
    try testing.expectError(error.ParseError, p.parse());
    try testing.expect(p.had_error);
}

test "nested blocks are depth guarded" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    for (0..300) |_| try buf.appendSlice(arena.allocator(), "(");
    try buf.appendSlice(arena.allocator(), "1");
    for (0..300) |_| try buf.appendSlice(arena.allocator(), ")");
    const src = buf.items;

    var tree = ast.Tree.init(arena.allocator(), src);
    var p = Parser.init(arena.allocator(), src, &tree);
    defer tree.deinit();
    try testing.expectError(error.ParseError, p.parse());
    try testing.expect(p.had_error);
}

test "recovers after a bad declaration and reports the rest" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\fn main() {
        \\    print(1)
        \\}
        \\let x = ;
        \\let y = ;
    ;
    var tree = ast.Tree.init(arena.allocator(), src);
    var p = Parser.init(arena.allocator(), src, &tree);
    defer tree.deinit();
    try testing.expectError(error.ParseError, p.parse());
    // Statement-level recovery: both bad declarations are reported, not just
    // the first (the seed's `synchronize` behaviour).
    try testing.expectEqual(@as(usize, 2), p.error_count);
}

test "a stray top-level semicolon recovers instead of spinning" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src =
        \\fn main() {
        \\    print(1)
        \\}
        \\;
        \\fn other() {
        \\    print(2)
        \\}
    ;
    var tree = ast.Tree.init(arena.allocator(), src);
    var p = Parser.init(arena.allocator(), src, &tree);
    defer tree.deinit();
    try testing.expectError(error.ParseError, p.parse());
    try testing.expectEqual(@as(usize, 1), p.error_count);
}

test "use takes a dot-separated module path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parsed = try parseSource(arena.allocator(),
        \\use std.io
        \\use a.b.c
        \\let x = 1
    );
    defer parsed.tree.deinit();
    const items = parsed.tree.extraSlice(parsed.tree.node(parsed.root).source_file);
    try testing.expectEqual(@as(u32, 3), items.len);
    try testing.expectEqualStrings("std.io", parsed.tree.node(items[0]).use_decl);
    try testing.expectEqualStrings("a.b.c", parsed.tree.node(items[1]).use_decl);
    try testing.expectEqual(ast.Tag.var_decl, std.meta.activeTag(parsed.tree.node(items[2])));
}

test "import keeps its alias" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parsed = try parseSource(arena.allocator(),
        \\import geometry.mesh as gm
        \\let x = 1
    );
    defer parsed.tree.deinit();
    const items = parsed.tree.extraSlice(parsed.tree.node(parsed.root).source_file);
    const imp = parsed.tree.node(items[0]).import_decl;
    try testing.expectEqualStrings("geometry.mesh", imp.path);
    try testing.expectEqualStrings("gm", imp.alias.?);
}

test "from ... import keeps every item and per-item alias" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parsed = try parseSource(arena.allocator(),
        \\from geometry.vector import Vec2, add as plus
        \\let x = 1
    );
    defer parsed.tree.deinit();
    const items = parsed.tree.extraSlice(parsed.tree.node(parsed.root).source_file);
    const f = parsed.tree.node(items[0]).from_decl;
    try testing.expectEqualStrings("geometry.vector", f.path);
    try testing.expectEqual(@as(u32, 2), f.items.len);
    const list = parsed.tree.extraSlice(f.items);
    const first = parsed.tree.node(list[0]).import_item;
    try testing.expectEqualStrings("Vec2", first.name);
    try testing.expect(first.alias == null);
    const second = parsed.tree.node(list[1]).import_item;
    try testing.expectEqualStrings("add", second.name);
    try testing.expectEqualStrings("plus", second.alias.?);
}

// Phase 2.2 adopted the dot form the construct grammar already declared
// (research/010 §12.1) and fixed the seed, which had drifted to matching `::`.
// This pins the decision on the Zig side too.
test "`::` is not a module path separator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "use std::io\n";
    var tree = ast.Tree.init(arena.allocator(), src);
    var p = Parser.init(arena.allocator(), src, &tree);
    defer tree.deinit();
    try testing.expectError(error.ParseError, p.parse());
}

// ARCHITECTURE §10.4 rules 3-4: `@/` anchors at the directory containing
// astra.toml, `/` and `.` are equivalent segment separators, and the path is
// kept exactly as written (the seed stores the same source slice, so
// --dump-ast agrees byte for byte).
test "module paths accept the @/ root prefix and slash separators" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var parsed = try parseSource(arena.allocator(),
        \\import @/utils/logger
        \\from @/pkg.tools import thing
        \\use shared/extra
        \\let x = 1
    );
    defer parsed.tree.deinit();
    const items = parsed.tree.extraSlice(parsed.tree.node(parsed.root).source_file);
    try testing.expectEqual(@as(u32, 4), items.len);
    const imp = parsed.tree.node(items[0]).import_decl;
    try testing.expectEqualStrings("@/utils/logger", imp.path);
    const f = parsed.tree.node(items[1]).from_decl;
    try testing.expectEqualStrings("@/pkg.tools", f.path);
    try testing.expectEqualStrings("shared/extra", parsed.tree.node(items[2]).use_decl);
}

test "`@` root prefix requires a following `/`" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const src = "import @utils\n";
    var tree = ast.Tree.init(arena.allocator(), src);
    var p = Parser.init(arena.allocator(), src, &tree);
    defer tree.deinit();
    try testing.expectError(error.ParseError, p.parse());
}
