---
name: quickfix
description: Use when Neovim is attached ($NVIM set) and the human refers to build errors, lint output, grep results or anything they just ran through :make or :grep — or when you have a list of places (call sites, findings, review comments, failing lines) for them to step through. Covers the `quickfix` and `set_quickfix` actions on the `drive` tool.
---

# The quickfix list

Quickfix is Neovim's list of places: `:make` fills it with compiler errors,
`:grep` with matches, and a language server's references land there too. The
human steps through it with `]q` / `[q`, or in the quickfix window or Trouble.
Two actions on `drive` reach it.

## Reading what the human ran

```json
{ "action": "quickfix" }
```

When the human says "fix these errors" or "what's wrong with the build", they
have usually just run something, and its output is sitting in quickfix. Read
it rather than running the build again: it is instant, and it is exactly what
they are looking at. Their Rust keymaps (`<Leader>rb`, `<Leader>rk`) send
`cargo build` and `cargo clippy` through `:make` into quickfix.

The reply has the list's `title` (`:make build`, `:grep foo`), `count`, a count
per `types` (error, warning, …) and `items` of `{ file, line, column, type,
text }`. Compiler notes printed under an error — rustc's `= note:` and
`= help:` lines — arrive as that item's `detail`, and output before the first
located line (`Compiling …`) as `preamble`. The first 20 items come back;
`detail: "full"` gives all of them.

`title` tells you what produced the list. If it is not what the human means —
an old grep when they are asking about the build — say so rather than working
from it. `nr` reads an older list; `lists` says how many there are.

## Handing the human a list of places

```json
{
  "action": "set_quickfix",
  "args": {
    "title": "call sites of parse_config",
    "items": [
      { "path": "src/config.rs", "line": 42, "text": "reads the env var first" },
      { "path": "src/main.rs", "line": 7, "column": 5 }
    ]
  }
}
```

Use it when you have **several places the human will want to visit**: call
sites to change, findings from a review, the lines a failing test touches.
Paths in chat have to be copied; a quickfix list is `]q` away. For a single
place, `show` is better.

- **It never replaces their list.** Each call adds a new one, titled
  `Claude: <title>`, and theirs stays one `:colder` away. Say so when their
  list mattered (a build they were working through).
- **Make `text` say why each place is on the list** — that is what they read
  while stepping through. Keep it to a line.
- `type` (`E`, `W`, `I`, `N`) is optional; use it when the entries really are
  errors or warnings.
- The quickfix window opens without taking their cursor. Pass `open: false` to
  fill the list without opening it.
- Relative paths resolve against this session's working directory.
