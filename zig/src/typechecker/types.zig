//! Canonical (hash-consed) Astra types.
//!
//! Every type value is interned: structurally identical types share one
//! allocation, so the checker holds one canonical `*Type` per distinct type
//! instead of one heap node per occurrence. That identity is the substrate
//! the Phase 2 generics/monomorphization work keys on
//! (`PHASE2_ARCHITECTURE.md` §3.3); replacing `*Type` with TypeIds later is
//! a mechanical step once nothing but the pool constructs types.
//!
//! Equality is not plain pointer identity, though: the seed's `type_eq`
//! unification rules (`unknown` ~ anything, `nil` ~ any optional,
//! `int_literal` ~ any integer) still recurse into composites, because
//! `[1]` : `array(int_literal)` must equal `[]i32` : `array(i32)`. Interning
//! gives the O(1) fast path for the common identical case; `typeEq` keeps the
//! rules. When literals are resolved at their construction site instead of
//! at comparison time (a future inference step), the recursion collapses to
//! the pointer compare and the special cases can retire.
//!
//! Struct and enum identity is their *name* (the seed compares `a.name` /
//! `b.name` and ignores layout), so the pool keys them by name alone. A
//! re-declaration of the same name aliases the existing entry and overwrites
//! its layout — the seed accepts duplicates too, and later lookups win with
//! the last declaration.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum {
    void,
    bool_,
    int, // i32
    int64,
    uint32,
    uint64,
    int_literal, // polymorphic integer literal (no width yet)
    float, // f64
    string,
    optional,
    array,
    fn_type,
    struct_,
    enum_,
    nil,
    /// One `<T>` placeholder of the generic fn being checked (Phase 2.4 step
    /// 2a); interned per (name, owner declaration).
    param,
    unknown,
    error_,

    pub fn name(self: Kind) []const u8 {
        return switch (self) {
            .void => "void",
            .bool_ => "bool",
            .int => "i32",
            .int_literal => "integer literal",
            .int64 => "i64",
            .uint32 => "u32",
            .uint64 => "u64",
            .float => "f64",
            .string => "string",
            .optional => "optional",
            .array => "array",
            .fn_type => "fn",
            .struct_ => "struct",
            .enum_ => "enum",
            .nil => "nil",
            .param => "type parameter",
            .unknown => "unknown",
            .error_ => "<error>",
        };
    }
};

pub const Field = struct { name: []const u8, type_: *Type };

/// Compile-time payload layout of one data-carrying variant, parallel to
/// `variants`. Unnamed fields keep an empty name.
pub const VariantLayout = struct {
    names: []const []const u8 = &.{},
    types: []const *Type = &.{},
    field_count: usize = 0,
};

pub const Type = struct {
    kind: Kind,
    inner: ?*Type = null, // optional
    elem: ?*Type = null, // array
    params: []const *Type = &.{}, // fn
    ret: ?*Type = null, // fn (normalized to void at interning, never null in practice)
    name: []const u8 = "", // struct / enum / param
    fields: []const Field = &.{}, // struct
    variants: []const []const u8 = &.{}, // enum
    payloads: []const VariantLayout = &.{}, // enum
    /// The owning fn declaration node (param): two `<T>` placeholders are the
    /// same type only when they come from the same declaration.
    owner: ?u32 = null,
};

pub fn isInteger(t: *const Type) bool {
    return switch (t.kind) {
        .int, .int64, .uint32, .uint64, .int_literal => true,
        else => false,
    };
}

/// Port of the seed's `type_eq`. Interning makes the common case (same
/// canonical pointer) a single compare, but equality is *not* plain identity:
/// the unification rules still recurse into composites, because
/// `[1]` : `array(int_literal)` must equal `[]i32` : `array(i32)` — literals
/// are polymorphic at every depth (`COHERENCE_AUDIT.md` Hallazgo E).
pub fn typeEq(a: *const Type, b: *const Type) bool {
    if (a == b) return true;
    if (a.kind == .unknown or b.kind == .unknown) return true;
    if ((a.kind == .nil and b.kind == .optional) or (a.kind == .optional and b.kind == .nil)) return true;
    if (a.kind == .int_literal and b.kind != .int_literal) return isInteger(b);
    if (b.kind == .int_literal and a.kind != .int_literal) return isInteger(a);
    if (a.kind != b.kind) return false;
    return switch (a.kind) {
        .optional => typeEq(a.inner.?, b.inner.?),
        .array => typeEq(a.elem.?, b.elem.?),
        .fn_type => blk: {
            if (a.params.len != b.params.len) break :blk false;
            for (a.params, b.params) |pa, pb| {
                if (!typeEq(pa, pb)) break :blk false;
            }
            break :blk typeEq(a.ret.?, b.ret.?); // normalized to void at interning
        },
        // Same name is the same interned pointer (caught by the fast path);
        // different pointers mean different names. A param is interned per
        // (name, owner), so pointer identity is full identity too.
        .struct_, .enum_, .param => false,
        else => true,
    };
}

