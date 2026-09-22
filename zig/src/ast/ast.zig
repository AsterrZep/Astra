const std = @import("std");
const lexer = @import("../lexer/lexer.zig");

pub const Node = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum(u16) {
        // Top-level
        source_file,
        fn_decl,
        struct_decl,
        enum_decl,
        trait_decl,
        impl_decl,
        import_decl,
        pub_decl,

        // Statements
        let_stmt,
        assign_stmt,
        return_stmt,
        break_stmt,
        continue_stmt,
        expr_stmt,
        block,

        // Expressions
        binary_expr,
        unary_expr,
        call_expr,
        field_access,
        index_access,
        if_expr,
        while_expr,
        for_expr,
        match_expr,
        lambda_expr,
        block_expr,

        // Literals
        int_literal,
        float_literal,
        string_literal,
        bool_literal,
        nil_literal,

        // Identifiers and types
        identifier,
        type_identifier,
        qualified_type, // e.g., Color.Red

        // Patterns
        match_arm,
        pattern_literal,
        pattern_binding,
        pattern_wildcard,
        pattern_or,

        // Function
        param,
        return_type,

        // Struct
        field_decl,
        struct_literal,
        struct_init_field,

        // Enum
        enum_variant,
        enum_variant_data,

        // Type annotations
        type_array,
        type_optional,
        type_fn,
        type_ptr,
    };

    pub const Data = union(enum) {
        simple: u32,
        binop: struct {
            op: lexer.Token.Tag,
            left: u32,
            right: u32,
        },
        unary: struct {
            op: lexer.Token.Tag,
            operand: u32,
        },
        call: struct {
            callee: u32,
            args_start: u32,
            args_len: u16,
        },
        literal: struct {
            start: u32,
            len: u32,
        },
        node_list: struct {
            start: u32,
            len: u32,
        },
    };
};

pub const Tree = struct {
    nodes: std.ArrayListUnmanaged(Node),
    source: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Tree {
        return .{
            .nodes = .empty,
            .source = source,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Tree) void {
        self.nodes.deinit(self.allocator);
    }

    pub fn addNode(self: *Tree, tag: Node.Tag, data: Node.Data) !u32 {
        const idx: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{ .tag = tag, .data = data });
        return idx;
    }

    pub fn getSourceText(self: Tree, loc: lexer.Token.Loc) []const u8 {
        return self.source[loc.start..loc.end];
    }
};

test "ast node creation" {
    var tree = Tree.init(std.testing.allocator, "let x = 42;");
    defer tree.deinit();

    const idx = try tree.addNode(.identifier, .{ .literal = .{ .start = 4, .len = 1 } });
    try std.testing.expectEqual(@as(u32, 0), idx);
    try std.testing.expectEqual(Node.Tag.identifier, tree.nodes.items[0].tag);
}
