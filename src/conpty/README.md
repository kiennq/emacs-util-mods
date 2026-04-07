# conpty

Windows ConPTY backend for an Emacs native module package.

- **Platform:** Windows only
- **Provided feature:** `conpty-module`
- **Entry points:** `conpty--init`, `conpty--is-alive`, `conpty--kill`, `conpty--read-pending`, `conpty--resize`, `conpty--write`

## Build

From `src/conpty/`:

```powershell
zig build
zig build check
zig build test
```

The default install step emits `bin/conpty-module.dll`.

## Emacs header selection

`build.zig` looks for `emacs-module.h` in this order:

1. `EMACS_INCLUDE_DIR`
2. `EMACS_SOURCE_DIR` (generates the header from the Emacs source tree)
3. `../../include/emacs-module.h`

This matches the Ghostel override behavior while keeping the module self-contained under `src/conpty/`.
