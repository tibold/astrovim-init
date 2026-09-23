-- AstroCommunity: import any community modules here
-- We import this file in `lazy_setup.lua` before the `plugins/` folder.
-- This guarantees that the specs are processed before any user plugins.

---@type LazySpec
return {
  "AstroNvim/astrocommunity",
  { import = "astrocommunity.pack.lua" },
  -- import/override with your plugins folder
  { import = "astrocommunity.pack.typescript-all-in-one" },
  { import = "astrocommunity.pack.html-css" },
  { import = "astrocommunity.pack.python" },
  { import = "astrocommunity.pack.bash" },
  { import = "astrocommunity.pack.json" },
  { import = "astrocommunity.pack.yaml" },
  { import = "astrocommunity.pack.markdown" },
  { import = "astrocommunity.pack.docker" },
  { import = "astrocommunity.pack.ps1" },
  { import = "astrocommunity.pack.nushell" },

  -- Database client. Connections live in `lua/plugins/dadbod.lua`; note that
  -- dadbod drives the vendor CLI, so postgres needs `psql` and sqlite needs
  -- `sqlite3` on PATH. This pack adds the `:DBUI` lazy triggers and the
  -- blink.cmp source that completes table and column names in sql buffers,
  -- none of which the bare plugin list this replaces had.
  { import = "astrocommunity.pack.full-dadbod" },
  { import = "astrocommunity.pack.sql" },

  -- NOTE: deliberately NOT `astrocommunity.pack.cs`. That pack sets up
  -- `csharp_ls` and csharpls-extended-lsp, which would run alongside the
  -- roslyn.nvim server configured in `lua/plugins/roslyn.lua` and fight it for
  -- the same buffers. C# support lives in that file instead.

  -- Neither of these touches C# or razor. prettierd is registered as a none-ls
  -- source through mason-null-ls (this config has no conform.nvim, so the
  -- pack's `optional = true` conform block is skipped), and it is wired only
  -- for the js/ts/css/html/json/yaml/markdown family. `eslint` is a language
  -- server that attaches to javascript and typescript buffers alone.
  { import = "astrocommunity.pack.prettier" },
  { import = "astrocommunity.pack.eslint" },

  -- Review diffs, branch ranges and file history in-editor. gitsigns covers
  -- the hunk-level view in the gutter; this covers everything larger.
  { import = "astrocommunity.git.diffview-nvim" },

  -- Project-wide find and replace. The snacks picker finds but cannot replace.
  { import = "astrocommunity.search.grug-far-nvim" },

  -- A list view over `vim.diagnostic` (plus quickfix, loclist and LSP
  -- references). Note that roslyn is configured for `openFiles` diagnostic
  -- scope, so its workspace view reaches open buffers only.
  { import = "astrocommunity.diagnostics.trouble-nvim" },

  -- Pins the enclosing class/method header to the top of the window, which is
  -- what makes long C# files navigable.
  { import = "astrocommunity.editing-support.nvim-treesitter-context" },

  -- Operate on the delimiters around the cursor: `cs"'`, `ds(`, `ysiw]`, and
  -- `S<div>` over a visual selection.
  { import = "astrocommunity.motion.nvim-surround" },

  -- `s` plus two characters labels every match on screen; press a label to
  -- jump. This takes over `s` and `S` in normal and visual mode, which in
  -- stock vim are synonyms for `cl` and `cc`.
  { import = "astrocommunity.motion.flash-nvim" },
}
