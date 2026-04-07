const builtin = @import("builtin");
const std = @import("std");

pub const vendored_emacs_include_dir = "include";

pub const EmacsIncludeSource = union(enum) {
    include_dir: []const u8,
    source_dir: []const u8,
    vendored,
};

const ModuleSpec = struct {
    name: []const u8,
    dir: []const u8,
    platform: Platform = .any,

    const Platform = enum {
        any,
        windows,
    };
};

const module_specs = [_]ModuleSpec{
    .{ .name = "dyn-loader", .dir = "src/dyn-loader" },
    .{ .name = "conpty", .dir = "src/conpty", .platform = .windows },
};

pub fn build(b: *std.Build) void {
    const default_target: std.Target.Query = if (builtin.os.tag == .windows)
        .{
            .cpu_arch = builtin.cpu.arch,
            .os_tag = .windows,
            .abi = .gnu,
        }
    else
        .{};
    const target = b.standardTargetOptions(.{
        .default_target = default_target,
    });
    const optimize = b.standardOptimizeOption(.{});
    const target_os = target.result.os.tag;

    _ = resolveEmacsIncludePath(b);

    const install_step = b.getInstallStep();
    const check_step = b.step("check", "Check the root build logic and any configured modules");
    const test_step = b.step("test", "Run root build tests and any configured module tests");

    const root_test_mod = b.createModule(.{
        .root_source_file = b.path("build.zig"),
        .target = target,
        .optimize = optimize,
    });
    const root_tests = b.addTest(.{
        .root_module = root_test_mod,
    });
    check_step.dependOn(&root_tests.step);
    const run_root_tests = b.addRunArtifact(root_tests);
    test_step.dependOn(&run_root_tests.step);

    for (module_specs) |module_spec| {
        if (!moduleSupportsTarget(module_spec, target_os)) continue;
        addModuleSteps(b, module_spec, install_step, check_step, test_step);
    }
}

pub fn resolveEmacsIncludePath(b: *std.Build) std.Build.LazyPath {
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
        .vendored => .{ .cwd_relative = vendoredEmacsIncludeDir() },
    };
}

pub fn resolveEmacsIncludeSource(
    emacs_include_dir: ?[]const u8,
    emacs_source_dir: ?[]const u8,
) EmacsIncludeSource {
    if (emacs_include_dir) |dir| return .{ .include_dir = dir };
    if (emacs_source_dir) |dir| return .{ .source_dir = dir };
    return .vendored;
}

pub fn vendoredEmacsIncludeDir() []const u8 {
    return vendored_emacs_include_dir;
}

fn addModuleSteps(
    b: *std.Build,
    module_spec: ModuleSpec,
    install_step: *std.Build.Step,
    check_step: *std.Build.Step,
    test_step: *std.Build.Step,
) void {
    const build_file = std.fs.path.join(b.allocator, &.{ module_spec.dir, "build.zig" }) catch |err|
        std.debug.panic("failed to resolve build file for {s}: {s}", .{
            module_spec.name,
            @errorName(err),
        });

    if (!pathExistsRelative(build_file)) return;

    const module_build_step = b.step(
        module_spec.name,
        b.fmt("Build the {s} module", .{module_spec.name}),
    );
    const install_cmd = addModuleCommand(b, module_spec.dir, "install");
    module_build_step.dependOn(&install_cmd.step);
    install_step.dependOn(&install_cmd.step);

    const check_cmd = addModuleCommand(b, module_spec.dir, "check");
    check_step.dependOn(&check_cmd.step);

    const test_cmd = addModuleCommand(b, module_spec.dir, "test");
    test_step.dependOn(&test_cmd.step);
}

fn addModuleCommand(
    b: *std.Build,
    module_dir: []const u8,
    build_step_name: []const u8,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{
        "zig",
        "build",
        "--build-file",
        "build.zig",
        build_step_name,
    });
    run.setCwd(b.path(module_dir));
    return run;
}

fn moduleSupportsTarget(module_spec: ModuleSpec, target_os: std.Target.Os.Tag) bool {
    return switch (module_spec.platform) {
        .any => true,
        .windows => target_os == .windows,
    };
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

fn pathExistsRelative(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

test "emacs include resolution prefers include dir override" {
    const source = resolveEmacsIncludeSource("C:/headers", "Q:/repos/emacs-build/git/master");
    try std.testing.expect(source == .include_dir);
    try std.testing.expectEqualStrings("C:/headers", source.include_dir);
}

test "emacs include resolution prefers source dir over vendored header" {
    const source = resolveEmacsIncludeSource(null, "Q:/repos/emacs-build/git/master");
    try std.testing.expect(source == .source_dir);
    try std.testing.expectEqualStrings("Q:/repos/emacs-build/git/master", source.source_dir);
}

test "emacs include resolution falls back to vendored header" {
    const source = resolveEmacsIncludeSource(null, null);
    try std.testing.expect(source == .vendored);
}

test "dyn-loader stays enabled on non-Windows targets" {
    try std.testing.expect(moduleSupportsTarget(module_specs[0], .linux));
    try std.testing.expect(moduleSupportsTarget(module_specs[0], .macos));
    try std.testing.expect(moduleSupportsTarget(module_specs[0], .windows));
}

test "conpty is only enabled on Windows targets" {
    try std.testing.expect(moduleSupportsTarget(module_specs[1], .windows));
    try std.testing.expect(!moduleSupportsTarget(module_specs[1], .linux));
    try std.testing.expect(!moduleSupportsTarget(module_specs[1], .macos));
}
