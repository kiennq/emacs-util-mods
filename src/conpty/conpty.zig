const builtin = @import("builtin");
const std = @import("std");
const emacs = @import("emacs");

const is_windows = builtin.os.tag == .windows;

const c = if (is_windows)
    @cImport({
        @cInclude("windows.h");
        @cInclude("io.h");
    })
else
    struct {};

const HPCON = if (is_windows) ?*anyopaque else ?*anyopaque;
const CreatePseudoConsoleFn = if (is_windows)
    *const fn (c.COORD, c.HANDLE, c.HANDLE, u32, *HPCON) callconv(.winapi) c.HRESULT
else
    *const fn () callconv(.c) c_int;
const ResizePseudoConsoleFn = if (is_windows)
    *const fn (HPCON, c.COORD) callconv(.winapi) c.HRESULT
else
    *const fn () callconv(.c) c_int;
const ClosePseudoConsoleFn = if (is_windows)
    *const fn (HPCON) callconv(.winapi) void
else
    *const fn () callconv(.c) void;

const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const OUTPUT_BUFFER_SIZE = 64 * 1024;
const PENDING_BUFFER_SIZE = 4 * 1024 * 1024;

pub const State = if (is_windows) struct {
    arena: std.heap.ArenaAllocator,
    hpc: HPCON = null,
    pty_input: c.HANDLE = c.INVALID_HANDLE_VALUE,
    pty_output: c.HANDLE = c.INVALID_HANDLE_VALUE,
    shell_process: c.HANDLE = c.INVALID_HANDLE_VALUE,
    reader_thread: c.HANDLE = c.INVALID_HANDLE_VALUE,
    notify_fd: c_int = -1,
    pending_lock: c.CRITICAL_SECTION = undefined,
    output_buf: *[2][OUTPUT_BUFFER_SIZE]u8,
    pending_buf: *[PENDING_BUFFER_SIZE]u8,
    pending_len: usize = 0,
    running: std.atomic.Value(u8) = std.atomic.Value(u8).init(1),
} else struct {};

var create_pseudo_console: ?CreatePseudoConsoleFn = null;
var resize_pseudo_console: ?ResizePseudoConsoleFn = null;
var close_pseudo_console: ?ClosePseudoConsoleFn = null;

pub fn init(
    env: emacs.Env,
    process: emacs.Value,
    shell_command: []const u8,
    rows: u16,
    cols: u16,
    working_directory: []const u8,
    environment_overrides: emacs.Value,
    allocator: std.mem.Allocator,
) !*State {
    if (!is_windows) return error.UnsupportedPlatform;
    if (!(try initApi())) return error.MissingConpty;

    const state = try std.heap.page_allocator.create(State);
    errdefer std.heap.page_allocator.destroy(state);

    state.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    errdefer state.arena.deinit();

    const arena_alloc = state.arena.allocator();
    state.output_buf = try arena_alloc.create([2][OUTPUT_BUFFER_SIZE]u8);
    state.pending_buf = try arena_alloc.create([PENDING_BUFFER_SIZE]u8);

    state.hpc = null;
    state.pty_input = c.INVALID_HANDLE_VALUE;
    state.pty_output = c.INVALID_HANDLE_VALUE;
    state.shell_process = c.INVALID_HANDLE_VALUE;
    state.reader_thread = c.INVALID_HANDLE_VALUE;
    state.notify_fd = -1;
    state.pending_len = 0;
    state.running = std.atomic.Value(u8).init(1);

    c.InitializeCriticalSection(&state.pending_lock);
    errdefer c.DeleteCriticalSection(&state.pending_lock);

    state.notify_fd = env.openChannel(process);
    if (state.notify_fd < 0) return error.OpenChannelFailed;

    try createConpty(state, rows, cols);
    errdefer deinit(state);

    try spawnShell(state, env, shell_command, working_directory, environment_overrides, allocator);

    state.reader_thread = c.CreateThread(
        null,
        0,
        readerThread,
        state,
        0,
        null,
    ) orelse return error.CreateThreadFailed;

    return state;
}

