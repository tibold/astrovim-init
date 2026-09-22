# nvim-checklist

A panel that displays a checklist written by an external agent process. The agent pushes
state; you read it. Nothing round-trips back into the agent's context.

Claude Code's built-in todo display was removed because it bloated context. A file-based
checklist would put the list back in the context budget the moment the agent re-read it,
and leave artifacts in the repo. This is an in-memory buffer, write-only from the agent's
side.

## Status

Complete. Nothing to install: the plugin registers a `checklist_update` tool with
[`nvim-mcp`](../nvim-mcp), so Claude drives the panel with no wrapper on `PATH`, no
`CLAUDE.md` boilerplate and no entry in `~/.claude.json`.

## Usage

`<Leader>tc` toggles the panel. It splits below neo-tree when the explorer is open, and
opens its own left split when it is not.

An update arriving while the panel is closed surfaces it, but **never takes your cursor** —
it appears beside you while you keep typing. Set `auto_open = false` to make the panel
appear only when you ask for it.

A checklist left over from the last session is restored and reopened when nvim starts
(`open_on_startup`). An empty checklist is never worth a window, so clearing the list
closes the panel, and a cleared list leaves nothing for the next startup to restore.

| Command | Action |
| --- | --- |
| `:ChecklistToggle` | Show or hide the panel |
| `:ChecklistClear` | Clear the checklist and close the panel |
| `:ChecklistSweep` | Drop completed items |

```lua
require("checklist").set("certmgr", { text = "cert-manager ClusterIssuer", group = "RKE2" })
require("checklist").set("certmgr", { state = "done" })
require("checklist").sweep()
```

### Panel keymaps

| Key | Action |
| --- | --- |
| `q` | Close the panel |
| `<CR>` | Toggle the item under the cursor between todo and done |
| `d` | Drop the item under the cursor |
| `S` | Sweep completed items |
| `C` | Clear the checklist, with a confirm |
| `gy` | Yank the checklist as markdown |

### Configuration

```lua
{
  icons = "nerd",        -- "nerd" | "ascii"
  height = 15,           -- split height below neo-tree
  width = 50,            -- split width when neo-tree is absent
  focus_on_open = false, -- move the cursor into the panel on open
  auto_open = true,      -- surface the panel when an agent update arrives
  open_on_startup = true,-- reopen a restored checklist when nvim starts
  store = "state",       -- "state" | "repo"
  max_age = 86400,       -- discard state older than this; 0 disables expiry
  debounce = 2000,       -- ms between a mutation and the save it triggers
}
```

## Transport

`checklist.load(path)` is the only externally reachable entry point. It reads a JSON
payload from a file, validates it in full, applies it all-or-nothing, and re-renders.
It returns `1` or `0`, never throws, and never reports anything to the user.

An external driver reaches it through the address in `$NVIM`, which Neovim sets for its
terminal children:

```lua
local ch = vim.fn.sockconnect("pipe", vim.env.NVIM, { rpc = true })
vim.rpcrequest(ch, "nvim_exec_lua", 'return require("checklist").load(...)', { payload_path })
```

Run that through `nvim -l`, not `nvim --server --remote-expr`. Measured on Windows:
**87 ms versus 1098 ms**, and `--remote-expr` additionally returns terminal escape
sequences on stdout rather than the expression result. `sockconnect` fails fast when
nothing is listening, so the no-editor case costs the same 86 ms and needs no probing.

Pass the payload as a **file path**, not as JSON on the command line — JSON containing a
Windows path loses a backslash level in transit.

## Ops

```json
{ "ops": [
  { "op": "set", "id": "nodes", "group": "RKE2", "text": "Provision nodes", "state": "done" },
  { "op": "set", "id": "dns", "text": "DNS cutover", "state": "blocked", "note": "vendor TTL" },
  { "op": "drop", "id": "old" },
  { "op": "sweep" },
  { "op": "clear" }
] }
```

`set` upserts by `id` and merges only the fields supplied; an explicit `null` clears a
field. `id` is a stable slug matching `[a-z0-9_-]{1,64}`. `state` is `todo`, `done` or
`blocked`. `text` is capped at 120 characters, `group` at 60, `note` at 80 — oversized
values are truncated, not rejected, and control whitespace collapses to a space because
a checklist item is a single line.

Ops apply in array order, and the whole array applies or none of it does. A payload
containing one unrecognised op changes nothing.

Insertion order is preserved and meaningful — re-`set`ting an existing id never reorders
it, and groups render in first-appearance order rather than alphabetically.

## Persistence

State is saved to `stdpath("state")/checklist/<sha256(realpath(git_root))[:16]>.json`,
outside the repo, so there is nothing to gitignore and nothing to commit by accident.
Saves are debounced; `VimLeavePre` flushes synchronously. State is restored at startup
when `open_on_startup` is set, and otherwise lazily on first `load()` or first open.
State older than `max_age` is discarded rather than restored, and a corrupt file is
treated as no file.

The lazy spec must set `main = "checklist"`. Without it lazy.nvim derives the module
from the plugin directory name, calls `require("nvim-checklist").setup`, finds nothing,
and silently never runs `setup()` — which leaves the save-on-quit flush, the autocmds
and the user commands unregistered.

## Agent contract

There is no contract to install. `lua/checklist/mcp.lua` registers a tool with
[`nvim-mcp`](../nvim-mcp), and the tool's **description is** the contract — Claude
receives the rules with the tool itself, so they cannot drift apart.

Claude reaches it as `mcp__plugin_nvim_nvim__nvim (action checklist_update)`. The namespace is load-bearing:
registering with `claudecode.nvim` instead produces `mcp__ide__checklist_update`, which
Claude Code drops against a hardcoded two-item allowlist. See the nvim-mcp README.

Because the server is sideloaded onto the Claude that `claudecode.nvim` launches, the
tool exists only inside Neovim. A `claude` started from a plain terminal does not see it;
`load(path)` over `$NVIM` remains for that case.

Unlike a shell wrapper, a malformed call **raises** rather than failing silently. The
wrapper's silence covered "no editor running"; over a live tool that cannot happen, so
the only remaining failure is the agent sending something invalid, which it should learn
about rather than repeat.

## Tests

```bash
cd nvim-checklist
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua' }"
```

73 tests across state, render, window, load, startup, persistence and the MCP tool. The
suite exits non-zero on failure. `nvim-mcp` carries its own 16.
