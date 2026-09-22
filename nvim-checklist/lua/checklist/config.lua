--- Configuration defaults and the live merged options table.
local M = {}

M.defaults = {
  icons = "nerd", -- "nerd" | "ascii"
  -- 1 or less is a fraction of the screen, above 1 is an absolute count.
  height = 0.3, -- split height when placed below neo-tree
  width = 50, -- split width when neo-tree is absent
  focus_on_open = false, -- move the cursor into the panel on open
  auto_open = true, -- surface the panel when an agent update arrives
  open_on_startup = true, -- reopen a restored checklist when nvim starts
  store = "state", -- "state" | "repo"
  max_age = 86400, -- seconds; 0 disables expiry
  debounce = 2000, -- ms between a mutation and the save it triggers
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts) M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {}) end

return M
