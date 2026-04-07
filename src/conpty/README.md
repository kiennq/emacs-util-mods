# conpty

`conpty` is the Windows-specific shim used in this repo to make Windows console
shells look like the PTY-style backend that the Emacs side expects. It wraps
Windows ConPTY behind the existing native-module entry points, so Emacs can
start a shell, write input, read pending output, resize the terminal, check
liveness, and terminate the child process through one consistent interface.

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

The standalone package build installs `bin/conpty-module.dll`.

## Emacs header selection

`build.zig` resolves `emacs-module.h` in this order:

1. `EMACS_INCLUDE_DIR`
2. `EMACS_SOURCE_DIR` (generates the header from the Emacs source tree)
3. `../../include/emacs-module.h`

This preserves the header-override behavior for this repo while keeping the
module self-contained under `src/conpty/`.