pub fn deinit(state_opt: ?*State) void {
    if (!is_windows) return;
    const state = state_opt orelse return;

    requestShutdown(state);

    if (state.reader_thread != c.INVALID_HANDLE_VALUE) {
        const cleanup_thread = c.CreateThread(
            null,
            0,
            cleanupThread,
            state,
            0,
            null,
        );
        if (cleanup_thread != null) {
            _ = c.CloseHandle(cleanup_thread);
            return;
        }
    }

    waitForReaderThread(state, c.INFINITE);
    finalizeState(state);
}

fn requestShutdown(state: *State) void {
    state.running.store(0, .release);

    if (state.shell_process != c.INVALID_HANDLE_VALUE) {
        var exit_code: c.DWORD = 0;
        if (c.GetExitCodeProcess(state.shell_process, &exit_code) != 0 and exit_code == c.STILL_ACTIVE) {
            _ = c.TerminateProcess(state.shell_process, 1);
        }
        _ = c.CloseHandle(state.shell_process);
        state.shell_process = c.INVALID_HANDLE_VALUE;
    }

    if (state.pty_input != c.INVALID_HANDLE_VALUE) {
        _ = c.CloseHandle(state.pty_input);
        state.pty_input = c.INVALID_HANDLE_VALUE;
    }

    if (state.hpc != null) {
        close_pseudo_console.?(state.hpc);
        state.hpc = null;
    }

    if (state.reader_thread != c.INVALID_HANDLE_VALUE) {
        _ = c.CancelSynchronousIo(state.reader_thread);
    }

    if (state.pty_output != c.INVALID_HANDLE_VALUE) {
        _ = c.CloseHandle(state.pty_output);
        state.pty_output = c.INVALID_HANDLE_VALUE;
    }
}

fn waitForReaderThread(state: *State, timeout_ms: c.DWORD) void {
    if (state.reader_thread == c.INVALID_HANDLE_VALUE) return;
    _ = c.WaitForSingleObject(state.reader_thread, timeout_ms);
    _ = c.CloseHandle(state.reader_thread);
    state.reader_thread = c.INVALID_HANDLE_VALUE;
}

fn finalizeState(state: *State) void {
    if (state.notify_fd >= 0) {
        _ = c._close(state.notify_fd);
        state.notify_fd = -1;
    }

    c.DeleteCriticalSection(&state.pending_lock);
    state.arena.deinit();
    std.heap.page_allocator.destroy(state);
}

fn cleanupThread(param: ?*anyopaque) callconv(.winapi) c.DWORD {
    const state: *State = @ptrCast(@alignCast(param.?));
    waitForReaderThread(state, c.INFINITE);
    finalizeState(state);
    return 0;
}

pub fn readPending(env: emacs.Env, state: *State) emacs.Value {
    if (!is_windows) return env.nil();

    c.EnterCriticalSection(&state.pending_lock);
    defer c.LeaveCriticalSection(&state.pending_lock);

    if (state.pending_len == 0) return env.nil();

    const str = env.makeString(state.pending_buf[0..state.pending_len]);
    state.pending_len = 0;
    return str;
}

pub fn write(state: *State, data: []const u8) !void {
    if (!is_windows) return error.UnsupportedPlatform;
    if (data.len == 0) return;

    var offset: usize = 0;
    while (offset < data.len) {
        var wrote: c.DWORD = 0;
        const chunk_len: c.DWORD = @intCast(@min(data.len - offset, std.math.maxInt(c.DWORD)));
        if (c.WriteFile(state.pty_input, data[offset..].ptr, chunk_len, &wrote, null) == 0) {
            return error.WriteFailed;
        }
        offset += wrote;
        if (wrote == 0) return error.WriteFailed;
    }
}

pub fn resize(state: *State, rows: u16, cols: u16) bool {
    if (!is_windows) return false;
    const size = c.COORD{
        .X = @intCast(cols),
        .Y = @intCast(rows),
    };
    return resize_pseudo_console.?(state.hpc, size) >= 0;
}

pub fn isAlive(state: *State) bool {
    if (!is_windows) return false;
    if (state.shell_process == c.INVALID_HANDLE_VALUE) return false;
    var exit_code: c.DWORD = 0;
    return c.GetExitCodeProcess(state.shell_process, &exit_code) != 0 and exit_code == c.STILL_ACTIVE;
}

