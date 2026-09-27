# LSP actions for nvim-mcp

Give Claude the language servers the human's Neovim is already running —
navigation and LSP-driven edits — as nvim-mcp actions, plus an `lsp` skill that
says when to use them.

## Why

Claude Code's own `LSP` tool starts separate copies of the servers: a second
cold index (painful for Roslyn and rust-analyzer), more memory, and settings
that can differ from what the human sees. The editor's servers are already
warm and configured. Until now the only LSP data reachable through `drive` was
`diagnostics`.

Out of scope: the general `lua` tool (a separate MCP tool beside `drive`,
designed later), and non-blocking requests (see *Blocking*).

## Actions

One module, `nvim-mcp/lua/nvim-mcp/lsp.lua`, registers everything through
`require("nvim-mcp").register`, the way nvim-checklist does. Nothing changes in
the bridge.

**Advertised:** `definition`, `references`, `hover`, `rename`.
**Hidden** (found through `search`): `implementation`, `symbols`, `calls`,
`code_actions`, `code_action`, `format`.

### Addressing

Position-taking actions accept `{ path, line, symbol }`, with `column` accepted
instead of `symbol` when known. Lines and columns are 1-based, as in Read
output and the editor.

- The buffer is loaded if it is not already (`bufadd` + `bufload`), without
  showing it.
- `symbol` is matched as a whole word on that line. Not found, or found more
  than once, is an error that lists the words on the line; `column` then
  disambiguates.
- The resolved column is converted to the server's `offsetEncoding`.

### Read-only

| action | args | returns |
|---|---|---|
| `definition` | position | locations |
| `references` | position | locations grouped by file |
| `hover` | position | the hover text, as markdown |
| `implementation` | position | locations |
| `symbols` | `path` or `query` | a file's outline, or a workspace symbol search |
| `calls` | position, `direction: incoming\|outgoing` | one level of the call hierarchy |

A location is `{ file, line, column, text }`, where `text` is the trimmed
source line. `detail: "summary"` (the default) caps lists — `references`
returns counts per file and the first 20 locations with `truncated`;
`detail: "full"` returns everything, as `diagnostics` does.

### Editing

| action | args | does |
|---|---|---|
| `rename` | position, `new_name` | workspace-wide rename |
| `code_actions` | `path`, `line` (optional `end_line`) | lists what is available: `{ index, title, kind }`; changes nothing |
| `code_action` | same range, plus `title` (and optionally `index`) | applies one |
| `format` | `path` (optional `line`/`end_line`) | formats the file or range |

Every edit is **applied and saved**:

1. Collect every file the `WorkspaceEdit` touches.
2. If any of those buffers is modified, refuse the whole edit:
   `{ applied = false, reason = "modified", files = [...] }`. Nothing is
   applied, not partially. The unsaved work is the human's.
3. Otherwise apply with `vim.lsp.util.apply_workspace_edit` and `:write` each
   touched buffer (`noautocmd` is not used: format-on-save and friends are the
   human's settings and should run).
4. Reply `{ applied = true, changed = [{ file, edits }] }`.

Each touched buffer gets one undo step, so `u` reverts it; git covers the rest.

**`code_action` matches by title.** `code_actions` is a fresh request each
time; `code_action` re-requests for the same range and applies the entry whose
title matches exactly. An `index` is honoured only if the title at that index
also matches, so a list shifted by an intervening edit cannot apply the wrong
fix.

**Actions that run a command.** Some code actions carry a `command` instead of
(or as well as) an edit; the server executes it and sends the edit back as
`workspace/applyEdit`, possibly after our request returns. While `code_action`
runs, the `workspace/applyEdit` handler is wrapped so arriving edits go through
the same refuse-or-apply-and-save path, and the action waits for
`workspace/executeCommand` to complete before replying. The reply lists what
changed either way; an action that produced no edit says so rather than "ok".

## Blocking

Handlers run on Neovim's main loop and use synchronous requests
(`client:request_sync` / `vim.lsp.buf_request_sync`) with a timeout: 5 s by
default, `timeout` per call, capped at 30 s. While a request runs the human's
editor does not respond; keystrokes are queued, not lost.

This is a deliberate trade: one tool call per request, nothing to poll. If the
freeze becomes a problem in practice, the fix is to move slow requests to
bridge-side polling (as `wait_for` does), not to make calls less efficient. The
action interface stays the same either way.

On timeout the reply carries `timed_out = true` and whatever is known, as
`diagnostics` does.

## Notice

The human should always know when the editor is busy on Claude's behalf.

- Before a request is sent, a small floating window in the top-right corner
  shows e.g. `Claude · LSP rename ParseConfig → LoadConfig (rust-analyzer)…`,
  followed by an immediate `redraw`. `vim.notify` alone is not enough: a
  notifier plugin may render asynchronously, which cannot happen while the
  main loop is blocked.
- The window closes when the action returns — on success, error or timeout.
- Edits additionally leave a `vim.notify` summary afterwards, e.g.
  `Claude renamed ParseConfig → LoadConfig in 7 files`, so they are in the
  message history.
- For read-only actions the window appears only if the request is still
  pending after ~300 ms, to avoid a flash on every hover. Whether a timer can
  draw during the synchronous wait is verified in the live test; if it cannot,
  read-only actions show the notice immediately like edits.

## Errors

All failures are readable errors (`error { code, message }`) or structured
replies, never raw Lua errors:

- **No server attached** — name the filetype, and the server that would serve
  it if one is configured; suggest `diagnostics` with `wait_for`.
- **Capability missing** — e.g. `marksman has no implementation provider`.
- **Timeout** — `timed_out = true` plus what is known.
- **Symbol not on the line / ambiguous** — list the words on the line.
- **Refused edit** — `reason = "modified"` with the files.
- **No server result** — an empty list, with `clients` so an empty answer can
  be told from an unwatched file.

## The `lsp` skill

`claude/skills/lsp/SKILL.md`, beside `nvim` and `checklist`. Its description
triggers on needing a definition, callers/references, a type or docs, a rename
or a quick fix while `$NVIM` is set. Content:

- **When LSP, when grep.** LSP for anything semantic — references, callers,
  types, overloads, cross-file renames. Grep for text: strings, comments,
  config keys, files no server knows. Claude Code's own `LSP` tool only when
  no Neovim is attached.
- **Prefer `rename` to search-and-replace with Edit**; it gets scoping,
  shadowing and overloads right.
- **Workflow.** Confirm a server is attached (`diagnostics`, `wait_for` when
  cold) → look up → `show` the result when discussing it → after an edit,
  `diagnostics` again to check the outcome.
- **Reading results.** Empty from an unattached server is not "nothing found";
  capabilities vary by server; `code_actions` then `code_action` by title;
  refused edits mean the human has unsaved work — ask, never force.
- **Blocking.** Requests hold the human's editor while they run and the notice
  shows it. No advice to ration calls.

`nvim`'s skill gains a one-line pointer to `lsp`, as it has for `checklist`.

## Testing

- **Plenary**, alongside `actions_spec.lua`: a fake language server started
  with `vim.lsp.start` in the test instance (an in-process `cmd` function, as
  Neovim's own LSP tests do) answering definition, references, hover, rename,
  code actions (edit and command variants) and formatting with fixed data.
  Covers position resolution and encoding, summarising, the refuse-modified
  rule, apply-and-save, title matching, the command/applyEdit path, timeouts
  and registration (advertised vs hidden).
- **Live**, in the human's running Neovim: every action against the servers
  attached there, on a scratch file and one real project; rename and code
  actions on a throwaway branch. The notice timing question is settled here.
