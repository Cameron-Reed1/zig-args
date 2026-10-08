const std = @import("std");
const root = @import("root");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const has_global = @hasDecl(root, "GlobalArguments");

const Arguments: type = root.Arguments;
const GlobalArguments: type = if (has_global) root.GlobalArguments else void;

const ParseError = error{
    MissingRequiredArgument,
    MissingArgumentValue,
    MissingSubCommand,
    InvalidSubCommand,
    InvalidValue,
    UnknownArgument,
    UnexpectedValue,
    DuplicateArgument,
} || Allocator.Error;

const Options = struct {
    allow_repeats: bool = false,
    collect_extra_values: bool = false,
};

var arg0: ?[]const u8 = null;
var print_help: bool = false;

fn Result(comptime options: Options) type {
    comptime var len = 1;
    if (has_global) len += 1;
    if (options.collect_extra_values) len += 1;

    comptime var field_types: [len]type = undefined;
    field_types[0] = Arguments;

    if (has_global) {
        field_types[1] = GlobalArguments;
    }

    if (options.collect_extra_values) {
        field_types[len - 1] = []const []const u8;
    }

    return @Tuple(&field_types);
}

fn ExtraValues(comptime options: Options) type {
    return if (options.collect_extra_values) std.ArrayList([]const u8) else void;
}

pub fn parse(gpa: Allocator, arena: Allocator, args: std.process.Args, comptime options: Options) !Result(options) {
    var iter = try args.iterateAllocator(gpa);
    defer iter.deinit();

    arg0 = iter.next() orelse unreachable;

    var extra_values: ExtraValues(options) = if (options.collect_extra_values) .empty else {};
    defer if (options.collect_extra_values) extra_values.deinit(arena);

    var global_args: OptionalStruct(GlobalArguments) = if (has_global) .{} else {};
    const parsed: Optional(Arguments) = switch (@typeInfo(Arguments)) {
        .optional, .@"union" => try parseSubCommand(arena, Arguments, &iter, options, &global_args, &extra_values),
        .@"struct" => try parseFlags(arena, Arguments, &iter, options, &global_args, &extra_values),
        else => unreachable,
    };

    while (iter.next()) |arg| {
        if (try parseGlobalArgument(arena, &global_args, arg, &iter, options)) continue;

        if (std.mem.startsWith(u8, arg, "--")) return ParseError.UnknownArgument;

        if (options.collect_extra_values) {
            const duped = try arena.dupe(u8, arg);
            try extra_values.append(arena, duped);
        } else {
            return ParseError.UnexpectedValue;
        }
    }

    if (print_help) try printHelp(gpa, parsed);

    var result: Result(options) = undefined;
    result[0] = try finalize(Arguments, parsed);
    comptime var i: usize = 1;

    if (has_global) {
        result[i] = try finalize(GlobalArguments, global_args);
        i += 1;
    }

    if (options.collect_extra_values) {
        result[i] = try extra_values.toOwnedSlice(arena);
        i += 1;
    }

    return result;
}

fn parseSubCommand(arena: Allocator, T: type, iter: *std.process.Args.Iterator, comptime options: Options, global_args: *OptionalStruct(GlobalArguments), extra_values: *ExtraValues(options)) ParseError!Optional(T) {
    const cmd = blk: {
        while (iter.next()) |arg| {
            if (try parseGlobalArgument(arena, global_args, arg, iter, options)) continue;
            break :blk arg;
        }

        return null;
    };

    const union_info = switch (@typeInfo(T)) {
        .@"union" => |info| info,
        .optional => |info| @typeInfo(info.child).@"union",
        else => unreachable,
    };
    inline for (union_info.field_names, union_info.field_types) |cmd_name, cmd_type| {
        if (std.mem.eql(u8, cmd_name, cmd)) {
            const union_type = @typeInfo(Optional(T)).optional.child;

            return switch (@typeInfo(cmd_type)) {
                .void => @unionInit(union_type, cmd_name, {}),
                .@"struct" => @unionInit(union_type, cmd_name, try parseFlags(arena, cmd_type, iter, options, global_args, extra_values)),
                .@"union", .optional => @unionInit(union_type, cmd_name, try parseSubCommand(arena, cmd_type, iter, options, global_args, extra_values)),
                else => unreachable,
            };
        }
    }

    return ParseError.InvalidSubCommand;
}

