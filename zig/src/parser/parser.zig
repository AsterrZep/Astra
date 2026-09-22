const std = @import("std");
const lexer = @import("../lexer/lexer.zig");
const ast = @import("../ast/ast.zig");

pub const Parser = struct {
    tokenizer: lexer.Tokenizer,
    tree: *ast.Tree,
    current: lexer.Token,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8, tree: *ast.Tree) Parser {
        var tok = lexer.Tokenizer.init(source);
        const first = tok.next();
        return .{
            .tokenizer = tok,
            .tree = tree,
            .current = first,
            .allocator = allocator,
        };
    }

    pub fn parse(self: *Parser) !u32 {
        return self.parseSourceFile();
    }

    fn parseSourceFile(self: *Parser) !u32 {
        var decls: std.ArrayListUnmanaged(u32) = .empty;
        defer decls.deinit(self.allocator);

        while (self.current.tag != .eof) {
            const decl = try self.parseTopLevelDecl();
            try decls.append(self.allocator, decl);
        }

        return try self.tree.addNode(.source_file, .{ .node_list = .{
            .start = 0,
            .len = @intCast(decls.items.len),
        } });
    }

    fn parseTopLevelDecl(self: *Parser) !u32 {
        return switch (self.current.tag) {
            .kw_fn => self.parseFnDecl(),
            .kw_struct => self.parseStructDecl(),
            .kw_enum => self.parseEnumDecl(),
            .kw_let => self.parseLetStmt(),
            else => {
                const expr = try self.parseExpression();
                _ = try self.expect(.semicolon);
                return try self.tree.addNode(.expr_stmt, .{ .simple = expr });
            },
        };
    }

    fn parseFnDecl(self: *Parser) !u32 {
        _ = try self.expect(.kw_fn);
        _ = try self.expect(.identifier);
        _ = try self.expect(.lparen);
        // TODO: parse params
        _ = try self.expect(.rparen);

        if (self.current.tag == .arrow) {
            _ = try self.expect(.arrow);
            _ = try self.parseType();
        }

        const body = try self.parseBlock();

        return try self.tree.addNode(.fn_decl, .{ .simple = body });
    }

    fn parseStructDecl(self: *Parser) !u32 {
        _ = try self.expect(.kw_struct);
        _ = try self.expect(.identifier);
        _ = try self.expect(.lbrace);

        var fields: std.ArrayListUnmanaged(u32) = .empty;
        defer fields.deinit(self.allocator);

        while (self.current.tag != .rbrace and self.current.tag != .eof) {
            const field = try self.parseFieldDecl();
            try fields.append(self.allocator, field);
        }

        _ = try self.expect(.rbrace);

        return try self.tree.addNode(.struct_decl, .{ .node_list = .{
            .start = 0,
            .len = @intCast(fields.items.len),
        } });
    }

    fn parseFieldDecl(self: *Parser) !u32 {
        _ = try self.expect(.identifier);
        _ = try self.expect(.colon);
        const type_node = try self.parseType();
        return try self.tree.addNode(.field_decl, .{ .simple = type_node });
    }

    fn parseEnumDecl(self: *Parser) !u32 {
        _ = try self.expect(.kw_enum);
        _ = try self.expect(.identifier);
        _ = try self.expect(.lbrace);

        var variants: std.ArrayListUnmanaged(u32) = .empty;
        defer variants.deinit(self.allocator);

        while (self.current.tag != .rbrace and self.current.tag != .eof) {
            const variant = try self.parseEnumVariant();
            try variants.append(self.allocator, variant);
        }

        _ = try self.expect(.rbrace);

        return try self.tree.addNode(.enum_decl, .{ .node_list = .{
            .start = 0,
            .len = @intCast(variants.items.len),
        } });
    }

    fn parseEnumVariant(self: *Parser) !u32 {
        const name_start = self.current.loc.start;
        _ = try self.expect(.identifier);

        if (self.current.tag == .lparen) {
            _ = try self.expect(.lparen);
            while (self.current.tag != .rparen) {
                _ = try self.parseType();
                if (self.current.tag == .comma) {
                    _ = try self.expect(.comma);
                }
            }
            _ = try self.expect(.rparen);
        }

        if (self.current.tag == .comma) {
            _ = try self.expect(.comma);
        }

        return try self.tree.addNode(.enum_variant, .{ .literal = .{
            .start = name_start,
            .len = self.current.loc.start - name_start,
        } });
    }

    fn parseLetStmt(self: *Parser) !u32 {
        _ = try self.expect(.kw_let);
        if (self.current.tag == .kw_mut) {
            _ = try self.expect(.kw_mut);
        }
        _ = try self.expect(.identifier);

        if (self.current.tag == .colon) {
            _ = try self.expect(.colon);
            _ = try self.parseType();
        }

        _ = try self.expect(.eq);
        const init_expr = try self.parseExpression();
        _ = try self.expect(.semicolon);

        return try self.tree.addNode(.let_stmt, .{ .simple = init_expr });
    }

    fn parseBlock(self: *Parser) !u32 {
        _ = try self.expect(.lbrace);
        var stmts: std.ArrayListUnmanaged(u32) = .empty;
        defer stmts.deinit(self.allocator);

        while (self.current.tag != .rbrace and self.current.tag != .eof) {
            const stmt = try self.parseStatement();
            try stmts.append(self.allocator, stmt);
        }

        _ = try self.expect(.rbrace);

        return try self.tree.addNode(.block, .{ .node_list = .{
            .start = 0,
            .len = @intCast(stmts.items.len),
        } });
    }

    fn parseStatement(self: *Parser) !u32 {
        return switch (self.current.tag) {
            .kw_let => self.parseLetStmt(),
            .kw_return => {
                _ = try self.expect(.kw_return);
                const expr = try self.parseExpression();
                _ = try self.expect(.semicolon);
                return try self.tree.addNode(.return_stmt, .{ .simple = expr });
            },
            .kw_break => {
                _ = try self.expect(.kw_break);
                _ = try self.expect(.semicolon);
                return try self.tree.addNode(.break_stmt, .{ .simple = 0 });
            },
            .kw_continue => {
                _ = try self.expect(.kw_continue);
                _ = try self.expect(.semicolon);
                return try self.tree.addNode(.continue_stmt, .{ .simple = 0 });
            },
            else => {
                const expr = try self.parseExpression();
                _ = try self.expect(.semicolon);
                return try self.tree.addNode(.expr_stmt, .{ .simple = expr });
            },
        };
    }

    fn parseExpression(self: *Parser) anyerror!u32 {
        return self.parseBinaryExpr(0);
    }

    fn parseBinaryExpr(self: *Parser, min_prec: u32) anyerror!u32 {
        var left = try self.parseUnaryExpr();

        while (self.isBinaryOp() and self.getPrecedence() >= min_prec) {
            const op = self.current.tag;
            _ = try self.advance();
            const right = try self.parseBinaryExpr(self.getPrecedence() + 1);
            left = try self.tree.addNode(.binary_expr, .{ .binop = .{
                .op = op,
                .left = left,
                .right = right,
            } });
        }

        return left;
    }

    fn parseUnaryExpr(self: *Parser) anyerror!u32 {
        if (self.current.tag == .minus or self.current.tag == .bang or self.current.tag == .tilde) {
            const op = self.current.tag;
            _ = try self.advance();
            const operand = try self.parseUnaryExpr();
            return try self.tree.addNode(.unary_expr, .{ .unary = .{
                .op = op,
                .operand = operand,
            } });
        }
        return self.parsePrimaryExpr();
    }

    fn parsePrimaryExpr(self: *Parser) anyerror!u32 {
        return switch (self.current.tag) {
            .int_literal, .float_literal => {
                const tok = self.current;
                _ = try self.advance();
                return try self.tree.addNode(if (tok.tag == .int_literal) .int_literal else .float_literal, .{ .literal = .{
                    .start = tok.loc.start,
                    .len = tok.loc.end - tok.loc.start,
                } });
            },
            .string_literal => {
                const tok = self.current;
                _ = try self.advance();
                return try self.tree.addNode(.string_literal, .{ .literal = .{
                    .start = tok.loc.start,
                    .len = tok.loc.end - tok.loc.start,
                } });
            },
            .true_literal, .false_literal => {
                const tok = self.current;
                _ = try self.advance();
                return try self.tree.addNode(.bool_literal, .{ .literal = .{
                    .start = tok.loc.start,
                    .len = tok.loc.end - tok.loc.start,
                } });
            },
            .nil_literal => {
                _ = try self.advance();
                return try self.tree.addNode(.nil_literal, .{ .simple = 0 });
            },
            .identifier => {
                const tok = self.current;
                _ = try self.advance();
                if (self.current.tag == .dot) {
                    _ = try self.advance();
                    _ = try self.expect(.identifier);
                    return try self.tree.addNode(.qualified_type, .{ .literal = .{
                        .start = tok.loc.start,
                        .len = self.current.loc.start - tok.loc.start,
                    } });
                }
                return try self.tree.addNode(.identifier, .{ .literal = .{
                    .start = tok.loc.start,
                    .len = tok.loc.end - tok.loc.start,
                } });
            },
            .lparen => {
                _ = try self.advance();
                // Parse expression inside parens without recursion
                var expr: u32 = 0;
                if (self.current.tag != .rparen) {
                    // Inline primary expression parsing
                    expr = switch (self.current.tag) {
                        .int_literal, .float_literal => blk: {
                            const tok = self.current;
                            _ = try self.advance();
                            break :blk try self.tree.addNode(if (tok.tag == .int_literal) .int_literal else .float_literal, .{ .literal = .{
                                .start = tok.loc.start,
                                .len = tok.loc.end - tok.loc.start,
                            } });
                        },
                        .string_literal => blk: {
                            const tok = self.current;
                            _ = try self.advance();
                            break :blk try self.tree.addNode(.string_literal, .{ .literal = .{
                                .start = tok.loc.start,
                                .len = tok.loc.end - tok.loc.start,
                            } });
                        },
                        .true_literal, .false_literal => blk: {
                            const tok = self.current;
                            _ = try self.advance();
                            break :blk try self.tree.addNode(.bool_literal, .{ .literal = .{
                                .start = tok.loc.start,
                                .len = tok.loc.end - tok.loc.start,
                            } });
                        },
                        .nil_literal => blk: {
                            _ = try self.advance();
                            break :blk try self.tree.addNode(.nil_literal, .{ .simple = 0 });
                        },
                        .identifier => blk: {
                            const tok = self.current;
                            _ = try self.advance();
                            break :blk try self.tree.addNode(.identifier, .{ .literal = .{
                                .start = tok.loc.start,
                                .len = tok.loc.end - tok.loc.start,
                            } });
                        },
                        else => return error.UnexpectedToken,
                    };
                    while (self.isBinaryOp()) {
                        const op = self.current.tag;
                        _ = try self.advance();
                        // Inline primary for right side
                        const right = switch (self.current.tag) {
                            .int_literal, .float_literal => blk: {
                                const tok = self.current;
                                _ = try self.advance();
                                break :blk try self.tree.addNode(if (tok.tag == .int_literal) .int_literal else .float_literal, .{ .literal = .{
                                    .start = tok.loc.start,
                                    .len = tok.loc.end - tok.loc.start,
                                } });
                            },
                            .identifier => blk: {
                                const tok = self.current;
                                _ = try self.advance();
                                break :blk try self.tree.addNode(.identifier, .{ .literal = .{
                                    .start = tok.loc.start,
                                    .len = tok.loc.end - tok.loc.start,
                                } });
                            },
                            else => return error.UnexpectedToken,
                        };
                        expr = try self.tree.addNode(.binary_expr, .{ .binop = .{
                            .op = op,
                            .left = expr,
                            .right = right,
                        } });
                    }
                }
                _ = try self.expect(.rparen);
                return expr;
            },
            .lbrace => self.parseBlock(),
            .kw_if => self.parseIfExpr(),
            .kw_while => self.parseWhileExpr(),
            .kw_for => self.parseForExpr(),
            .kw_match => @call(.auto, Parser.parseMatchExpr, .{self}),
            else => {
                return error.UnexpectedToken;
            },
        };
    }

    fn parseIfExpr(self: *Parser) !u32 {
        _ = try self.expect(.kw_if);
        const cond = try self.parseExpression();
        const then = try self.parseBlock();

        var else_node: u32 = 0;
        if (self.current.tag == .kw_else) {
            _ = try self.expect(.kw_else);
            if (self.current.tag == .kw_if) {
                else_node = try self.parseIfExpr();
            } else {
                else_node = try self.parseBlock();
            }
        }

        _ = then;
        return try self.tree.addNode(.if_expr, .{ .simple = cond });
    }

    fn parseWhileExpr(self: *Parser) !u32 {
        _ = try self.expect(.kw_while);
        const cond = try self.parseExpression();
        const body = try self.parseBlock();
        _ = body;
        return try self.tree.addNode(.while_expr, .{ .simple = cond });
    }

    fn parseForExpr(self: *Parser) !u32 {
        _ = try self.expect(.kw_for);
        _ = try self.expect(.identifier);
        _ = try self.expect(.kw_in);
        _ = try self.parseExpression();
        const body = try self.parseBlock();
        _ = body;
        return try self.tree.addNode(.for_expr, .{ .simple = 0 });
    }

    fn parseMatchExpr(self: *Parser) !u32 {
        _ = try self.expect(.kw_match);
        const expr = try self.parseExpression();
        _ = try self.expect(.lbrace);

        while (self.current.tag != .rbrace) {
            _ = try self.parseExpression();
            _ = try self.expect(.fat_arrow);
            _ = try self.parseExpression();
            if (self.current.tag == .comma) {
                _ = try self.expect(.comma);
            }
        }

        _ = try self.expect(.rbrace);
        return try self.tree.addNode(.match_expr, .{ .simple = expr });
    }

    fn parseType(self: *Parser) !u32 {
        const base = try self.expectTypeToken();

        if (self.current.tag == .lbracket) {
            _ = try self.expect(.lbracket);
            _ = try self.expect(.rbracket);
            return try self.tree.addNode(.type_array, .{ .simple = base });
        }
        if (self.current.tag == .question) {
            _ = try self.expect(.question);
            return try self.tree.addNode(.type_optional, .{ .simple = base });
        }

        return base;
    }

    fn expectTypeToken(self: *Parser) !u32 {
        return switch (self.current.tag) {
            .kw_i32, .kw_i64, .kw_u32, .kw_u64, .kw_f32, .kw_f64, .kw_bool, .kw_string, .kw_void => {
                const tok = self.current;
                _ = try self.advance();
                return try self.tree.addNode(.type_identifier, .{ .literal = .{
                    .start = tok.loc.start,
                    .len = tok.loc.end - tok.loc.start,
                } });
            },
            .identifier => {
                const tok = self.current;
                _ = try self.advance();
                return try self.tree.addNode(.type_identifier, .{ .literal = .{
                    .start = tok.loc.start,
                    .len = tok.loc.end - tok.loc.start,
                } });
            },
            else => error.UnexpectedToken,
        };
    }

    fn expect(self: *Parser, expected: lexer.Token.Tag) !u32 {
        if (self.current.tag != expected) {
            return error.UnexpectedToken;
        }
        const start = self.current.loc.start;
        _ = try self.advance();
        return start;
    }

    fn advance(self: *Parser) !lexer.Token.Tag {
        const prev = self.current.tag;
        self.current = self.tokenizer.next();
        return prev;
    }

    fn isBinaryOp(self: *Parser) bool {
        return switch (self.current.tag) {
            .plus, .minus, .star, .slash, .percent,
            .amp, .pipe, .caret, .lt_lt, .gt_gt,
            .lt, .gt, .lt_eq, .gt_eq, .eq_eq, .bang_eq,
            .amp_amp, .pipe_pipe, .dot_dot, .dot_dot_eq,
            => true,
            else => false,
        };
    }

    fn getPrecedence(self: *Parser) u32 {
        return switch (self.current.tag) {
            .pipe_pipe => 1,
            .amp_amp => 2,
            .pipe => 3,
            .caret => 4,
            .amp => 5,
            .eq_eq, .bang_eq => 6,
            .lt, .gt, .lt_eq, .gt_eq => 7,
            .lt_lt, .gt_gt => 8,
            .plus, .minus => 9,
            .star, .slash, .percent => 10,
            else => 0,
        };
    }
};

test "parser let statement" {
    const source = "let x = 42;";
    var tree = ast.Tree.init(std.testing.allocator, source);
    defer tree.deinit();

    var par = Parser.init(std.testing.allocator, source, &tree);
    const root = try par.parse();
    try std.testing.expect(root < tree.nodes.items.len);
    try std.testing.expectEqual(ast.Node.Tag.source_file, tree.nodes.items[root].tag);
}
