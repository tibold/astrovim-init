-- Session checklist panel, driven by an external agent over RPC.
-- Source lives in `nvim-checklist/` at the root of this config.

---@type LazySpec
return {
  "nvim-checklist",
  dir = vim.fn.stdpath "config" .. "/nvim-checklist",
  -- Without this lazy derives the module from the plugin name and calls
  -- require("nvim-checklist").setup, which does not exist, so setup never runs.
  main = "checklist",
  -- Registers its tool into the shared MCP surface during setup().
  dependencies = { "nvim-mcp" },
  -- Not `keys`-only: the module must be require-able when the agent calls in,
  -- even in a session where the panel was never opened.
  event = "VeryLazy",
  opts = {},
  keys = {
    { "<Leader>tc", function() require("checklist").toggle() end, desc = "Session checklist" },
  },
}