pub fn kill(state: *State) bool {
    if (!is_windows) return false;
    if (state.shell_process == c.INVALID_HANDLE_VALUE) return false;
    return c.TerminateProcess(state.shell_process, 1) != 0;
}

fn initApi() !bool {
    if (!is_windows) return false;
    if (create_pseudo_console != null) return true;

    const kernel32 = c.GetModuleHandleA("kernel32.dll") orelse return false;
    create_pseudo_console = @ptrCast(c.GetProcAddress(kernel32, "CreatePseudoConsole") orelse return false);
    resize_pseudo_console = @ptrCast(c.GetProcAddress(kernel32, "ResizePseudoConsole") orelse return false);
    close_pseudo_console = @ptrCast(c.GetProcAddress(kernel32, "ClosePseudoConsole") orelse return false);
    return true;
}

fn createConpty(state: *State, rows: u16, cols: u16) !void {
    var in_read: c.HANDLE = c.INVALID_HANDLE_VALUE;
    var in_write: c.HANDLE = c.INVALID_HANDLE_VALUE;
    var out_read: c.HANDLE = c.INVALID_HANDLE_VALUE;
    var out_write: c.HANDLE = c.INVALID_HANDLE_VALUE;
    errdefer {
        if (in_read != c.INVALID_HANDLE_VALUE) _ = c.CloseHandle(in_read);
        if (in_write != c.INVALID_HANDLE_VALUE) _ = c.CloseHandle(in_write);
        if (out_read != c.INVALID_HANDLE_VALUE) _ = c.CloseHandle(out_read);
        if (out_write != c.INVALID_HANDLE_VALUE) _ = c.CloseHandle(out_write);
    }

    var sa = std.mem.zeroes(c.SECURITY_ATTRIBUTES);
    sa.nLength = @sizeOf(c.SECURITY_ATTRIBUTES);
    sa.bInheritHandle = c.TRUE;

    if (c.CreatePipe(&in_read, &in_write, &sa, 0) == 0) return error.CreatePipeFailed;
    if (c.CreatePipe(&out_read, &out_write, &sa, 0) == 0) return error.CreatePipeFailed;

    const size = c.COORD{
        .X = @intCast(cols),
        .Y = @intCast(rows),
    };
    if (create_pseudo_console.?(size, in_read, out_write, 0, &state.hpc) < 0) {
        return error.CreatePseudoConsoleFailed;
    }

    state.pty_input = in_write;
    state.pty_output = out_read;

    _ = c.CloseHandle(in_read);
    _ = c.CloseHandle(out_write);
}

fn spawnShell(
    state: *State,
    env: emacs.Env,
    shell_command: []const u8,
    working_directory: []const u8,
    environment_overrides: emacs.Value,
    allocator: std.mem.Allocator,
) !void {
    const command_line = try std.unicode.utf8ToUtf16LeAllocZ(allocator, shell_command);
    defer allocator.free(command_line);

    const cwd = try std.unicode.utf8ToUtf16LeAllocZ(allocator, working_directory);
    defer allocator.free(cwd);

    const env_block = try buildEnvironmentBlock(allocator, env, environment_overrides);
    defer if (env_block) |blk| allocator.free(blk);

    var attr_list_size: usize = 0;
    _ = c.InitializeProcThreadAttributeList(null, 1, 0, &attr_list_size);
    const attr_list_buf = try allocator.alloc(u8, attr_list_size);
    defer allocator.free(attr_list_buf);

    var si = std.mem.zeroes(c.STARTUPINFOEXW);
    si.StartupInfo.cb = @sizeOf(c.STARTUPINFOEXW);
    si.lpAttributeList = @ptrCast(@alignCast(attr_list_buf.ptr));
    if (c.InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, &attr_list_size) == 0) {
        return error.InitializeProcThreadAttributeListFailed;
    }
    defer c.DeleteProcThreadAttributeList(si.lpAttributeList);

    if (c.UpdateProcThreadAttribute(
        si.lpAttributeList,
        0,
        PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        state.hpc,
        @sizeOf(HPCON),
        null,
        null,
    ) == 0) {
        return error.UpdateProcThreadAttributeFailed;
    }

    var pi = std.mem.zeroes(c.PROCESS_INFORMATION);
    const flags = c.EXTENDED_STARTUPINFO_PRESENT | c.CREATE_UNICODE_ENVIRONMENT;
    const env_ptr = if (env_block) |blk| @as(?*anyopaque, @ptrCast(blk.ptr)) else null;
    if (c.CreateProcessW(
        null,
        command_line.ptr,
        null,
        null,
        c.FALSE,
        flags,
        env_ptr,
        cwd.ptr,
        &si.StartupInfo,
        &pi,
    ) == 0) {
        return error.CreateProcessFailed;
    }

    state.shell_process = pi.hProcess;
    _ = c.CloseHandle(pi.hThread);
}

