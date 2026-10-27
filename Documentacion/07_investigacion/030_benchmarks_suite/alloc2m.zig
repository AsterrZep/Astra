const std = @import("std");
pub fn main() void {
    const alloc = std.heap.smp_allocator;
    var s: i64 = 0;
    var i: i64 = 0;
    while (i < 2000000) : (i += 1) {
        const a = alloc.alloc(i64, 8) catch return;
        for (0..8) |j| a[j] = @intCast(j + 1);
        s += a[0];
        alloc.free(a);
    }
    std.debug.print("{d}\n", .{s});
}
