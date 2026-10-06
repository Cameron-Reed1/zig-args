const std = @import("std");
const root = @import("root");
const Io = std.Io;
const Allocator = std.mem.Allocator;


const Args: type = root.Args;
const ArgsOptional = makeArgsOptional();

comptime {
    checkFieldTypes();
}


const ParseError = error {
    MissingRequiredArgument,
    MissingArgumentValue,
    InvalidValue,
    UnexpectedValue,
    DuplicateArgument,
};


const Options = struct {
    allow_repeats: bool = false,
};


pub fn parse(gpa: Allocator, args: std.process.Args, options: Options) !Args {
    var iter = try args.iterateAllocator(gpa);
    defer iter.deinit();

    _ = iter.next(); // Skip program name

    var partial: ArgsOptional = .{};

    while (iter.next()) |arg| {
        if (!std.mem.startsWith(u8, arg, "--")) {
            return ParseError.UnexpectedValue;
        }

        const struct_info = @typeInfo(ArgsOptional).@"struct";
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

    return finalize(partial);
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

fn finalize(partial: ArgsOptional) ParseError!Args {
    const args_type_info = @typeInfo(Args).@"struct";

    var finalized: Args = undefined;

    inline for (args_type_info.field_names, args_type_info.field_types) |field_name, field_type| {
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

fn makeArgsOptional() type {
    const type_info = @typeInfo(Args);
    if (type_info != .@"struct") @compileError("root.Args must be a struct");
    const struct_info = type_info.@"struct";

    comptime var field_types: [struct_info.field_types.len]type = undefined;
    comptime var field_attrs: [struct_info.field_types.len]std.builtin.Type.Struct.FieldAttributes = @splat(.{});
    for (&field_types, &field_attrs, struct_info.field_types) |*ftype, *attr, original| {
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

fn checkFieldTypes() void {
    const type_info = @typeInfo(Args);
    if (type_info != .@"struct") @compileError("root.Args must be a struct");

    for (type_info.@"struct".field_types) |field_type| {
        checkFieldType(field_type);
    }
}

fn checkFieldType(T: type) void {
    const type_info = @typeInfo(T);
    switch (type_info) {
        .int,
        .bool,
        .float,
        .@"enum" => {},
        .pointer => |ptr_info| if (ptr_info.size != .slice or ptr_info.child != u8) @compileError("Unsupported argument type: " ++ @typeName(T)),
        .optional => |opt_info| {
            checkFieldType(opt_info.child);
        },
        else => @compileError("Unsupported argument type: " ++ @typeName(T)),
    }
}
