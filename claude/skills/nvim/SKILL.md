---
name: nvim
description: Use when the human is working in Neovim and you want to show them code rather than describe it, open a file at a line while they keep typing, read language server diagnostics without running a build, choose between several editor instances, or mirror your working plan into their checklist panel. Covers the `drive` MCP tool's actions and when each is worth using.
---

# Driving the human's Neovim

Everything here goes through one tool, `drive`, with an `action` and `args`.

The tool lists only the commonly used actions. Others are registered but not
listed, because every listed name costs context in every session whether or not
it is used. Reach them with `search`, which matches on name *and* description and
returns schemas, so a hit is immediately callable:

```json
{ "action": "search", "args": { "query": "unsaved buffers" } }
```

`describe` with a name returns one schema; with no name it returns the full
roster, hidden actions included. Between them nothing below has to be memorised —
this skill covers *when* each listed action is worth using, not its arguments.

The point is not file management. It is that **showing beats explaining**. When
a question is about code, put the code on their screen at the line under
discussion rather than pasting an excerpt into chat or describing it in prose.
Do this while talking, not instead of talking.

## Which instance

`action: "instances"` lists every Neovim serving an RPC address on this machine,
each with its working directory and open files, and marks the one hosting this
session as `host: true`.

You rarely need it. Omitting `instance` targets the host, which is the right
editor whenever Claude Code is running in one of its terminal buffers — the
normal case. Reach for `instances` only when the human is working across several
worktrees and the file in question lives in a different one. **The mapping from
address to worktree changes every session, so never hardcode it.** Opening a
file in the wrong editor is confusing.

## Showing code

```json
{ "action": "show", "args": { "path": "D:\\source\\thing\\Thing.cs", "line": 42 } }
```

Two fields in the reply are worth reading:

- `focus_kept` must be `true`. Claude Code runs in a terminal buffer, so editing
  the current window would push the conversation out of view. `show` picks a
  window holding an ordinary file, or an unnamed scratch, and edits it from the
  outside so the cursor never leaves the terminal they are typing in.
- `created_window` says whether a split had to be made. Reusing is normal.

Sidebars are never taken, because they carry buffer names.

`show` is non-destructive; use it freely once the instance is right.

## Diagnostics without a build

```json
{ "action": "diagnostics" }
{ "action": "diagnostics", "detail": "full" }
```

`detail` defaults to `summary`: counts per file, the first ten findings, and a
`truncated` flag. A large solution can produce hundreds, and reading them all
costs more than the answer is worth mid-debug. Ask for `full` once you know
which file you care about. `detail` works on any action — it shapes the reply,
not the request.

**An empty result is ambiguous**, and this is the trap. It means equally
"nothing is wrong" and "nothing is watching". The reply carries `clients` and, in
summary form, `unattached` — the open files no language server is watching. Both
survive summarising precisely because they are what tell the two cases apart.
Read them before believing a clean result.

A server does not attach the instant a file opens — Roslyn loads the solution
first, which can take well over a minute from cold while reporting the file
clean however broken it is. If your file appears in
`unattached`, the answer is "not watched yet", not "fine".

This is worth having because a build cannot always run. It is not a substitute
for one: it sees open buffers, not the solution.

`mcp__ide__getDiagnostics` reaches the same findings in one call but reports no
attachment information, so it cannot distinguish the empty cases.

## The checklist panel

Claude Code's built-in todo display was removed because it bloated context. This
replaces it outside the context window: the human sees your plan in a panel
beside their code, and it costs you nothing to keep there.

```json
{ "action": "checklist_update", "args": { "ops": [
  { "op": "set", "id": "nodes", "group": "RKE2", "text": "Provision nodes", "state": "done" },
  { "op": "set", "id": "dns", "text": "DNS cutover", "state": "blocked", "note": "vendor TTL" }
] } }
```

**Write-only.** The human reads it; you never read it back and never report on
it. It is a courtesy display, not a source of truth. Reading it back would
reintroduce exactly the context cost that removing the todo display was meant to
avoid.

Batch every change for a turn into **one** call.

| op | effect |
| --- | --- |
| `set` | Upsert by `id`. Merges: send only the fields that changed |
| `drop` | Remove one item by `id` |
| `clear` | Empty it — use when starting a new task |
| `sweep` | Drop completed items, keeping todo and blocked |

- `id` is a stable slug you choose, matching `[a-z0-9_-]`. Re-`set`ting the same
  id updates that item rather than creating a second one, which is what makes a
  retried turn harmless.
- `text` is required when the id is new; `state` defaults to `todo`.
- `note` says what a blocker is waiting on, and nothing else.
- `group` is a short workstream name, reused exactly across items.

Ops apply in order and the whole array applies or none of it does, so a payload
with one bad op changes nothing. Insertion order is meaningful: groups render in
first-appearance order, not alphabetically.

## Closing a buffer

```json
{ "action": "close", "args": { "path": "..." } }
```

Refuses a modified buffer and reports `reason: "modified"` — unsaved work is
theirs. It also rescues any window showing the buffer first, because deleting it
otherwise closes every such window and takes their layout with it.

## Safety

- Interrogate before acting. `state` or `instances` first, then decide.
- **Never send keystrokes**, and never close or reload a buffer without asking.
  The human is often mid-edit and unsaved state is theirs.
- `state` reports `modified` for that reason: when a file has unsaved changes,
  what is on disk is not what they are looking at, and reading the file misleads.
- If the tool reports no Neovim, say so once and carry on. It is a convenience,
  not something to retry or reason about.
