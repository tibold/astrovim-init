# Linux integration test

The plenary suites run on Windows, so the unix half of `claude/server.lua` never
executed under test. This covers it.

```sh
podman build -t nvim-mcp-test -f nvim-mcp/tests/integration/Containerfile .
podman run --rm nvim-mcp-test
MSYS_NO_PATHCONV=1 podman run --rm -e XDG_RUNTIME_DIR=/run/user/0 nvim-mcp-test
```

Run it **both** ways. Neovim chooses a different socket layout depending on
whether `XDG_RUNTIME_DIR` is set, and only one is covered per run:

| `XDG_RUNTIME_DIR` | socket |
| --- | --- |
| set | `$XDG_RUNTIME_DIR/nvim.<pid>.<n>` — flat, the directory is already private |
| unset | `/tmp/nvim.<user>/<random>/nvim.<pid>.<n>` — nested, because `/tmp` is shared |

`MSYS_NO_PATHCONV=1` matters when invoking podman from Git Bash: without it the
shell rewrites `/run/user/0` into `C:/Program Files/Git/run/user/0` before
podman ever sees it, and the run silently tests the wrong thing.

## What it found

Written after `instances` had been shipped and believed working. It was not,
on either platform:

- **Linux, `ipairs` over a nil.** `ipairs { vim.env.XDG_RUNTIME_DIR, "/tmp" }`
  stops at the first nil, so with `XDG_RUNTIME_DIR` unset — the common case —
  `/tmp` was never globbed and discovery always came back empty.
- **Linux, wrong socket layout.** The glob looked for the pre-0.10
  `<dir>/nvim*/0`, which matches nothing on a current Neovim, and did not know
  the flat and nested layouts differ.
- **Windows, wrong glob form.** `[[\\.\pipe\*]]` matches nothing at all: the
  globber reads the backslashes as escapes. The namespace has to be written
  with forward slashes.
- **Both, unbounded hang.** Once the globs were fixed, a single editor holding
  its socket open without servicing RPC hung discovery forever, because
  `vim.rpcrequest` has no timeout and a uv timer cannot interrupt a blocked
  main loop. Probing now runs in child processes with a timeout.

The last one only appeared *because* the first three were fixed — a silently
empty result had been hiding it.