/// Hash-consing table for `Type`. Individual types are freed by `deinit`
/// (a no-op under the arena the checker uses in production).
pub const TypePool = struct {
    const Self = @This();

    const Key = struct {
        kind: Kind,
        elem: ?*Type = null, // array
        inner: ?*Type = null, // optional
        params: []const *Type = &.{}, // fn
        ret: ?*Type = null, // fn
        name: []const u8 = "", // struct / enum / param
        owner: ?u32 = null, // param
    };

    const KeyContext = struct {
        pub fn hash(_: KeyContext, k: Key) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&@intFromEnum(k.kind)));
            if (k.elem) |p| h.update(std.mem.asBytes(&@intFromPtr(p)));
            if (k.inner) |p| h.update(std.mem.asBytes(&@intFromPtr(p)));
            if (k.ret) |p| h.update(std.mem.asBytes(&@intFromPtr(p)));
            for (k.params) |p| h.update(std.mem.asBytes(&@intFromPtr(p)));
            h.update(k.name);
            if (k.owner) |o| h.update(std.mem.asBytes(&o));
            return h.final();
        }

        pub fn eql(_: KeyContext, a: Key, b: Key) bool {
            if (a.kind != b.kind) return false;
            // Struct/enum identity is the name alone (seed `type_eq`); a
            // param adds its owner declaration.
            switch (a.kind) {
                .struct_, .enum_ => return std.mem.eql(u8, a.name, b.name),
                .param => return a.owner == b.owner and std.mem.eql(u8, a.name, b.name),
                else => {},
            }
            if (a.elem != b.elem or a.inner != b.inner or a.ret != b.ret) return false;
            if (a.params.len != b.params.len) return false;
            for (a.params, b.params) |pa, pb| {
                if (pa != pb) return false;
            }
            return true;
        }
    };

    a: Allocator,
    map: std.HashMap(Key, *Type, KeyContext, std.hash_map.default_max_load_percentage),
    /// Every type this pool handed out, so `deinit` can free them when the
    /// backing allocator is not an arena.
    allocated: std.ArrayListUnmanaged(*Type) = .empty,
    /// Canonical `void`, used to normalize function types without a return
    /// annotation (`ret == null` was equal to `ret == void` in the seed).
    void_t: *Type,

    pub fn init(a: Allocator) !Self {
        var self = Self{
            .a = a,
            .map = std.HashMap(Key, *Type, KeyContext, std.hash_map.default_max_load_percentage).init(a),
            .void_t = undefined,
        };
        self.void_t = try self.primitive(.void);
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.allocated.items) |t| self.a.destroy(t);
        self.allocated.deinit(self.a);
        self.map.deinit();
    }

    pub fn primitive(self: *Self, kind: Kind) !*Type {
        return self.intern(.{ .kind = kind });
    }

    pub fn optional(self: *Self, inner: *Type) !*Type {
        return self.intern(.{ .kind = .optional, .inner = inner });
    }

    pub fn array(self: *Self, elem: *Type) !*Type {
        return self.intern(.{ .kind = .array, .elem = elem });
    }

    /// Canonical function type. A missing return annotation (`ret == null`)
    /// is normalized to `void`: the seed treats the two as equal
    /// (`a.ret orelse voidType`), so interning them as distinct keys would
    /// have changed behaviour.
    pub fn fnType(self: *Self, params: []const *Type, ret: ?*Type) !*Type {
        return self.intern(.{ .kind = .fn_type, .params = params, .ret = ret orelse self.void_t });
    }

    /// Canonical struct type keyed by name only. The caller fills in
    /// `fields` afterwards; a re-declaration of the same name aliases this
    /// entry and overwrites the layout (see the file header).
    pub fn structType(self: *Self, name: []const u8) !*Type {
        return self.intern(.{ .kind = .struct_, .name = name });
    }

    /// Canonical enum type keyed by name only; same aliasing rule as structs.
    pub fn enumType(self: *Self, name: []const u8) !*Type {
        return self.intern(.{ .kind = .enum_, .name = name });
    }

    /// One `<T>` placeholder, interned per (name, owner declaration node).
    pub fn paramType(self: *Self, name: []const u8, owner: u32) !*Type {
        return self.intern(.{ .kind = .param, .name = name, .owner = owner });
    }

    fn intern(self: *Self, key: Key) !*Type {
        const gop = try self.map.getOrPut(key);
        if (gop.found_existing) return gop.value_ptr.*;
        const t = try self.a.create(Type);
        t.* = .{
            .kind = key.kind,
            .elem = key.elem,
            .inner = key.inner,
            .params = key.params,
            .ret = key.ret,
            .name = key.name,
            .owner = key.owner,
        };
        try self.allocated.append(self.a, t);
        gop.value_ptr.* = t;
        return t;
    }
};

