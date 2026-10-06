const std = @import("std");
const Io = std.Io;

const args = @import("args");

pub const Arguments = union(enum) {
    cmd1: struct {
        value: ?[]const u8,
    },
    cmd2: struct {
        value: u8,
    },
    cmd3: struct {
        value: bool,
        value2: ?f32,
    },
};

pub fn main(init: std.process.Init) !void {
    const parsed_args = try args.parse(init.gpa, init.minimal.args, .{});
    std.debug.print("{any}\n", .{parsed_args});
}
