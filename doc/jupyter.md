# ink Jupyter kernel

`ink jupyter` is a Jupyter kernel built into the interpreter, alongside the
`ink lsp` language server. It lets editors with Jupyter REPL support (Zed,
JupyterLab, nteract, …) evaluate ink interactively, sharing one VM across cells
so variables persist.

The kernel speaks the Jupyter messaging protocol (v5.3) over ZeroMQ. The ZMTP
3.0 wire protocol (NULL security mechanism) is implemented directly in
`src/jupyter.zig` — there is no `libzmq` or other external dependency. HMAC
signing uses `std.crypto`; the sockets are raw TCP via libc.

## Subcommands

```bash
# Run a kernel against a Jupyter connection file (how front-ends launch it).
ink jupyter -f /path/to/connection.json

# Install a kernelspec so editors can discover the kernel.
ink jupyter install
```

`install` writes a kernelspec pointing at the current `ink` binary to:

- macOS: `~/Library/Jupyter/kernels/ink/kernel.json`
- Linux: `~/.local/share/jupyter/kernels/ink/kernel.json`

## Zed integration

Zed's REPL discovers Jupyter kernelspecs and matches them to a language by the
kernelspec's `language` field. The installed spec declares `"language": "ink"`,
which matches the `Ink` language registered by the `zed-ink` extension.

1. Build ink and make sure the binary is the one referenced by the kernelspec:
   `zig build -Doptimize=ReleaseFast`
2. Install the kernelspec: `ink jupyter install`
3. In Zed, open a `.k` file and run **repl: run** (or the REPL menu). Zed starts
   `ink jupyter -f …` and evaluates the current cell/selection.

Re-run `ink jupyter install` if you move the binary — the kernelspec stores an
absolute path to it.

## Behaviour notes

- Each cell is evaluated statement-by-statement through the same `Repl`/`VM`
  used by the CLI, so globals defined in one cell are visible in the next.
- Side-effecting output (e.g. `` `0:"hi\n" ``) is streamed as `stdout`; the
  formatted value of the last non-suppressed statement becomes the
  `execute_result`.
- ink error *values* (`!type`, `!rank`, …) are reported as Jupyter errors so the
  front-end renders them as errors rather than ordinary results.
- `is_complete_request` reports `incomplete` while a multi-line string is still
  open, so editors keep the cell open for continuation.