fn buildEnvironmentBlock(allocator: std.mem.Allocator, env: emacs.Env, list: emacs.Value) !?[]u16 {
    if (!is_windows) return null;

    var overrides = std.ArrayList([:0]u16).empty;
    defer {
        for (overrides.items) |item| allocator.free(item);
        overrides.deinit(allocator);
    }

    var iter = list;
    const car = env.intern("car");
    const cdr = env.intern("cdr");
    while (env.isNotNil(iter)) {
        const item = env.call1(car, iter);
        const item_utf8 = env.extractStringAlloc(item, allocator) orelse
            return error.InvalidEnvironmentEntry;
        defer allocator.free(item_utf8);
        try overrides.append(allocator, try std.unicode.utf8ToUtf16LeAllocZ(allocator, item_utf8));
        iter = env.call1(cdr, iter);
    }
    if (overrides.items.len == 0) return null;

    var base_entries = std.ArrayList([]const u16).empty;
    defer {
        for (base_entries.items) |entry| allocator.free(entry);
        base_entries.deinit(allocator);
    }
    const os_env = c.GetEnvironmentStringsW();
    if (os_env != null) {
        defer _ = c.FreeEnvironmentStringsW(os_env);

        var cursor = os_env.?;
        while (cursor[0] != 0) {
            const entry = std.mem.sliceTo(cursor, 0);
            try base_entries.append(allocator, try allocator.dupe(u16, entry));
            cursor += entry.len + 1;
        }
    }

    return try buildEnvironmentBlockFromEntries(allocator, base_entries.items, overrides.items);
}

fn environmentKeyLen(entry: []const u16) usize {
    return std.mem.indexOfScalar(u16, entry, '=') orelse entry.len;
}

fn lowerAscii(unit: u16) u16 {
    return switch (unit) {
        'A'...'Z' => unit + ('a' - 'A'),
        else => unit,
    };
}

fn environmentKeyMatches(entry: []const u16, override: []const u16) bool {
    const entry_len = environmentKeyLen(entry);
    const override_len = environmentKeyLen(override);
    if (entry_len != override_len) return false;

    for (entry[0..entry_len], override[0..override_len]) |lhs, rhs| {
        if (lowerAscii(lhs) != lowerAscii(rhs)) return false;
    }
    return true;
}

fn buildEnvironmentBlockFromEntries(
    allocator: std.mem.Allocator,
    base_entries: []const []const u16,
    overrides: []const [:0]const u16,
) !?[]u16 {
    if (overrides.len == 0) return null;

    var builder = std.ArrayList(u16).empty;
    errdefer builder.deinit(allocator);

    for (base_entries) |entry| {
        var overridden = false;
        for (overrides) |override| {
            if (environmentKeyMatches(entry, override[0..override.len])) {
                overridden = true;
                break;
            }
        }
        if (!overridden) {
            try builder.appendSlice(allocator, entry);
            try builder.append(allocator, 0);
        }
    }

    for (overrides) |override| {
        try builder.appendSlice(allocator, override[0..override.len]);
        try builder.append(allocator, 0);
    }
    try builder.append(allocator, 0);
    return try builder.toOwnedSlice(allocator);
}

