const std = @import("std");
pub fn main() void {
    const alloc = std.heap.smp_allocator;
    var s: []const u8 = "";
    var i: i32 = 0;
    while (i < 25000) : (i += 1) {
        const ns = alloc.alloc(u8, s.len + 1) catch return;
        @memcpy(ns[0..s.len], s);
        ns[s.len] = 'x';
        if (s.len > 0) alloc.free(s);
        s = ns;
    }
    std.debug.print("{s}\n", .{s});
    if (s.len > 0) alloc.free(@constCast(s));
}
