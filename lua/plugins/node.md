# Node: known plugin issues

Workarounds live in `node.lua`. All found on Windows; not reported upstream.

## neotest-jest: never finds the local jest

- **Symptom:** every jest test fails with `ENOENT`.
- **Cause:** its path helpers (`util.lua`, `dirname`) split on `/` only, so the
  upward search for `node_modules/.bin/jest` never gets anywhere on Windows and
  it falls back to a bare `jest`, which is not on PATH.
- **Workaround:** `jestCommand` finds the package's own `jest.cmd`.

## neotest-jest: its test file pattern matches nothing

- **Symptom:** jest runs, reports `Pattern: C:\/Users\/... - 0 matches`.
- **Cause:** it appends the absolute test path, escaped as a regex, as jest's
  test path pattern; jest on Windows never matches a drive-letter pattern.
- **Workaround:** `jestCommand` also adds the file relative to the package, with
  forward slashes; jest ORs patterns, so the broken one is harmless. `cwd` is
  the package, not the editor's directory.

## deno-nvim: placeholder `pwa-node` adapter

- **Symptom:** every Node debug session starts a bare `node` that exits at once
  (code 0).
- **Cause:** deno-nvim (in astrocommunity's typescript all-in-one pack)
  registers `pwa-node` as `node` with no arguments, meant to be filled in with
  js-debug's path, whenever no adapter exists yet, and it runs before
  mason-nvim-dap.
- **Workaround:** `node.lua` defines `pwa-node` as js-debug's
  `dapDebugServer.js` when nvim-dap loads; deno-nvim leaves an existing adapter
  alone.

Drop the workarounds once neotest-jest handles Windows paths and deno-nvim stops
installing an unconfigured adapter.
