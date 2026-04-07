# dyn-loader

`dyn-loader` exists in this repo to make Emacs native module development less
disruptive: it can reload a target module into the current Emacs session
without restarting Emacs.

At runtime it:

- reads a small JSON manifest that points at the target module
- validates the module's published loader ABI against the loader
- republishes the module's exported Lisp functions and variables into the
  current Emacs session

This lets you rebuild a native module, load it again through `dyn-loader`, and
continue testing from the same Emacs instance.

## Building

Run the standalone package build from this directory:

```sh
zig build -Doptimize=ReleaseFast
```

Useful local checks:

```sh
zig build check
zig build test
```

The build installs `dyn-loader-module` to `zig-out/bin/` with the
platform-appropriate shared-library extension (`.dll`, `.dylib`, or `.so`).

## Emacs header resolution

By default, the standalone build uses the repo's vendored header at
`../../include/emacs-module.h`.

You can override that when needed:

- `EMACS_INCLUDE_DIR=/path/to/include` to use an existing directory that
  already contains `emacs-module.h`
- `EMACS_SOURCE_DIR=/path/to/emacs` to generate `emacs-module.h` from an Emacs
  source checkout

If both variables are set, `EMACS_INCLUDE_DIR` wins.

## Loader manifest

`dyn-loader-load-manifest` expects JSON like:

```json
{"loader_abi":1,"module_path":"sample-module.dll"}
```

`module_path` may be absolute or relative to the manifest file.
