-- lua/plugins/sqls.lua
--
-- astrocommunity.pack.sql asks mason for sqls, whose upstream package builds
-- from source and fails without a C compiler. Putting our own registry first
-- makes mason install the release binary instead (see lua/mason-local/sqls.lua).
-- Inserted rather than listed so it lands ahead of the mason-org registry
-- AstroNvim appends, whichever order the opts are merged in.

---@type LazySpec
return {
  "mason-org/mason.nvim",
  opts = function(_, opts)
    opts.registries = opts.registries or {}
    if not vim.tbl_contains(opts.registries, "lua:mason-local") then
      table.insert(opts.registries, 1, "lua:mason-local")
    end
  end,
}
