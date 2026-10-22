# nvim-mcp

A generic MCP surface for this Neovim instance. Plugins register actions at runtime and
Claude Code drives them through five tools: `drive` for the editor, `lsp` for
language server lookups, `lsp_edit` for edits made through them, `debug` for
the debugger, and `lua` for running Lua in the editor when no action reports
what is needed.

## How it reaches Claude

```
Claude ──stdio──▶ nvim -u NONE -l claude/server.lua ──$NVIM──▶ host nvim
                  (protocol only, no state)                    require("nvim-mcp")
                                                                 .specs() .describe() .invoke()
```

The bridge ships in the Claude Code plugin at [`../claude`](../claude), registered once:

```
claude plugin marketplace add <this repo>
claude plugin install nvim@tibold-nvim
```

That writes under `~/.claude/plugins` — not into `~/.claude.json` — and delivers two
skills alongside the server: `nvim` for driving the editor, and `checklist` for the panel.
A `SessionStart` hook injects a short standing instruction to keep the checklist current,
gated on `$NVIM` so it costs nothing in a session with no editor attached. Installation is
a one-off and belongs in a dotfiles repo; this repository only *delivers* the plugin.

Installing copies `claude/` into `~/.claude/plugins/cache/tibold-nvim/nvim/<version>`,
and that copy is what `${CLAUDE_PLUGIN_ROOT}` points at. Changes to `claude/server.lua`,
the skills or the hooks therefore reach Claude Code only after bumping the version in
`claude/.claude-plugin/plugin.json` and running `claude plugin update nvim@tibold-nvim`.
Actions registered inside the editor need none of this: they are live on reload.

Claude Code spawns the bridge as a child process, so it inherits `$NVIM` and already
knows which editor to talk to. Several Neovim instances each get a bridge bound to their
own editor, with no discovery and no ambiguity. The `instances` action exists only for
the case where a *different* worktree is the target.

The bridge holds no state and knows no actions. `tools/call` is forwarded into the
editor, so an action registered at runtime is reachable without restarting either side.

### An editor waiting on the human

A request sent to an editor at a prompt — "Press ENTER", a question such as
"Overwrite existing file?" — is never answered, and `vim.rpcrequest` has no timeout:
the bridge, and every call queued behind it, would wait until Claude Code gives up half
an hour later. So the bridge never waits on the editor except through `nvim_get_mode`,
a fast API function that answers even at a prompt:

- **Before each call it asks for the mode.** At a prompt, the call fails at once and
  says which editor is waiting, at what, and that nothing was sent.
- **The call itself is an RPC notification** (`nvim_exec_lua`). Its code runs the call
  and sends the result back the same way, to the bridge's channel id, which the bridge
  learns from `nvim_get_api_info` when it connects (that function is RPC only, so the
  editor cannot ask it). Meanwhile the bridge asks for the mode about once a second;
  if the editor has stopped at a prompt, the call fails at once and says the call is
  still running there and finishes once the human answers. Its late reply is dropped.

A prompt is mode `r`, `rm` or `r?`. `blocking` alone misses questions: they report `r?`
with `blocking` false, because Neovim still services RPC while it asks. `blocking` in
any other mode is a command the human is typing — `f` waiting for its character, `"`
its register, `m` its mark, `<C-w>` or a mapping its next key — which holds every call
until that key comes. The bridge waits up to 3 s for it, then fails the call saying a
command is half typed (before sending, nothing was sent; after, the call is queued
behind it).
`instances` lists an announced editor found at a prompt as `prompt: true`, beside `busy`.

An error raised by the call in the editor fails that call only; the channel stays up.
A `tools/list` made while the hosting editor cannot be asked says so in each tool's
description, and the bridge sends `notifications/tools/list_changed` once a call
reaches that editor again.
Design: `../docs/superpowers/specs/2026-10-10-bridge-prompts-design.md`.

### Sideload fallback

`nvim-mcp.config` generates an `--mcp-config` file pointing at the same bridge, for
driving the editor before the plugin is installed:

```lua
opts.terminal_cmd = require("nvim-mcp.config").claude_cmd()  -- in claudecode.nvim's spec
```

Do not run both: two registrations of one server name collide. Note the `=` in
`--mcp-config=<path>` — the flag takes a variable number of paths, so a space-separated
value swallows the rest of the command line.

