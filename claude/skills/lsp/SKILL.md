---
name: lsp
description: Use when Neovim is attached ($NVIM set) and you need what a language server knows — where something is defined, every reference or caller, a symbol's type or docs, a file's outline — or want to rename a symbol, apply a quick fix or refactor, or format a file. Covers the editor's `lsp` and `lsp_edit` tools, when they beat grep, and how their edits behave.
---

# Language servers through the human's Neovim

The editor is already running language servers for the files in front of the
human: warm, indexed, configured the way they see them. Two tools reach them:
**`lsp`** for lookups, which change nothing, and **`lsp_edit`** for renames,
code actions and formatting, which change files. They are separate so the
human can allow lookups and still be asked about edits. Prefer them to Claude
Code's own `LSP` tool, which starts a second, cold copy of each server; use
that only when no Neovim is attached.

## When LSP, when grep

- **LSP for meaning:** where a symbol is defined, every real reference to it,
  who calls a function, what type something has, what implements an
  interface. Grep cannot tell a reference from a same-named local, a comment
  or a string.
- **Grep for text:** strings, comments, config keys, log messages, and files
  no server understands.
- **Renames go through `rename`,** not search-and-replace with Edit. The
  server knows scoping, shadowing, overloads and every file involved.

## Pointing at a symbol

Every positioned action takes `path`, `line` and **`symbol` — the word at that
spot**. The column is found for you; do not count columns from Read output.
If the word appears more than once on the line, the error says so and
`column` (1-based characters) picks one. If it is not there, the error lists
the words that are. A relative `path` resolves against this session's working
directory, not the editor's.

```json
{ "action": "references", "args": { "path": "src/config.rs", "line": 42, "symbol": "parse_config" } }
```

That is a call to the `lsp` tool. Calling an action through the other tool is
refused, and the error names the right one.

## The actions

| tool | action | args beyond the position | answers |
|---|---|---|---|
| `lsp` | `definition` | — | locations `{ file, line, column, text }` |
| `lsp` | `references` | — | `count`, `by_file`, first 20 `locations`, `truncated` |
| `lsp` | `hover` | — | `text` (markdown) |
| `lsp` | `implementation` | — | locations |
| `lsp` | `calls` | `direction: incoming\|outgoing` | `calls: [{ name, file, line, sites }]` |
| `lsp` | `symbols` | `path` **or** `query` instead of a position | `symbols: [{ name, file, line }]` |
| `lsp` | `code_actions` | `path`, `line`, `end_line?` | `actions: [{ index, title, kind, server }]` |
| `lsp_edit` | `rename` | `new_name` | `applied`, `changed: [{ file, edits }]` |
| `lsp_edit` | `code_action` | `path`, `line`, `end_line?`, `title`, `index?` | like `rename` |
| `lsp_edit` | `format` | `path`, `line?`, `end_line?` | like `rename` |

`describe` with a name gives a schema on either tool. `detail: "full"` lifts
the caps on lists. Every action takes `timeout` in seconds (default 5, max 30).

## Workflow

1. **Ask.** Any file works, open or not, including library and standard
   library sources a `definition` led to: the action loads it and waits for
   its server. Read the reply, not just the count.
2. **Cold servers are waited for.** A server still attaching or indexing is
   polled for up to a minute while the human's editor stays usable, with a
   notice saying what it is doing.
3. **Show** the interesting location with `show` on `drive` when you are
   discussing it — showing beats pasting.
4. **After an edit,** `diagnostics` again: the server's view of the result is
   the fastest check there is.

## Edits

`rename`, `code_action` and `format` are **applied and saved**: the files on
disk — what Read and Edit see — match the editor. Each touched buffer gets
one undo step. A notification records what changed.

**If any touched buffer has unsaved changes, nothing is applied** and the
reply is `{ applied: false, reason: "modified", files }`. That work is the
human's. Tell them which files, and ask them to save or discard; never try to
get around it.

Code actions: call `code_actions` on `lsp` first, then `code_action` on
`lsp_edit` with the exact `title`. The list is fetched fresh each time and matched by title, so an index
from an earlier list cannot apply the wrong fix; `index` only chooses between
duplicate titles. Some actions run a server command whose edit arrives
separately — the reply still lists what changed, and says so when nothing did.

Three other replies to recognise:

- **`reason: "client command"`** — the action runs inside the editor (a picker,
  say) and was not run. Ask the human to apply it themselves.
- **`applied: "partial"`** with `error` — applying failed partway (a buffer
  that is not modifiable, a file that could not be renamed). What landed is
  saved and listed in `changed`; tell the human the rest did not.
- **`server_error`** beside `changed` — the server failed its command after
  edits had already landed. The files listed did change.

## Reading replies

- **A reply names its `server`.** An empty list from a server that answered
  means "none found".
- **No server attached** is an error, not an empty answer. It names the
  filetype and any configured server; wait for it or tell the human.
- **Capabilities differ.** `marksman: no server here supports
  textDocument/implementation` is an answer, not a failure to retry.
- **`timed_out: true`** means the answer is partial or missing. Retry with a
  larger `timeout` only if the server was plausibly still indexing.
- **`not_ready: true`** with `status` (`Indexing: 16/21 (std)`, say) means the
  server was still loading when the wait ran out, and nothing was asked. Call
  again; it picks up where it left off. Edits always answer this way against a
  loading server rather than apply a rename computed from half an index.
- **`loading`** beside a lookup's answer means the server was still loading
  when it answered, so an empty or short list may not be the whole story.

## The human's editor waits

Requests are synchronous: while one runs, the human's Neovim does not respond,
and a small `Claude · LSP …` notice in the corner says why. Most answer in
milliseconds. Use the actions as freely as you need; this is a known trade,
and if it bites, the fix belongs in the bridge rather than in fewer calls.
