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
    cmd4: void,
    cmd5: ?union(enum) {
        cmd51: void,
        cmd52: struct {
            value: u32,
        },
    }
};

pub const GlobalArguments = struct {
    global: ?[]const u8,
};

pub fn main(init: std.process.Init) !void {
    const parsed_args, const global_args = try args.parse(init.gpa, init.minimal.args, .{});
    std.debug.print("{any}\n", .{parsed_args});
    std.debug.print("{any}\n", .{global_args});
}
