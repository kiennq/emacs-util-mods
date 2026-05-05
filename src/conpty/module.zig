const std = @import("std");
const emacs = @import("emacs");
const Conpty = @import("conpty.zig");
const loader = @import("dyn_loader_abi");

const c = emacs.c;
const Registry = std.AutoHashMap(usize, *Conpty.State);

const id: [:0]const u8 = "conpty-module";
const version: [:0]const u8 = "0.1";

export const plugin_is_GPL_compatible: c_int = 1;

var registry = Registry.init(std.heap.page_allocator);

fn termKey(env: emacs.Env, value: emacs.Value) ?usize {
    const raw_ptr = env.raw.get_user_ptr.?(env.raw, value) orelse return null;
    return @intFromPtr(raw_ptr);
}

fn put(term_key: usize, state: *Conpty.State) !void {
    try registry.put(term_key, state);
}

fn get(term_key: usize) ?*Conpty.State {
    return registry.get(term_key);
}

fn remove(term_key: usize) ?*Conpty.State {
    const entry = registry.fetchRemove(term_key) orelse return null;
    return entry.value;
}

fn cleanupModule(_: ?*c.emacs_env) callconv(.c) void {
    var iterator = registry.valueIterator();
    while (iterator.next()) |state| {
        Conpty.deinit(state.*);
    }
    registry.clearRetainingCapacity();
}

fn fnConptyInit(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const key = termKey(env, args[0]) orelse {
        env.signalError("conpty: invalid terminal handle");
        return env.nil();
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var command_stack: [512]u8 = undefined;
    var cwd_stack: [512]u8 = undefined;
    const command = env.extractString(args[2], &command_stack) orelse blk: {
        break :blk env.extractStringAlloc(args[2], allocator);
    };
    const cwd = env.extractString(args[5], &cwd_stack) orelse blk: {
        break :blk env.extractStringAlloc(args[5], allocator);
    };

    if (command == null or cwd == null) {
        env.signalError("conpty: invalid arguments");
        return env.nil();
    }

    if (remove(key)) |existing| {
        Conpty.deinit(existing);
    }

    const state = Conpty.init(
        env,
        args[1],
        command.?,
        @intCast(env.extractInteger(args[3])),
        @intCast(env.extractInteger(args[4])),
        cwd.?,
        args[6],
        allocator,
    ) catch |err| {
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            "conpty: failed to initialize backend: {s}",
            .{@errorName(err)},
        ) catch "conpty: failed to initialize backend";
        env.signalError(msg);
        return env.nil();
    };
    errdefer Conpty.deinit(state);

    put(key, state) catch {
        env.signalError("conpty: failed to register backend state");
        return env.nil();
    };

    return env.t();
}

fn fnConptyReadPending(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const key = termKey(env, args[0]) orelse return env.nil();
    const state = get(key) orelse return env.nil();
    return Conpty.readPending(env, state);
}

fn fnConptyWrite(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const key = termKey(env, args[0]) orelse return env.nil();
    const state = get(key) orelse return env.nil();

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stack_buf: [65536]u8 = undefined;
    const data = env.extractString(args[1], &stack_buf) orelse blk: {
        break :blk env.extractStringAlloc(args[1], allocator);
    };
    if (data == null) return env.nil();

    Conpty.write(state, data.?) catch {
        env.signalError("conpty: failed to write to backend");
        return env.nil();
    };
    return env.t();
}

fn fnConptyResize(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const key = termKey(env, args[0]) orelse return env.nil();
    const state = get(key) orelse return env.nil();
    return if (Conpty.resize(
        state,
        @intCast(env.extractInteger(args[1])),
        @intCast(env.extractInteger(args[2])),
    )) env.t() else env.nil();
}

fn fnConptyIsAlive(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const key = termKey(env, args[0]) orelse return env.nil();
    const state = get(key) orelse return env.nil();
    return if (Conpty.isAlive(state)) env.t() else env.nil();
}

fn fnConptyKill(raw_env: ?*c.emacs_env, _: isize, args: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const key = termKey(env, args[0]) orelse return env.nil();
    const state = remove(key) orelse return env.nil();
    const killed = Conpty.kill(state);
    Conpty.deinit(state);
    return if (killed) env.t() else env.nil();
}

// ---------------------------------------------------------------------------
// Dual-mode export infrastructure
// ---------------------------------------------------------------------------

const ExportId = enum(u32) {
    init_backend = 1,
    read_pending = 2,
    write = 3,
    resize = 4,
    is_alive = 5,
    kill = 6,
};

