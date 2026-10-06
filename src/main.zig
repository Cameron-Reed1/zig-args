const std = @import("std");
const Io = std.Io;

const args = @import("args");

pub const Args = struct {
    first: []const u8,
    second: bool,
    third: ?u8,
};

pub fn main(init: std.process.Init) !void {
    const parsed_args = try args.parse(init.gpa, init.minimal.args, .{});
    std.debug.print("{any}\n", .{parsed_args});
}