fn parseFlags(arena: Allocator, T: type, iter: *std.process.Args.Iterator, comptime options: Options, global_args: *OptionalStruct(GlobalArguments), extra_values: *ExtraValues(options)) ParseError!Optional(T) {
    var partial: OptionalStruct(T) = .{};

    outer: while (iter.next()) |arg| {
        if (try parseGlobalArgument(arena, global_args, arg, iter, options)) continue;
        if (!std.mem.startsWith(u8, arg, "--")) {
            if (options.collect_extra_values) {
                const duped = try arena.dupe(u8, arg);
                try extra_values.append(arena, duped);
                continue;
            } else {
                return ParseError.UnexpectedValue;
            }
        }

        const struct_info = @typeInfo(@TypeOf(partial)).@"struct";
        inline for (struct_info.field_names, struct_info.field_types) |field_name, field_type| {
            if (std.mem.eql(u8, field_name, arg[2..])) {
                if (field_type == bool) {
                    if (@field(partial, field_name) and !options.allow_repeats) return ParseError.DuplicateArgument;

                    @field(partial, field_name) = true;
                } else {
                    if (@field(partial, field_name) != null and !options.allow_repeats) return ParseError.DuplicateArgument;

                    const val = iter.next() orelse return ParseError.MissingArgumentValue;
                    @field(partial, field_name) = try parseValue(arena, @typeInfo(field_type).optional.child, val);
                }

                continue :outer;
            }
        }

        return ParseError.UnknownArgument;
    }

    return partial;
}

fn parseGlobalArgument(arena: Allocator, global_args: *OptionalStruct(GlobalArguments), arg: []const u8, iter: *std.process.Args.Iterator, options: Options) !bool {
    if (try checkHelp(arg, options)) return true;
    if (!has_global) return false;
    if (!std.mem.startsWith(u8, arg, "--")) return false;

    const struct_info = @typeInfo(OptionalStruct(GlobalArguments)).@"struct";
    inline for (struct_info.field_names, struct_info.field_types) |field_name, field_type| {
        if (std.mem.eql(u8, field_name, arg[2..])) {
            if (field_type == bool) {
                if (@field(global_args, field_name) and !options.allow_repeats) return ParseError.DuplicateArgument;

                @field(global_args, field_name) = true;
            } else {
                if (@field(global_args, field_name) != null and !options.allow_repeats) return ParseError.DuplicateArgument;

                const val = iter.next() orelse return ParseError.MissingArgumentValue;
                @field(global_args, field_name) = try parseValue(arena, @typeInfo(field_type).optional.child, val);
            }

            return true;
        }
    }

    return false;
}

fn parseValue(arena: Allocator, T: type, str: [:0]const u8) ParseError!T {
    const type_info = @typeInfo(T);

    return switch (type_info) {
        .int => std.fmt.parseInt(T, str, 0) catch return ParseError.InvalidValue,
        .float => std.fmt.parseFloat(T, str) catch return ParseError.InvalidValue,
        .pointer => try arena.dupe(u8, str),
        .@"enum" => |enum_info| blk: {
            for (enum_info.fields) |enum_field| {
                if (std.mem.eql(u8, enum_field.name, str)) {
                    break :blk @fromBackingInt(@intCast(enum_field.value));
                }
            }

            return ParseError.InvalidValue;
        },
        else => unreachable,
    };
}

fn finalize(T: type, partial: Optional(T)) ParseError!T {
    return switch (@typeInfo(T)) {
        .@"struct" => finalizeStruct(T, partial),
        .@"union", .optional => finalizeUnion(T, partial),
        .void => {},
        else => unreachable,
    };
}

fn finalizeStruct(T: type, partial: OptionalStruct(T)) ParseError!T {
    var finalized: T = undefined;

    const type_info = @typeInfo(T).@"struct";
    inline for (type_info.field_names, type_info.field_types) |field_name, field_type| {
        const val = @field(partial, field_name);

        if (@typeInfo(field_type) == .optional or field_type == bool) {
            @field(finalized, field_name) = val;
        } else {
            if (val == null) return ParseError.MissingRequiredArgument;
            @field(finalized, field_name) = val.?;
        }
    }

    return finalized;
}

fn finalizeUnion(T: type, partial: Optional(T)) ParseError!T {
    const type_info = @typeInfo(T);
    if (partial == null) {
        if (type_info != .optional) return ParseError.MissingSubCommand;
        return null;
    }

    const finalized_type = if (type_info == .optional) type_info.optional.child else T;

    return switch (partial.?) {
        inline else => |v, tag| @unionInit(finalized_type, @tagName(tag), try finalize(@FieldType(finalized_type, @tagName(tag)), v)),
    };
}

