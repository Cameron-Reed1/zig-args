const std = @import("std");
const root = @import("root");
const Io = std.Io;
const Allocator = std.mem.Allocator;


const Arguments: type = root.Arguments;


const ParseError = error {
    MissingRequiredArgument,
    MissingArgumentValue,
    MissingSubCommand,
    InvalidSubCommand,
    InvalidValue,
    UnexpectedValue,
    DuplicateArgument,
};


const Options = struct {
    allow_repeats: bool = false,
};


pub fn parse(gpa: Allocator, args: std.process.Args, options: Options) !Arguments {
    var iter = try args.iterateAllocator(gpa);
    defer iter.deinit();

    _ = iter.next(); // Skip program name

    return switch (@typeInfo(Arguments)) {
        .@"union" => parseSubCommand(Arguments, &iter, options),
        .@"struct" => parseFlags(Arguments, &iter, options),
        else => unreachable,
    };
}

pub fn parseSubCommand(T: type, iter: *std.process.Args.Iterator, options: Options) !T {
    const cmd = iter.next() orelse return ParseError.MissingSubCommand;

    const union_info = @typeInfo(T).@"union";
    inline for(union_info.field_names, union_info.field_types) |cmd_name, cmd_type| {
        if (std.mem.eql(u8, cmd_name, cmd)) {
            return switch (@typeInfo(cmd_type)) {
                .void => @unionInit(T, cmd_name, {}),
                .@"struct" => @unionInit(T, cmd_name, try parseFlags(cmd_type, iter, options)),
                .@"union" => @unionInit(T, cmd_name, try parseSubCommand(cmd_type, iter, options)),
                else => unreachable,
            };
        }
    }

    return ParseError.InvalidSubCommand;
}

pub fn parseFlags(T: type, iter: *std.process.Args.Iterator, options: Options) !T {
    var partial: OptionalStruct(T) = .{};

    while (iter.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) {
            return ParseError.UnexpectedValue;
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
                    @field(partial, field_name) = try parseValue(@typeInfo(field_type).optional.child, val);
                }
            }
        }
    }

    return finalize(T, partial);
}

fn parseValue(T: type, str: [:0]const u8) !T {
    const type_info = @typeInfo(T);

    return switch (type_info) {
        .int => std.fmt.parseInt(T, str, 0) catch return ParseError.InvalidValue,
        .float => std.fmt.parseFloat(T, str) catch return ParseError.InvalidValue,
        .pointer => str,
        .@"enum" => |enum_info| blk: {
            for (enum_info.fields) |enum_field| {
                if (std.mem.eql(u8, enum_field.name, str)) {
                    break :blk @enumFromInt(enum_field.value);
                }
            }

            return ParseError.InvalidValue;
        },
        else => unreachable,
    };
}

fn finalize(T: type, partial: OptionalStruct(T)) ParseError!T {
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

fn OptionalStruct(T: type) type {
    const struct_info = @typeInfo(T).@"struct";

    comptime var field_types: [struct_info.field_types.len]type = undefined;
    comptime var field_attrs: [struct_info.field_types.len]std.builtin.Type.Struct.FieldAttributes = @splat(.{});
    for (&field_types, &field_attrs, struct_info.field_types) |*ftype, *attr, original| {
        checkFieldType(original);
        if (original == bool) {
            ftype.* = bool;
            attr.default_value_ptr = &false;
        } else {
            ftype.* = if (@typeInfo(original) == .optional) original else ?original;
            attr.default_value_ptr = &@as(ftype.*, null);
        }
    }

    return @Struct(.auto, null, struct_info.field_names, &field_types, &field_attrs);
}

fn checkFieldType(T: type) void {
    switch (@typeInfo(T)) {
        .int,
        .bool,
        .float,
        .@"enum" => return,
        .pointer => |ptr_info| if (ptr_info.size == .slice and ptr_info.child == u8) return,
        .optional => |opt_info| return checkFieldType(opt_info.child),
        else => {},
    }

    @compileError("Unsupported argument type: " ++ @typeName(T));
}
