const builtin = @import("builtin");
const std = @import("std");

const EmacsIncludeSource = union(enum) {
    include_dir: []const u8,
    source_dir: []const u8,
    vendored,
};

pub fn build(b: *std.Build) void {
    const default_target: std.Target.Query = switch (builtin.os.tag) {
        .windows => .{
            .cpu_arch = builtin.cpu.arch,
            .os_tag = .windows,
            .abi = .gnu,
        },
        else => .{},
    };
    const target = b.standardTargetOptions(.{
        .default_target = default_target,
    });
    const optimize = b.standardOptimizeOption(.{});
    const strip_binaries = optimize != .Debug;
    const target_os = target.result.os.tag;
    const emacs_include = resolveEmacsIncludePath(b, target_os);

    const emacs_mod = b.createModule(.{
        .root_source_file = b.path("../shared/emacs.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip_binaries,
        .link_libc = true,
    });
    emacs_mod.addSystemIncludePath(emacs_include);

    const loader_mod = b.createModule(.{
        .root_source_file = b.path("module.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip_binaries,
        .link_libc = true,
    });
    addLoaderIncludes(loader_mod, emacs_include);
    loader_mod.addImport("emacs", emacs_mod);

    const loader_lib = b.addLibrary(.{
        .name = "dyn-loader-module",
        .linkage = .dynamic,
        .root_module = loader_mod,
    });
    addLoaderRuntimeLibraries(b, loader_lib, target.result);
    b.installArtifact(loader_lib);
    const copy_loader = b.addInstallFile(
        loader_lib.getEmittedBin(),
        loaderModuleOutputName(target_os),
    );
    b.getInstallStep().dependOn(&copy_loader.step);

    const loader_check_mod = b.createModule(.{
        .root_source_file = b.path("module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addLoaderIncludes(loader_check_mod, emacs_include);
    loader_check_mod.addImport("emacs", emacs_mod);
    const loader_check_obj = b.addObject(.{
        .name = "dyn-loader-module-check",
        .root_module = loader_check_mod,
    });

    const check = b.step("check", "Check that dyn-loader compiles");
    check.dependOn(&loader_check_obj.step);

    const loader_test_mod = b.createModule(.{
        .root_source_file = b.path("module.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addLoaderIncludes(loader_test_mod, emacs_include);
    loader_test_mod.addImport("emacs", emacs_mod);
    const loader_tests = b.addTest(.{
        .root_module = loader_test_mod,
    });
    addLoaderRuntimeLibraries(b, loader_tests, target.result);

    const run_loader_tests = b.addRunArtifact(loader_tests);
    const test_step = b.step("test", "Run dyn-loader Zig unit tests");
    test_step.dependOn(&run_loader_tests.step);
}

fn addLoaderIncludes(mod: *std.Build.Module, emacs_include: std.Build.LazyPath) void {
    mod.addSystemIncludePath(emacs_include);
}

fn resolveEmacsIncludePath(b: *std.Build, target_os: std.Target.Os.Tag) std.Build.LazyPath {
    _ = target_os;
    return switch (resolveEmacsIncludeSource(
        b.graph.env_map.get("EMACS_INCLUDE_DIR"),
        b.graph.env_map.get("EMACS_SOURCE_DIR"),
    )) {
        .include_dir => |dir| .{ .cwd_relative = dir },
        .source_dir => |dir| blk: {
            const generated = b.addWriteFiles();
            const header = generateEmacsModuleHeader(b.allocator, dir) catch |err|
                std.debug.panic("failed to generate emacs-module.h from {s}: {s}", .{
                    dir,
                    @errorName(err),
                });
            _ = generated.add("emacs-module.h", header);
            break :blk generated.getDirectory();
        },
        .vendored => b.path("../../include"),
    };
}

fn resolveEmacsIncludeSource(
    emacs_include_dir: ?[]const u8,
    emacs_source_dir: ?[]const u8,
) EmacsIncludeSource {
    if (emacs_include_dir) |dir| return .{ .include_dir = dir };
    if (emacs_source_dir) |dir| return .{ .source_dir = dir };
    return .vendored;
}

fn generateEmacsModuleHeader(allocator: std.mem.Allocator, source_dir: []const u8) ![]u8 {
    const src_dir = try std.fs.path.join(allocator, &.{ source_dir, "src" });
    defer allocator.free(src_dir);

    const template_path = try std.fs.path.join(allocator, &.{ src_dir, "emacs-module.in.h" });
    defer allocator.free(template_path);

    var header = try readFileAllocAbsolute(allocator, template_path);
    errdefer allocator.free(header);

    const major_version = try detectEmacsModuleVersion(allocator, src_dir);
    const version_text = try std.fmt.allocPrint(allocator, "{d}", .{major_version});
    defer allocator.free(version_text);

    header = try replaceOwned(allocator, header, "@emacs_major_version@", version_text);

    var version: usize = 25;
    while (version <= major_version) : (version += 1) {
        const fragment_name = try std.fmt.allocPrint(allocator, "module-env-{d}.h", .{version});
        defer allocator.free(fragment_name);
        const fragment_path = try std.fs.path.join(allocator, &.{ src_dir, fragment_name });
        defer allocator.free(fragment_path);
        const fragment = try readFileAllocAbsolute(allocator, fragment_path);
        defer allocator.free(fragment);

        const placeholder = try std.fmt.allocPrint(allocator, "@module_env_snippet_{d}@", .{version});
        defer allocator.free(placeholder);

        header = try replaceOwned(allocator, header, placeholder, fragment);
    }

    return header;
}

fn detectEmacsModuleVersion(allocator: std.mem.Allocator, src_dir: []const u8) !usize {
    var max_version: usize = 0;
    var version: usize = 25;
    while (version < 80) : (version += 1) {
        const fragment_name = try std.fmt.allocPrint(allocator, "module-env-{d}.h", .{version});
        defer allocator.free(fragment_name);
        const fragment_path = try std.fs.path.join(allocator, &.{ src_dir, fragment_name });
        defer allocator.free(fragment_path);

        if (pathExistsAbsolute(fragment_path)) {
            max_version = version;
        }
    }

    if (max_version == 0) return error.EmacsModuleFragmentsNotFound;
    return max_version;
}

fn replaceOwned(
    allocator: std.mem.Allocator,
    text: []u8,
    needle: []const u8,
    replacement: []const u8,
) ![]u8 {
    const replaced = try std.mem.replaceOwned(u8, allocator, text, needle, replacement);
    allocator.free(text);
    return replaced;
}

fn readFileAllocAbsolute(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    return try file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

fn pathExistsAbsolute(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn addLoaderRuntimeLibraries(
    b: *std.Build,
    step: *std.Build.Step.Compile,
    resolved_target: std.Target,
) void {
    switch (resolved_target.os.tag) {
        .windows => {
            step.linkSystemLibrary("kernel32");
            switch (resolved_target.abi) {
                .msvc => {
                    step.linkSystemLibrary("libvcruntime");

                    var libc = std.zig.LibCInstallation.findNative(.{
                        .allocator = b.allocator,
                        .verbose = false,
                        .target = &resolved_target,
                    }) catch null;
                    if (libc) |*installation| {
                        defer installation.deinit(b.allocator);
                        if (installation.crt_dir) |crt_dir| {
                            step.addLibraryPath(.{ .cwd_relative = crt_dir });
                        }
                    }
                },
                else => {},
            }
        },
        .linux, .freebsd, .netbsd, .openbsd, .dragonfly, .solaris => step.linkSystemLibrary("dl"),
        else => {},
    }
}

fn loaderModuleOutputName(target_os: std.Target.Os.Tag) []const u8 {
    return switch (target_os) {
        .macos => "bin/dyn-loader-module.dylib",
        .windows => "bin/dyn-loader-module.dll",
        else => "bin/dyn-loader-module.so",
    };
}

test "emacs include resolution prefers include dir override" {
    const source = resolveEmacsIncludeSource("fixtures/headers", "fixtures/emacs-source");
    try std.testing.expect(source == .include_dir);
    try std.testing.expectEqualStrings("fixtures/headers", source.include_dir);
}

test "emacs include resolution prefers source dir over vendored header" {
    const source = resolveEmacsIncludeSource(null, "fixtures/emacs-source");
    try std.testing.expect(source == .source_dir);
    try std.testing.expectEqualStrings("fixtures/emacs-source", source.source_dir);
}

test "emacs include resolution falls back to vendored header" {
    const source = resolveEmacsIncludeSource(null, null);
    try std.testing.expect(source == .vendored);
}
