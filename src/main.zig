const std = @import("std");
const Io = std.Io;

const args = @import("args");

pub const Arguments = union(enum) { cmd1: struct {
    value: ?[]const u8,
}, cmd2: struct {
    value: u8,
}, cmd3: struct {
    value: bool,
    value2: ?f32,
}, cmd4: void, cmd5: ?union(enum) {
    cmd51: void,
    cmd52: struct {
        value: u32,
    },
} };

pub const GlobalArguments = struct {
    global: ?[]const u8,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const parsed_args, const global_args, const extra = try args.parse(init.gpa, arena, init.minimal.args, .{ .collect_extra_values = true });
    std.debug.print("{any}\n", .{parsed_args});
    std.debug.print("{any}\n", .{global_args});

    if (extra.len != 0) {
        std.debug.print("Extra Values:\n", .{});
        for (extra) |ex| {
            std.debug.print("\t{s}\n", .{ex});
        }
    }
}
