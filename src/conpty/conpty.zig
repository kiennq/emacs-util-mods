const builtin = @import("builtin");
const std = @import("std");
const emacs = @import("emacs");

const is_windows = builtin.os.tag == .windows;

const c = if (is_windows)
    @cImport({
        @cInclude("windows.h");
        @cInclude("tlhelp32.h");
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

const NotifyCrtProvider = enum {
    msvcrt,
    ucrt,
};

const NotifyCrtWriteFn = *const fn (c_int, ?*const anyopaque, c_uint) callconv(.c) c_int;
const NotifyCrtCloseFn = *const fn (c_int) callconv(.c) c_int;

const NotifyCrt = struct {
    write: NotifyCrtWriteFn,
    close: NotifyCrtCloseFn,
};

const ConhostProcess = if (is_windows) struct {
    pid: c.DWORD,
    parent_pid: c.DWORD,
} else struct {};

const ResizeRequest = struct {
    rows: u16,
    cols: u16,
};

const ResizeQueue = struct {
    pending: bool = false,
    request: ResizeRequest = .{ .rows = 0, .cols = 0 },

    fn push(self: *ResizeQueue, request: ResizeRequest) void {
        self.pending = true;
        self.request = request;
    }

    fn pop(self: *ResizeQueue) ?ResizeRequest {
        if (!self.pending) return null;
        self.pending = false;
        return self.request;
    }
};

fn notifyCrtProviderForImport(dll_name: []const u8, symbol_name: []const u8) ?NotifyCrtProvider {
    if (!std.mem.eql(u8, symbol_name, "_dup")) return null;

    if (std.ascii.eqlIgnoreCase(dll_name, "msvcrt.dll")) return .msvcrt;
    if (std.ascii.eqlIgnoreCase(dll_name, "ucrtbase.dll")) return .ucrt;
    if (std.ascii.startsWithIgnoreCase(dll_name, "api-ms-win-crt-")) return .ucrt;
    return null;
}

fn ptrFromRva(comptime T: type, base: usize, rva: c.DWORD) *const T {
    return @ptrFromInt(base + @as(usize, @intCast(rva)));
}

fn cStringFromRva(base: usize, rva: c.DWORD) []const u8 {
    const ptr: [*:0]const u8 = @ptrFromInt(base + @as(usize, @intCast(rva)));
    return std.mem.span(ptr);
}

fn importDescriptorHasSymbol(base: usize, descriptor: *const c.IMAGE_IMPORT_DESCRIPTOR, symbol_name: []const u8) bool {
    const thunk_rva = if (descriptor.unnamed_0.OriginalFirstThunk != 0)
        descriptor.unnamed_0.OriginalFirstThunk
    else
        descriptor.FirstThunk;
    if (thunk_rva == 0) return false;

    const thunks: [*]const c.IMAGE_THUNK_DATA = @ptrFromInt(base + @as(usize, @intCast(thunk_rva)));
    var i: usize = 0;
    while (thunks[i].u1.AddressOfData != 0) : (i += 1) {
        const address = thunks[i].u1.AddressOfData;
        const ordinal_flag = @as(@TypeOf(address), 1) << (@bitSizeOf(@TypeOf(address)) - 1);
        if ((address & ordinal_flag) != 0) continue;

        const import_by_name = ptrFromRva(c.IMAGE_IMPORT_BY_NAME, base, @intCast(address));
        const name_addr = @intFromPtr(import_by_name) + @offsetOf(c.IMAGE_IMPORT_BY_NAME, "Name");
        const import_name: [*:0]const u8 = @ptrFromInt(name_addr);
        if (std.mem.eql(u8, std.mem.span(import_name), symbol_name)) return true;
    }
    return false;
}

fn findNotifyCrtProviderInImage(module: c.HMODULE) ?NotifyCrtProvider {
    const base = @intFromPtr(module);
    const dos = ptrFromRva(c.IMAGE_DOS_HEADER, base, 0);
    if (dos.e_magic != c.IMAGE_DOS_SIGNATURE or dos.e_lfanew < 0) return null;

    const nt: *const c.IMAGE_NT_HEADERS = @ptrFromInt(base + @as(usize, @intCast(dos.e_lfanew)));
    if (nt.Signature != c.IMAGE_NT_SIGNATURE) return null;

    const import_index: usize = @intCast(c.IMAGE_DIRECTORY_ENTRY_IMPORT);
    if (nt.OptionalHeader.NumberOfRvaAndSizes <= import_index) return null;
    const import_directory = nt.OptionalHeader.DataDirectory[import_index];
    if (import_directory.VirtualAddress == 0) return null;

    const descriptors: [*]const c.IMAGE_IMPORT_DESCRIPTOR = @ptrFromInt(base + @as(usize, @intCast(import_directory.VirtualAddress)));
    var i: usize = 0;
    while (descriptors[i].Name != 0) : (i += 1) {
        const dll_name = cStringFromRva(base, descriptors[i].Name);
        if (importDescriptorHasSymbol(base, &descriptors[i], "_dup")) {
            if (notifyCrtProviderForImport(dll_name, "_dup")) |provider| return provider;
        }
    }
    return null;
}

fn detectNotifyCrtProvider() !NotifyCrtProvider {
    const module = c.GetModuleHandleW(null) orelse return error.NotifyCrtUnavailable;
    return findNotifyCrtProviderInImage(module) orelse error.NotifyCrtUnavailable;
}

fn resolveNotifyCrt() !NotifyCrt {
    const provider = try detectNotifyCrtProvider();
    const dll_name = switch (provider) {
        .msvcrt => std.unicode.utf8ToUtf16LeStringLiteral("msvcrt.dll"),
        .ucrt => std.unicode.utf8ToUtf16LeStringLiteral("ucrtbase.dll"),
    };
    const module = c.GetModuleHandleW(dll_name) orelse return error.NotifyCrtUnavailable;
    const write_proc = c.GetProcAddress(module, "_write") orelse return error.NotifyCrtUnavailable;
    const close_proc = c.GetProcAddress(module, "_close") orelse return error.NotifyCrtUnavailable;
    return .{
        .write = @ptrCast(write_proc),
        .close = @ptrCast(close_proc),
    };
}

pub const State = if (is_windows) struct {
    arena: std.heap.ArenaAllocator,
    hpc: HPCON = null,
    pty_input: c.HANDLE = c.INVALID_HANDLE_VALUE,
    pty_output: c.HANDLE = c.INVALID_HANDLE_VALUE,
    shell_process: c.HANDLE = c.INVALID_HANDLE_VALUE,
    conhost_process: c.HANDLE = c.INVALID_HANDLE_VALUE,
    reader_thread: c.HANDLE = c.INVALID_HANDLE_VALUE,
    resize_thread: c.HANDLE = c.INVALID_HANDLE_VALUE,
    resize_event: c.HANDLE = c.INVALID_HANDLE_VALUE,
    notify_fd: c_int = -1,
    notify_crt: NotifyCrt,
    pending_lock: c.CRITICAL_SECTION = undefined,
    resize_lock: c.CRITICAL_SECTION = undefined,
    output_buf: *[2][OUTPUT_BUFFER_SIZE]u8,
    pending_buf: *[PENDING_BUFFER_SIZE]u8,
    pending_len: usize = 0,
    resize_queue: ResizeQueue = .{},
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
    const notify_crt = try resolveNotifyCrt();

    const state = try std.heap.page_allocator.create(State);
    var state_owned_by_init = true;
    errdefer if (state_owned_by_init) std.heap.page_allocator.destroy(state);

    state.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var arena_owned_by_init = true;
    errdefer if (arena_owned_by_init) state.arena.deinit();

    const arena_alloc = state.arena.allocator();
    state.output_buf = try arena_alloc.create([2][OUTPUT_BUFFER_SIZE]u8);
    state.pending_buf = try arena_alloc.create([PENDING_BUFFER_SIZE]u8);

    state.hpc = null;
    state.pty_input = c.INVALID_HANDLE_VALUE;
    state.pty_output = c.INVALID_HANDLE_VALUE;
    state.shell_process = c.INVALID_HANDLE_VALUE;
    state.conhost_process = c.INVALID_HANDLE_VALUE;
    state.reader_thread = c.INVALID_HANDLE_VALUE;
    state.resize_thread = c.INVALID_HANDLE_VALUE;
    state.resize_event = c.INVALID_HANDLE_VALUE;
    state.notify_fd = -1;
    state.notify_crt = notify_crt;
    state.pending_len = 0;
    state.resize_queue = .{};
    state.running = std.atomic.Value(u8).init(1);

    c.InitializeCriticalSection(&state.pending_lock);
    var pending_lock_initialized = true;
    errdefer if (pending_lock_initialized) c.DeleteCriticalSection(&state.pending_lock);

    c.InitializeCriticalSection(&state.resize_lock);
    var resize_lock_initialized = true;
    errdefer if (resize_lock_initialized) c.DeleteCriticalSection(&state.resize_lock);

    state.resize_event = c.CreateEventW(null, c.FALSE, c.FALSE, null) orelse return error.CreateResizeEventFailed;
    var resize_event_owned_by_init = true;
    errdefer if (resize_event_owned_by_init) {
        _ = c.CloseHandle(state.resize_event);
        state.resize_event = c.INVALID_HANDLE_VALUE;
    };

    state.notify_fd = env.openChannel(process);
    if (state.notify_fd < 0) return error.OpenChannelFailed;
    var notify_fd_owned_by_init = true;
    errdefer if (notify_fd_owned_by_init) {
        closeNotifyFd(state);
    };

    try createConpty(state, rows, cols);
    state_owned_by_init = false;
    arena_owned_by_init = false;
    pending_lock_initialized = false;
    resize_lock_initialized = false;
    resize_event_owned_by_init = false;
    notify_fd_owned_by_init = false;
    errdefer deinit(state);

    try spawnShell(state, env, shell_command, working_directory, environment_overrides, allocator);

    state.resize_thread = c.CreateThread(
        null,
        0,
        resizeThread,
        state,
        0,
        null,
    ) orelse return error.CreateResizeThreadFailed;

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

    if (state.reader_thread == c.INVALID_HANDLE_VALUE) {
        if (state.resize_thread != c.INVALID_HANDLE_VALUE) {
            startCleanupThread(state);
            return;
        }
        finalizeState(state);
        return;
    }

    startCleanupThread(state);
}

fn startCleanupThread(state: *State) void {
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
    }
}

fn requestShutdown(state: *State) void {
    state.running.store(0, .release);
    signalResizeWorker(state);

    terminateProcessHandle(&state.shell_process);
    terminateProcessHandle(&state.conhost_process);

    if (state.pty_input != c.INVALID_HANDLE_VALUE) {
        _ = c.CloseHandle(state.pty_input);
        state.pty_input = c.INVALID_HANDLE_VALUE;
    }

    if (state.reader_thread != c.INVALID_HANDLE_VALUE) {
        _ = c.CancelSynchronousIo(state.reader_thread);
    }

    if (state.pty_output != c.INVALID_HANDLE_VALUE) {
        _ = c.CloseHandle(state.pty_output);
        state.pty_output = c.INVALID_HANDLE_VALUE;
    }
}

fn waitForReaderThread(state: *State, timeout_ms: c.DWORD) bool {
    if (state.reader_thread == c.INVALID_HANDLE_VALUE) return true;
    if (c.WaitForSingleObject(state.reader_thread, timeout_ms) != c.WAIT_OBJECT_0) return false;
    _ = c.CloseHandle(state.reader_thread);
    state.reader_thread = c.INVALID_HANDLE_VALUE;
    return true;
}

fn waitForResizeThread(state: *State, timeout_ms: c.DWORD) bool {
    if (state.resize_thread == c.INVALID_HANDLE_VALUE) return true;
    if (c.WaitForSingleObject(state.resize_thread, timeout_ms) != c.WAIT_OBJECT_0) return false;
    _ = c.CloseHandle(state.resize_thread);
    state.resize_thread = c.INVALID_HANDLE_VALUE;
    return true;
}

fn terminateProcessHandle(process: *c.HANDLE) void {
    if (process.* == c.INVALID_HANDLE_VALUE) return;

    var should_terminate = true;
    var exit_code: c.DWORD = 0;
    if (c.GetExitCodeProcess(process.*, &exit_code) != 0) {
        should_terminate = exit_code == c.STILL_ACTIVE;
    }
    if (should_terminate) {
        _ = c.TerminateProcess(process.*, 1);
    }

    _ = c.CloseHandle(process.*);
    process.* = c.INVALID_HANDLE_VALUE;
}

fn closeNotifyFd(state: *State) void {
    if (state.notify_fd >= 0) {
        _ = state.notify_crt.close(state.notify_fd);
        state.notify_fd = -1;
    }
}

fn finalizeState(state: *State) void {
    if (state.hpc != null) {
        close_pseudo_console.?(state.hpc);
        state.hpc = null;
    }

    if (state.resize_event != c.INVALID_HANDLE_VALUE) {
        _ = c.CloseHandle(state.resize_event);
        state.resize_event = c.INVALID_HANDLE_VALUE;
    }

    closeNotifyFd(state);

    c.DeleteCriticalSection(&state.resize_lock);
    c.DeleteCriticalSection(&state.pending_lock);
    state.arena.deinit();
    std.heap.page_allocator.destroy(state);
}

fn cleanupThread(param: ?*anyopaque) callconv(.winapi) c.DWORD {
    const state: *State = @ptrCast(@alignCast(param.?));
    if (waitForReaderThread(state, c.INFINITE) and
        waitForResizeThread(state, c.INFINITE))
    {
        finalizeState(state);
    }
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
    const queued = queueResize(state, .{ .rows = rows, .cols = cols });
    if (queued) notify(state);
    return queued;
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

fn queueResize(state: *State, request: ResizeRequest) bool {
    if (state.running.load(.acquire) == 0) return false;
    if (state.resize_event == c.INVALID_HANDLE_VALUE) return false;

    c.EnterCriticalSection(&state.resize_lock);
    state.resize_queue.push(request);
    c.LeaveCriticalSection(&state.resize_lock);

    return c.SetEvent(state.resize_event) != 0;
}

fn takeResizeRequest(state: *State) ?ResizeRequest {
    c.EnterCriticalSection(&state.resize_lock);
    defer c.LeaveCriticalSection(&state.resize_lock);
    return state.resize_queue.pop();
}

fn signalResizeWorker(state: *State) void {
    if (state.resize_event != c.INVALID_HANDLE_VALUE) {
        _ = c.SetEvent(state.resize_event);
    }
}

fn resizeThread(param: ?*anyopaque) callconv(.winapi) c.DWORD {
    const state: *State = @ptrCast(@alignCast(param.?));

    while (state.running.load(.acquire) != 0) {
        if (c.WaitForSingleObject(state.resize_event, c.INFINITE) != c.WAIT_OBJECT_0) break;
        if (state.running.load(.acquire) == 0) break;

        while (takeResizeRequest(state)) |request| {
            if (state.running.load(.acquire) == 0) break;
            _ = resizePseudoConsole(state, request);
            notify(state);
        }
    }

    return 0;
}

fn resizePseudoConsole(state: *State, request: ResizeRequest) bool {
    if (state.hpc == null) return false;
    const size = c.COORD{
        .X = @intCast(request.cols),
        .Y = @intCast(request.rows),
    };
    return resize_pseudo_console.?(state.hpc, size) >= 0;
}

fn createConpty(state: *State, rows: u16, cols: u16) !void {
    const allocator = std.heap.page_allocator;
    const existing_conhosts = collectConhostProcesses(allocator) catch null;
    defer if (existing_conhosts) |processes| allocator.free(processes);

    var in_read: c.HANDLE = c.INVALID_HANDLE_VALUE;
    var in_write: c.HANDLE = c.INVALID_HANDLE_VALUE;
    var out_read: c.HANDLE = c.INVALID_HANDLE_VALUE;
    var out_write: c.HANDLE = c.INVALID_HANDLE_VALUE;
    errdefer {
        terminateProcessHandle(&state.conhost_process);
        if (state.hpc != null) {
            close_pseudo_console.?(state.hpc);
            state.hpc = null;
        }
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
    if (existing_conhosts) |processes| {
        state.conhost_process = openCreatedConhostProcess(allocator, processes);
    }

    state.pty_input = in_write;
    state.pty_output = out_read;

    _ = c.CloseHandle(in_read);
    _ = c.CloseHandle(out_write);
}

fn collectConhostProcesses(allocator: std.mem.Allocator) ![]ConhostProcess {
    var processes = std.ArrayList(ConhostProcess).empty;
    errdefer processes.deinit(allocator);

    const snapshot = c.CreateToolhelp32Snapshot(c.TH32CS_SNAPPROCESS, 0);
    if (snapshot == c.INVALID_HANDLE_VALUE) return error.ProcessSnapshotFailed;
    defer _ = c.CloseHandle(snapshot);

    var entry = std.mem.zeroes(c.PROCESSENTRY32W);
    entry.dwSize = @sizeOf(c.PROCESSENTRY32W);
    if (c.Process32FirstW(snapshot, &entry) == 0) return error.ProcessSnapshotFailed;

    while (true) {
        if (wideStringEqualsAsciiIgnoreCase(entry.szExeFile[0..], "conhost.exe")) {
            try processes.append(allocator, .{
                .pid = entry.th32ProcessID,
                .parent_pid = entry.th32ParentProcessID,
            });
        }
        if (c.Process32NextW(snapshot, &entry) == 0) {
            if (c.GetLastError() == c.ERROR_NO_MORE_FILES) break;
            return error.ProcessSnapshotFailed;
        }
    }

    return try processes.toOwnedSlice(allocator);
}

fn openCreatedConhostProcess(allocator: std.mem.Allocator, existing_conhosts: []const ConhostProcess) c.HANDLE {
    const current_conhosts = collectConhostProcesses(allocator) catch return c.INVALID_HANDLE_VALUE;
    defer allocator.free(current_conhosts);

    const pid = createdConhostPid(
        existing_conhosts,
        current_conhosts,
        c.GetCurrentProcessId(),
    ) orelse return c.INVALID_HANDLE_VALUE;
    return c.OpenProcess(c.PROCESS_TERMINATE, c.FALSE, pid) orelse c.INVALID_HANDLE_VALUE;
}

fn createdConhostPid(
    existing_conhosts: []const ConhostProcess,
    current_conhosts: []const ConhostProcess,
    parent_pid: c.DWORD,
) ?c.DWORD {
    var found_pid: ?c.DWORD = null;
    for (current_conhosts) |process| {
        if (process.parent_pid != parent_pid) continue;
        if (containsProcessPid(existing_conhosts, process.pid)) continue;
        if (found_pid != null) return null;
        found_pid = process.pid;
    }
    return found_pid;
}

fn containsProcessPid(processes: []const ConhostProcess, pid: c.DWORD) bool {
    for (processes) |process| {
        if (process.pid == pid) return true;
    }
    return false;
}

fn wideStringEqualsAsciiIgnoreCase(wide: []const c.WCHAR, ascii: []const u8) bool {
    const wide_name = std.mem.sliceTo(wide, 0);
    if (wide_name.len != ascii.len) return false;

    for (wide_name, ascii) |wide_char, ascii_char| {
        if (lowerAscii(@intCast(wide_char)) != lowerAscii(ascii_char)) return false;
    }
    return true;
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
    while (env.isNotNil(iter)) {
        const item = env.f("car", .{iter});
        var item_buf: ?[]u8 = null;
        const item_utf8 = env.extractStringAlloc(allocator, item, &item_buf) catch
            return error.InvalidEnvironmentEntry;
        defer if (item_buf) |buf| allocator.free(buf);
        try overrides.append(allocator, try std.unicode.utf8ToUtf16LeAllocZ(allocator, item_utf8));
        iter = env.f("cdr", .{iter});
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

fn environmentEntryHasValue(entry: []const u16) bool {
    return std.mem.indexOfScalar(u16, entry, '=') != null;
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
        if (!environmentEntryHasValue(override[0..override.len])) continue;
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

        notify(state);
        slot = (slot + 1) % state.output_buf.len;
    }

    state.running.store(0, .release);
    notify(state);
    return 0;
}

fn notify(state: *State) void {
    if (state.notify_fd < 0) return;
    const signal = [_]u8{'1'};
    _ = state.notify_crt.write(
        state.notify_fd,
        @as(?*const anyopaque, @ptrCast(signal[0..].ptr)),
        @intCast(signal.len),
    );
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

test "module cleanup paths use fire-and-forget teardown" {
    const source = @embedFile("module.zig");
    try std.testing.expect(std.mem.indexOf(u8, source, "Conpty.deinitSync") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "Conpty.deinit(") != null);
}

test "shutdown forcibly terminates captured conhost process" {
    const source = @embedFile("conpty.zig");
    try std.testing.expect(std.mem.indexOf(u8, source, "conhost_" ++ "process: c.HANDLE = c.INVALID_HANDLE_VALUE") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "terminateProcessHandle(&state.conhost_" ++ "process)") != null);
}

test "createdConhostPid ignores unrelated new conhosts" {
    if (!is_windows) return;

    const existing = [_]ConhostProcess{
        .{ .pid = 10, .parent_pid = 100 },
    };
    const current = [_]ConhostProcess{
        .{ .pid = 10, .parent_pid = 100 },
        .{ .pid = 20, .parent_pid = 200 },
        .{ .pid = 30, .parent_pid = 100 },
    };

    try std.testing.expectEqual(
        @as(?c.DWORD, 30),
        createdConhostPid(&existing, &current, 100),
    );
}

test "createdConhostPid refuses ambiguous owned conhosts" {
    if (!is_windows) return;

    const existing = [_]ConhostProcess{};
    const current = [_]ConhostProcess{
        .{ .pid = 20, .parent_pid = 100 },
        .{ .pid = 30, .parent_pid = 100 },
    };

    try std.testing.expectEqual(
        @as(?c.DWORD, null),
        createdConhostPid(&existing, &current, 100),
    );
}

test "notify CRT provider follows the CRT that owns Emacs dup" {
    try std.testing.expectEqual(
        NotifyCrtProvider.msvcrt,
        notifyCrtProviderForImport("msvcrt.dll", "_dup").?,
    );
    try std.testing.expectEqual(
        NotifyCrtProvider.ucrt,
        notifyCrtProviderForImport("api-ms-win-crt-stdio-l1-1-0.dll", "_dup").?,
    );
    try std.testing.expectEqual(
        NotifyCrtProvider.ucrt,
        notifyCrtProviderForImport("ucrtbase.dll", "_dup").?,
    );
}

test "notify CRT provider ignores non-dup CRT imports" {
    try std.testing.expectEqual(
        @as(?NotifyCrtProvider, null),
        notifyCrtProviderForImport("msvcrt.dll", "_write"),
    );
    try std.testing.expectEqual(
        @as(?NotifyCrtProvider, null),
        notifyCrtProviderForImport("kernel32.dll", "_dup"),
    );
}

test "notify channel avoids module CRT fd operations" {
    const source = @embedFile("conpty.zig");
    try std.testing.expect(std.mem.indexOf(u8, source, "c." ++ "_write") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "c." ++ "_close") == null);
}

test "public resize queues work instead of resizing inline" {
    const source = @embedFile("conpty.zig");
    const resize_start = std.mem.indexOf(u8, source, "pub fn resize(").?;
    const is_alive_start = std.mem.indexOfPos(u8, source, resize_start, "pub fn isAlive(").?;
    const resize_body = source[resize_start..is_alive_start];

    try std.testing.expect(std.mem.indexOf(u8, resize_body, "resize_pseudo_console") == null);
    try std.testing.expect(std.mem.indexOf(u8, resize_body, "queueResize") != null);
}

test "buildEnvironmentBlockFromEntries treats bare overrides as unsets" {
    const base_path = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, "PATH=os");
    defer std.testing.allocator.free(base_path);
    const base_prompt = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, "PROMPT_COMMAND=old");
    defer std.testing.allocator.free(base_prompt);
    const base_home = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, "HOME=/tmp");
    defer std.testing.allocator.free(base_home);
    const override_path = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, "PATH=override");
    defer std.testing.allocator.free(override_path);
    const unset_prompt = try std.unicode.utf8ToUtf16LeAllocZ(std.testing.allocator, "PROMPT_COMMAND");
    defer std.testing.allocator.free(unset_prompt);

    const base_entries = [_][]const u16{ base_path, base_prompt, base_home };
    const overrides = [_][:0]const u16{ override_path, unset_prompt };
    const block = (try buildEnvironmentBlockFromEntries(std.testing.allocator, &base_entries, &overrides)).?;
    defer std.testing.allocator.free(block);

    const expected = [_]u16{
        'H', 'O', 'M', 'E', '=', '/', 't', 'm', 'p', 0,
        'P', 'A', 'T', 'H', '=', 'o', 'v', 'e', 'r', 'r',
        'i', 'd', 'e', 0,   0,
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
    state.notify_crt = undefined;
    state.resize_thread = c.INVALID_HANDLE_VALUE;
    state.resize_event = c.INVALID_HANDLE_VALUE;
    state.resize_queue = .{};
    state.pending_len = 0;
    state.running = std.atomic.Value(u8).init(1);
    c.InitializeCriticalSection(&state.pending_lock);
    c.InitializeCriticalSection(&state.resize_lock);
    state.reader_thread = reader_thread;

    const start = std.time.nanoTimestamp();
    deinit(state);
    const elapsed_ms = @as(u64, @intCast(@divTrunc(std.time.nanoTimestamp() - start, std.time.ns_per_ms)));
    try std.testing.expect(elapsed_ms < 100);

    c.Sleep(300);
}
