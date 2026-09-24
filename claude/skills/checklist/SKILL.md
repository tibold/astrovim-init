---
name: checklist
description: Use as soon as any work or discussion is under way, and again on every turn that changes what is open — mirror the state of the conversation into the human's Neovim checklist panel so they can see what is agreed, in progress, finished, blocked or deferred without reading back through the transcript. Covers the update contract, grouping, deferring, and when to clear.
---

# The checklist panel

The human has a panel beside their code showing the shape of the conversation.
You write to it; they read it. Claude Code's built-in todo display was removed
because it bloated context — this puts the same information *outside* the
context window, where it costs you one tool call and them no scrolling.

It is not only a task list. It is the shared record of what you two have agreed,
what is still open, and what was consciously set aside. A long conversation
loses that shape fast, and the human is the one who pays for it.

All of it goes through the `drive` MCP tool:

```json
{ "action": "checklist_update", "args": { "ops": [
  { "op": "set", "id": "nodes", "group": "RKE2", "text": "Provision nodes", "state": "done" },
  { "op": "set", "id": "dns",   "group": "RKE2", "text": "DNS cutover", "state": "blocked", "note": "vendor TTL" },
  { "op": "set", "id": "smoke", "group": "Verify", "text": "Smoke test the ingress" }
] } }
```

## When to write to it

**As soon as anything is open, and on every turn that changes what is open.**

Not "once the task is big enough". If the conversation has produced something
that is not finished — work in flight, a decision not yet made, a question you
owe an answer to, something explicitly put off — it belongs in the panel.

That includes discussions with no code in them. Working through a list of
options, agreeing some and parking others, is exactly the case where the human
most needs the state written down, because nothing else in the conversation
records it.

Write the shape up front rather than one item at a time. A checklist that grows
by one line per turn tells the human nothing about how much is left.

Then update at every point their understanding would otherwise go stale:

| what happened | what to write |
| --- | --- |
| something is agreed and will be done | `set` it, `state: "todo"` |
| you start on it | `state: "inprogress"` |
| it finishes | `state: "done"` |
| it cannot proceed | `state: "blocked"` with a `note` saying what it waits on |
| they put it off | move it to the `Deferred` group — see below |
| it is genuinely abandoned | `drop` it |

Mark things `done` as you finish them, not in one sweep at the end. A panel that
only becomes accurate when the work is over was never worth writing to, and the
human is reading it while you work, not afterwards.

Keep at most one item `inprogress`. Its job is to answer "what is it doing right
now", and two of them answer nothing.

Batch everything for one turn into **one** call. Three calls in a turn is three
redraws and three round trips for the same result.

## Deferring

When the human says "not now", "later", "let's park that", or asks you to skip
something — **move it to a group called `Deferred`. Do not drop it.**

```json
{ "op": "set", "id": "neotest", "group": "Deferred", "text": "Test runner: neotest + adapter" }
```

Dropping it loses the decision. The point of the panel is that a deferred item
stays visible, so neither of you has to remember it was raised, and picking it
back up is a matter of re-`set`ting it into its real group.

Keep the `text` self-contained. "Test runner: neotest + adapter" still makes
sense in a week; "the thing we said we'd do later" does not.

## Write-only

**Never read it back, and never report on it.** Do not tell the human what their
checklist says; they are looking at it. Pulling it mid-conversation would
reintroduce exactly the context cost that removing the todo display was meant to
avoid.

There is one exception, and it is not yours to make: the `SessionStart` hook
hands you the panel's contents when a session starts, is cleared, or is
compacted. That is a single bounded push at the moment the plan would otherwise
be lost, rather than a habit of reading. When it arrives, treat it as your plan
and carry on from it — it is what you wrote, coming back to you across the gap.
Between those moments the panel is still write-only.

## Operations

| op | effect |
| --- | --- |
| `set` | Upsert by `id`. Merges, so send only the fields that changed |
| `drop` | Remove one item by `id` |
| `clear` | Empty the panel |
| `sweep` | Drop completed items, keeping `todo` and `blocked` |

Ops apply in order, and the whole array applies or none of it does: a payload
with one bad op changes nothing, so a retried turn is harmless.

## Fields

- **`id`** — a stable slug you choose, matching `[a-z0-9_-]`. Re-`set`ting the
  same id updates that item rather than adding a second one. Choose it from what
  the item *is* (`dns`, `migrate-schema`), never its position (`step-3`), so it
  survives being reordered or deferred.
- **`text`** — required when the id is new. Written for someone who has not read
  your reasoning: "Provision nodes", not "do the thing we discussed".
- **`state`** — `todo` (the default), `inprogress`, `done`, or `blocked`.
  `sweep` drops only `done`, so the other three survive it.
- **`note`** — a short qualifier, rendered on its own line beneath the item in
  the muted colour. Most often what a blocked item is waiting on. Not
  commentary, and not a place to continue the text.
- **`group`** — a short workstream name.

## Grouping

Grouping is what makes the panel readable at a glance rather than a flat wall,
so use it whenever more than one strand is in play.

- Reuse the group string **exactly**. `"RKE2"` and `"rke2"` are two headings.
- Name the workstream, not the phase: `"Ingress"`, `"Migrations"`, `"Docs"`
  rather than `"Step 1"`, `"Later"`. Phase is already visible in the states.
  `Deferred` is the one exception, because it records a decision rather than a
  phase.
- Keep them few and short. Three groups of four items reads well; eight groups
  of one do not — those are just items with extra lines between them.
- Ungrouped items render above the first heading, which makes them the right
  home for the one or two things that belong to the whole task.
- Groups appear in **first-appearance order**, not alphabetically. Put the
  strand you are working on first; mention `Deferred` last so it sinks to the
  bottom.

## Clearing

`sweep` is the everyday one: it keeps a long session readable by dropping what
is done while preserving what is not. Reach for it whenever the finished items
start outnumbering the live ones.

`clear` only when moving to genuinely unrelated work. It takes the deferred
items with it, which is usually the wrong outcome mid-session — those are the
ones most easily forgotten and least easily reconstructed. If in doubt, `sweep`
and leave `Deferred` standing.

## If there is no editor

The tool reports that no Neovim is running. Say so once and carry on with the
work — the checklist is a convenience, not something to retry, reason about, or
mention again.
