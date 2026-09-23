# nvim-mcp

A generic MCP surface for this Neovim instance. Plugins register actions at runtime and
Claude Code drives them through a single tool, `mcp__plugin_nvim_editor__drive`.

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

`${CLAUDE_PLUGIN_ROOT}` resolves to this repository, not to a copy under
`~/.claude/plugins`, so edits to `claude/server.lua` are live without reinstalling.

Claude Code spawns the bridge as a child process, so it inherits `$NVIM` and already
knows which editor to talk to. Several Neovim instances each get a bridge bound to their
own editor, with no discovery and no ambiguity. The `instances` action exists only for
the case where a *different* worktree is the target.

The bridge holds no state and knows no actions. `tools/call` is forwarded into the
editor, so an action registered at runtime is reachable without restarting either side.

### Sideload fallback

`nvim-mcp.config` generates an `--mcp-config` file pointing at the same bridge, for
driving the editor before the plugin is installed:

```lua
opts.terminal_cmd = require("nvim-mcp.config").claude_cmd()  -- in claudecode.nvim's spec
```

Do not run both: two registrations of one server name collide. Note the `=` in
`--mcp-config=<path>` — the flag takes a variable number of paths, so a space-separated
value swallows the rest of the command line.

## One advertised tool, not one per action

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
| `close` | Remove a buffer; refuses when it holds unsaved work |
| `identify` | This instance's working directory and open files |

These are ported from the `driving-neovim` skill's `drive.lua`, which reached the editor
through a Bash round trip costing ~160 tokens per call.

## Tests

```bash
cd nvim-mcp
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"
```

31 tests covering registration, validation, ordering, invocation, hidden actions,
search, the ported editor actions and config generation.
The protocol itself is verified by driving the bridge with real JSON-RPC and by a real
`claude` session, rather than mocked.