const testing = std.testing;

test "intern dedups primitives and composites" {
    var pool = try TypePool.init(testing.allocator);
    defer pool.deinit();
    const i32t = try pool.primitive(.int);
    try testing.expect(i32t == try pool.primitive(.int));
    const o1 = try pool.optional(i32t);
    const o2 = try pool.optional(i32t);
    try testing.expect(o1 == o2);
    const f64t = try pool.primitive(.float);
    try testing.expect(o1 != try pool.optional(f64t));
    const arr = try pool.array(i32t);
    try testing.expect(arr == try pool.array(i32t));
    try testing.expect(arr != o1);
}

test "fn types dedup and normalize a missing return to void" {
    var pool = try TypePool.init(testing.allocator);
    defer pool.deinit();
    const i32t = try pool.primitive(.int);
    var params = [_]*Type{i32t};
    const p = params[0..];
    const f_null = try pool.fnType(p, null);
    const f_void = try pool.fnType(p, pool.void_t);
    try testing.expect(f_null == f_void);
    const f_ret = try pool.fnType(p, i32t);
    try testing.expect(f_ret != f_null);
    const empty = try pool.fnType(&.{}, null);
    try testing.expect(empty != f_null);
}

test "struct and enum identity is the name" {
    var pool = try TypePool.init(testing.allocator);
    defer pool.deinit();
    const a = try pool.structType("Point");
    const b = try pool.structType("Point");
    try testing.expect(a == b);
    a.fields = &.{ .{ .name = "x", .type_ = try pool.primitive(.int) } };
    try testing.expect(b.fields.len == 1); // aliased, not a second copy
    const c = try pool.structType("Other");
    try testing.expect(a != c);
    const e = try pool.enumType("Point"); // same name, different kind
    try testing.expect(e != a);
}

test "typeEq keeps the seed unification rules" {
    var pool = try TypePool.init(testing.allocator);
    defer pool.deinit();
    const i32t = try pool.primitive(.int);
    const unknown = try pool.primitive(.unknown);
    const nil = try pool.primitive(.nil);
    const lit = try pool.primitive(.int_literal);
    const str = try pool.primitive(.string);
    const opt = try pool.optional(i32t);
    try testing.expect(typeEq(unknown, str));
    try testing.expect(typeEq(nil, opt));
    try testing.expect(typeEq(lit, i32t));
    try testing.expect(!typeEq(lit, str));
    try testing.expect(typeEq(i32t, i32t));
    try testing.expect(!typeEq(i32t, str));
    try testing.expect(typeEq(try pool.array(i32t), try pool.array(i32t)));
    try testing.expect(!typeEq(try pool.array(i32t), try pool.array(str)));
    // Literals unify inside composites, not just at the top level:
    // `[1]` : array(int_literal) must equal `[]i32` : array(i32).
    try testing.expect(typeEq(try pool.array(lit), try pool.array(i32t)));
    try testing.expect(!typeEq(try pool.array(lit), try pool.array(str)));
    // fn with null ret was equal to fn with void ret under the seed.
    const f_null = try pool.fnType(&.{i32t}, null);
    const f_void = try pool.fnType(&.{i32t}, pool.void_t);
    try testing.expect(typeEq(f_null, f_void));
}
