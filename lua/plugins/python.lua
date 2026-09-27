-- lua/plugins/python.lua
--
-- Local additions on top of `astrocommunity.pack.python` (imported in
-- community.lua).
return {
  {
    "mfussenegger/nvim-dap-python",
    optional = true,
    -- Replaces the pack's config, which hands dap-python
    -- `exepath("debugpy-adapter")`. On Windows that is Mason's
    -- `debugpy-adapter.CMD`, and dap-python recognises the adapter by its
    -- basename being exactly `debugpy-adapter`: it takes the .CMD for a python
    -- interpreter and appends `-m debugpy.adapter`, the adapter exits with a
    -- usage error (code 2), and no Python session ever starts. Mason's debugpy
    -- package carries its own python with debugpy installed, which is what
    -- `-m debugpy.adapter` wants.
    config = function(_, opts)
      local python = vim.fn.expand "$MASON/packages/debugpy/venv/Scripts/python.exe"
      if vim.fn.has "win32" == 0 or not vim.uv.fs_stat(python) then
        python = vim.fn.exepath "debugpy-adapter"
        if python == "" then python = vim.fn.exepath "python" end
      end
      require("dap-python").setup(python, opts)
    end,
  },
}
