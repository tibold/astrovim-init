# Rust: known plugin issues

Workarounds live in `rust.lua`. Not reported upstream.

## rustaceanvim + neotest: no tests on first open

- **Symptom:** a Rust file shows no tests until it is saved; neotest's log says
  `Couldn't find positions ... assertion failed`.
- **Cause:** neotest discovers a file's tests as soon as it loads, before
  rust-analyzer has attached or indexed. rustaceanvim gets no runnables, calls
  `parse_tree({})`, and neotest caches "no tests" until the next save.
- **Workaround:** when rust-analyzer reports itself loaded (`on_initialized`),
  and for Rust files opened after that (on attach), neotest re-discovers the
  file through its private `_update_positions`, the call its own save handler
  makes.

## rustaceanvim: debug configurations only for the current buffer

- **Symptom:** no `Cargo: ...` debug configurations when rust-analyzer finished
  loading while another window (Claude's terminal, say) had focus.
- **Cause:** `add_dap_debuggables` asks rust-analyzer for the runnables of
  buffer `0`, the current buffer.
- **Workaround:** the same refresh loads the debuggables with each Rust buffer
  made current (`nvim_buf_call`).

Drop them once rustaceanvim re-discovers when rust-analyzer turns ready, and
asks for debuggables per Rust buffer.
