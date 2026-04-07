# emacs-util-mods

Shared infrastructure for Emacs dynamic modules built with Zig.

This repository is a small monorepo for native modules that share the same
Emacs module header handling, build conventions, and release packaging.

## Layout

- `build.zig` - root build entrypoint and shared Emacs header resolution helpers
- `include/emacs-module.h` - vendored fallback header used when no local Emacs
  headers are configured
- `src/dyn-loader/` - cross-platform dynamic loader module package
- `src/conpty/` - Windows-only ConPTY helper module package
- `test/support/` - shared test helper area for cross-module fixtures and helpers

## Building

The root build keeps shared options in one place and aggregates the module
packages that are valid for the selected target.

- `zig build` - build the modules supported by the current target
- `zig build check` - compile-check the root build logic and supported modules
- `zig build test` - run root build-script tests and supported module tests

`dyn-loader` is always available. `conpty` is only wired into the root build
when the selected target OS is Windows.

Emacs header resolution matches Ghostel:

1. `EMACS_INCLUDE_DIR`
2. `EMACS_SOURCE_DIR`
3. vendored `include/emacs-module.h`

If `EMACS_SOURCE_DIR` is set, the root build script generates `emacs-module.h`
from the upstream Emacs module fragments.

## Release model

Each module owns its implementation, tests, and module-specific build details
under `src/<module>/`, while the repo root owns shared header resolution,
common build entrypoints, and top-level release documentation.

Release artifacts are produced per module, with the root build remaining the
single entrypoint for local validation and multi-module release automation.

The release base version lives in `VERSION`. Published release versions use the
format `<base>.<run_number>.<sha7>`, with tags created as
`v<base>.<run_number>.<sha7>`. Release assets are uploaded directly as raw
module binaries (`.so` / `.dll`) per build matrix entry.