pub const conpty_export_descriptors = [_]loader.ExportDescriptor{
    .{ .export_id = @intFromEnum(ExportId.init_backend), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "conpty--init", .min_arity = 7, .max_arity = 7, .docstring = "Start a Windows ConPTY backend.\n\n(conpty--init TERM PROCESS COMMAND ROWS COLS CWD ENV-OVERRIDES)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.read_pending), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "conpty--read-pending", .min_arity = 1, .max_arity = 1, .docstring = "Read pending Windows ConPTY output.\n\n(conpty--read-pending TERM)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.write), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "conpty--write", .min_arity = 2, .max_arity = 2, .docstring = "Write raw bytes to the Windows ConPTY backend.\n\n(conpty--write TERM DATA)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.resize), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "conpty--resize", .min_arity = 3, .max_arity = 3, .docstring = "Resize the Windows ConPTY backend.\n\n(conpty--resize TERM ROWS COLS)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.is_alive), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "conpty--is-alive", .min_arity = 1, .max_arity = 1, .docstring = "Return t if the Windows ConPTY child is alive.\n\n(conpty--is-alive TERM)", .flags = 0 },
    .{ .export_id = @intFromEnum(ExportId.kill), .kind = @intFromEnum(loader.ExportKind.function), .lisp_name = "conpty--kill", .min_arity = 1, .max_arity = 1, .docstring = "Terminate the Windows ConPTY child.\n\n(conpty--kill TERM)", .flags = 0 },
};

pub fn invokeExport(export_id: u32, raw_env: ?*c.emacs_env, nargs: isize, args: [*c]c.emacs_value, data: ?*anyopaque) callconv(.c) c.emacs_value {
    return switch (@as(ExportId, @enumFromInt(export_id))) {
        .init_backend => fnConptyInit(raw_env, nargs, args, data),
        .read_pending => fnConptyReadPending(raw_env, nargs, args, data),
        .write => fnConptyWrite(raw_env, nargs, args, data),
        .resize => fnConptyResize(raw_env, nargs, args, data),
        .is_alive => fnConptyIsAlive(raw_env, nargs, args, data),
        .kill => fnConptyKill(raw_env, nargs, args, data),
    };
}

pub fn getVariable(export_id: u32, raw_env: ?*c.emacs_env, _: ?*anyopaque) callconv(.c) c.emacs_value {
    _ = export_id;
    const env = emacs.Env.init(raw_env.?);
    env.signalError("conpty: variable export not supported");
    return env.nil();
}

pub fn setVariable(export_id: u32, raw_env: ?*c.emacs_env, _: c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {
    _ = export_id;
    const env = emacs.Env.init(raw_env.?);
    env.signalError("conpty: variable export not supported");
    return env.nil();
}

export fn loader_module_init_generic(out: *loader.GenericManifest) callconv(.c) void {
    out.* = .{
        .loader_abi = loader.LoaderAbiVersion,
        .module_id = id.ptr,
        .module_version = version.ptr,
        .exports_len = conpty_export_descriptors.len,
        .exports = conpty_export_descriptors[0..].ptr,
        .invoke = &invokeExport,
        .get_variable = &getVariable,
        .set_variable = &setVariable,
    };
}

export fn loader_module_cleanup(raw_env: ?*c.emacs_env) callconv(.c) void {
    cleanupModule(raw_env);
}

fn bindExportDescriptor(env: emacs.Env, descriptor: *const loader.ExportDescriptor) void {
    switch (descriptor.kind) {
        @intFromEnum(loader.ExportKind.function) => {
            const function = env.makeFunction(
                descriptor.min_arity,
                descriptor.max_arity,
                &invokeExportDescriptor,
                descriptor.docstring,
                @ptrCast(@constCast(descriptor)),
            );
            _ = env.call2(env.intern("fset"), env.intern(descriptor.lisp_name), function);
        },
        @intFromEnum(loader.ExportKind.variable) => {
            const value = getVariable(
                descriptor.export_id,
                env.raw,
                @ptrCast(@constCast(descriptor)),
            );
            _ = env.call2(env.intern("set"), env.intern(descriptor.lisp_name), value);
        },
        else => unreachable,
    }
}

fn invokeExportDescriptor(
    raw_env: ?*c.emacs_env,
    nargs: isize,
    args: [*c]c.emacs_value,
    data: ?*anyopaque,
) callconv(.c) c.emacs_value {
    const env = emacs.Env.init(raw_env.?);
    const raw_descriptor = data orelse {
        env.signalError("conpty: missing export descriptor");
        return env.nil();
    };
    const descriptor: *const loader.ExportDescriptor = @ptrCast(@alignCast(raw_descriptor));
    return invokeExport(descriptor.export_id, raw_env, nargs, args, null);
}

export fn emacs_module_init(runtime: *c.struct_emacs_runtime) callconv(.c) c_int {
    if (runtime.size < @sizeOf(c.struct_emacs_runtime)) return 1;

    const env = emacs.Env.init(runtime.get_environment.?(runtime));
    for (&conpty_export_descriptors) |*descriptor| {
        bindExportDescriptor(env, descriptor);
    }

    emacs.initSymbols(env);
    env.provide("conpty-module");
    return 0;
}
