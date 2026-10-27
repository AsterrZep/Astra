fn fib(n: i32) i32 {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}
pub fn main() void {
    std.debug.print("{d}\n", .{fib(30)});
}
const std = @import("std");
