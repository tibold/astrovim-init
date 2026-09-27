---
name: debug
description: Use when Neovim is attached ($NVIM set) and the human is debugging — stopped at a breakpoint, asking what a variable holds, why execution went somewhere, or wants to step through code — or when a bug is easier to find by watching the program than by reading it. Covers the `debug` tool (nvim-dap): state, inspect, stepping, starting and stopping sessions, breakpoints.
---

# Debugging with the human

The `debug` tool drives the human's nvim-dap session: the same session they see
in dap-ui, with the same breakpoints and watches. When they are stopped
somewhere and ask about it, read `state` rather than asking them to paste
variables.

## Reading where it is

```json
{ "action": "state" }
```

- `session: false` — no session. The reply lists plain `configurations` and
  `computed` ones, which work something out when they start — a virtualenv's
  python, or a prompt for the human. `ended.exit_code` says how the last one
  ended (null when the adapter gave none).
- `running: true` — the program is running, not stopped. Use `pause`, or wait
  for a breakpoint with `continue`.
- Stopped: `stopped.reason` (breakpoint, step, exception — with `text` for an
  exception), `location` with the source line, `stack` (top 10 frames,
  `stack_more` counts the rest), `scopes` with the **current frame's locals**
  one level deep, the human's dap-ui `watches` evaluated, and `breakpoints`.

Other scopes (statics, globals, registers) are named with a `ref`, not fetched.

## Looking further

```json
{ "action": "inspect", "args": { "expression": "names.len() > 1" } }
{ "action": "inspect", "args": { "ref": 1078, "depth": 2 } }
{ "action": "inspect", "args": { "frame": 3 } }
```

- `expression` — evaluated in the current frame, or in `frame`. **It runs in
  the program**: a call can change state. The human has accepted that; still,
  prefer reading to calling when either answers the question.
- `ref` — expand a variable with children (a `Vec`, a struct) from `state` or
  an earlier `inspect`. Refs are only good until the program moves: after a
  step, take them from the new `state`.
- `frame` — another frame's locals, by its `index` in `stack`.
- `depth` — levels to expand, 1 to 3. Values over 200 characters come back cut,
  marked `cut: true`; expand them by ref instead.

## Moving

`continue`, `step_over`, `step_into`, `step_out` and `pause` each **wait for the
next stop and answer with the new `state`** — one call, not a call and a poll.
If the program runs past the wait (60 s), the reply is the current state with
`running: true`; `state` with `wait: true` waits again for the next stop or
end — or, with no session yet, for one to start and stop (debugging a test
with `run_tests`, which builds it first). When the program ends, the reply has `session: false` and `ended`.

Say what you are doing when you move the program: the human is watching their
editor jump.

## Starting and stopping

```json
{ "action": "start", "args": { "name": "Cargo: build --package demo --bin demo --message-format=json " } }
{ "action": "stop" }
```

`start` takes a name exactly as `state` lists it under `configurations` (the
Rust ones come from rust-analyzer and build before they run; names can end in
a space). It waits for the first stop, so set breakpoints first or it may run
to the end.

- Configurations that debug "the current file" (`${file}` — Python's `file`,
  Node's launch) get `file`; without it, the file in the human's window is
  used. Claude's own terminal never is.
- `start` refuses a `computed` configuration that would ask the human for
  something (a program path, a process to attach to, easy-dotnet's profile
  picker). Ask the human to start those, then drive the session they started
  — or launch it yourself with `config`.
- `config` takes a whole DAP configuration instead of a name, for a launch
  nothing listed covers. For .NET, build first (`dotnet build`), then:

  ```json
  { "action": "start", "args": { "config": { "type": "coreclr", "program": "src/App/bin/Debug/net10.0/App.dll", "cwd": "src/App" } } }
  ```

  `type` must be an adapter nvim-dap knows (`coreclr` is netcoredbg). Add
  `env` as needed, e.g. `ASPNETCORE_ENVIRONMENT` for a web app.

## Breakpoints

```json
{ "action": "breakpoint", "args": { "path": "src/main.rs", "line": 42, "condition": "id == 7" } }
{ "action": "breakpoint", "args": { "path": "src/main.rs", "line": 42, "clear": true } }
```

`condition`, `hit_condition` (`"5"`, `">= 3"`) and `log_message` (a logpoint:
logs `{expr}` instead of stopping) are optional. Breakpoints go to the running
session at once. The ones Claude set are marked `by_claude` in every list —
clear them when you are done with them, and leave the human's alone.

## A good loop

1. Set a breakpoint where the behaviour first looks wrong, `start` or
   `continue`.
2. Read `state`: the locals usually answer the question.
3. `inspect` what they do not show; `step_over` / `step_into` to watch it
   change.
4. `show` (on `drive`) is not needed for the current line — nvim-dap already
   jumps there — but is useful for pointing at a caller in the stack.
5. Clear your breakpoints and `stop` (or `continue` to the end) when done.
