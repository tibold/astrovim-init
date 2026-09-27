# Testbeds

One small project per platform, for checking that debugging and tests work in
this Neovim config — and through Claude's `debug`, `tests` and `run_tests`
actions — after a plugin update or a config change.

Each has the same shape: a `greet` and a `total_length` (`totalLength`), a
program that loops over three names (somewhere to put a breakpoint and step),
and three tests, **one of which fails on purpose** so that failure reporting
is checked too.

| platform | tests | debugger | set up once |
|---|---|---|---|
| `rust/` | neotest via rustaceanvim | codelldb via rustaceanvim | — |
| `python/` | neotest-python (pytest) | debugpy via nvim-dap-python | `python -m venv .venv` then `.venv\Scripts\python -m pip install pytest` |
| `node/` | neotest-jest | js-debug-adapter (`pwa-node`), configurations in `lua/plugins/node.lua` | `npm install` |
| `dotnet/` | easy-dotnet's neotest adapter (xUnit, bUnit) | netcoredbg, bundled with easy-dotnet | `dotnet tool install -g EasyDotnet`; easy-dotnet installs the `roslyn-language-server` tool itself |

The .NET testbed is a solution, since Blazor is part of what has to work:
`Testbed.Core` (the library) with `Testbed.Core.Tests` (xUnit), `Testbed.Cli`
(the loop), and `Testbed.Web`, a Blazor Web App whose `Greeting.razor` keeps
its logic in `@code`, with `Testbed.Web.Tests` rendering it through bUnit.
Beyond tests and debugging, check that C# and `.razor` files both get language
server answers, and that a breakpoint in `@code` stops when the page renders.

## The check

Open the project's directory in Neovim (`:cd testbeds/rust`), then:

1. **Tests.** Run the file's tests (`<Leader>T`, or ask Claude to `run_tests`
   the test file). Expect 2 passed, 1 failed, with the failure's assertion
   and output. Then run just the test at one line.
2. **Debugging.** Put a breakpoint on the line that builds a greeting inside
   the loop in the program, and start the debugger (Claude: `start` with the
   configuration `state` lists). Expect a stop there with `name` and the
   collection in the locals; `step_over`, `continue` to the next pass, clear
   the breakpoint and run to the end with exit code 0.
3. **Debugging a test.** Set a breakpoint in a test and run it with
   `debug: true`; the session stops inside the test.

## Asking Claude

> Run the testbed check for rust.

Claude drives the same editor through its tools, so every step shows up on
screen as it happens.
