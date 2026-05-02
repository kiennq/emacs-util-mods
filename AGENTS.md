# Copilot instructions for `emacs-util-mods`

## What this repo is

`emacs-util-mods` is a small Zig monorepo for Emacs native modules that share:

- shared Emacs header resolution logic
- shared root build entrypoints
- per-module packaging under `src/<module>/`
- shared CI/release automation

Current modules:

- `src/dyn-loader/` - cross-platform loader that can reload a target Emacs module into a live Emacs session
- `src/conpty/` - Windows-only ConPTY shim that exposes a PTY-like interface to Emacs

The root `build.zig` is the top-level orchestrator. Each module also has its own standalone `build.zig`, and the root build delegates into those module-local builds instead of rebuilding everything in one giant script.

## Build, check, test, and format commands

Run these from the repository root unless noted otherwise.

### Whole-repo commands

- Build supported modules for the current target:
  - `zig build`
- Compile-check the root build logic and supported modules:
  - `zig build check`
- Run the root build-script tests plus supported module tests:
  - `zig build test`

### Module-local commands

Standalone module builds are expected to keep working from each module directory.

- `dyn-loader`
  - `cd src/dyn-loader`
  - `zig build`
  - `zig build check`
  - `zig build test`
- `conpty`
  - `cd src/conpty`
  - `zig build`
  - `zig build check`
  - `zig build test`

You can also invoke a module build from the repo root:

- `zig build --build-file src/dyn-loader/build.zig test`
- `zig build --build-file src/conpty/build.zig test`

### Formatting

There is no separate linter configured in this repo. For Zig sources, keep touched files formatted with:

- `zig fmt build.zig src/**/*.zig`

If you only changed a few files, format just those files instead of broad rewrites.

## Architecture and code organization

### Root build

`build.zig` owns:

- the shared Emacs header resolution helpers
- the target-aware module list (`dyn-loader` always, `conpty` only on Windows)
- the top-level `install`, `check`, and `test` steps
- root-level tests for build logic

The root build uses `addSystemCommand("zig", "build", "--build-file", "build.zig", ...)` to run each module's own build script in its module directory. Preserve that pattern when extending the repo.

### Module packages

Each module package under `src/<module>/` owns:

- its Zig implementation
- its standalone `build.zig`
- its module README
- module-local tests

Do not move module-specific logic into the root build unless it is genuinely shared across multiple modules.

### Shared include handling

The header resolution order is intentional and must stay aligned with Ghostel:

1. `EMACS_INCLUDE_DIR`
2. `EMACS_SOURCE_DIR`
3. vendored `include/emacs-module.h`

If `EMACS_SOURCE_DIR` is set, the build generates `emacs-module.h` from upstream Emacs `module-env-*.h` fragments. Reuse the existing helper logic instead of adding a second resolution path.

## Codebase-specific conventions

### General

- Keep changes small and module-scoped.
- Preserve the root/module split: shared orchestration at the repo root, module behavior inside the module package.
- If you add a new module, wire it into:
  - `module_specs` in the root `build.zig`
  - its own `src/<module>/build.zig`
  - CI/release workflow matrices as needed
  - a module README

### `conpty`

- Windows only.
- Do not wire `conpty` into non-Windows root targets or non-Windows CI jobs.
- The provided Emacs feature is `conpty-module`.

### `dyn-loader`

`dyn-loader` is not just a loader; it has explicit lifecycle guarantees that tests depend on.

- Old exported function objects must stay crash-safe after unload or reload.
- Repeated unload is a no-op.
- Compatible reloads should let old function objects retarget to the new implementation.
- Incompatible reloads should surface explicit Emacs errors instead of crashing.
- Exported variables keep snapshot-style Lisp semantics.

When changing `dyn-loader`, keep the lifecycle test and fixture builder in sync:

- `test/dyn-loader-lifecycle.el`
- `test/build-dyn-loader-fixtures.ps1`

## Zig coding principles

### Error handling

- **Errors are always errors.** Never swallow with bare `catch {}` or `catch continue` unless you can prove the specific error code means "no value" (see below). Log or propagate every real error.
- **Keep Zig errors inside Zig.** Internal Zig code may use `try` and error unions, but exported Emacs module and C ABI boundaries must not expose or propagate Zig errors. Catch errors at the boundary and translate them to that boundary's contract: an explicit Emacs signal, logged `nil`/void return, C result code, or another documented value.
- **Know your error codes before mapping them.** `GHOSTTY_INVALID_VALUE` can mean either a programmer error (null handle, bad enum) or "no value configured" depending on which data key you query. Check the libghostty header comment for the specific data key before deciding.
  - `GHOSTTY_NO_VALUE` → always means "optional absence" — map to `null` via `getOpt`.
  - `GHOSTTY_INVALID_VALUE` → usually a programmer error, but some cell-level keys use it to mean "no per-cell value, use terminal default" — check the libghostty header comment for the specific key. When it means absence, use `catch |err| switch (err) { gt.Error.InvalidValue => null, else => return err }`.

### C ABI boundary (module.zig callbacks)

Functions with `callconv(.c)` cannot propagate Zig errors — handle them explicitly at the call site:

```zig
// For paths that can fail deep in the call stack (redraw, encode, emitPlacements):
something.deepWork() catch |err| {
    env.logStackTrace(@errorReturnTrace());
    env.signalErrorf("ghostel: deepWork failed: {s}", .{@errorName(err)});
    return env.nil();
};

// For simple one-call getters (getTitle, getScrollbar, getTotalRows, etc.):
const val = term.getSomething() catch |err| {
    env.signalErrorf("ghostel: getSomething failed: {s}", .{@errorName(err)});
    return env.nil();
};

// For void C callbacks (callconv(.c) returning void), use logErrorf instead of signalErrorf:
const val = term.getSomething() catch |err| {
    env.logErrorf("ghostel: getSomething failed: {s}", .{@errorName(err)});
    return;
};

// For per-item errors inside a loop where items are independent, log and continue:
const val = term.getSomething() catch |err| {
    env.logErrorf("ghostel: getSomething failed: {s}", .{@errorName(err)});
    continue;
};
```

### Accessor pattern (ghostty.zig)

All libghostty `_get` functions that follow `(obj, key, *anyopaque) -> GhosttyResult` are wrapped by `Accessor()`:

```zig
// Returns !T — propagates all errors
const val = try gt.terminal_data.get(T, obj, KEY_CONSTANT);

// Returns !?T — maps NO_VALUE to null, propagates other errors
const opt = try gt.terminal_data.getOpt(T, obj, KEY_CONSTANT);

// Writes into an existing pointer (e.g. to repopulate an iterator in-place)
try gt.kitty_graphics_data.read(obj, KEY_CONSTANT, &existing_ptr);
```

Available Accessors (see `ghostty.zig`): `terminal_data`, `row`, `cell`, `rs`, `rs_row`, `rs_row_cells`, `kitty_graphics_data`, `kitty_placement_data`.

`ghostty_terminal_mode_get` has a different signature — use `gt.terminalModeGet(terminal, mode) !bool`.

### Out-pointers

Do not add new functions with out-pointer + bool/null return patterns. Always return `!T` or `!?T`:
- Use the `Accessor` wrappers for C getter functions.
- For `_new` constructor calls (opaque object creation), the out-pointer is inherent to the C ABI — use `try gt.toError(gt.c.ghostty_X_new(null, &handle))`.

### C ABI callbacks — do not change calling convention

Any function with `callconv(.c)` is part of a fixed ABI contract with libghostty or Emacs. Do not change its signature, calling convention, or return type without understanding the ABI contract on both sides.

### Build and format workflow

After editing any `.zig` file:
1. `zig build` — must pass before moving on
2. Format via Emacs: `(with-current-buffer (find-file-noselect "/path/to/file.zig") (indent-region (point-min) (point-max)) (save-buffer))`

## Testing expectations

- `zig build test` is necessary but not sufficient for behavioral changes.
- If you touch module loading or exported feature behavior, also run the relevant Emacs batch test.
- CI currently uses:
  - Zig `0.15.2`
  - Emacs `29.4`
  - Ubuntu and Windows runners

### Generic smoke-load test

1. Build the module:
   - `zig build --build-file src/conpty/build.zig -Doptimize=ReleaseSafe install`
2. Load it in batch Emacs:
   - `emacs --batch -Q -l test/smoke-load.el -- src/conpty/zig-out/bin/conpty-module.dll conpty-module`

For `dyn-loader` on Unix, the module path uses the platform extension in `src/dyn-loader/zig-out/bin/` (`.so` on Linux, `.dylib` on macOS).

### `dyn-loader` lifecycle test

This is the deeper integration test for unload/reload safety.

1. Build the loader module:
   - `zig build --build-file src/dyn-loader/build.zig -Doptimize=ReleaseSafe install`
2. Build fixture modules:
   - `pwsh -File test/build-dyn-loader-fixtures.ps1 -OutputDir <tmp-dir>`
3. Run the Emacs lifecycle test:
   - `emacs --batch -Q -l test/dyn-loader-lifecycle.el -- <module-path> <manifest-path> <live-path> <v2-path> <v3-path>`

The PowerShell fixture builder emits a manifest plus three test module versions used to verify unload, compatible reload, and incompatible reload behavior.

## Release conventions

Release behavior is defined in `.github/workflows/release.yml`.

- Base version lives in `VERSION`.
- Published release version format:
  - `<base>.<run_number>.<sha7>`
- Release tag format:
  - `v<base>.<run_number>.<sha7>`
- Release assets are uploaded as raw module binaries, not zip files.
- Asset names include architecture, for example:
  - `dyn-loader-module-x86_64.so`
  - `conpty-module-x86_64.dll`

When touching release logic, preserve the current assumptions:

- `push` releases only trigger from `main` when `VERSION` changes
- weekly scheduled releases skip if nothing changed since the latest tag
- matrix entries publish independently to the same release shell

## Existing repo documentation to follow

Prefer the repo's existing docs before inventing new behavior:

- `README.md` for top-level layout, header resolution, and release model
- `src/dyn-loader/README.md` for loader purpose and manifest format
- `src/conpty/README.md` for the Windows PTY shim contract