## A few advertised tools, not one per action

A tool definition costs roughly **600 tokens of permanent context**, measured with Claude
Code's own `/context`. Six typed tools would be ~2,200 tokens in every session. One
dispatcher taking an `action` costs ~456, regardless of how many actions exist.

| shape | cost |
| --- | --- |
| six typed tools | ~2200 tok |
| dispatcher, names **and** one-line blurbs | ~817 tok |
| **dispatcher, names only** | **~456 tok** |
| `tool_search` + `tools_call` (the telemetry servers' split) | 500 tok, constant |

Three things follow from those numbers.

**Blurbs are not worth their weight.** A one-line description per action reads nicely and
costs ~70 characters each of permanent context, while duplicating the `nvim` skill, which
explains every action properly and loads only when relevant. Names alone are enough to
know what exists; `describe` supplies meaning and schema on demand.

**The action list is built from the live registry**, not hardcoded. A static list would go
stale the moment a plugin registered an action, which is the thing this server exists to
allow. The list is a snapshot taken at `tools/list` time, so an action registered later in
the session will not be in it — `describe` with no name returns everything currently
registered, which is the discovery path for exactly that case.

**Both, split by frequency.** Listed names cost context in every session; a `search` costs
a round trip per use. Neither is right for every action, so which one an action gets is a
property of the action:

```lua
require("nvim-mcp").register {
  name = "rotate_gaskets",
  hidden = true,                       -- callable, not advertised
  description = "Rotate the widget gaskets.",
  ...
}
```

A frequently used action earns its ~12 characters in the names line. Something reached
once a month does not, and `search` finds it by name or description and returns its
schema, so a hit is immediately callable. That is the same split Claude Code applies to
its own tools: a few loaded, the rest behind a search.

The advertised surface therefore stays flat as the long tail grows, and `describe` with no
name returns the full roster — hidden actions included — for when you want to see
everything at once.

### Where a second tool is worth its cost

Two things a dispatcher cannot do justify splitting it, and each split is by what the
actions *are*, never one tool per action.

**Permissions.** Claude Code matches an MCP permission rule on the tool name, never on its
arguments. On one tool, allowing `hover` allows `rename`, which edits and saves files
across the workspace without passing through Claude Code's own Edit. So lookups and edits
sit on separate tools, `lsp` and `lsp_edit`, and a rule can allow one and still ask for
the other.

**The name is what gets read.** With tool search on, Claude Code defers MCP tools and shows
only their names until one is loaded. Then the per-tool cost above mostly disappears, and
`drive` says nothing about finding references. Claude Code's own `LSP` tool does, and it
starts a cold second copy of every server. A tool called `lsp` next to it puts the right
choice in view. The `SessionStart` hook adds a line saying so.

An action names its tool when it registers, `drive` by default:

```lua
require("nvim-mcp").register { name = "rename", tool = "lsp_edit", ... }
```

Which tools exist is fixed in the bridge, since a tool is what a permission rule names and
should change only with a plugin release; their action lists still come from the live
registry. Calling an action through a tool it is not on is refused, so an edit cannot be
reached through a tool allowed for lookups. `describe` and `search` report each action's
tool.

### Why not claudecode.nvim's tool registry

It has a public `register()`, and registering there works — but Claude Code drops every
`mcp__ide__*` tool that is not on a hardcoded two-item allowlist:

```js
var ys = ["mcp__ide__executeCode", "mcp__ide__getDiagnostics"];
function Bo(e) { return !e.startsWith("mcp__ide__") || ys.includes(e); }
```

That is why claudecode.nvim's own `openFile` and `openDiff` are advertised and still not
callable. The predicate only guards that prefix, so a separately named server is never
examined.

## Registering an action

```lua
require("nvim-mcp").register {
  name = "my_action",                    -- [a-zA-Z][a-zA-Z0-9_]*
  description = "One line. Detail belongs in a skill.",
  inputSchema = {
    type = "object",
    properties = { thing = { type = "string" } },
    required = { "thing" },
  },
  handler = function(args)
    return { some = "data" }             -- string, data table, or { content = { ... } }
  end,
}
```

A handler may return a string, a data table (encoded as JSON for the reply), or MCP
content it builds itself. Re-registering a name replaces it, so reloading a plugin does
not duplicate actions. A handler that throws is caught and reported as a tool error; it
cannot take the bridge down. `error { code = -32602, message = "..." }` sets the
JSON-RPC error explicitly.

Actions are listed in registration order rather than hash order, so the surface is stable
between sessions.

## Built-in actions

| action | does |
| --- | --- |
| `show` | Put a file on screen at a line, without taking the cursor |
| `state` | Working directory, the file and cursor in view, unsaved buffers |
| `diagnostics` | Language server findings, plus what is attached |

A `detail` argument on the tool shapes the reply rather than the request:
`summary` (the default) returns counts per file, the first ten findings and a
`truncated` flag; `full` returns everything. The attachment signal survives
summarising, since without it an empty result cannot be told from an unwatched
one. Handlers receive it as a second parameter, `handler(args, opts)`, so an
action that does not care can ignore it.

The idea is borrowed from the telemetry MCP servers' `tools_call`, which pairs
`detail: summary|full` with a `tool_search`. That two-tool split is the right
shape once the action list outgrows a description — call it 12-15 actions. Below
that, inlining the names here costs about the same and saves a round trip on
every first use.
| `project` | Open a directory as a project in its own tab (`:tcd`), keeping the human's tab on screen |
| `close` | Remove a buffer; refuses when it holds unsaved work |
| `identify` | This instance's working directory and open files |
| `quickfix` | The current quickfix list (or an older one), notes folded under their error |
| `set_quickfix` | Hand the human a list of places as a new `Claude: …` list |
| `tests` | The last neotest run: counts, and failures with file, line, errors, output |
| `run_tests` | Run a file, the test at a line, an id, the suite or the last run in neotest; waits for results |

These are ported from the `driving-neovim` skill's `drive.lua`, which reached the editor
through a Bash round trip costing ~160 tokens per call.

`tests` reads neotest through a consumer, the only way neotest hands out its
client: `require("nvim-mcp.neotest").consumer` goes in neotest's `consumers`
(this config does that in `lua/plugins/neotest.lua`). It records each run from
neotest's own listeners, so the action reads a snapshot and never calls into
neotest's async client.

## Debug actions

`nvim-mcp.debug` registers the `debug` tool over nvim-dap: `state`, `inspect`,
`continue`, `step_over`, `step_into`, `step_out`, `pause`, `start`, `stop` and
`breakpoint`. The `debug` skill in `../claude/skills/debug` explains each.

- **`state` stays small.** Only the current frame's locals are expanded, one
  level deep, values cut at 200 characters; other scopes (statics, globals,
  registers) and other frames come back as refs and indexes for `inspect`.
  Adapters disagree on which scopes are "expensive", so that flag alone does
  not keep a stop's reply small.
- **Controls wait in the bridge.** A control replies `{ poll = { action =
  "state", args = { after = n } } }`, where `n` counts stops and ends seen by
  nvim-dap listeners. The bridge switches to polling `state`, which is
  `not_ready` until the count moves, so the editor stays usable while the
  program runs.
- **`inspect` evaluates in the "watch" context**, which every adapter treats
  as an expression; codelldb reads "repl" input as LLDB commands. Side effects
  happen, by agreement.
- **Configurations that prompt are not started.** Any function-valued field
  (mason-nvim-dap's `program = function() return vim.fn.input(...) end`)
  would leave the human facing a prompt they did not ask for.
- **Breakpoints Claude sets are marked `by_claude`** and sent to every
  session at once.

## LSP actions

`nvim-mcp.lsp` registers the editor's language servers as actions:
`definition`, `references`, `hover`, `implementation`, `symbols`, `calls` and
`code_actions` on the `lsp` tool; `rename`, `code_action` and `format` on
`lsp_edit`. Each tool lists all of its actions. The `lsp` skill in
`../claude/skills/lsp` explains when to use each.

- **Addressing** is `{ path, line, symbol }`; the column is found from the
  symbol, converted to the server's position encoding.
- **Requests are synchronous**, with `timeout` (default 5 s, max 30 s). The
  editor waits while one runs, so a floating `Claude · LSP …` notice is drawn
  with an explicit redraw — immediately for edits, after 300 ms for lookups.
  If the wait ever matters, slow requests move to bridge-side polling, as
  `wait_for` does; the action interface stays the same.
- **A server still loading is waited for in the bridge.** An attached server
  that has not finished indexing answers with nothing, which reads as "none
  found", so the action replies `not_ready` instead of asking, and the bridge
  polls for up to a minute with the editor responsive. Readiness is
  rust-analyzer's `experimental/serverStatus` when it sends one, otherwise
  `$/progress` settling. A buffer an action has just loaded is given time for
  a server to attach when some config names its filetype, which covers
  rustaceanvim, whose attach waits on `cargo metadata`. The last attempt runs
  lookups anyway, marked `loading`; edits refuse. `ContentModified` counts as
  not ready.
- **Edits are applied and saved, all or nothing.** A touched buffer with
  unsaved changes refuses the whole edit, and so does a touched file another
  running editor has unsaved work in, found from its swap file (`reason:
  "swap file"`). A swap file a crashed Neovim left is deleted once the edit
  has saved its file (`deleted_swaps`). No action asks about a swap file when
  it opens a file. A code action's reply carries what every edit it applied
  reports — `changed`, `failed`, `deleted_swaps` — including the edits before
  one that was refused. Buffers an edit had to open are named natively
  (capital drive, whatever the server's uri said) and unlisted again once
  saved; one left unsaved stays listed, where the human can find it. Edits a
  server sends back while running a command
  (`workspace/applyEdit`) are captured and follow the same rules. A file the
  edit itself creates over an existing one is read again before its text edits
  land.
- **Edits are computed from what is on disk.** Before an edit asks its server,
  every loaded, unmodified buffer whose file changed behind it is reloaded, and
  the server is sent the new text (`reloaded` in the reply, once, even when the
  bridge had to retry). A server asked first answers for the old text, and its
  edit lands at the wrong columns. A rewrite with the same text is no change. A
  buffer Neovim took for a new file whose file has since appeared is read with
  `:edit!`, since `:checktime` would ask; a swap file a crashed session left is
  answered "edit anyway" and kept. A touched buffer that changes while the
  server computes — reloaded, or edited and saved by another call — refuses the
  edit (`reason: "changed on disk"`). A file whose stat has not moved since it
  was last found current is not looked at again. Implemented in
  `nvim-mcp.lsp.disk`.
- **Saving never asks.** `'confirm'` is off while an edit writes, so a refusal
  (a readonly buffer, a file that appeared) is an error, and a file changed
  since the edit began is not overwritten; either way the file is listed in
  `failed`, its buffer holding the edit unsaved, and the reply is
  `applied: "partial"`. A save Windows refuses with E212 while another process
  has the file memory-mapped (git hashing a file over 32 KiB, a scanner) is
  retried for about 1.5 seconds first.

Design: `../docs/superpowers/specs/2026-09-27-lsp-actions-design.md`.

## Tests

```bash
cd nvim-mcp
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"
```

260 tests covering registration, validation, ordering, invocation, hidden actions,
the tool each action is on, readiness, quickfix, neotest results, debugging, search, the ported editor actions, config generation, and the LSP actions against
an in-process fake language server (`tests/fake_lsp.lua`), and the bridge driven
over real JSON-RPC (`tests/bridge_spec.lua`).
The protocol itself is verified by driving the bridge with real JSON-RPC and by a real
`claude` session, rather than mocked.

Prompts need a UI: without one, Neovim answers its own questions with their
default and never shows "Press ENTER". `tests/target.lua` starts an editor of the
test's own in a pseudo-terminal, so it runs the real TUI, and drives it over RPC;
`bridge_prompt_spec.lua` and part of `lsp_disk_spec.lua` use it. The bridge in
tests runs with `NVIM_MCP_SCAN=0`, so `instances` probes only editors the test
announced, in records of its own under `NVIM_MCP_INSTANCES` (none without it),
and never the human's own. Test editors keep their swap files in a directory
of their own, not the human's.

Those run on Windows, so the unix half of `claude/server.lua` needs its own harness:

```bash
podman build -t nvim-mcp-test -f nvim-mcp/tests/integration/Containerfile .
podman run --rm nvim-mcp-test
MSYS_NO_PATHCONV=1 podman run --rm -e XDG_RUNTIME_DIR=/run/user/0 nvim-mcp-test
```

Both invocations matter, because Neovim's socket layout depends on whether
`XDG_RUNTIME_DIR` is set. See `nvim-mcp/tests/integration/README.md`, which records
the four discovery bugs this found — three of which meant `instances` had never
worked on *either* platform.