fn readerThread(param: ?*anyopaque) callconv(.winapi) c.DWORD {
    const state: *State = @ptrCast(@alignCast(param.?));
    var slot: usize = 0;

    while (state.running.load(.acquire) != 0) {
        var bytes_read: c.DWORD = 0;
        if (c.ReadFile(
            state.pty_output,
            state.output_buf[slot][0..].ptr,
            OUTPUT_BUFFER_SIZE,
            &bytes_read,
            null,
        ) == 0 or bytes_read == 0) {
            break;
        }

        c.EnterCriticalSection(&state.pending_lock);
        const available = state.pending_buf.len - state.pending_len;
        const copy_len = @min(available, @as(usize, @intCast(bytes_read)));
        if (copy_len > 0) {
            @memcpy(
                state.pending_buf[state.pending_len .. state.pending_len + copy_len],
                state.output_buf[slot][0..copy_len],
            );
            state.pending_len += copy_len;
        }
        c.LeaveCriticalSection(&state.pending_lock);

        notify(state.notify_fd);
        slot = (slot + 1) % state.output_buf.len;
    }

    state.running.store(0, .release);
    notify(state.notify_fd);
    return 0;
}

fn notify(fd: c_int) void {
    if (fd < 0) return;
    const signal = [_]u8{'1'};
    _ = c._write(fd, &signal, signal.len);
}

test "buildEnvironmentBlockFromEntries preserves base entries and overrides matching keys" {
    const base_path = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, "PATH=os");
    defer std.testing.allocator.free(base_path);
    const base_home = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, "HOME=/tmp");
    defer std.testing.allocator.free(base_home);
    const override_path = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, "PATH=override");
    defer std.testing.allocator.free(override_path);
    const override_term = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, "TERM=xterm");
    defer std.testing.allocator.free(override_term);

    const base_entries = [_][]const u16{ base_path, base_home };
    const overrides = [_][:0]const u16{ override_path, override_term };
    const block = (try buildEnvironmentBlockFromEntries(std.testing.allocator, &base_entries, &overrides)).?;
    defer std.testing.allocator.free(block);

    const expected = [_]u16{
        'H', 'O', 'M', 'E', '=', '/', 't', 'm', 'p', 0,
        'P', 'A', 'T', 'H', '=', 'o', 'v', 'e', 'r', 'r',
        'i', 'd', 'e', 0,   'T', 'E', 'R', 'M', '=', 'x',
        't', 'e', 'r', 'm', 0,   0,
    };
    try std.testing.expectEqualSlices(u16, &expected, block);
}

test "buildEnvironmentBlockFromEntries returns null for an empty override list" {
    const base_entries = [_][]const u16{};
    const overrides = [_][:0]const u16{};
    try std.testing.expectEqual(@as(?[]u16, null), try buildEnvironmentBlockFromEntries(std.testing.allocator, &base_entries, &overrides));
}

test "State keeps large buffers off-struct" {
    if (!is_windows) return;
    try std.testing.expect(@sizeOf(State) < 4096);
}

fn testSleepThread(_: ?*anyopaque) callconv(.winapi) c.DWORD {
    c.Sleep(200);
    return 0;
}

test "deinit returns without waiting for the reader thread" {
    if (!is_windows) return;

    const reader_thread = c.CreateThread(
        null,
        0,
        testSleepThread,
        null,
        0,
        null,
    ) orelse return error.CreateThreadFailed;

    const state = try std.heap.page_allocator.create(State);
    state.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena_alloc = state.arena.allocator();
    state.output_buf = try arena_alloc.create([2][OUTPUT_BUFFER_SIZE]u8);
    state.pending_buf = try arena_alloc.create([PENDING_BUFFER_SIZE]u8);
    state.hpc = null;
    state.pty_input = c.INVALID_HANDLE_VALUE;
    state.pty_output = c.INVALID_HANDLE_VALUE;
    state.shell_process = c.INVALID_HANDLE_VALUE;
    state.notify_fd = -1;
    state.pending_len = 0;
    state.running = std.atomic.Value(u8).init(1);
    c.InitializeCriticalSection(&state.pending_lock);
    state.reader_thread = reader_thread;

    const start = std.time.nanoTimestamp();
    deinit(state);
    const elapsed_ms = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp() - start, std.time.ns_per_ms)));
    try std.testing.expect(elapsed_ms < 100);

    c.Sleep(300);
}
