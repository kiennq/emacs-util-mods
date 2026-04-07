# dyn-loader

`dyn-loader` is an Emacs native module that loads other native modules from a
small JSON manifest, validates their published loader ABI, and registers the
exported Lisp functions and variables into the current Emacs session.

## Supported platforms

- Windows (`LoadLibraryW`)
- macOS
- Linux and other Unix-like targets with `dlopen`/`dlsym`

## Building

Run the standalone build from this directory:

```sh
zig build -Doptimize=ReleaseFast
```

Useful build steps:

```sh
zig build check
zig build test
```

The built module is installed under `zig-out/bin/` as `dyn-loader-module` with
the platform-appropriate shared-library extension.

## Emacs header resolution

By default, this package expects the repository root to provide
`include/emacs-module.h` and uses `../../include` relative to this directory.

You can override that in the same way Ghostel does:

- `EMACS_INCLUDE_DIR=/path/to/include` to use a directory that already contains
  `emacs-module.h`
- `EMACS_SOURCE_DIR=/path/to/emacs` to generate `emacs-module.h` from an Emacs
  source checkout

If both variables are set, `EMACS_INCLUDE_DIR` wins.

## Loader manifest

`dyn-loader-load-manifest` expects JSON shaped like:

```json
{"loader_abi":1,"module_path":"sample-module.dll"}
```

`module_path` may be absolute or relative to the manifest file.
