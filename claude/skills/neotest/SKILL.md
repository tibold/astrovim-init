---
name: neotest
description: Use when Neovim is attached ($NVIM set) and the human mentions failing tests, a test run, or asks why a test fails — read the results of the run they just did in neotest instead of running the suite again — or when you need to run tests yourself (after a fix, to check a change, to debug one test). Covers the `tests` and `run_tests` actions on the `drive` tool.
---

# The human's last test run

The human runs tests through neotest, under `<Leader>T`: a summary pane with
the test tree, and an output panel. When they say "the tests are failing" or
"why does this one fail", they have usually just run them there. Read that run
rather than running the suite yourself: it is instant, it is exactly what they
saw, and a slow suite is not run twice.

```json
{ "action": "tests" }
```

## Reading the reply

- `ran: false` — nothing has run since the editor started. Ask them to run the
  tests (or run them yourself with the project's test command) instead of
  concluding anything.
- `running: true` — a run is still going. `counts.pending` says how many are
  left; call again shortly, or read what has already finished.
- `counts` — passed, failed, skipped and pending, for tests only (files and
  modules are not counted again).
- `failures` — each with `name`, `id` (the full path, such as
  `tests::greets_politely`), `file`, `line`, and:
  - `errors` — messages the adapter tied to a line, 1-based. Often the
    assertion itself.
  - `output` — the test's own output, colour codes removed. Only the last 30
    lines unless `detail: "full"`, since panics and assertion values come last;
    `output_truncated` says when lines were dropped.
  - `output_file` — the complete output on disk. Read it when the trimmed
    output is not enough.

The first 10 failures come back; `detail: "full"` gives all of them.

`adapter` and `started` say which run this is. It is the **last** run only, and
a run of a single test replaces a run of the whole suite — if the human is
asking about a failure that is not in the list, their last run was probably
narrower than the question.

## Running tests yourself

```json
{ "action": "run_tests", "args": { "path": "src/util.rs", "line": 16 } }
{ "action": "run_tests", "args": { "id": "tests::greets_politely" } }
{ "action": "run_tests", "args": { "path": "tests/" } }
{ "action": "run_tests", "args": { "last": true } }
{ "action": "run_tests", "args": { "suite": true } }
```

Runs go through the human's neotest, so they see them in the summary pane as
if they had pressed the key themselves, and **the call waits for the results
and answers like `tests`**. Prefer it to running the test command in a shell:
the human sees the run, and the answer is already parsed.

- `path` with `line` runs the test at that line; `path` alone runs the file
  or directory; `id` runs a test `tests` reported; `last` repeats the last run.
- Run the narrowest thing that answers the question. `suite` runs everything.
- `debug: true` runs it under nvim-dap. Set a breakpoint first (the `debug`
  tool). This call answers at once instead of waiting, because the run will
  stop at the breakpoint: continue with `debug` `state` (`wait: true`), step
  through, and read `tests` once the session has ended.
- A long run answers after a minute with `not_ready` and `timed_out`;
  `tests` later picks up the finished results.

## Good follow-ups

- **Show the failing test** with `show` at its `file` and `line` while you
  explain it.
- **Several failures to fix?** Put them in a quickfix list with `set_quickfix`
  so the human can step through them with `]q`.
- After a fix, rerun what failed with `run_tests { last = true }`.

## When it says neotest is not reporting

The error means either neotest has not loaded yet (it loads on first use of
`<Leader>T`), or its config lacks the consumer. The consumer is added in
`lua/plugins/neotest.lua` of this Neovim config.
