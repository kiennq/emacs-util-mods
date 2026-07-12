param(
  [Parameter(Mandatory = $true)]
  [string]$OutputDir,

  [string]$IncludeDir = (Join-Path (Split-Path -Parent $PSScriptRoot) 'include')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ModuleExtension {
  if ($IsWindows) { return '.dll' }
  if ($IsMacOS) { return '.dylib' }
  return '.so'
}

function Get-TargetArgs {
  if ($IsWindows) {
    return @('-target', 'x86_64-windows-gnu')
  }

  return @()
}

function Get-FixtureSource([string]$Version, [int]$ReturnValue, [int]$VariableValue, [int]$MinArity, [int]$MaxArity) {
  $template = @'
const c = @cImport({
    @cInclude("emacs-module.h");
    @cInclude("stdlib.h");
});

const DispatchFn = *const fn (u32, ?*c.emacs_env, isize, [*c]c.emacs_value, ?*anyopaque) callconv(.c) c.emacs_value;
const VariableGetFn = *const fn (u32, ?*c.emacs_env, ?*anyopaque) callconv(.c) c.emacs_value;
const VariableSetFn = *const fn (u32, ?*c.emacs_env, c.emacs_value, ?*anyopaque) callconv(.c) c.emacs_value;
const ExportDescriptor = extern struct {
    export_id: u32,
    kind: u32,
    lisp_name: [*:0]const u8,
    min_arity: i32,
    max_arity: i32,
    docstring: [*:0]const u8,
    flags: u32,
};

const GenericManifest = extern struct {
    loader_abi: u32,
    module_id: [*:0]const u8,
    module_version: [*:0]const u8,
    exports_len: u32,
    exports: [*]const ExportDescriptor,
    invoke: DispatchFn,
    get_variable: VariableGetFn,
    set_variable: VariableSetFn,
};

const ExportKind = enum(u32) {
    function = 1,
    variable = 2,
};

var variable_value: i64 = __VARIABLE_VALUE__;

const FixtureObject = extern struct {
    marker: i64,
};

fn makeInteger(raw_env: ?*c.emacs_env, value: i64) c.emacs_value {
    const env = raw_env orelse unreachable;
    return env.make_integer.?(env, @as(c.intmax_t, @intCast(value)));
}

fn makeNil(raw_env: ?*c.emacs_env) c.emacs_value {
    const env = raw_env orelse unreachable;
    return env.intern.?(env, "nil");
}

fn fixtureObjectFinalize(ptr: ?*anyopaque) callconv(.c) void {
    c.free(ptr);
}

fn makeFixtureObject(raw_env: ?*c.emacs_env) c.emacs_value {
    const env = raw_env orelse unreachable;
    const ptr = c.malloc(@sizeOf(FixtureObject)) orelse return makeNil(raw_env);
    const object: *FixtureObject = @ptrCast(@alignCast(ptr));
    object.* = .{ .marker = __RETURN_VALUE__ };
    return env.make_user_ptr.?(env, &fixtureObjectFinalize, object);
}

fn makeNullFixtureObject(raw_env: ?*c.emacs_env) c.emacs_value {
    const env = raw_env orelse unreachable;
    return env.make_user_ptr.?(env, &fixtureObjectFinalize, null);
}

export fn fixtureInvoke(export_id: u32, raw_env: ?*c.emacs_env, nargs: isize, args: [*c]c.emacs_value, data: ?*anyopaque) callconv(.c) c.emacs_value {
    _ = data;

    return switch (export_id) {
        1 => makeInteger(raw_env, __RETURN_VALUE__),
        3 => makeFixtureObject(raw_env),
        4 => blk: {
            if (nargs != 1) break :blk makeNil(raw_env);
            const env = raw_env orelse unreachable;
            const ptr = env.get_user_ptr.?(env, args[0]) orelse
                break :blk makeInteger(raw_env, __RETURN_VALUE__);
            const object: *FixtureObject = @ptrCast(@alignCast(ptr));
            if (object.marker <= 0) break :blk makeNil(raw_env);
            break :blk makeInteger(raw_env, __RETURN_VALUE__);
        },
        5 => makeNullFixtureObject(raw_env),
        6 => blk: {
            if (nargs != 1) break :blk makeNil(raw_env);
            const env = raw_env orelse unreachable;
            const old_ptr = env.get_user_ptr.?(env, args[0]) orelse
                break :blk makeNil(raw_env);
            const new_ptr = c.malloc(@sizeOf(FixtureObject)) orelse
                break :blk makeNil(raw_env);
            const object: *FixtureObject = @ptrCast(@alignCast(new_ptr));
            object.* = .{ .marker = __RETURN_VALUE__ };
            c.free(old_ptr);
            env.set_user_ptr.?(env, args[0], new_ptr);
            break :blk makeInteger(raw_env, __RETURN_VALUE__);
        },
        else => makeNil(raw_env),
    };
}

export fn fixtureGetVariable(export_id: u32, raw_env: ?*c.emacs_env, data: ?*anyopaque) callconv(.c) c.emacs_value {
    _ = data;
    if (export_id != 2) return makeNil(raw_env);
    return makeInteger(raw_env, variable_value);
}

export fn fixtureSetVariable(export_id: u32, raw_env: ?*c.emacs_env, value: c.emacs_value, data: ?*anyopaque) callconv(.c) c.emacs_value {
    _ = data;

    const env = raw_env orelse unreachable;
    if (export_id == 2) {
        variable_value = @as(i64, @intCast(env.extract_integer.?(env, value)));
    }
    return value;
}

const exports = [_]ExportDescriptor{
    .{
        .export_id = 1,
        .kind = @intFromEnum(ExportKind.function),
        .lisp_name = "dyn-loader-test-call",
        .min_arity = __MIN_ARITY__,
        .max_arity = __MAX_ARITY__,
        .docstring = "Dyn-loader fixture function.",
        .flags = 0,
    },
    .{
        .export_id = 2,
        .kind = @intFromEnum(ExportKind.variable),
        .lisp_name = "dyn-loader-test-value",
        .min_arity = 0,
        .max_arity = 0,
        .docstring = "Dyn-loader fixture variable.",
        .flags = 0,
    },
    .{
        .export_id = 3,
        .kind = @intFromEnum(ExportKind.function),
        .lisp_name = "dyn-loader-test-make-object",
        .min_arity = 0,
        .max_arity = 0,
        .docstring = "Create a generation-owned fixture object.",
        .flags = 0,
    },
    .{
        .export_id = 4,
        .kind = @intFromEnum(ExportKind.function),
        .lisp_name = "dyn-loader-test-object-call",
        .min_arity = 1,
        .max_arity = 1,
        .docstring = "Call through a generation-owned fixture object.",
        .flags = 0,
    },
    .{
        .export_id = 5,
        .kind = @intFromEnum(ExportKind.function),
        .lisp_name = "dyn-loader-test-make-null-object",
        .min_arity = 0,
        .max_arity = 0,
        .docstring = "Create a generation-owned null fixture object.",
        .flags = 0,
    },
    .{
        .export_id = 6,
        .kind = @intFromEnum(ExportKind.function),
        .lisp_name = "dyn-loader-test-replace-object",
        .min_arity = 1,
        .max_arity = 1,
        .docstring = "Replace a generation-owned fixture object's pointer.",
        .flags = 0,
    },
};

export fn loader_module_init_generic(manifest: *GenericManifest) callconv(.c) void {
    manifest.* = .{
        .loader_abi = 1,
        .module_id = "dyn-loader-test",
        .module_version = "__VERSION__",
        .exports_len = exports.len,
        .exports = exports[0..].ptr,
        .invoke = &fixtureInvoke,
        .get_variable = &fixtureGetVariable,
        .set_variable = &fixtureSetVariable,
    };
}
'@

  return $template.
    Replace('__VERSION__', $Version).
    Replace('__RETURN_VALUE__', $ReturnValue.ToString()).
    Replace('__VARIABLE_VALUE__', $VariableValue.ToString()).
    Replace('__MIN_ARITY__', $MinArity.ToString()).
    Replace('__MAX_ARITY__', $MaxArity.ToString())
}

function Get-PassthroughFixtureSource {
  return @'
const c = @cImport({
    @cInclude("emacs-module.h");
});

const DispatchFn = *const fn (u32, ?*c.emacs_env, isize, [*c]c.emacs_value, ?*anyopaque) callconv(.c) c.emacs_value;
const VariableGetFn = *const fn (u32, ?*c.emacs_env, ?*anyopaque) callconv(.c) c.emacs_value;
const VariableSetFn = *const fn (u32, ?*c.emacs_env, c.emacs_value, ?*anyopaque) callconv(.c) c.emacs_value;
const ExportDescriptor = extern struct {
    export_id: u32,
    kind: u32,
    lisp_name: [*:0]const u8,
    min_arity: i32,
    max_arity: i32,
    docstring: [*:0]const u8,
    flags: u32,
};

const GenericManifest = extern struct {
    loader_abi: u32,
    module_id: [*:0]const u8,
    module_version: [*:0]const u8,
    exports_len: u32,
    exports: [*]const ExportDescriptor,
    invoke: DispatchFn,
    get_variable: VariableGetFn,
    set_variable: VariableSetFn,
};

fn makeNil(raw_env: ?*c.emacs_env) c.emacs_value {
    const env = raw_env orelse unreachable;
    return env.intern.?(env, "nil");
}

export fn fixtureInvoke(export_id: u32, raw_env: ?*c.emacs_env, nargs: isize, args: [*c]c.emacs_value, data: ?*anyopaque) callconv(.c) c.emacs_value {
    _ = data;
    if (export_id != 1 or nargs != 1) return makeNil(raw_env);
    return args[0];
}

export fn fixtureGetVariable(export_id: u32, raw_env: ?*c.emacs_env, data: ?*anyopaque) callconv(.c) c.emacs_value {
    _ = export_id;
    _ = data;
    return makeNil(raw_env);
}

export fn fixtureSetVariable(export_id: u32, raw_env: ?*c.emacs_env, value: c.emacs_value, data: ?*anyopaque) callconv(.c) c.emacs_value {
    _ = export_id;
    _ = raw_env;
    _ = data;
    return value;
}

const exports = [_]ExportDescriptor{
    .{
        .export_id = 1,
        .kind = 1,
        .lisp_name = "dyn-loader-test-pass-through",
        .min_arity = 1,
        .max_arity = 1,
        .docstring = "Return a user pointer owned by another module.",
        .flags = 0,
    },
};

export fn loader_module_init_generic(manifest: *GenericManifest) callconv(.c) void {
    manifest.* = .{
        .loader_abi = 1,
        .module_id = "dyn-loader-passthrough",
        .module_version = "1.0",
        .exports_len = exports.len,
        .exports = exports[0..].ptr,
        .invoke = &fixtureInvoke,
        .get_variable = &fixtureGetVariable,
        .set_variable = &fixtureSetVariable,
    };
}
'@
}

function Build-Fixture([string]$Name, [string]$Version, [int]$ReturnValue, [int]$VariableValue, [int]$MinArity, [int]$MaxArity) {
  $extension = Get-ModuleExtension
  $sourcePath = Join-Path $OutputDir "$Name.zig"
  $outputPath = Join-Path $OutputDir "$Name$extension"
  $emitArg = "-femit-bin=$outputPath"

  Set-Content -Path $sourcePath -Value (Get-FixtureSource -Version $Version -ReturnValue $ReturnValue -VariableValue $VariableValue -MinArity $MinArity -MaxArity $MaxArity) -Encoding utf8NoBOM

  $command = @(
    'zig', 'build-lib',
    '-dynamic',
    '-O', 'ReleaseSafe',
    '-fstrip',
    '-lc',
    '-I', $IncludeDir
  ) + (Get-TargetArgs) + @(
    $sourcePath,
    $emitArg
  )

  & $command[0] $command[1..($command.Length - 1)]
  if ($LASTEXITCODE -ne 0) {
    throw "failed to build dyn-loader fixture $Name"
  }

  return $outputPath
}

function Build-PassthroughFixture {
  $extension = Get-ModuleExtension
  $sourcePath = Join-Path $OutputDir 'fixture-passthrough.zig'
  $outputPath = Join-Path $OutputDir "fixture-passthrough$extension"
  $emitArg = "-femit-bin=$outputPath"

  Set-Content -Path $sourcePath -Value (Get-PassthroughFixtureSource) -Encoding utf8NoBOM

  $command = @(
    'zig', 'build-lib',
    '-dynamic',
    '-O', 'ReleaseSafe',
    '-fstrip',
    '-lc',
    '-I', $IncludeDir
  ) + (Get-TargetArgs) + @(
    $sourcePath,
    $emitArg
  )

  & $command[0] $command[1..($command.Length - 1)]
  if ($LASTEXITCODE -ne 0) {
    throw 'failed to build dyn-loader passthrough fixture'
  }

  return $outputPath
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$v1Path = Build-Fixture -Name 'fixture-v1' -Version '1.0' -ReturnValue 1 -VariableValue 10 -MinArity 0 -MaxArity 0
$v2Path = Build-Fixture -Name 'fixture-v2' -Version '2.0' -ReturnValue 2 -VariableValue 20 -MinArity 0 -MaxArity 0
$v3Path = Build-Fixture -Name 'fixture-v3' -Version '3.0' -ReturnValue 3 -VariableValue 30 -MinArity 1 -MaxArity 1
$passthroughPath = Build-PassthroughFixture

$livePath = Join-Path $OutputDir ("fixture-live" + (Get-ModuleExtension))
Copy-Item -Path $v1Path -Destination $livePath -Force

$manifestPath = Join-Path $OutputDir 'fixture-manifest.json'
@{
  loader_abi = 1
  module_path = $livePath
} | ConvertTo-Json -Compress | Set-Content -Path $manifestPath -Encoding utf8NoBOM

$passthroughManifestPath = Join-Path $OutputDir 'fixture-passthrough-manifest.json'
@{
  loader_abi = 1
  module_path = $passthroughPath
} | ConvertTo-Json -Compress | Set-Content -Path $passthroughManifestPath -Encoding utf8NoBOM