fn checkHelp(arg: []const u8, options: Options) !bool {
    if (std.mem.eql(u8, "--help", arg)) {
        if (print_help and !options.allow_repeats) return ParseError.DuplicateArgument;
        print_help = true;
        return true;
    }

    return false;
}

fn printHelp(gpa: Allocator, parsed: Optional(Arguments)) !void {
    std.debug.assert(arg0 != null);

    var parsed_commands: std.ArrayList(u8) = .empty;
    defer parsed_commands.deinit(gpa);

    const help_options = try chooseHelpMsg(gpa, &parsed_commands, parsed);

    comptime var help_str: []const u8 = "Usage: {s}{s} [OPTIONS]\n\n{s}";

    if (has_global) {
        help_str = help_str ++ "Global Options:\n" ++ comptime buildStructHelp(GlobalArguments);
    }

    std.debug.print(help_str, .{ arg0.?, parsed_commands.items, help_options });
    std.process.exit(0);
}

fn chooseHelpMsg(gpa: Allocator, cmds: *std.ArrayList(u8), value: anytype) ![]const u8 {
    const T = @TypeOf(value);

    switch (@typeInfo(T)) {
        .@"union" => {
            const cmd = @tagName(value);

            try cmds.append(gpa, ' ');
            try cmds.appendSlice(gpa, cmd);

            switch (value) {
                inline else => |v| return try chooseHelpMsg(gpa, cmds, v),
            }
        },
        .optional => {
            if (value) |v| {
                return try chooseHelpMsg(gpa, cmds, v);
            } else {
                return "Commands:\n" ++ comptime buildUnionHelp(T) ++ "\n";
            }
        },
        .@"struct" => return "Options:\n" ++ comptime buildStructHelp(T) ++ "\n",
        .void => return "",
        else => unreachable,
    }
}

fn buildStructHelp(T: type) []const u8 {
    comptime var help_str: []const u8 = "";

    const struct_info = @typeInfo(T).@"struct";
    inline for (struct_info.field_names) |field_name| {
        help_str = help_str ++ "\t--" ++ field_name ++ "\n";
    }

    return help_str;
}

fn buildUnionHelp(T: type) []const u8 {
    const type_info = @typeInfo(T);
    if (type_info == .optional) return buildUnionHelp(type_info.optional.child);

    comptime var help_str: []const u8 = "";

    const union_info = type_info.@"union";
    inline for (union_info.field_names) |field_name| {
        help_str = help_str ++ "\t" ++ field_name ++ "\n";
    }

    return help_str;
}

fn Optional(T: type) type {
    return switch (@typeInfo(T)) {
        .@"struct" => OptionalStruct(T),
        .@"union" => OptionalUnion(T),
        .void => void,
        .optional => |opt_info| switch (@typeInfo(opt_info.child)) {
            .@"union" => OptionalUnion(opt_info.child),
            else => unreachable,
        },
        else => unreachable,
    };
}

fn OptionalStruct(T: type) type {
    const struct_info = @typeInfo(T).@"struct";

    const field_names = struct_info.field_names;
    comptime var field_types: [struct_info.field_types.len]type = undefined;
    comptime var field_attrs: [struct_info.field_types.len]std.builtin.Type.Struct.FieldAttributes = @splat(.{});
    for (struct_info.field_types, 0..) |original, i| {
        if (std.mem.eql(u8, "help", field_names[i])) @compileError("--help is reserved");

        checkFieldType(original);
        if (original == bool) {
            field_types[i] = bool;
            field_attrs[i].default_value_ptr = &false;
        } else {
            field_types[i] = if (@typeInfo(original) == .optional) original else ?original;
            field_attrs[i].default_value_ptr = &@as(field_types[i], null);
        }
    }

    return @Struct(.auto, null, field_names, &field_types, &field_attrs);
}

fn OptionalUnion(T: type) type {
    const union_info = @typeInfo(T).@"union";

    comptime var field_types: [union_info.field_types.len]type = undefined;
    inline for (&field_types, union_info.field_types) |*ftype, original| {
        ftype.* = switch (@typeInfo(original)) {
            .optional, .@"struct", .@"union", .void => Optional(original),
            else => unreachable,
        };
    }

    return ?@Union(.auto, union_info.tag_type, union_info.field_names, &field_types, &@splat(.{}));
}

fn checkFieldType(T: type) void {
    switch (@typeInfo(T)) {
        .int, .bool, .float, .@"enum" => return,
        .pointer => |ptr_info| if (ptr_info.size == .slice and ptr_info.child == u8) return,
        .optional => |opt_info| return checkFieldType(opt_info.child),
        else => {},
    }

    @compileError("Unsupported argument type: " ++ @typeName(T));
}
