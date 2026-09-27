# .NET: known plugin issues

Workarounds live in `dotnet.lua`. Found on Windows with easy-dotnet.nvim
(checkout of 2026-09-15); not reported upstream.

## easy-dotnet's neotest adapter finds no test files

- **Symptom:** `<Leader>T` shows no .NET tests; neotest runs nothing.
- **Cause:** the test runner reports files with forward slashes, neotest asks
  with backslashes, and `is_test_file` compares them as strings
  (`vim.fn.resolve` does not change separators).
- **Workaround:** the adapter is asked with forward slashes, and the tree it
  returns is handed back with the platform's own; neotest merges trees by path
  prefix, and a forward-slash file under a backslash directory crashes that.

## Tests are only discovered at startup, and only sometimes

- **Symptom:** the runner knows the solution but no projects or tests under it.
- **Cause:** projects and tests come from the runner's `quick_discover`, which
  only easy-dotnet's startup calls, and only when a solution is already selected
  for the editor's directory then. The neotest adapter only calls
  `initialize`.
- **Workaround:** `quick_discover` runs once when the adapter finds no projects.

## One run that never completes blocks all later runs

- **Symptom:** a .NET test run stays "running" forever, and every later run
  waits behind it until Neovim restarts.
- **Cause:** runs are queued one at a time, and each waits for its root node's
  final status with no timeout; a run for a node the server does not know (one
  started before discovery) never gets one.
- **Workaround:** none directly; discovering first keeps runs from starting that
  early.

## Which Roslyn runs depends on what is installed

- **What happens:** easy-dotnet's wrapper runs the `roslyn-language-server`
  global tool, falling back to whatever `roslyn-language-server` is on the PATH
  (Mason's `bin` comes first in Neovim) when the tool is missing, and installs
  the tool when started from a shell without it.
- **Now:** only the global tool is installed, pinned to `5.12.0-1.26475.2`
  from the Azure DevOps feed (easy-dotnet's README names it). nuget.org is
  behind that feed, and a plain `--prerelease` update from the feed picks a
  `-test` build, since `1-test` sorts above `1`; update with an explicit
  `--version`.

## Unrelated, but it looked like one: Razor markup in Brixter

Razor markup had no answers because Roslyn could not load the project: the
repo's `StaticAssets.targets` errors on stale, gitignored `.razor.css` files
whose `.scss` was deleted. Deleting those fixed it; the rule itself is a hard
`<Error>` in IDE builds too.
