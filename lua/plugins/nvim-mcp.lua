-- Generic MCP surface for this Neovim instance. Source lives in `nvim-mcp/`
-- at the root of this config; plugins register tools into it at runtime.

---@type LazySpec
return {
  "nvim-mcp",
  dir = vim.fn.stdpath "config" .. "/nvim-mcp",
  -- Without this lazy derives the module from the directory name; it happens to
  -- match here, but being explicit is what the checklist spec learned the hard way.
  main = "nvim-mcp",
  -- Eager: the config file it writes has to exist before claudecode.nvim builds
  -- the command line that points at it.
  lazy = false,
  opts = {},
}
